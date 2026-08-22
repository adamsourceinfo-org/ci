#!/usr/bin/env bash
# 把一個機密寫進 GCP Secret Manager，並授權給該環境的 Cloud Run 執行身分。
# 值不經過 GitHub、不進版控、不出現在 CI log。
#
#   ./scripts/set-secret.sh dev  myapp-db-password
#   ./scripts/set-secret.sh prod myapp-db-password
#
# 之後在專案的 .cicd/secrets.<env> 加一行（只有名字，沒有值）：
#   DB_PASSWORD=myapp-db-password:latest
set -euo pipefail

ENV_NAME="${1:-}"
SECRET_NAME="${2:-}"
RUNTIME=run-runtime

if [ -z "$ENV_NAME" ] || [ -z "$SECRET_NAME" ]; then
  echo "用法: $0 <dev|prod> <secret-name>" >&2
  exit 1
fi
case "$ENV_NAME" in
  dev)  PROJECT=adamsourceinfo-dev ;;
  prod) PROJECT=adamsourceinfo-prod ;;
  *) echo "環境只能是 dev 或 prod，收到 '$ENV_NAME'" >&2; exit 1 ;;
esac
if ! printf '%s' "$SECRET_NAME" | grep -Eq '^[a-z0-9][a-z0-9_-]*$'; then
  echo "secret 名稱只能用小寫字母、數字、連字號、底線" >&2
  exit 1
fi

printf '請輸入 %s 在 %s 的值（輸入不會顯示）: ' "$SECRET_NAME" "$PROJECT" >&2
read -rs VALUE
printf '\n' >&2
[ -n "$VALUE" ] || { echo "值不能是空的" >&2; exit 1; }

gcloud secrets describe "$SECRET_NAME" --project="$PROJECT" >/dev/null 2>&1 || \
  gcloud secrets create "$SECRET_NAME" --project="$PROJECT" --replication-policy=automatic --quiet

printf '%s' "$VALUE" | gcloud secrets versions add "$SECRET_NAME" --project="$PROJECT" --data-file=- --quiet >/dev/null
unset VALUE

# 只授權這一個 secret，不是專案層級的 secretAccessor。
gcloud secrets add-iam-policy-binding "$SECRET_NAME" --project="$PROJECT" \
  --member="serviceAccount:${RUNTIME}@${PROJECT}.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" --quiet >/dev/null

VER=$(gcloud secrets versions list "$SECRET_NAME" --project="$PROJECT" --limit=1 --format='value(name)')
cat <<EOF

✅ 已寫入 $PROJECT / ${SECRET_NAME}（版本 ${VER}）

下一步：在專案的 .cicd/secrets.${ENV_NAME} 加一行
    你的環境變數名=${SECRET_NAME}:latest
commit → merge 進 main 就會自動掛上去。
EOF
