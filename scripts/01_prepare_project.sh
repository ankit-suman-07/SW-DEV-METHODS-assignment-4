#!/usr/bin/env bash
# MS4 prerequisites only. No keys, builds, cluster, billing changes or Git pushes.
set -Eeuo pipefail
trap 'printf "\nStopped at line %s. Resolve the error above, then rerun this script.\n" "$LINENO" >&2' ERR

readonly PROJECT_ID='project-9ac387a6-66c9-4c04-81d'
readonly EXPECTED_ACCOUNT='romyromy455@gmail.com'
readonly REGION='northamerica-northeast2'
readonly REPOSITORY='sofe4630u'
readonly TOPIC='election'
readonly SA_NAME='ms4-pubsub'
readonly SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
readonly REPO="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}"

for tool in gcloud git python3; do
  command -v "$tool" >/dev/null || { printf 'Required tool missing: %s\n' "$tool" >&2; exit 1; }
done

TASK_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  printf 'Run this script from inside your SOFE4630U-MS4 checkout.\n' >&2
  exit 1
}
cd "$TASK_ROOT"
for directory in voting_logger voting_record voting_machine; do
  [[ -d "$directory" ]] || { printf 'Missing MS4 directory: %s\n' "$directory" >&2; exit 1; }
done

printf '\n[1/7] Checking active account and project\n'
ACTIVE_ACCOUNT=$(gcloud config get-value account 2>/dev/null)
ACTIVE_PROJECT=$(gcloud config get-value project 2>/dev/null)
if [[ "$ACTIVE_ACCOUNT" != "$EXPECTED_ACCOUNT" || "$ACTIVE_PROJECT" != "$PROJECT_ID" ]]; then
  printf 'Wrong account/project. Expected %s / %s; found %s / %s.\n' \
    "$EXPECTED_ACCOUNT" "$PROJECT_ID" "$ACTIVE_ACCOUNT" "$ACTIVE_PROJECT" >&2
  exit 1
fi

printf '\n[2/7] Checking billing linkage (read-only)\n'
BILLING_STATE=$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)')
if [[ "${BILLING_STATE,,}" != 'true' ]]; then
  printf 'Billing is not enabled. No billing changes were made. Check the project in the console.\n' >&2
  exit 1
fi
printf 'Billing linkage exists. This check does not establish free-trial status or remaining credit.\n'

printf '\n[3/7] Ensuring required APIs are enabled\n'
gcloud services enable \
  pubsub.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  bigquery.googleapis.com \
  compute.googleapis.com \
  --project="$PROJECT_ID" --quiet

printf '\n[4/7] Ensuring election topic and service account exist\n'
if gcloud pubsub topics describe "$TOPIC" --project="$PROJECT_ID" >/dev/null; then
  printf 'Topic already exists: %s\n' "$TOPIC"
else
  gcloud pubsub topics create "$TOPIC" --project="$PROJECT_ID" --quiet
fi
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null; then
  printf 'Service account already exists: %s\n' "$SA_EMAIL"
else
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name='MS4 Pub/Sub Service Account' --project="$PROJECT_ID" --quiet
fi

printf '\n[5/7] Checking existing Pub/Sub Admin binding\n'
HAS_BINDING=$(gcloud projects get-iam-policy "$PROJECT_ID" --format=json | \
  python3 -c 'import json,sys; p=json.load(sys.stdin); member="serviceAccount:"+sys.argv[1]; print("yes" if any(b.get("role")=="roles/pubsub.admin" and member in b.get("members",[]) and not b.get("condition") for b in p.get("bindings",[])) else "no")' "$SA_EMAIL")
if [[ "$HAS_BINDING" == 'yes' ]]; then
  printf 'Required binding already exists; no IAM change needed.\n'
else
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" --role='roles/pubsub.admin' \
    --condition=None --quiet --format='value(etag)'
fi

printf '\n[6/7] Ensuring Docker Artifact Registry repository exists\n'
if gcloud artifacts repositories describe "$REPOSITORY" \
    --location="$REGION" --project="$PROJECT_ID" >/dev/null; then
  FORMAT=$(gcloud artifacts repositories describe "$REPOSITORY" \
    --location="$REGION" --project="$PROJECT_ID" --format='value(format)')
  [[ "$FORMAT" == 'DOCKER' ]] || { printf 'Existing repository is not Docker format.\n' >&2; exit 1; }
  printf 'Docker repository already exists.\n'
else
  gcloud artifacts repositories create "$REPOSITORY" --repository-format=docker \
    --location="$REGION" --description='SOFE4630U MS4 container images' \
    --project="$PROJECT_ID" --quiet
fi
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

printf '\n[7/7] Saving non-secret configuration\n'
# The supplied .gitignore already covers .env.*; check before writing.
git check-ignore -q .env.ms4 || {
  printf 'Add .env.* to .gitignore before rerunning.\n' >&2
  exit 1
}
umask 077
cat > .env.ms4 <<EOF
# Non-secret MS4 configuration. Load later with: source .env.ms4
export PROJECT_ID='$PROJECT_ID'
export PROJECT='$PROJECT_ID'
export REGION='$REGION'
export REPO='$REPO'
export LOGGER_IMAGE='$REPO/logger:latest'
export RECORDER_IMAGE='$REPO/recorder:latest'
export POSTGRES_IMAGE='$REPO/postgres:election'
export MS4_SERVICE_ACCOUNT='$SA_EMAIL'
EOF

printf '\nSUCCESS: MS4 project prerequisites are ready.\n'
printf 'Project: %s\nRegistry: %s\nConfig: %s/.env.ms4\n' "$PROJECT_ID" "$REPO" "$TASK_ROOT"
printf 'No cluster, service-account key, image build, billing change, commit or push was performed.\n'
printf '\nGit status:\n'
git status --short
