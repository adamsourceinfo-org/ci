#!/usr/bin/env bash
# 保護 ci repo 自己的 main。
#
# 這件事容易被忘記，但它是整個安全模型的根：GCP 的信任條件釘在
# ci/.github/workflows/deploy.yml@refs/heads/main —— 能推這裡的 main，
# 就等於能改寫兩個 GCP 專案所信任的部署邏輯。
#
# 不能沿用 new-project.sh 那份 ruleset：它要求 "ci / 1 verify" 與 "ci / 2 build"，
# 但本 repo 的 workflow 是 workflow_call 專用，在自己的 PR 上不會執行，
# 那兩個 check 永遠不會回報，PR 會被永久卡住。這裡改用 self-test 的 "check"。
set -euo pipefail
ORG=adamsourceinfo-org
REPO=ci

RULESET=$(cat <<'JSON'
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
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
        "required_status_checks": [ { "context": "check" } ]
      } }
  ]
}
JSON
)

EXISTING=$(gh api "repos/${ORG}/${REPO}/rulesets" --jq '.[] | select(.name=="protect-main") | .id' 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  printf '%s' "$RULESET" | gh api -X PUT "repos/${ORG}/${REPO}/rulesets/${EXISTING}" --input - >/dev/null
  echo "✅ ${ORG}/${REPO} ruleset 已更新"
else
  printf '%s' "$RULESET" | gh api -X POST "repos/${ORG}/${REPO}/rulesets" --input - >/dev/null
  echo "✅ ${ORG}/${REPO} ruleset 已建立"
fi
echo "   main：禁直推 / 禁 force push / 禁刪除 / 強制 PR + self-test 通過"
