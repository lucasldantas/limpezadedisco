# ================== Remover perfis inativos (>= 30 dias) ==================
# Mantém o usuário atual e ignora perfis especiais/sistema.
# Necessário: PowerShell 5+ e privilégio de Administrador.

$Days      = 30
$Cutoff    = (Get-Date).AddDays(-$Days)
$UserRoot  = 'C:\Users'
$keepAlso  = @('TechSupport')   # Opcional: adicione nomes extras para manter, ex.: @('TechSupport','Administrador')

# Tenta descobrir o dono do Explorer (usuário realmente logado na sessão)
function Get-ActiveUsername {
    try {
        $p = Get-Process explorer -IncludeUserName -ErrorAction Stop | Select-Object -First 1
        if ($p.UserName) { return ($p.UserName -split '\\')[-1] }
    } catch {}
    # fallback para o contexto do processo atual
    return $env:USERNAME
}

$activeUser = Get-ActiveUsername
$currentProfilePath = [Environment]::GetFolderPath('UserProfile')
$currentLeaf = Split-Path -Leaf $currentProfilePath

Write-Host "Usuário atual: $activeUser (perfil: $currentProfilePath)"
Write-Host "Removendo perfis não usados desde $($Cutoff.ToString('yyyy-MM-dd HH:mm'))..." 

# Obtém perfis locais "normais" sob C:\Users (não especiais), não carregados, e antigos
$profiles = Get-CimInstance -ClassName Win32_UserProfile |
    Where-Object {
        $_.LocalPath -and
        $_.LocalPath.StartsWith($UserRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $_.Special -and
        -not $_.Loaded -and
        $_.LastUseTime -lt $Cutoff
    }

if (-not $profiles) {
    Write-Host "Nenhum perfil candidato encontrado."
    return
}

$removed = 0
foreach ($prof in $profiles) {
    try {
        $leaf = Split-Path -Leaf $prof.LocalPath

        # Pula o perfil do usuário atual e qualquer adicional em $keepAlso
        if ($leaf -ieq $currentLeaf -or $leaf -in $keepAlso) {
            Write-Host "Mantendo: $leaf (perfil atual ou marcado para manter)."
            continue
        }

        # Segurança extra: não tocar em pastas padrão conhecidas
        if ($leaf -in @('Default','Default User','Public','All Users')) {
            Write-Host "Ignorando perfil especial: $leaf"
            continue
        }

        # Remove via método da própria classe (apaga registro + pasta em C:\Users)
        $res = Invoke-CimMethod -InputObject $prof -MethodName Delete -ErrorAction Stop
        if ($res.ReturnValue -eq 0) {
            Write-Host "Removido: $leaf ($($prof.LocalPath))"
            $removed++
        } else {
            Write-Warning "Falha ao remover $leaf (ReturnValue=$($res.ReturnValue))"
        }
    } catch {
        Write-Warning "Erro ao remover $($prof.LocalPath): $($_.Exception.Message)"
    }
}

Write-Host "Concluído. Perfis removidos: $removed"
