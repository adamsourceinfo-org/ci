#!/usr/bin/env bash
# 在 adamsourceinfo-org 開一個新專案，接上共用 CI/CD，並保護 main 分支。
#
#   ./scripts/new-project.sh my-app
#   ./scripts/new-project.sh my-app --dir ~/repository/adamsourceinfo --allow-admin-bypass
#
# 做四件事：
#   1. 建立 public repo（Free 方案只有 public repo 能設分支保護）
#   2. 放進 caller stub、.cicd 設定骨架、README
#   3. 推第一版上 main
#   4. 上 ruleset：main 禁止直推、禁止 force push、禁止刪除、強制 PR 且必須通過 ci 檢查
set -euo pipefail

ORG=adamsourceinfo-org
NAME="${1:-}"
shift || true

TARGET_DIR="$(pwd)"
ADMIN_BYPASS=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) TARGET_DIR="$2"; shift 2 ;;
    --allow-admin-bypass) ADMIN_BYPASS=true; shift ;;
    *) echo "未知參數: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$NAME" ]; then
  echo "用法: $0 <專案名稱> [--dir <路徑>] [--allow-admin-bypass]" >&2
  exit 1
fi
if ! printf '%s' "$NAME" | grep -Eq '^[a-z]([-a-z0-9]*[a-z0-9])?$'; then
  echo "專案名稱要符合 Cloud Run 服務命名規則：小寫字母開頭，只能有小寫字母/數字/連字號" >&2
  exit 1
fi

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }

log "建立 ${ORG}/${NAME}"
if gh repo view "${ORG}/${NAME}" >/dev/null 2>&1; then
  ok "repo 已存在，沿用"
else
  gh repo create "${ORG}/${NAME}" --public \
    --description "部署到 Cloud Run（dev/prod）by adamsourceinfo-org/ci" >/dev/null
  ok "已建立 public repo"
fi

WORK="${TARGET_DIR%/}/${NAME}"
if [ -d "$WORK/.git" ]; then
  ok "本機已有 $WORK"
else
  git clone "https://github.com/${ORG}/${NAME}.git" "$WORK" 2>/dev/null || true
  ok "已 clone 到 $WORK"
fi
cd "$WORK"

log "放入 CI/CD 設定"
mkdir -p .github/workflows .cicd
cp "$CI_DIR/templates/deploy.yml" .github/workflows/deploy.yml
cp "$CI_DIR/templates/ci.yml"     .github/workflows/ci.yml
ok ".github/workflows/{deploy,ci}.yml"

for E in dev prod; do
  [ -f ".cicd/env.$E" ] || cat > ".cicd/env.$E" <<EOF
# ${E} 環境的「非機密」設定。一行一個 KEY=VALUE，會進版控。
# 機密請放 .cicd/secrets.${E}，值寫在 Secret Manager。
# 範例：
# LOG_LEVEL=$([ "$E" = dev ] && echo debug || echo info)
EOF
  [ -f ".cicd/secrets.$E" ] || cat > ".cicd/secrets.$E" <<EOF
# ${E} 環境的機密「掛載表」。這個檔案只放名字，絕對不要放值。
# 格式：環境變數名=SecretManager名稱:版本
# 先跑：ci/scripts/set-secret.sh ${E} <secret-name>
# 再加：
# DB_PASSWORD=${NAME}-db-password-${E}:latest
EOF
done
ok ".cicd/{env,secrets}.{dev,prod}"

if [ ! -f Dockerfile ]; then
  cat > Dockerfile <<'EOF'
# adamsourceinfo-org 的部署契約要求每個專案自備 Dockerfile。
# 容器必須監聽 ${PORT}（Cloud Run 會注入，預設 8080）。
FROM nginx:alpine
RUN printf 'server { listen 8080; location / { return 200 "replace me\n"; } }' > /etc/nginx/conf.d/default.conf
EXPOSE 8080
EOF
  ok "Dockerfile（範本，請換成你的）"
fi

[ -f README.md ] || cat > README.md <<EOF
# ${NAME}

部署由 [adamsourceinfo-org/ci](https://github.com/${ORG}/ci) 負責。

- push \`main\` → 部署 \`adamsourceinfo-dev\`
- 打 tag \`vX.Y.Z\` → 把 dev 驗過的同一個 image 發到 \`adamsourceinfo-prod\`（不重新 build）

設定改 \`.cicd/env.<env>\`；機密跑 \`ci/scripts/set-secret.sh\` 後在 \`.cicd/secrets.<env>\` 掛名字。
EOF

git add -A
if git diff --cached --quiet; then
  ok "沒有變更需要提交"
else
  git -c user.email=noreply@adamsourceinfo.dev -c user.name="adamsourceinfo ci" \
    commit -q -m "接上 adamsourceinfo-org/ci 共用 CI/CD"
  git branch -M main
  git push -u origin main -q
  ok "已推上 main"
fi

log "保護 main 分支"
BYPASS='[]'
[ "$ADMIN_BYPASS" = true ] && BYPASS='[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]'

RULESET=$(cat <<EOF
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": ${BYPASS},
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["merge", "squash", "rebase"]
      } },
    { "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "ci / 1 verify" },
          { "context": "ci / 2 build" }
        ]
      } }
  ]
}
EOF
)

EXISTING=$(gh api "repos/${ORG}/${NAME}/rulesets" --jq '.[] | select(.name=="protect-main") | .id' 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  printf '%s' "$RULESET" | gh api -X PUT "repos/${ORG}/${NAME}/rulesets/${EXISTING}" --input - >/dev/null
  ok "ruleset 已更新"
else
  printf '%s' "$RULESET" | gh api -X POST "repos/${ORG}/${NAME}/rulesets" --input - >/dev/null
  ok "ruleset 已建立"
fi
[ "$ADMIN_BYPASS" = true ] && ok "（admin 可繞過）" || ok "（含 admin 都不能直推 main）"

cat <<EOF

────────────────────────────────────────────────────────────
✅ ${ORG}/${NAME} 已就緒
   本機：$WORK
   main 保護：禁直推 / 禁 force push / 禁刪除 / 強制 PR + ci 通過

接下來：
   1. 換掉 Dockerfile 成你真正的應用（要監聽 \${PORT}）
   2. 開分支 → PR → merge 進 main，自動部署 dev
   3. git tag v0.1.0 && git push origin v0.1.0，發到 prod
────────────────────────────────────────────────────────────
EOF
