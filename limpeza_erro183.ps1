# ==================== Fix-Upgrade-183_v2.ps1 ====================
# Limpeza pós erro 183 (ERROR_ALREADY_EXISTS) na atualização Win10 -> Win11
# Executar como ADMIN

# ===== Configurações =====
$LogRoot   = "C:\ProgramData\UpdateW11\Logs"
$LogFile   = Join-Path $LogRoot "Fix-183_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$TimeStamp = Get-Date -Format 'yyyyMMdd_HHmmss'

$TargetsToDelete = @(
  "$env:SystemDrive\`$WINDOWS.~BT",
  "$env:SystemDrive\`$Windows.~WS",
  "$env:SystemDrive\`$WinREAgent",
  "$env:SystemDrive\`$GetCurrent",
  "$env:SystemDrive\ESD\Windows",
  "$env:SystemDrive\ESD",
  "$env:SystemRoot\Panther",
  "$env:SystemRoot\Logs\MoSetup"
)

$ServicesToReset = @('wuauserv','bits','cryptSvc','msiserver')

# ===== Funções =====
function Write-Log {
  param([string]$Msg)
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
  Write-Host $line
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Ensure-Admin {
  $admin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
  if (-not $admin) { Write-Host "Execute como Administrador."; exit 2 }
}

function Stop-ServicesSoft {
  param([string[]]$Names)
  foreach($n in $Names){
    try {
      Write-Log "Parando serviço ${n}..."
      Stop-Service -Name $n -Force -ErrorAction Stop
    } catch { Write-Log "Aviso ao parar ${n}: $($_.Exception.Message)" }
  }
}

function Start-ServicesSoft {
  param([string[]]$Names)
  foreach($n in $Names){
    try {
      Write-Log "Iniciando serviço ${n}..."
      Start-Service -Name $n -ErrorAction Stop
    } catch { Write-Log "Aviso ao iniciar ${n}: $($_.Exception.Message)" }
  }
}

function Remove-ItemSafe {
  param([string]$Path)
  if (Test-Path -LiteralPath $Path) {
    try {
      Write-Log "Removendo: ${Path}"
      Takeown /F "$Path" /R /D Y | Out-Null
      Icacls "$Path" /grant "*S-1-5-32-544:(OI)(CI)F" /T /C | Out-Null  # Admins Full
      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
      Write-Log "Falha removendo ${Path}: $($_.Exception.Message). Tentando renomear..."
      try {
        $bak = "${Path}_old_$TimeStamp"
        Rename-Item -LiteralPath $Path -NewName (Split-Path $bak -Leaf) -ErrorAction Stop
        Write-Log "Renomeado para: $bak"
      } catch {
        Write-Log "Falha ao renomear ${Path}: $($_.Exception.Message)"
      }
    }
  } else {
    Write-Log "Não existe: ${Path}"
  }
}

function Run-Cmd {
  param([string]$Cmd, [int]$Good0=0, [int]$Good1=0)
  Write-Log "CMD> $Cmd"
  $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $Cmd" -PassThru -Wait -WindowStyle Hidden
  Write-Log "ExitCode: $($p.ExitCode)"
  if ($p.ExitCode -ne $Good0 -and $p.ExitCode -ne $Good1) { Write-Log "Aviso: código fora do esperado." }
  return $p.ExitCode
}

function Dismount-ISOsSafe {
  Write-Log "Verificando e desmontando ISOs/mídias montadas (modo silencioso)..."

  # 1) Tenta via CIM: MSFT_DiskImage (não interativo)
  try {
    $imgs = Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName 'MSFT_DiskImage' -ErrorAction Stop |
            Where-Object { $_.Attached -eq $true -and $_.ImagePath }
    foreach($img in $imgs){
      Write-Log "Desmontando ISO (CIM): $($img.ImagePath)"
      try { Dismount-DiskImage -ImagePath $img.ImagePath -ErrorAction Stop } catch {}
    }
  } catch {
    Write-Log "CIM MSFT_DiskImage indisponível: $($_.Exception.Message)"
  }

  # 2) Ejetar CD-ROMs via COM (não interativo)
  try {
    $cdroms = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=5" -ErrorAction Stop
    foreach($d in $cdroms){
      $drive = $d.DeviceID  # ex: 'E:'
      Write-Log "Ejetando mídia: $drive"
      try {
        $shell = New-Object -ComObject Shell.Application
        $shell.Namespace(17).ParseName($drive).InvokeVerb('Eject') | Out-Null
      } catch {
        # 3) Fallback: remover ponto de montagem
        Run-Cmd ("mountvol {0}\ /d" -f $drive.TrimEnd(':')) | Out-Null
      }
    }
  } catch {
    Write-Log "Falha ao enumerar CD-ROMs: $($_.Exception.Message)"
  }
}

# ===== Execução =====
New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
Write-Log "==== Início da rotina de limpeza (erro 183) ===="

Ensure-Admin

# 0) Informação do SO
try {
  $os = Get-ComputerInfo | Select-Object WindowsProductName, OsVersion
  Write-Log "SO: $($os.WindowsProductName) ($($os.OsVersion))"
} catch { Write-Log "Não foi possível obter info do SO: $($_.Exception.Message)" }

# 1) Desmontar imagens ISO/mídias sem interações
Dismount-ISOsSafe

# 2) Parar serviços críticos
Stop-ServicesSoft -Names $ServicesToReset

# 3) Reset do Windows Update (SoftwareDistribution/Catroot2)
$SD   = "$env:SystemRoot\SoftwareDistribution"
$CR2  = "$env:SystemRoot\System32\catroot2"
if (Test-Path $SD) {
  try {
    $bak = "$SD.bak_$TimeStamp"
    Write-Log "Renomeando $SD -> $bak"
    Rename-Item $SD $bak -ErrorAction Stop
  } catch { Write-Log "Falha ao renomear SoftwareDistribution: $($_.Exception.Message)" }
}
if (Test-Path $CR2) {
  try {
    $bak = "$CR2.bak_$TimeStamp"
    Write-Log "Renomeando $CR2 -> $bak"
    Rename-Item $CR2 $bak -ErrorAction Stop
  } catch { Write-Log "Falha ao renomear catroot2: $($_.Exception.Message)" }
}

# 4) Remover pastas e logs de setup/upgrade
foreach($p in $TargetsToDelete){ Remove-ItemSafe -Path $p }

# 5) Limpar temporários
$temps = @("$env:TEMP","$env:SystemRoot\Temp")
foreach($t in $temps){
  if (Test-Path $t) {
    Write-Log "Limpando temp: $t"
    Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue | ForEach-Object {
      try { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop } catch {}
    }
  }
}

# 6) Component Store cleanup + RestoreHealth
Write-Log "Executando DISM StartComponentCleanup..."
Run-Cmd 'dism /online /cleanup-image /startcomponentcleanup' | Out-Null

Write-Log "Executando DISM RestoreHealth..."
$rc = Run-Cmd 'dism /online /cleanup-image /restorehealth'
if ($rc -ne 0) { Write-Log "DISM /RestoreHealth retornou $rc (pode haver corrupção reparável em reinicialização)." }

# 7) Verificação de integridade de sistema
Write-Log "Executando SFC /SCANNOW (pode demorar)..."
Run-Cmd 'sfc /scannow' | Out-Null

# 8) Reativar serviços
Start-ServicesSoft -Names $ServicesToReset

# 9) Recomendar reinício
Write-Log "==== Limpeza concluída. Reinicie o computador antes de tentar novamente o setup ===="
Write-Host "`n>>> Reinicie o PC e rode novamente o instalador do Windows 11 (Setup.exe). <<<`n"
exit 3010
# ==================== Fim ====================
