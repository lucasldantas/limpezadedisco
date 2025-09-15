# Requer: PowerShell como Administrador

$delprofExe = 'C:\Program Files (x86)\Windows Resource Kits\Tools\delprof.exe'
$msiUrl     = 'https://raw.githubusercontent.com/lucasldantas/limpezadedisco/main/delprof.msi'
$msiLocal   = Join-Path $env:TEMP 'delprof.msi'

function Ensure-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Error 'Execute este script como Administrador.'
        exit 1
    }
}

Ensure-Admin

# 1) Instalar apenas se o delprof.exe não existe
if (-not (Test-Path $delprofExe)) {
    Write-Host 'Delprof não encontrado. Baixando e instalando...'

    # Baixa o MSI para %TEMP%
    try {
        # Garante TLS mais atual
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiLocal -UseBasicParsing
    } catch {
        Write-Error "Falha ao baixar o MSI: $($_.Exception.Message)"
        exit 2
    }

    # Instala silenciosamente
    try {
        $args = "/i `"$msiLocal`" /qn /norestart"
        $p = Start-Process -FilePath msiexec.exe -ArgumentList $args -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            Write-Error "Instalação do delprof.msi retornou código $($p.ExitCode)"
            exit 3
        }
    } catch {
        Write-Error "Falha ao instalar o MSI: $($_.Exception.Message)"
        exit 4
    }
}

# 2) Valida a presença do executável
if (-not (Test-Path $delprofExe)) {
    Write-Error 'delprof.exe não encontrado após a instalação.'
    exit 5
}

# 3) Executa a limpeza: perfis não usados há 15 dias, silencioso e ignorando erros
# /D:15 = mais antigos que 15 dias
# /Q    = quiet
# /I    = ignora erros (não interrompe por confirmações)
try {
    Write-Host 'Executando limpeza de perfis não utilizados há 15 dias...'
    $proc = Start-Process -FilePath $delprofExe -ArgumentList '/D:15','/Q','/I' -Wait -PassThru
    Write-Host "Concluído. Código de saída: $($proc.ExitCode)"
    exit $proc.ExitCode
} catch {
    Write-Error "Falha ao executar o delprof: $($_.Exception.Message)"
    exit 6
}
