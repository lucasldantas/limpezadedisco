<# 
.SYNOPSIS
  Limpa arquivos temporários e caches do sistema para liberar espaço sem afetar dados do usuário.

.PARAMETER KeepDays
  Idade mínima (em dias) dos arquivos temporários para exclusão. Padrão: 3.

.PARAMETER IncludeBrowserCache
  Inclui limpeza de caches de navegadores (Edge/Chrome/Brave/Firefox - somente cache). Não remove histórico/senhas.

.PARAMETER IncludeWindowsOld
  Inclui remoção da pasta C:\Windows.old (se existir). ATENÇÃO: remove a opção de rollback da atualização.

.PARAMETER ComponentCleanup
  Executa "DISM /Online /Cleanup-Image /StartComponentCleanup" (seguro, mas pode demorar).

.PARAMETER Aggressive
  Atalho que ativa IncludeBrowserCache + ComponentCleanup. NÃO inclui Windows.old (por segurança).

.PARAMETER WhatIf
  Mostra o que seria feito sem apagar nada.

.EXAMPLE
  .\Liberar-Espaco.ps1 -Aggressive -KeepDays 5 -WhatIf

.EXAMPLE
  .\Liberar-Espaco.ps1 -IncludeWindowsOld -IncludeBrowserCache
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [int]$KeepDays = 3,
  [switch]$IncludeBrowserCache,
  [switch]$IncludeWindowsOld,
  [switch]$ComponentCleanup,
  [switch]$Aggressive
)

# -------------------- Helpers --------------------
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeSpaceGB([string]$driveLetter = 'C:') {
  try {
    $d = Get-Item -LiteralPath $driveLetter
    $di = New-Object System.IO.DriveInfo($d.FullName)
    [math]::Round($di.AvailableFreeSpace/1GB,2)
  } catch { $null }
}

function Get-PathSizeBytes {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  try {
    (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
      Measure-Object Length -Sum).Sum
  } catch { 0 }
}

function Remove-ItemsOlderThan {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$Path,
    [int]$Days = 3,
    [switch]$OnlyFiles = $false
  )
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }

  $cut = (Get-Date).AddDays(-1 * $Days)
  $items = Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
           Where-Object { $_.LastWriteTime -lt $cut }

  if ($OnlyFiles) { $items = $items | Where-Object { -not $_.PSIsContainer } }

  $bytes = ($items | Where-Object { -not $_.PSIsContainer } | Measure-Object Length -Sum).Sum

  $action = "Remover itens mais antigos que $Days dias (~{0} MB)" -f ([math]::Round($bytes/1MB))
  if ($PSCmdlet.ShouldProcess($Path, $action)) {
    $items | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
  }
  return [int64]($bytes)
}

function Remove-AllChildren {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  $bytes = Get-PathSizeBytes -Path $Path
  if ($PSCmdlet.ShouldProcess($Path, "Remover conteúdo")) {
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
      Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
  }
  return [int64]($bytes)
}

# -------------------- Pré-checagens --------------------
if (-not (Test-Admin)) {
  Write-Warning "Execute este script como Administrador para limpar caches do sistema."
}

if ($Aggressive) {
  $IncludeBrowserCache = $true
  $ComponentCleanup    = $true
}

$report = @()
$startFree = Get-FreeSpaceGB 'C:\'
Write-Host ("Espaço livre inicial: {0} GB" -f $startFree) -ForegroundColor Cyan

# -------------------- Limpezas seguras --------------------

# 1) Lixeira
try {
  $before = Get-PathSizeBytes -Path "$env:SystemDrive\$Recycle.Bin"
  if ($PSCmdlet.ShouldProcess("Lixeira", "Esvaziar")) {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
  }
  $report += [pscustomobject]@{Categoria='Lixeira';RemovidoBytes=$before}
} catch {}

# 2) Temp do Windows e Temp do usuário atual (somente arquivos > KeepDays)
$report += [pscustomobject]@{Categoria='Temp Windows (arquivos antigos)'; RemovidoBytes= (Remove-ItemsOlderThan -Path $env:TEMP -Days $KeepDays -OnlyFiles) }
$report += [pscustomobject]@{Categoria='Temp Sistema (arquivos antigos)'; RemovidoBytes= (Remove-ItemsOlderThan -Path 'C:\Windows\Temp' -Days $KeepDays -OnlyFiles) }

# 3) Caches do Windows Update (SoftwareDistribution\Download)
$report += [pscustomobject]@{
  Categoria='Windows Update (Download)'
  RemovidoBytes= (Remove-AllChildren -Path 'C:\Windows\SoftwareDistribution\Download')
}

# 4) Delivery Optimization cache
$doPaths = @(
  'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache',
  'C:\Windows\SoftwareDistribution\DeliveryOptimization\Cache'
)
foreach ($p in $doPaths) {
  $report += [pscustomobject]@{
    Categoria="Delivery Optimization ($p)"
    RemovidoBytes= (Remove-AllChildren -Path $p)
  }
}

# 5) Windows Error Reporting (apenas filas/arquivos acumulados)
$werPaths = @(
  'C:\ProgramData\Microsoft\Windows\WER\ReportQueue',
  'C:\ProgramData\Microsoft\Windows\WER\ReportArchive'
)
foreach ($p in $werPaths) {
  $report += [pscustomobject]@{
    Categoria="Windows Error Reporting ($p)"
    RemovidoBytes= (Remove-AllChildren -Path $p)
  }
}

# 6) Logs antigos do Windows (somente > KeepDays)
$logDirs = @('C:\Windows\Logs','C:\Windows\Panther','C:\Windows\inf\setupapi.dev.log')
foreach ($p in $logDirs) {
  if (Test-Path -LiteralPath $p) {
    $report += [pscustomobject]@{
      Categoria="Logs ($p)"
      RemovidoBytes= (Remove-ItemsOlderThan -Path $p -Days $KeepDays)
    }
  }
}

# -------------------- Opcionais --------------------

# 7) Caches de navegador (opcional, seguro: apenas cache)
if ($IncludeBrowserCache) {
  $browserPaths = @(
    # Edge (Chromium)
    "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Cache\*",
    "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache\js",
    # Chrome
    "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Cache\*",
    "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache\js",
    # Brave
    "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Cache\*",
    # Firefox (cache2)
    "$env:APPDATA\Mozilla\Firefox\Profiles\*\cache2\*"
  )
  foreach ($glob in $browserPaths) {
    $paths = Get-ChildItem -Path $glob -Force -ErrorAction SilentlyContinue | Select-Object -Expand FullName
    foreach ($bp in $paths) {
      $bytes = Get-PathSizeBytes -Path $bp
      if ($PSCmdlet.ShouldProcess($bp, "Remover cache do navegador")) {
        Remove-Item -LiteralPath $bp -Recurse -Force -ErrorAction SilentlyContinue
      }
      $report += [pscustomobject]@{Categoria="Browser Cache ($bp)"; RemovidoBytes=$bytes}
    }
  }
}

# 8) Windows.old (opcional, pode ser grande)
if ($IncludeWindowsOld -and (Test-Path 'C:\Windows.old')) {
  $report += [pscustomobject]@{
    Categoria='Windows.old'
    RemovidoBytes= (Remove-AllChildren -Path 'C:\Windows.old')
  }
  if ($PSCmdlet.ShouldProcess('C:\Windows.old', 'Remover pasta se vazia')) {
    Remove-Item 'C:\Windows.old' -Force -Recurse -ErrorAction SilentlyContinue
  }
}

# 9) DISM Component Cleanup (seguro; não usa /ResetBase por padrão)
if ($ComponentCleanup) {
  Write-Host "Executando DISM /Online /Cleanup-Image /StartComponentCleanup ..." -ForegroundColor Yellow
  if ($PSCmdlet.ShouldProcess("DISM", "StartComponentCleanup")) {
    Start-Process -FilePath DISM.exe -ArgumentList "/Online","/Cleanup-Image","/StartComponentCleanup" -Wait -NoNewWindow
  }
  $report += [pscustomobject]@{Categoria='DISM Component Cleanup'; RemovidoBytes=[int64]0}
}

# -------------------- Resultado --------------------
$endFree = Get-FreeSpaceGB 'C:\'
$removedTotal = [math]::Round( ( ($report.RemovidoBytes | Measure-Object -Sum).Sum ) / 1GB, 2)

Write-Host ""
Write-Host "Resumo da limpeza:" -ForegroundColor Cyan
$report |
  Sort-Object { $_.RemovidoBytes } -Descending |
  ForEach-Object {
    "{0,-50} {1,15:N0} KB" -f $_.Categoria, [math]::Round(($_.RemovidoBytes/1KB))
  } | Write-Output

Write-Host ""
Write-Host ("Espaço livre antes: {0} GB" -f $startFree)
Write-Host ("Espaço livre depois: {0} GB" -f $endFree)
Write-Host ("Estimativa liberada (somatório): {0} GB" -f $removedTotal)
Write-Host ""
Write-Host "Dica: use -WhatIf para simular, ou -Aggressive para uma limpeza mais profunda (sem Windows.old)." -ForegroundColor DarkGray
