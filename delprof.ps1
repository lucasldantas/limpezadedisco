Clear-Host

$exe  = Join-Path $env:TEMP 'ADProfileCleanup.exe'
$url  = "https://raw.githubusercontent.com/lucasldantas/limpezadedisco/main/ADProfileCleanup.exe"

function Show-DiskInfo {
    $drive   = Get-PSDrive C
    $tamanho = [math]::Round(($drive.Used + $drive.Free) / 1GB, 0)
    $livre   = [math]::Round($drive.Free / 1GB, 0)

    Write-Host "Tamanho do disco: ${tamanho}GB"
    Write-Host "Espaço livre:    ${livre}GB"
    Write-Host ""
}

# Baixa o executável se não existir
if (-not (Test-Path $exe)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
}

if (Test-Path $exe) {
    Write-Host "===== Antes da limpeza =====" -ForegroundColor Yellow
    Show-DiskInfo

    Start-Process $exe -ArgumentList "30 ExcludeLocal=No" -Wait -WindowStyle Hidden

    Write-Host "===== Depois da limpeza =====" -ForegroundColor Green
    Show-DiskInfo
} else {
    Write-Error 'ADProfileCleanup.exe não encontrado após o download.'
}
