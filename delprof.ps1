# Executar como Administrador

$exe = 'C:\Program Files (x86)\Windows Resource Kits\Tools\delprof.exe'
$msi = Join-Path $env:TEMP 'delprof.msi'
$url = 'https://raw.githubusercontent.com/lucasldantas/limpezadedisco/main/delprof.msi'

if (-not (Test-Path $exe)) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
  Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
}

if (Test-Path $exe) {
  & $exe /D:10 /Q /I
} else {
  Write-Error 'delprof.exe não encontrado após a instalação.'
}
