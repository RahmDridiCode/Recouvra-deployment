<#
.SYNOPSIS
  Crée/met à jour le Secret Kubernetes "recouvra-secrets" à partir de .env.docker.

.DESCRIPTION
  - Lit .env.docker (jamais versionné) ; aucune valeur sensible n'est affichée.
  - Construit MONGO_URI (identifiants encodés) pour le backend.
  - Passe par un fichier temporaire (supprimé en fin de script) plutôt que par des
    arguments de ligne de commande, qui seraient visibles dans la liste des processus.
  - Les clés optionnelles vides (SMTP_*, TWILIO_*) ne sont pas ajoutées au Secret.

.PARAMETER DryRun
  Valide la construction du Secret sans rien envoyer au cluster.
#>
[CmdletBinding()]
param(
    [string]$EnvFile,
    [string]$Namespace = 'recouvra',
    [string]$SecretName = 'recouvra-secrets',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not $EnvFile) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $EnvFile = Join-Path $scriptDir '..\.env.docker'
}

if (-not (Test-Path $EnvFile)) {
    throw "Fichier introuvable : $EnvFile. Créez-le avec : Copy-Item .env.example .env.docker (puis renseignez les valeurs)."
}
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl est introuvable dans le PATH.'
}

# Lecture de .env.docker (KEY=VALUE, commentaires et lignes vides ignorés)
$vars = @{}
foreach ($line in Get-Content -LiteralPath $EnvFile) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $key, $value = $line -split '=', 2
    $key = $key.Trim()
    $value = $value.Trim().Trim('"').Trim("'")
    if ($key) { $vars[$key] = $value }
}

$required = 'MONGO_ROOT_USER', 'MONGO_ROOT_PASSWORD', 'JWT_SECRET'
$missing = $required | Where-Object { -not $vars[$_] }
if ($missing) {
    throw "Variables obligatoires vides ou absentes dans $EnvFile : $($missing -join ', ')"
}

# Identifiants encodés pour être valides dans l'URI MongoDB
$user = [Uri]::EscapeDataString($vars['MONGO_ROOT_USER'])
$pass = [Uri]::EscapeDataString($vars['MONGO_ROOT_PASSWORD'])

$secret = [ordered]@{
    MONGO_ROOT_USER     = $vars['MONGO_ROOT_USER']
    MONGO_ROOT_PASSWORD = $vars['MONGO_ROOT_PASSWORD']
    MONGO_URI           = "mongodb://${user}:${pass}@mongodb:27017/recouvra?authSource=admin"
    JWT_SECRET          = $vars['JWT_SECRET']
}
foreach ($k in 'SMTP_USER', 'SMTP_PASS', 'TWILIO_ACCOUNT_SID', 'TWILIO_AUTH_TOKEN', 'TWILIO_PHONE_NUMBER') {
    if ($vars[$k]) { $secret[$k] = $vars[$k] }
}

if (-not $DryRun) {
    kubectl get namespace $Namespace *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Le namespace '$Namespace' n'existe pas. Créez-le d'abord : kubectl create namespace $Namespace"
    }
}

$tmp = [IO.Path]::GetTempFileName()
try {
    $content = ($secret.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
    [IO.File]::WriteAllText($tmp, $content + "`n", (New-Object Text.UTF8Encoding($false)))

    if ($DryRun) {
        kubectl create secret generic $SecretName --namespace $Namespace --from-env-file=$tmp --dry-run=client -o name
        if ($LASTEXITCODE -ne 0) { throw 'Échec de la validation du Secret.' }
        Write-Host "[DryRun] Secret valide. Clés : $($secret.Keys -join ', ')"
        return
    }

    kubectl create secret generic $SecretName --namespace $Namespace --from-env-file=$tmp --dry-run=client -o yaml |
        kubectl apply -f - | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Échec de la création du Secret.' }
    Write-Host "Secret '$SecretName' appliqué dans '$Namespace'. Clés : $($secret.Keys -join ', ')"
}
finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
