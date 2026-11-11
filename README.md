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

## Dépannage

| Symptôme | Action |
|---|---|
| `ErrImageNeverPull` | Recharger l'image : `minikube image load ...`. |
| Backend bloqué en `Init:0/1` | `kubectl logs -n recouvra deploy/backend -c wait-for-mongodb` (MongoDB pas prête ou identifiants incohérents). |
| `CreateContainerConfigError` | Secret absent : lancer `scripts/create-secrets.ps1`. |
| Ingress 503 | Pods non prêts : `kubectl get pods -n recouvra`. |
| `recouvra.local` injoignable | `minikube tunnel` non lancé en administrateur, ou entrée `hosts` manquante. |
