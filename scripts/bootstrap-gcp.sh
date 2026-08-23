#!/usr/bin/env bash
# 一次性設定 adamsourceinfo-dev / adamsourceinfo-prod 兩個 GCP 專案，讓 GitHub Actions
# 能夠「無金鑰」部署到 Cloud Run。可以重複執行（idempotent）。
#
#   ./scripts/bootstrap-gcp.sh
#
# 完成後 GitHub 端不需要設定任何 secret —— 沒有 SA key JSON，沒有長期憑證。
set -euo pipefail

ORG=adamsourceinfo-org
CI_REPO=ci
# 信任條件綁死在這支 workflow。從別的 workflow 呼叫換不到憑證。
WORKFLOW_REF="${ORG}/${CI_REPO}/.github/workflows/deploy.yml@refs/heads/main"

REGION=asia-east1
AR_REPO=apps
POOL=github
PROVIDER=${ORG}
DEPLOYER=github-deployer
RUNTIME=run-runtime

DEV_PROJECT=adamsourceinfo-dev
PROD_PROJECT=adamsourceinfo-prod

log()  { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }

# 新建的 service account 不會馬上出現在 IAM policy API 眼裡。這不是錯誤，是最終一致性，
# 直接跑後續的 add-iam-policy-binding 會拿到 "does not exist"。重試而不是 sleep 固定秒數。
retry() {
  local n=0 max=12
  until "$@"; do
    n=$((n+1))
    if [ "$n" -ge "$max" ]; then
      echo "  ✗ 重試 ${max} 次仍失敗: $*" >&2
      return 1
    fi
    sleep 5
  done
}

bootstrap_project() {
  local PROJECT="$1" ENV_NAME="$2"
  local NUMBER
  NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')

  log "[$ENV_NAME] $PROJECT (number=$NUMBER)"

  # 帳單。沒連結的話後面所有 API 都開不起來，先擋在這裡講清楚。
  if [ "$(gcloud billing projects describe "$PROJECT" --format='value(billingEnabled)')" != "True" ]; then
    echo "  ✗ $PROJECT 沒有連結帳單帳戶。先執行："
    echo "      gcloud billing projects link $PROJECT --billing-account=<ACCOUNT_ID>"
    exit 1
  fi
  ok "帳單已連結"

  # sqladmin 一定要開，即使這個專案還沒有任何 Cloud SQL：部署帶 --add-cloudsql-instances
  # 時 gcloud 會要求它已啟用，在 CI 的 --quiet 下會直接「Aborted by user」而不是問你。
  gcloud services enable \
    run.googleapis.com artifactregistry.googleapis.com \
    iamcredentials.googleapis.com sts.googleapis.com \
    secretmanager.googleapis.com cloudresourcemanager.googleapis.com \
    sqladmin.googleapis.com \
    --project="$PROJECT" --quiet
  ok "API 已開通"

  gcloud artifacts repositories describe "$AR_REPO" --location="$REGION" --project="$PROJECT" >/dev/null 2>&1 || \
    gcloud artifacts repositories create "$AR_REPO" \
      --repository-format=docker --location="$REGION" --project="$PROJECT" \
      --description="adamsourceinfo-org 應用程式 image" --quiet
  ok "Artifact Registry: ${REGION}-docker.pkg.dev/${PROJECT}/${AR_REPO}"

  # 執行身分。Cloud Run 服務用這個帳號跑，預設沒有任何權限。
  # 不用 default compute SA —— 那個帶 Editor，等於每個服務都是專案管理員。
  gcloud iam service-accounts describe "${RUNTIME}@${PROJECT}.iam.gserviceaccount.com" --project="$PROJECT" >/dev/null 2>&1 || \
    gcloud iam service-accounts create "$RUNTIME" --project="$PROJECT" \
      --display-name="Cloud Run 執行身分（${ENV_NAME}）" --quiet
  ok "執行身分 SA: ${RUNTIME}@${PROJECT}.iam.gserviceaccount.com"

  # 部署身分。GitHub Actions 透過 WIF 冒用這個帳號。
  gcloud iam service-accounts describe "${DEPLOYER}@${PROJECT}.iam.gserviceaccount.com" --project="$PROJECT" >/dev/null 2>&1 || \
    gcloud iam service-accounts create "$DEPLOYER" --project="$PROJECT" \
      --display-name="GitHub Actions 部署身分（${ENV_NAME}）" --quiet
  ok "部署身分 SA: ${DEPLOYER}@${PROJECT}.iam.gserviceaccount.com"

  for ROLE in roles/run.admin roles/artifactregistry.writer; do
    retry gcloud projects add-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:${DEPLOYER}@${PROJECT}.iam.gserviceaccount.com" \
      --role="$ROLE" --condition=None --quiet >/dev/null
  done
  # 只能冒用「執行身分」這一個帳號，不是專案層級的 serviceAccountUser。
  retry gcloud iam service-accounts add-iam-policy-binding "${RUNTIME}@${PROJECT}.iam.gserviceaccount.com" \
    --member="serviceAccount:${DEPLOYER}@${PROJECT}.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser" --project="$PROJECT" --quiet >/dev/null
  ok "部署身分權限：run.admin + artifactregistry.writer + serviceAccountUser(限 ${RUNTIME})"

  # Workload Identity Federation
  gcloud iam workload-identity-pools describe "$POOL" --location=global --project="$PROJECT" >/dev/null 2>&1 || \
    gcloud iam workload-identity-pools create "$POOL" --location=global --project="$PROJECT" \
      --display-name="GitHub Actions" --quiet
  ok "WIF pool: $POOL"

  if ! gcloud iam workload-identity-pools providers describe "$PROVIDER" \
        --workload-identity-pool="$POOL" --location=global --project="$PROJECT" >/dev/null 2>&1; then
    gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
      --workload-identity-pool="$POOL" --location=global --project="$PROJECT" \
      --display-name="$ORG" \
      --issuer-uri="https://token.actions.githubusercontent.com" \
      --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.job_workflow_ref=assertion.job_workflow_ref" \
      --attribute-condition="assertion.repository_owner == '${ORG}'" \
      --quiet
  fi
  ok "WIF provider: ${PROVIDER}（只接受 ${ORG} 底下的 repo）"

  # 關鍵：能冒用部署身分的，只有 ci repo 的那一支 reusable workflow。
  # 各專案 repo 自己的 workflow 檔怎麼改都換不到憑證。
  retry gcloud iam service-accounts add-iam-policy-binding "${DEPLOYER}@${PROJECT}.iam.gserviceaccount.com" \
    --project="$PROJECT" --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.job_workflow_ref/${WORKFLOW_REF}" \
    --quiet >/dev/null
  ok "信任綁定：只有 ${WORKFLOW_REF} 換得到憑證"
}

bootstrap_project "$DEV_PROJECT"  dev
bootstrap_project "$PROD_PROJECT" prod

# promote 階段是用 prod 的部署身分去讀 dev 的 image，所以要跨專案讀取權。
log "跨專案：prod 部署身分 → 讀 dev Artifact Registry"
retry gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" \
  --location="$REGION" --project="$DEV_PROJECT" \
  --member="serviceAccount:${DEPLOYER}@${PROD_PROJECT}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.reader" --quiet >/dev/null
ok "已授權（promote 時 prod 才讀得到 dev 建好的 image）"

DEV_NUMBER=$(gcloud projects describe "$DEV_PROJECT" --format='value(projectNumber)')
PROD_NUMBER=$(gcloud projects describe "$PROD_PROJECT" --format='value(projectNumber)')
cat <<EOF

────────────────────────────────────────────────────────────
✅ bootstrap 完成

若專案編號有變動，請同步更新 .github/workflows/deploy.yml 的 env：
  DEV_PROJECT_NUMBER:  "$DEV_NUMBER"
  PROD_PROJECT_NUMBER: "$PROD_NUMBER"

GitHub 端不需要設定任何 secret。
────────────────────────────────────────────────────────────
EOF
