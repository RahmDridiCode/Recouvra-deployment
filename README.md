# recouvra-deployment

Dépôt de déploiement de **Recouvra** (Angular + Node.js/Express + MongoDB) sur Kubernetes (Minikube) :
chart Helm, scripts de secrets et configuration du monitoring. Le code applicatif vit dans
`recouvra-backend` et `recouvra-frontend`.

```
Navigateur → http://recouvra.local → Ingress (nginx)
   ├─ /api → Service backend :3000  → Deployment backend
   └─ /    → Service frontend :80   → Deployment frontend
Backend → Service mongodb (headless) :27017 → StatefulSet mongodb → PVC data-mongodb-0
```

## Structure

| Chemin | Rôle |
|---|---|
| `helm/recouvra/` | Chart Helm (backend, frontend, MongoDB, Ingress, ConfigMap, ServiceMonitors). |
| `scripts/create-secrets.ps1` | Crée le Secret `recouvra-secrets` depuis `.env.docker`. |
| `monitoring/values-light.yaml` | Values allégées de `kube-prometheus-stack`. |
| `monitoring/mongo-exporter-values.yaml` | Values de `prometheus-mongodb-exporter` (utilise le Secret existant). |
| `monitoring/dashboards/` | Dashboards Grafana (backend, MongoDB, frontend) à importer. |
| `.env.example` | Modèle des variables secrètes. |

## Prérequis

```powershell
minikube start --driver=docker
minikube addons enable ingress
kubectl wait --namespace ingress-nginx --for=condition=ready pod `
  --selector=app.kubernetes.io/component=controller --timeout=180s
```

Les images utilisent `imagePullPolicy: Never` : elles doivent être chargées dans Minikube
(`minikube image load recouvra/backend:<tag>`, `recouvra/frontend:<tag>`, `mongo:7.0`).
Les tags sont définis dans `helm/recouvra/values.yaml`.

## Secrets

Aucun Secret n'est versionné. Le Secret `recouvra-secrets` est créé hors Helm :

```powershell
kubectl create namespace recouvra            # si absent
Copy-Item .env.example .env.docker           # puis renseigner les valeurs (jamais committé)
.\scripts\create-secrets.ps1 -DryRun         # valide sans toucher au cluster
.\scripts\create-secrets.ps1                 # crée ou met à jour le Secret
```

Le script n'affiche que les noms des clés.

| Clé | Utilisée par | Obligatoire |
|---|---|---|
| `MONGO_ROOT_USER`, `MONGO_ROOT_PASSWORD` | StatefulSet MongoDB | oui |
| `MONGO_URI` | backend, initContainer, exporter MongoDB (construit par le script) | oui |
| `JWT_SECRET` | backend | oui |
| `SMTP_USER`, `SMTP_PASS`, `TWILIO_*` | backend (email/SMS, sinon simulés) | non |

Rotation : relancer le script puis `kubectl rollout restart deployment/backend -n recouvra`.
`MONGO_INITDB_*` n'est appliqué qu'à l'initialisation du volume : changer le mot de passe dans
le Secret ne modifie pas une base existante.

## Déploiement

```powershell
helm lint helm/recouvra
helm upgrade --install recouvra helm/recouvra -n recouvra
kubectl rollout status deployment/backend -n recouvra
kubectl rollout status deployment/frontend -n recouvra
kubectl get pods -n recouvra
```

Accès (Windows, driver docker) : ajouter `127.0.0.1 recouvra.local` au fichier `hosts`, puis lancer
`minikube tunnel` dans un terminal administrateur et ouvrir http://recouvra.local.
Test rapide : `curl.exe --resolve recouvra.local:80:127.0.0.1 http://recouvra.local/health`.

## Monitoring

Nécessite `kube-prometheus-stack` (release `prometheus-stack`, namespace `monitoring`). Les ServiceMonitors
du chart portent le label `release: prometheus-stack` et sont activés par `metrics.enabled`.

```powershell
# 1. Stack Prometheus/Grafana (si pas déjà installée)
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack `
  -n monitoring --create-namespace -f monitoring/values-light.yaml

# 2. Exporter MongoDB (après la création du Secret)
helm upgrade --install mongodb-exporter prometheus-community/prometheus-mongodb-exporter `
  --version 3.23.2 -n recouvra -f monitoring/mongo-exporter-values.yaml

# 3. Vérification : Status > Targets
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090
```

Dashboards : dans Grafana, *Dashboards > New > Import*, puis charger les JSON de `monitoring/dashboards/`.

## CI/CD

```
push main (recouvra-backend / recouvra-frontend)
  → tests (backend) → build + push ghcr.io/rahmdridicode/recouvra-<composant>:sha-<7 car.>
  → repository_dispatch "deploy-image" {component, tag} vers ce dépôt
  → .github/workflows/deploy.yml (runner self-hosted Windows) → helm upgrade du seul composant concerné
```

### Configuration manuelle (une seule fois)

| Où | Quoi |
|---|---|
| Dépôts backend et frontend, *Settings > Secrets > Actions* | secret `DEPLOYMENT_TOKEN` (PAT fine-grained limité à `recouvra-deployment`, permission *Contents: Read and write*) |
| Dépôts backend et frontend | rien d'autre : `GITHUB_TOKEN` est fourni automatiquement (`packages: write` déclaré dans le workflow) |
| Dépôt deployment, *Settings > Actions > Runners* | runner self-hosted Windows en ligne, avec `minikube`, `kubectl` et `helm` (≥ 4) dans le `PATH` du compte qui l'exécute |
| Cluster, namespace `recouvra` | Secrets `ghcr-secret` (PAT `read:packages`) et `recouvra-secrets` (voir *Secrets*) |
| GHCR | si le paquet n'est pas lié au dépôt, l'ajouter en accès pour que le PAT puisse le lire |

### Premier déploiement (bootstrap)

`values.yaml` contient des tags par défaut (`v2`) qui n'existent pas sur GHCR. Une fois les deux CI passées,
déployer une première fois les deux tags (visibles dans *Packages* sur GitHub) :

```powershell
helm upgrade --install recouvra helm/recouvra -n recouvra `
  --set backend.image.tag=sha-xxxxxxx --set frontend.image.tag=sha-yyyyyyy
```

Ensuite chaque push met à jour un seul composant via `scripts/deploy-component.ps1` : pas de `--reuse-values` (les anciennes valeurs stockées par Helm sont ignorées), seul `<composant>.image.tag` est modifié (`--set-string`), et l'image de l'autre composant est figée sur celle réellement en cours d'exécution dans le cluster. Le script vérifie après coup que l'autre Deployment n'a pas changé.
Test sans toucher au cluster : `./scripts/deploy-component.ps1 -Component backend -Tag sha-abc1234 -DryRun`.
Si un dispatch arrive avant ce bootstrap, le déploiement échoue et Helm revient en arrière (`--rollback-on-failure`) : sans conséquence.

### Rollback

```powershell
helm history recouvra -n recouvra
helm rollback recouvra <révision> -n recouvra
kubectl rollout status deployment/backend -n recouvra
```

Le déploiement automatique utilise `--rollback-on-failure` : en cas d'échec ou de timeout (5 min), Helm restaure la révision précédente.

### Dépannage CI/CD

| Symptôme | Action |
|---|---|
| `notify-deployment` : HTTP 404 ou 403 | `DEPLOYMENT_TOKEN` absent, expiré ou sans accès à ce dépôt. |
| Le workflow `Deploy` ne démarre pas | `deploy.yml` doit être sur la branche par défaut de ce dépôt ; le runner doit être en ligne. |
| `Minikube n'est pas démarré` | `minikube start --driver=docker` sur la machine du runner. |
| Contexte kubectl inattendu | Le service du runner n'utilise pas le même `~/.kube/config` que ton compte. |
| `ImagePullBackOff` / `unauthorized` | `ghcr-secret` absent ou PAT sans `read:packages` ; vérifier que le tag existe sur GHCR. |
| `ImagePullBackOff` sur le composant non déployé | Bootstrap non fait (tag par défaut `v2` inexistant). |
| Erreur `unknown flag: --rollback-on-failure` | Helm trop ancien (Helm 4 requis ; Helm 3 : `--atomic`). |

## Dépannage

| Symptôme | Action |
|---|---|
| `ErrImageNeverPull` | Recharger l'image : `minikube image load ...`. |
| Backend bloqué en `Init:0/1` | `kubectl logs -n recouvra deploy/backend -c wait-for-mongodb` (MongoDB pas prête ou identifiants incohérents). |
| `CreateContainerConfigError` | Secret absent : lancer `scripts/create-secrets.ps1`. |
| Ingress 503 | Pods non prêts : `kubectl get pods -n recouvra`. |
| `recouvra.local` injoignable | `minikube tunnel` non lancé en administrateur, ou entrée `hosts` manquante. |
