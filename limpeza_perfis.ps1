# ================== Remover perfis inativos (>= 30 dias) ==================
# Mantém usuário atual + TechSupport
# Necessário rodar como Administrador

$Days   = 5
$Cutoff = (Get-Date).AddDays(-$Days)
$Keep   = @("TechSupport")   # adicione aqui nomes extras para manter

# Detecta o usuário realmente logado (via explorer.exe)
function Get-ActiveUsername {
    try {
        $p = Get-Process explorer -IncludeUserName -ErrorAction Stop | Select-Object -First 1
        if ($p.UserName) { return ($p.UserName -split '\\')[-1] }
    } catch {}
    return $env:USERNAME
}
$activeUser = Get-ActiveUsername
$Keep += $activeUser   # garante que o usuário atual fique

Write-Host "Usuário atual: $activeUser"
Write-Host "Mantendo também: $($Keep -join ', ')"
Write-Host "Cortando perfis não logados desde: $($Cutoff.ToString('yyyy-MM-dd HH:mm'))"
Write-Host ""

# Obtém perfis locais válidos
$profiles = Get-CimInstance Win32_UserProfile |
    Where-Object {
        $_.LocalPath -like "C:\Users\*" -and
        -not $_.Special -and
        $_.LastUseTime -lt $Cutoff -and
        -not $_.Loaded
    }

foreach ($prof in $profiles) {
    $leaf = Split-Path -Leaf $prof.LocalPath

    if ($Keep -icontains $leaf) {
        Write-Host "Mantendo perfil: $leaf"
        continue
    }

    try {
        $res = Invoke-CimMethod -InputObject $prof -MethodName Delete -ErrorAction Stop
        if ($res.ReturnValue -eq 0) {
            Write-Host "✔ Perfil removido: $leaf (último logon: $($prof.LastUseTime))"
        } else {
            Write-Warning "Falha ao remover $leaf (ReturnValue=$($res.ReturnValue))"
        }
    } catch {
        Write-Warning ("Erro ao remover {0}: {1}" -f $leaf, $_.Exception.Message)
    }
}
