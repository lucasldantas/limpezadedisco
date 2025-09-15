Clear-Host

$delprof = "C:\Program Files (x86)\Windows Resource Kits\Tools\delprof.exe"
$msi = Join-Path $env:TEMP 'delprof.msi'
$url = "https://raw.githubusercontent.com/lucasldantas/limpezadedisco/main/delprof.msi"

if (-not (Test-Path $delprof)) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
  Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
}

if (Test-Path $delprof) {
  Start-Process cmd.exe -ArgumentList '/c "C:\Program Files (x86)\Windows Resource Kits\Tools\delprof.exe" /D:30 /Q /I' -Wait -WindowStyle Hidden
} else {
  Write-Error 'delprof.exe não encontrado após a instalação.'
}
