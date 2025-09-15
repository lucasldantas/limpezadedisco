Clear-Host

$delprof = "C:\Program Files (x86)\Windows Resource Kits\Tools\delprof.exe"
$msi     = Join-Path $env:TEMP 'delprof.msi'
$url     = "https://raw.githubusercontent.com/lucasldantas/limpezadedisco/main/delprof.msi"

function Show-DiskInfo {
    $drive   = Get-PSDrive C
    $tamanho = [math]::Round(($drive.Used + $drive.Free) / 1GB, 0)
    $livre   = [math]::Round($drive.Free / 1GB, 0)

    Write-Host "Tamanho do disco: ${tamanho}GB"
    Write-Host "Espaço livre:    ${livre}GB"
    Write-Host ""
}

# Instala o delprof se não existir
if (-not (Test-Path $delprof)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
}

# Executa se existir
if (Test-Path $delprof) {
    Write-Host "===== Antes da limpeza =====" -ForegroundColor Yellow
    Show-DiskInfo

    Start-Process cmd.exe -ArgumentList '/c "C:\Program Files (x86)\Windows Resource Kits\Tools\delprof.exe" /D:30 /Q /I' -Wait -WindowStyle Hidden

    Write-Host "===== Depois da limpeza =====" -ForegroundColor Green
    Show-DiskInfo
} else {
    Write-Error 'delprof.exe não encontrado após a instalação.'
}
