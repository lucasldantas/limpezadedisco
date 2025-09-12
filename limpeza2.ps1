# ===================== Cleanup-Perfis-e-Windows.ps1 =====================
# Exclui perfis inativos (> Days) e limpa arquivos do Windows para liberar espaço
# Requer PowerShell 5.1+ e execução como Administrador

[CmdletBinding()]
param(
  [int]$Days = 30,
  [switch]$Aggressive,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- Paths & Log ---
$BasePath = 'C:\ProgramData\fixtools\Cleanup'
$null = New-Item -ItemType Directory -Force -Path $BasePath -ErrorAction SilentlyContinue
$LogPath = Join-Path $BasePath 'Cleanup_Log.txt'

function Log {
  param([string]$Msg)
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$ts] $Msg"
  Add-Content -Path $LogPath -Value $line -Encoding UTF8
  Write-Host $line
}

function Ensure-Admin {
  $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pri = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $pri.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw "Execute este script como ADMINISTRADOR."
  }
}

function Get-LoggedOnUsernames {
  $names = @()

  try {
    (Get-Process -Name explorer -IncludeUserName -ErrorAction Stop) |
      ForEach-Object {
        if ($_.UserName) {
          $u = ($_.UserName -split '\\')[-1]
          if ($u -and $names -notcontains $u) { $names += $u }
        }
      }
  } catch {}

  try {
    $quser = (quser 2>$null) -as [string[]]
    if ($quser) {
      foreach ($ln in $quser) {
        if ($ln -match '^\s*(\S+)\s') {
          $u = $Matches[1]
          if ($u -and $names -notcontains $u) { $names += $u }
        }
      }
    }
  } catch {}

  if ($env:USERNAME -and $names -notcontains $env:USERNAME) {
    $names += $env:USERNAME
  }

  return ,$names
}

function Get-LastUseLocalTime {
  param([object]$Value)
  if ($null -eq $Value) { return $null }

  try {
    if ($Value -is [datetime]) {
      if ($Value.Kind -eq [System.DateTimeKind]::Utc) {
        return $Value.ToLocalTime()
      } else {
        return $Value
      }
    }

    if ($Value -is [uint64] -or $Value -is [int64]) {
      return [DateTime]::FromFileTimeUtc([int64]$Value).ToLocalTime()
    }

    if ($Value -is [string]) {
      $dt = $null
      if ([DateTime]::TryParse($Value, [ref]$dt)) {
        if ($dt.Kind -eq [System.DateTimeKind]::Utc) {
          return $dt.ToLocalTime()
        } else {
          return $dt
        }
      }
      $u64 = $null
      if ([UInt64]::TryParse($Value, [ref]$u64)) {
        return [DateTime]::FromFileTimeUtc([int64]$u64).ToLocalTime()
      }
    }
  } catch {}

  return $null
}

function Get-DirSizeBytes {
  param([string]$Path)
  try {
    $bytes = 0
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
      ForEach-Object { $bytes += $_.Length }
    return [int64]$bytes
  } catch { return 0 }
}

function Remove-OldProfiles {
  param(
    [int]$OlderThanDays,
    [string[]]$ExcludeUsers,
    [switch]$WhatIfMode
  )

  Log "=== Varredura de perfis inativos (>${OlderThanDays} dias) ==="
  $cutoff = (Get-Date).AddDays(-$OlderThanDays)

  $toSkipNames = @(
    'All Users','Default','Default User','Public',
    'Administrador','Administrator',
    'TEMP','temp'
  ) + $ExcludeUsers

  $toSkipSids = @('S-1-5-18','S-1-5-19','S-1-5-20')

  $profiles = Get-CimInstance -ClassName Win32_UserProfile -Filter "Special = FALSE" -ErrorAction Stop

  $totalFreed = 0
  $countDel = 0

  foreach ($p in $profiles) {
    try {
      $name = if ($p.LocalPath) { Split-Path -Leaf $p.LocalPath } else { $p.SID }

      if ($p.Loaded) {
        Log "SKIP: $name (perfil carregado)"
        continue
      }

      if (-not $p.LocalPath -or -not (Test-Path -LiteralPath $p.LocalPath -PathType Container)) {
        Log "SKIP: $name (LocalPath inválido ou inexistente)"
        continue
      }

      if ($toSkipNames -contains $name) {
        Log "SKIP: $name (nome na lista de exclusão)"
        continue
      }

      foreach ($sid in $toSkipSids) {
        if ($p.SID -like "$sid*") { 
          Log "SKIP: $name (SID de serviço $($p.SID))"
          continue 2
        }
      }

      if ($p.LocalPath -notlike 'C:\Users\*') {
        Log "SKIP: $name (fora de C:\Users)"
        continue
      }

      $last = Get-LastUseLocalTime $p.LastUseTime
      if (-not $last) {
        Log "INFO: $name sem LastUseTime detectável; será tratado como antigo"
      } elseif ($last -gt $cutoff) {
        Log "SKIP: $name (último uso $($last.ToString('yyyy-MM-dd HH:mm')), recente)"
        continue
      }

      $size = Get-DirSizeBytes -Path $p.LocalPath
      $sizeGB = [Math]::Round($size/1GB, 2)

      if ($WhatIfMode) {
        Log "DRYRUN: removeria perfil '$name' (Último uso: $last; Tamanho: ${sizeGB}GB) em $($p.LocalPath)"
        $totalFreed += $size
        $countDel++
        continue
      }

      try {
        Remove-CimInstance -InputObject $p -ErrorAction Stop
        Log "OK: perfil '$name' removido (Último uso: $last; ${sizeGB}GB liberados)"
        $totalFreed += $size
        $countDel++
      } catch {
        Log "ERRO: falha ao remover perfil '$name' ($($_.Exception.Message))"
      }

    } catch {
      Log "ERRO geral no perfil '$($p.LocalPath)': $($_.Exception.Message)"
    }
  }

  Log ("Resumo perfis: {0} removidos; espaço potencial/liberado: {1:N2} GB" -f $countDel, ($totalFreed/1GB))
  return $totalFreed
}

function Clear-FolderSafe {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  $freed = 0
  try {
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
      ForEach-Object {
        try {
          $bytes = 0
          if (Test-Path -LiteralPath $_.FullName) {
            if ($_.PSIsContainer) { $bytes = Get-DirSizeBytes -Path $_.FullName } else { $bytes = $_.Length }
            Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
            $freed += $bytes
          }
        } catch {}
      }
  } catch {}
  return $freed
}

function Clean-WindowsJunk {
  param([switch]$AggressiveMode, [switch]$WhatIfMode)

  Log "=== Limpeza de arquivos do Windows ==="
  $total = 0

  # 1) Lixeira
  try {
    if ($WhatIfMode) {
      Log "DRYRUN: esvaziaria lixeiras (Recycle Bin)"
    } else {
      try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch {}
      Log "OK: Lixeiras esvaziadas"
    }
  } catch { Log "ERRO Lixeira: $($_.Exception.Message)" }

  # 2) Parar serviços
  $services = @('wuauserv','bits','dosvc')
  foreach ($svc in $services) {
    try {
      $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
      if ($s -and $s.Status -eq 'Running') {
        if ($WhatIfMode) { Log "DRYRUN: pararia serviço $svc" }
        else {
          Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
          Log "OK: serviço $svc parado"
        }
      }
    } catch {
      Log "WARN: não foi possível parar $svc ($($_.Exception.Message))"
    }
  }

  # 3) Pastas alvo
  $targets = @(
    'C:\Windows\SoftwareDistribution\Download',
    'C:\Windows\Temp',
    'C:\ProgramData\Microsoft\Windows\WER\ReportArchive',
    'C:\ProgramData\Microsoft\Windows\WER\ReportQueue',
    'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache'
  )

  foreach ($t in $targets) {
    try {
      if ($WhatIfMode) {
        Log "DRYRUN: limparia '$t'"
      } else {
        $freed = Clear-FolderSafe -Path $t
        $total += $freed
        Log ("OK: limpo '{0}' (~{1:N2} GB)" -f $t, ($freed/1GB))
      }
    } catch {
      Log "WARN: falha ao limpar '$t' ($($_.Exception.Message))"
    }
  }

  # 4) Temp de cada usuário
  try {
    Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
      $t = Join-Path $_.FullName 'AppData\Local\Temp'
      if (Test-Path -LiteralPath $t) {
        if ($WhatIfMode) {
          Log "DRYRUN: limparia Temp do usuário '$($_.Name)'"
        } else {
          $freed = Clear-FolderSafe -Path $t
          $total += $freed
          Log ("OK: Temp de {0} limpo (~{1:N2} GB)" -f $_.Name, ($freed/1GB))
        }
      }
    }
  } catch { Log "WARN: falha ao limpar Temps de usuários ($($_.Exception.Message))" }

  # 5) DISM
  try {
    if ($WhatIfMode) {
      Log "DRYRUN: executaria 'DISM /Online /Cleanup-Image /StartComponentCleanup{0}'" -f ($(if($AggressiveMode){' /ResetBase'} else {''}))
    } else {
      $args = '/Online','/Cleanup-Image','/StartComponentCleanup'
      if ($AggressiveMode) { $args += '/ResetBase' }
      Log "Executando DISM $($args -join ' ') (pode demorar)..."
      $p = Start-Process -FilePath dism.exe -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
      Log "DISM finalizado com código $($p.ExitCode)"
    }
  } catch { Log "WARN: DISM falhou ($($_.Exception.Message))" }

  # 6) Reiniciar serviços
  foreach ($svc in $services) {
    try {
      if ($WhatIfMode) { Log "DRYRUN: iniciaria serviço $svc" }
      else {
        Start-Service -Name $svc -ErrorAction SilentlyContinue
        Log "OK: serviço $svc iniciado"
      }
    } catch {
      Log "WARN: não foi possível iniciar $svc ($($_.Exception.Message))"
    }
  }

  Log ("Resumo limpeza Windows: ~{0:N2} GB removidos (estimativa parcial, exceto Lixeira/DISM)" -f ($total/1GB))
  return $total
}

# ===================== MAIN =====================
try {
  Ensure-Admin
  Log "------------------------------------------------------------"
  Log "Início da execução (Days=$Days; Aggressive=$Aggressive; DryRun=$DryRun)"

  $loggedOn = Get-LoggedOnUsernames
  if ($loggedOn.Count -gt 0) {
    Log ("Usuários logados detectados (excluídos da remoção): {0}" -f ($loggedOn -join ', '))
  }

  $freedProfiles = Remove-OldProfiles -OlderThanDays $Days -ExcludeUsers $loggedOn -WhatIfMode:$DryRun
  $freedWindows  = Clean-WindowsJunk -AggressiveMode:$Aggressive -WhatIfMode:$DryRun

  $totalFreed = $freedProfiles + $freedWindows
  Log ("TOTAL estimado liberado: ~{0:N2} GB" -f ($totalFreed/1GB))

  if ($DryRun) { Log "DRYRUN concluído: nenhuma alteração foi aplicada." }
  else { Log "Concluído com sucesso." }

} catch {
  Log "FATAL: $($_.Exception.Message)"
  throw
}
# ========================================================================
