<#
.SYNOPSIS
  Met à jour UN SEUL composant (backend ou frontend) de la release Helm.

.DESCRIPTION
  - Valeurs du chart (--reset-values, jamais --reuse-values).
  - Tag du composant ciblé imposé via --set-string.
  - L'AUTRE composant est figé sur l'image et l'imagePullPolicy réellement en cours dans le cluster.
    Si son Deployment est illisible ou incomplet, le script s'arrête (aucune valeur par défaut silencieuse).
  - Rollback automatique (--rollback-on-failure), puis contrôle que l'autre composant n'a pas changé.

.PARAMETER DryRun
  Ne modifie rien : lit les Deployments, rend le chart avec "helm template", analyse les manifests
  (conversion YAML -> JSON par kubectl) et vérifie les images/pullPolicy des deux composants.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('backend', 'frontend')][string]$Component,
    [Parameter(Mandatory)][ValidatePattern('^sha-[0-9a-f]{7,40}$')][string]$Tag,
    [string]$Namespace = 'recouvra',
    [string]$Release = 'recouvra',
    [string]$Chart = 'helm/recouvra',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Lit image/pullPolicy du conteneur principal (nom = nom du Deployment). Toute anomalie -> exception.
function Get-DeploymentImage([string]$Name, $Deployment = $null) {
    if (-not $Deployment) {
        $json = kubectl get deployment $Name -n $Namespace -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $json) {
            throw "kubectl n'a pas pu lire le Deployment '$Name' (namespace '$Namespace', code $LASTEXITCODE) : Deployment absent ou cluster inaccessible. Arrêt."
        }
        $Deployment = ($json -join "`n") | ConvertFrom-Json
    }
    $c = @($Deployment.spec.template.spec.containers) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $c -or -not $c.image -or -not $c.imagePullPolicy) {
        throw "Informations incomplètes pour '$Name' (conteneur, image ou imagePullPolicy manquant). Arrêt."
    }
    if ($c.image -notmatch '^(?<repo>[^@]+):(?<tag>[^:/@]+)$') {
        throw "Image de '$Name' non gérée : '$($c.image)' (attendu <repository>:<tag>, pas de digest)."
    }
    [pscustomobject]@{ Image = $c.image; Repository = $Matches['repo']; Tag = $Matches['tag']; PullPolicy = $c.imagePullPolicy }
}

function Show-Image($Label, $Info) {
    Write-Host ("  {0,-9} image={1}  pullPolicy={2}" -f $Label, $Info.Image, $Info.PullPolicy)
}

$other = if ($Component -eq 'backend') { 'frontend' } else { 'backend' }

# Images actuelles (lecture seule)
$liveOther = Get-DeploymentImage $other
Write-Host "Etat actuel du cluster :"
Show-Image $other $liveOther
Write-Host "'$other' sera figé sur son état actuel ; '$Component' recevra le tag $Tag."

$setArgs = @(
    '--set-string', "$Component.image.tag=$Tag",
    '--set-string', "$other.image.repository=$($liveOther.Repository)",
    '--set-string', "$other.image.tag=$($liveOther.Tag)",
    '--set-string', "$other.image.pullPolicy=$($liveOther.PullPolicy)"
)

if ($DryRun) {
    $rendered = helm template $Release $Chart -n $Namespace @setArgs
    if ($LASTEXITCODE -ne 0) { throw 'helm template a échoué' }
    $converted = $rendered | kubectl create --dry-run=client -f - -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $converted) { throw "Conversion YAML -> JSON des manifests échouée (kubectl, code $LASTEXITCODE)" }
    # kubectl émet une suite d'objets JSON (un par ressource), chacun se terminant par "}" en colonne 0
    $items = @(($converted -join "`n") -split '(?m)^\}\s*$' |
        Where-Object { $_.Trim() } |
        ForEach-Object { ($_ + '}') | ConvertFrom-Json })
    $deployments = @($items | Where-Object { $_.kind -eq 'Deployment' })

    $result = @{}
    foreach ($name in 'backend', 'frontend') {
        $d = $deployments | Where-Object { $_.metadata.name -eq $name } | Select-Object -First 1
        if (-not $d) { throw "Deployment '$name' absent des manifests rendus" }
        $result[$name] = Get-DeploymentImage $name $d
    }
    Write-Host "Manifests rendus :"
    Show-Image 'backend' $result['backend']
    Show-Image 'frontend' $result['frontend']

    if ($result[$Component].Tag -ne $Tag) {
        throw "ECHEC : '$Component' n'a pas reçu le tag $Tag (rendu : $($result[$Component].Tag))"
    }
    if ($result[$other].Image -ne $liveOther.Image -or $result[$other].PullPolicy -ne $liveOther.PullPolicy) {
        throw "ECHEC : '$other' serait modifié (actuel : $($liveOther.Image)/$($liveOther.PullPolicy), rendu : $($result[$other].Image)/$($result[$other].PullPolicy))"
    }
    Write-Host "OK (DryRun) : seul '$Component' change ; '$other' conserve image et pullPolicy. Aucune ressource modifiée."
    return
}

helm upgrade --install $Release $Chart -n $Namespace --reset-values --force-conflicts @setArgs --rollback-on-failure --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "helm upgrade a échoué (code $LASTEXITCODE) ; rollback automatique effectué par Helm" }

$after = Get-DeploymentImage $other
if ($after.Image -ne $liveOther.Image -or $after.PullPolicy -ne $liveOther.PullPolicy) {
    Write-Host "DIAGNOSTIC '$other' :"
    Write-Host "  avant : $($liveOther.Image) / $($liveOther.PullPolicy)"
    Write-Host "  après : $($after.Image) / $($after.PullPolicy)"
    throw "ANOMALIE : '$other' a été modifié par le déploiement de '$Component'. Rollback manuel : helm rollback $Release -n $Namespace"
}
Write-Host "OK : '$other' inchangé ($($after.Image), pullPolicy $($after.PullPolicy))"
