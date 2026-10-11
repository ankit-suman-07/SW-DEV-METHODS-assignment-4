#!/usr/bin/env bash
# Usage: bash scripts/03_deploy_voting.sh --prepare-only
#        bash scripts/03_deploy_voting.sh --deploy
# Prepare first, review/commit, then deploy. Never changes billing or creates keys.
set -Eeuo pipefail
KUBE_READY=0
on_error() {
  printf '\nStopped at line %s. No resources were automatically deleted.\n' "$1" >&2
  printf 'If cluster creation started, existing resources may continue using credits.\n' >&2
  if [[ "$KUBE_READY" == 1 ]]; then
    kubectl -n ms4 get pods,pvc --ignore-not-found || true
    kubectl -n ms4 get events --sort-by=.lastTimestamp | tail -n 12 || true
  fi
}
trap 'on_error "$LINENO"' ERR
readonly EXPECTED_PROJECT='project-9ac387a6-66c9-4c04-81d'
readonly EXPECTED_ACCOUNT='romyromy455@gmail.com'
readonly CLUSTER='ms4-cluster'
readonly ZONE='northamerica-northeast2-a'
readonly NAMESPACE='ms4'
readonly KSA='ms4-voting'
readonly NODE_SA="ms4-gke-node@${EXPECTED_PROJECT}.iam.gserviceaccount.com"
MODE="${1:---prepare-only}"
[[ "$MODE" == '--prepare-only' || "$MODE" == '--deploy' ]] || {
  printf 'Use --prepare-only or --deploy.\n' >&2; exit 1;
}
for tool in git gcloud python3; do
  command -v "$tool" >/dev/null || { printf 'Missing tool: %s\n' "$tool" >&2; exit 1; }
done
TASK_ROOT=$(git rev-parse --show-toplevel)
cd "$TASK_ROOT"
[[ "$(gcloud config get-value project 2>/dev/null)" == "$EXPECTED_PROJECT" ]] || {
  printf 'Wrong active project; stopped.\n' >&2; exit 1;
}
[[ "$(gcloud config get-value account 2>/dev/null)" == "$EXPECTED_ACCOUNT" ]] || {
  printf 'Wrong active account; stopped.\n' >&2; exit 1;
}
[[ -f .env.ms4 ]] || { printf 'Run script 1 first.\n' >&2; exit 1; }
source .env.ms4
[[ "$PROJECT_ID" == "$EXPECTED_PROJECT" ]] || { printf 'Wrong project in configuration.\n' >&2; exit 1; }
readonly IMAGE_TAG="$(git rev-parse --short=12 HEAD)-ms4"
export LOGGER_IMAGE="$REPO/logger:$IMAGE_TAG"
export RECORDER_IMAGE="$REPO/recorder:$IMAGE_TAG"
export POSTGRES_IMAGE="$REPO/postgres:$IMAGE_TAG"

prepare_files() {
  python3 - <<'PY'
import ast
import os
from pathlib import Path

for folder in ('voting_logger', 'voting_record', 'voting_machine'):
    text = (Path(folder) / 'main.py').read_text()
    ast.parse(text)
    if 'files[0]' in text:
        raise SystemExit('Run script 2 before deploying.')
for folder in ('voting_logger', 'voting_record'):
    if 'COPY *.json' in (Path(folder) / 'Dockerfile').read_text():
        raise SystemExit('Credential files must not be copied into images.')

directory = Path('deploy')
directory.mkdir(exist_ok=True)
identity = f'''apiVersion: v1
kind: ServiceAccount
metadata:
  name: ms4-voting
  annotations:
    iam.gke.io/gcp-service-account: {os.environ['MS4_SERVICE_ACCOUNT']}
'''
(directory / 'voting-identity.yaml').write_text(identity)

def app(name, image, host_name, host, sub):
    return f'''apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: {name}
  template:
    metadata:
      labels:
        app: {name}
    spec:
      serviceAccountName: ms4-voting
      containers:
        - name: {name}
          image: {image}
          imagePullPolicy: IfNotPresent
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          env:
            - name: {host_name}
              value: {host}
            - name: GCP_PROJECT
              value: {os.environ['PROJECT_ID']}
            - name: ELECTION_SUB_ID
              value: {sub}
            - name: TOPIC_NAME
              value: election
'''
(directory / 'voting-services.yaml').write_text(
    app('logger', os.environ['LOGGER_IMAGE'], 'REDIS_HOST', 'redis', 'election-submit-sub')
    + '---\n'
    + app('recorder', os.environ['RECORDER_IMAGE'], 'POSTGRES_HOST', 'postgres', 'election-record-sub'))

# Database credentials match the supplied teaching scripts; these are not GCP credentials.
db = '''apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: standard-rwo
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  type: ClusterIP
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-deployment
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7.4-alpine
          args: ["redis-server", "--requirepass", "election", "--appendonly", "yes"]
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: 500m, memory: 512Mi}
          ports:
            - containerPort: 6379
          readinessProbe:
            exec:
              command: ["sh", "-c", "REDISCLI_AUTH=election redis-cli ping | grep -q PONG"]
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: redis-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: standard-rwo
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  type: ClusterIP
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-deployment
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: POSTGRES_IMAGE_PLACEHOLDER
          resources:
            requests: {cpu: 250m, memory: 256Mi}
            limits: {cpu: 1000m, memory: 1Gi}
          env:
            - name: POSTGRES_DB
              value: election
            - name: POSTGRES_USER
              value: admin
            - name: POSTGRES_PASSWORD
              value: adminpassword
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          ports:
            - containerPort: 5432
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "admin", "-d", "election"]
            initialDelaySeconds: 10
            periodSeconds: 5
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-data
'''
(directory / 'voting-databases.yaml').write_text(db.replace('POSTGRES_IMAGE_PLACEHOLDER', os.environ['POSTGRES_IMAGE']))
Path('voting_record/postgres/Dockerfile').write_text(
    'FROM postgres:16-alpine\nCOPY CreateTable.sql /docker-entrypoint-initdb.d/\n')
Path('voting_record/postgres/.dockerignore').write_text('*.json\n.env\n.env.*\n.git/\n')
print('Prepared deploy/voting-identity.yaml, voting-services.yaml, voting-databases.yaml')
print('Prepared PostgreSQL Dockerfile and credential exclusions.')
PY
}

if [[ "$MODE" == '--prepare-only' ]]; then
  prepare_files
  git diff --stat
  git status --short
  printf '\nPREPARATION COMPLETE. No cloud resources were created.\n'
  printf 'Review and commit these files before running this script with --deploy.\n'
  exit 0
fi

for tool in docker kubectl gke-gcloud-auth-plugin; do
  command -v "$tool" >/dev/null || { printf 'Missing tool: %s\n' "$tool" >&2; exit 1; }
done
docker info >/dev/null
for file in deploy/voting-identity.yaml deploy/voting-services.yaml deploy/voting-databases.yaml; do
  [[ -f "$file" ]] || { printf 'Run --prepare-only and review the generated files first.\n' >&2; exit 1; }
done
printf '\n[1/6] Building and pushing three container images before creating the cluster\n'
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker build -t "$LOGGER_IMAGE" voting_logger
docker push "$LOGGER_IMAGE"
docker build -t "$RECORDER_IMAGE" voting_record
docker push "$RECORDER_IMAGE"
docker build -t "$POSTGRES_IMAGE" voting_record/postgres
docker push "$POSTGRES_IMAGE"

printf '\n[2/6] Configuring node permissions and Workload Identity\n'
gcloud services enable iamcredentials.googleapis.com --project="$PROJECT_ID" --quiet
if ! gcloud iam service-accounts describe "$NODE_SA" --project="$PROJECT_ID" >/dev/null; then
  gcloud iam service-accounts create ms4-gke-node --display-name='MS4 GKE node account' --project="$PROJECT_ID" --quiet
fi
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$NODE_SA" --role=roles/container.defaultNodeServiceAccount \
  --condition=None --quiet --format='value(etag)'
gcloud artifacts repositories add-iam-policy-binding sofe4630u \
  --location="$REGION" --project="$PROJECT_ID" --member="serviceAccount:$NODE_SA" \
  --role=roles/artifactregistry.reader --condition=None --quiet --format='value(etag)'


printf '\n[3/6] Creating or checking the single-node cluster (billable resource)\n'
if gcloud container clusters describe "$CLUSTER" --zone="$ZONE" --project="$PROJECT_ID" >/dev/null; then
  OWNER_LABEL=$(gcloud container clusters describe "$CLUSTER" --zone="$ZONE" --project="$PROJECT_ID" --format='value(resourceLabels.assignment)')
  [[ "$OWNER_LABEL" == 'ms4' ]] || { printf 'Existing cluster is not labelled for MS4. Stopped.\n' >&2; exit 1; }
  POOL=$(gcloud container clusters describe "$CLUSTER" --zone="$ZONE" --project="$PROJECT_ID" --format='value(workloadIdentityConfig.workloadPool)')
  [[ "$POOL" == "${PROJECT_ID}.svc.id.goog" ]] || { printf 'Existing cluster has different identity settings. Stopped.\n' >&2; exit 1; }
else
  gcloud container clusters create "$CLUSTER" \
    --project="$PROJECT_ID" --zone="$ZONE" \
    --num-nodes=1 --machine-type=e2-standard-2 \
    --disk-type=pd-balanced --disk-size=30 \
    --service-account="$NODE_SA" --scopes=cloud-platform \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --workload-metadata=GKE_METADATA --enable-ip-alias \
    --release-channel=regular --labels=assignment=ms4 --quiet
fi
gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE" --project="$PROJECT_ID"
[[ "$(kubectl config current-context)" == "gke_${PROJECT_ID}_${ZONE}_${CLUSTER}" ]] || {
  printf 'Unexpected Kubernetes context. Stopped before deployment.\n' >&2; exit 1;
}
KUBE_READY=1

gcloud iam service-accounts add-iam-policy-binding "$MS4_SERVICE_ACCOUNT" \
  --project="$PROJECT_ID" --role=roles/iam.workloadIdentityUser \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA}]" \
  --condition=None --quiet --format='value(etag)'

printf '\n[4/6] Applying internal database services and persistent storage\n'
prepare_files
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" apply -f deploy/voting-identity.yaml
kubectl -n "$NAMESPACE" apply -f deploy/voting-databases.yaml
kubectl -n "$NAMESPACE" rollout status deployment/redis-deployment --timeout=600s
kubectl -n "$NAMESPACE" rollout status deployment/postgres-deployment --timeout=600s

printf '\n[5/6] Starting the logger and recorder\n'
kubectl -n "$NAMESPACE" apply -f deploy/voting-services.yaml
kubectl -n "$NAMESPACE" rollout status deployment/logger-deployment --timeout=600s
kubectl -n "$NAMESPACE" rollout status deployment/recorder-deployment --timeout=600s

printf '\n[6/6] Checking deployment status and the initialized votes table\n'
kubectl -n "$NAMESPACE" get pods,services,pvc
kubectl -n "$NAMESPACE" exec deployment/postgres-deployment -- \
  psql -U admin -d election -c '\d votes'
printf '\nDEPLOYMENT COMPLETE. This is a readiness check, not an end-to-end voting test.\n'
printf 'Cluster: %s, zone: %s, namespace: %s\n' "$CLUSTER" "$ZONE" "$NAMESPACE"
printf 'Compute and persistent disks continue using credits until cleaned up.\n'
printf 'No service-account keys, billing upgrades, commits or pushes were performed.\n'
git status --short
