#!/usr/bin/env bash
set -euo pipefail

# ---- Cambie solo estas dos líneas (respete mayúsculas y minúsculas) ----
GH_USER="su-usuario-github"
GH_REPO="gitops-lab"
# -------------------------------------------------------------------------

# ---- Opcional. Déjelas vacías para que el script cree tres proyectos. ----
# Si su cuenta no puede crear proyectos (cuota o políticas de la
# organización), escriba aquí el ID de un proyecto que ya exista; puede ser
# el mismo ID en las tres líneas.
PROJECT_STATE=""
PROJECT_DEV=""
PROJECT_PROD=""
# -------------------------------------------------------------------------

LOC="us-central1"
POOL="github"
PROVIDER="github-actions"
SA_NAME="sa-gitops-github"

# Reintenta un comando: IAM tarda unos segundos en ver lo que se acaba de crear.
retry() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge 6 ]; then echo "Falló tras $n intentos: $*" >&2; return 1; fi
    sleep 10
  done
}

echo "0/6 Identificadores del repositorio en GitHub"
# GitHub emite el subject con identificadores numéricos
# (repo:USUARIO@ID/REPO@ID:...). Los leemos de la API pública para que la
# vinculación coincida exactamente, con las mayúsculas correctas.
GH_JSON=$(curl -fsS "https://api.github.com/repos/${GH_USER}/${GH_REPO}") || {
  echo "No encontré github.com/${GH_USER}/${GH_REPO}. Cree primero el repositorio (público) y revise GH_USER y GH_REPO."
  exit 1
}
OWNER=$(echo "$GH_JSON" | jq -r .owner.login); OWNER_ID=$(echo "$GH_JSON" | jq -r .owner.id)
REPO=$(echo "$GH_JSON" | jq -r .name);         REPO_ID=$(echo "$GH_JSON" | jq -r .id)

# Los ID de proyecto son únicos en todo GCP: se derivan del ID del repositorio.
PROJECT_STATE="${PROJECT_STATE:-gitops-state-${REPO_ID}}"
PROJECT_DEV="${PROJECT_DEV:-gitops-dev-${REPO_ID}}"
PROJECT_PROD="${PROJECT_PROD:-gitops-prod-${REPO_ID}}"
TFSTATE_BUCKET="${PROJECT_STATE}-tfstate"

echo "1/6 Proyectos (equivalen a los grupos de recursos de Azure)"
BILLING=$(gcloud billing accounts list --filter="open=true" \
  --format="value(name)" --limit=1)
BILLING="${BILLING#billingAccounts/}"
if [ -z "$BILLING" ]; then
  echo "No encontré una cuenta de facturación abierta. Active la prueba gratuita o sus créditos educativos."
  exit 1
fi
for p in $(printf '%s\n' "$PROJECT_STATE" "$PROJECT_DEV" "$PROJECT_PROD" | sort -u); do
  if ! gcloud projects describe "$p" >/dev/null 2>&1; then
    gcloud projects create "$p" --name="$p" --quiet
  fi
  if [ "$(gcloud billing projects describe "$p" --format='value(billingEnabled)')" != "True" ]; then
    gcloud billing projects link "$p" --billing-account="$BILLING" --quiet >/dev/null
  fi
done
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com \
  sts.googleapis.com storage.googleapis.com \
  cloudresourcemanager.googleapis.com --project "$PROJECT_STATE"
for p in "$PROJECT_DEV" "$PROJECT_PROD"; do
  gcloud services enable storage.googleapis.com --project "$p"
done
STATE_NUM=$(gcloud projects describe "$PROJECT_STATE" --format="value(projectNumber)")

echo "2/6 Almacenamiento del estado de Terraform"
if ! gcloud storage buckets describe "gs://${TFSTATE_BUCKET}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${TFSTATE_BUCKET}" \
    --project "$PROJECT_STATE" --location "$LOC" \
    --uniform-bucket-level-access --public-access-prevention
fi
gcloud storage buckets update "gs://${TFSTATE_BUCKET}" --versioning >/dev/null

echo "3/6 Cuenta de servicio (sin claves; equivale a la identidad administrada)"
SA_EMAIL="${SA_NAME}@${PROJECT_STATE}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT_STATE" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" --project "$PROJECT_STATE" \
    --display-name "GitHub Actions - gitops-lab"
fi

echo "4/6 Workload Identity Federation: pool y proveedor OIDC de GitHub"
if ! gcloud iam workload-identity-pools describe "$POOL" --project "$PROJECT_STATE" \
     --location global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$POOL" --project "$PROJECT_STATE" \
    --location global --display-name "GitHub Actions"
fi
if ! gcloud iam workload-identity-pools providers describe "$PROVIDER" \
     --project "$PROJECT_STATE" --location global \
     --workload-identity-pool "$POOL" >/dev/null 2>&1; then
  # La condición de atributo es la primera barrera: solo entran tokens de ESTE
  # repositorio (por identificador numérico, que no cambia ni se reutiliza).
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --project "$PROJECT_STATE" --location global --workload-identity-pool "$POOL" \
    --display-name "GitHub ${OWNER}/${REPO}" \
    --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.repository_owner_id=assertion.repository_owner_id" \
    --attribute-condition "assertion.repository_owner_id == '${OWNER_ID}' && assertion.repository_id == '${REPO_ID}'"
fi
WIF_PROVIDER="projects/${STATE_NUM}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"

echo "5/6 Vinculaciones por subject (equivalen a las credenciales federadas)"
# Se registran los dos formatos (con y sin identificadores) por compatibilidad.
declare -A PREFIX=(
  [id]="repo:${OWNER}@${OWNER_ID}/${REPO}@${REPO_ID}"
  [nombre]="repo:${OWNER}/${REPO}"
)
declare -A CONTEXT=(
  [pull-request]="pull_request"
  [rama-main]="ref:refs/heads/main"
  [entorno-dev]="environment:dev"
  [entorno-prod]="environment:prod"
)
for p in "${!PREFIX[@]}"; do
  for c in "${!CONTEXT[@]}"; do
    SUBJECT="${PREFIX[$p]}:${CONTEXT[$c]}"
    retry gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
      --project "$PROJECT_STATE" --role "roles/iam.workloadIdentityUser" \
      --member "principal://iam.googleapis.com/projects/${STATE_NUM}/locations/global/workloadIdentityPools/${POOL}/subject/${SUBJECT}" \
      --condition=None --quiet >/dev/null
  done
done

echo "6/6 Permisos mínimos"
for p in "$PROJECT_DEV" "$PROJECT_PROD"; do
  retry gcloud projects add-iam-policy-binding "$p" \
    --member "serviceAccount:${SA_EMAIL}" --role "roles/storage.admin" \
    --condition=None --quiet >/dev/null
done
retry gcloud storage buckets add-iam-policy-binding "gs://${TFSTATE_BUCKET}" \
  --member "serviceAccount:${SA_EMAIL}" --role "roles/storage.objectAdmin" >/dev/null

echo
echo "Cree estas seis variables en GitHub (Settings > Secrets and variables"
echo "> Actions > Variables):"
echo "  GCP_WIF_PROVIDER    = $WIF_PROVIDER"
echo "  GCP_SERVICE_ACCOUNT = $SA_EMAIL"
echo "  GCP_PROJECT_DEV     = $PROJECT_DEV"
echo "  GCP_PROJECT_PROD    = $PROJECT_PROD"
echo "  GCP_LOCATION        = $LOC"
echo "  TFSTATE_BUCKET      = $TFSTATE_BUCKET"
