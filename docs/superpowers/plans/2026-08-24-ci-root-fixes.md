# ci 根因修復實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消掉 `deploy.yml` 的 117 行重複、把 GCP 前置條件的驗證提前並講清楚、把散文 runbook 換成可驗收的腳本，並替 Artifact Registry 加上清理政策。

**Architecture:** deploy 步驟抽成跨 repo 引用的 composite action（`adamsourceinfo-org/ci/.github/actions/deploy-service@main`），安全邊界留在 job 層；新增 `preflight` job 在 build 之前查 CI 權限查得到的三項；查不到的三項（角色綁定、DB user、GRANT）交給 `ci/scripts/provision-service.sh`，刻意不擴充部署身分的權限。

**Tech Stack:** GitHub Actions（reusable workflow + composite action）、`gcloud`、`cloud-sql-proxy`、`psql`、`yq`、bash

**Spec:** `ci/docs/superpowers/specs/2026-08-24-ci-root-fixes-design.md`

## Global Constraints

- **安全邊界不可搬進 composite action**：`permissions: id-token: write` 與 `if: github.event_name != 'pull_request'` 一律留在 `deploy.yml` 的 job 層。composite action 裡設不了 `permissions`。
- **composite action 不繼承 workflow 層 `env:`** —— `AR_HOST` / `AR_REPO` / `SQL_INSTANCE` 必須當 input 傳。
- **跨 repo 引用**：`uses: adamsourceinfo-org/ci/.github/actions/deploy-service@main`。路徑式 `./.github/actions/…` 會解析到**呼叫端**的 repo，不存在。
- **不擴充 `github-deployer` 的權限。** 它現在只有 `run.admin`、`artifactregistry.writer`、`cloudsql.viewer`。preflight 只能用這些查得到的東西。
- `cloudsql.viewer` **有** `instances.get`、`databases.get`，**沒有** `users.list`。
- `deploy-dev` / `deploy-prod` 裡原有的 instance 與 SA 檢查**保留**，preflight 是加速回饋不是唯一防線。
- `gh run rerun` 沿用舊版 reusable workflow —— 驗證一律推新 commit / 新 tag。
- 所有 repo 的 main 走 PR（`ci`、`hello-cicd`、`hello-db` 有 ruleset）。
- `gh` 要用 `AdamHsu2501`（`gh auth switch --user AdamHsu2501`），`AdamHsuC` 沒有 org 權限。

---

### Task 1: 把 deploy 步驟抽成 composite action

**Files:**
- Create: `ci/.github/actions/deploy-service/action.yml`
- Modify: `ci/.github/workflows/deploy.yml`（`deploy-dev` 的 L346–462、`deploy-prod` 的 L647–764）

**Interfaces:**
- Produces: action 的 12 個 input 與 1 個 output，Task 2 的 preflight 與 Task 6 的驗收都依賴部署行為不變。

| input | required | 說明 |
|---|---|---|
| `service` | ✅ | Cloud Run 服務名 |
| `digest` | ✅ | `sha256:…` |
| `region` | ✅ | |
| `project` | ✅ | `adamsourceinfo-dev` / `-prod` |
| `env_name` | ✅ | `dev` / `prod` |
| `app_version` | ❌ | dev 不傳 |
| `allow_unauthenticated` | ✅ | |
| `runtime_sa` | ✅ | |
| `db_name` | ❌ | 空字串代表不用 DB |
| `ar_host` | ✅ | |
| `ar_repo` | ✅ | |
| `sql_instance` | ✅ | |

output：`url`

- [ ] **Step 1: 先存一份現行行為的基準**

```bash
cd ci
sed -n '357,462p' .github/workflows/deploy.yml > /tmp/deploy-dev-before.txt
sed -n '658,764p' .github/workflows/deploy.yml > /tmp/deploy-prod-before.txt
diff /tmp/deploy-dev-before.txt /tmp/deploy-prod-before.txt
```

Expected：只有 4 處差異，全是 `DIGEST` / `APP_VERSION` / `ENV_NAME` / `PROJECT` 的來源。

- [ ] **Step 2: 建立 action.yml 的骨架**

```yaml
name: deploy-service
description: 把 image 部署到指定環境的 Cloud Run，並套用 .cicd 設定與 Cloud SQL 掛載。
# 這個 action 刻意「不」處理憑證與 permissions —— 兩者都是安全邊界，
# 必須留在 deploy.yml 的 job 層看得見的地方。呼叫前 job 要先跑
# google-github-actions/auth 並帶 permissions: id-token: write。

inputs:
  service:               {required: true,  description: Cloud Run 服務名}
  digest:                {required: true,  description: 'image digest（sha256:…）'}
  region:                {required: true,  description: 部署區域}
  project:               {required: true,  description: 目標 GCP 專案}
  env_name:              {required: true,  description: dev 或 prod，會注入成 APP_ENV}
  app_version:           {required: false, default: '', description: 注入成 APP_VERSION，dev 不傳}
  allow_unauthenticated: {required: true,  description: 'true / false'}
  runtime_sa:            {required: true,  description: 執行身分的 SA ID}
  db_name:               {required: false, default: '', description: 空字串代表不用 Cloud SQL}
  ar_host:               {required: true,  description: Artifact Registry host}
  ar_repo:               {required: true,  description: Artifact Registry repo}
  sql_instance:          {required: true,  description: 該環境的共用 Cloud SQL instance}

outputs:
  url:
    description: 部署後的 Cloud Run URL
    value: ${{ steps.deploy.outputs.url }}

runs:
  using: composite
  steps:
    - name: gcloud run deploy
      id: deploy
      shell: bash
      env:
        SERVICE: ${{ inputs.service }}
        DIGEST: ${{ inputs.digest }}
        REGION: ${{ inputs.region }}
        PROJECT: ${{ inputs.project }}
        ENV_NAME: ${{ inputs.env_name }}
        APP_VERSION: ${{ inputs.app_version }}
        UNAUTH: ${{ inputs.allow_unauthenticated }}
        RUNTIME_SA: ${{ inputs.runtime_sa }}
        DB_NAME: ${{ inputs.db_name }}
        AR_HOST: ${{ inputs.ar_host }}
        AR_REPO: ${{ inputs.ar_repo }}
        SQL_INSTANCE: ${{ inputs.sql_instance }}
      run: |
        # ← 這裡貼 Step 3 搬過來的 106 行
```

- [ ] **Step 3: 把 `deploy-dev` 的 run 內容原封搬進去**

`deploy.yml` 第 357–462 行（`set -euo pipefail` 到 `echo "✅ dev → ${URL}"`）整段搬進 action 的 `run:`，只改兩處：

1. 最後兩行的環境字樣改成通用：
   ```bash
   echo "url=${URL}" >> "$GITHUB_OUTPUT"
   echo "✅ ${ENV_NAME} → ${URL}"
   ```
2. 縮排調整成 action.yml 的層級。

其餘**一個字都不要改** —— 這是純搬移，行為必須逐字相同。

- [ ] **Step 4: `deploy-dev` job 改成 uses**

把 L346–462 那個 step 換成：

```yaml
      - name: 部署
        id: deploy
        uses: adamsourceinfo-org/ci/.github/actions/deploy-service@main
        with:
          service: ${{ needs.verify.outputs.service }}
          digest: ${{ needs.build-push.outputs.digest }}
          region: ${{ needs.verify.outputs.region }}
          project: ${{ env.DEV_PROJECT }}
          env_name: dev
          allow_unauthenticated: ${{ needs.verify.outputs.allow_unauthenticated }}
          runtime_sa: ${{ needs.verify.outputs.runtime_sa }}
          db_name: ${{ needs.verify.outputs.db_name }}
          ar_host: ${{ env.AR_HOST }}
          ar_repo: ${{ env.AR_REPO }}
          sql_instance: ${{ env.SQL_INSTANCE }}
```

- [ ] **Step 5: `deploy-prod` job 改成 uses**

同樣換掉，差別只有四處：

```yaml
          digest: ${{ needs.promote.outputs.digest }}
          project: ${{ env.PROD_PROJECT }}
          env_name: prod
          app_version: ${{ github.ref_name }}
```

- [ ] **Step 6: 確認 job 的 outputs 仍接得到**

兩個 job 的 `outputs:` 若引用 `steps.deploy.outputs.url`，因為 step id 仍是 `deploy`，不用改。確認：

```bash
grep -n "steps.deploy.outputs.url" ci/.github/workflows/deploy.yml
```

- [ ] **Step 7: 驗證 YAML 與行數**

```bash
python3 -c "import yaml;yaml.safe_load(open('ci/.github/workflows/deploy.yml'));print('workflow OK')"
python3 -c "import yaml;yaml.safe_load(open('ci/.github/actions/deploy-service/action.yml'));print('action OK')"
wc -l ci/.github/workflows/deploy.yml   # 預期從 806 降到 ~600
grep -c "permissions:" ci/.github/workflows/deploy.yml   # 邊界仍在 job 層
```

- [ ] **Step 8: Commit**

```bash
cd ci && git add .github/actions/deploy-service/action.yml .github/workflows/deploy.yml
git commit -m "抽出 deploy-service composite action，消掉 117 行複製貼上"
```

---

### Task 2: preflight job

**Files:**
- Modify: `ci/.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: `needs.verify.outputs.{db_name,runtime_sa}`、workflow env 的 `SQL_INSTANCE`
- Produces: 一個在 build 之前擋下缺件的 job；`build-push` 與 `resolve` 的 `needs` 要加上它

- [ ] **Step 1: 加 job**

放在 `build-push` 之前：

```yaml
  # ── 1.5 preflight ────────────────────────────────────────────────────────
  # 在 build 之前確認 GCP 那邊的一次性資源都到位。沒有這個 job 的話，
  # 缺一個 SA 會先白跑 36 秒的 build 並把一個 image 永久留在 AR。
  #
  # 只查「部署身分本來就看得到」的三項。角色綁定 / DB user / GRANT 查不到，
  # 因為那需要 getIamPolicy 與 cloudsql.users.list —— 刻意不為此擴權，
  # 那三項由 ci/scripts/provision-service.sh 在人這一端驗。
  preflight:
    name: 1.5 preflight
    if: github.event_name != 'pull_request' && needs.verify.outputs.db_name != ''
    needs: verify
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: google-github-actions/auth@v2
        with:
          project_id: ${{ github.ref_type == 'tag' && env.PROD_PROJECT || env.DEV_PROJECT }}
          workload_identity_provider: projects/${{ github.ref_type == 'tag' && env.PROD_PROJECT_NUMBER || env.DEV_PROJECT_NUMBER }}/locations/global/workloadIdentityPools/${{ env.WIF_POOL }}/providers/${{ env.WIF_PROVIDER }}
          service_account: ${{ env.DEPLOYER_SA_ID }}@${{ github.ref_type == 'tag' && env.PROD_PROJECT || env.DEV_PROJECT }}.iam.gserviceaccount.com

      - name: 檢查一次性資源
        env:
          PROJECT: ${{ github.ref_type == 'tag' && env.PROD_PROJECT || env.DEV_PROJECT }}
          RUNTIME_SA: ${{ needs.verify.outputs.runtime_sa }}
          DB_NAME: ${{ needs.verify.outputs.db_name }}
        run: |
          set -uo pipefail
          command -v gcloud >/dev/null || { echo "::error::runner 沒有預裝 gcloud"; exit 1; }
          MISSING=0

          # 把 stderr 收下來 —— 「查不到」和「不存在」是兩件事，
          # 印成同一句話會讓人往完全錯的方向查（實測踩過）。
          probe() {  # probe <描述> <補救提示> <指令...>
            local what="$1" hint="$2"; shift 2
            local err
            if err="$("$@" 2>&1 >/dev/null)"; then return 0; fi
            if printf '%s' "$err" | grep -qE 'SERVICE_DISABLED|has not been used in project|is disabled'; then
              local api
              api="$(printf '%s' "$err" | grep -oE '[a-z]+\.googleapis\.com' | head -1)"
              echo "::error::查不到${what} —— ${PROJECT} 沒有啟用 ${api:-必要的 API}："
              echo "::error::  gcloud services enable ${api:-<api>} --project=${PROJECT}"
            else
              echo "::error::${PROJECT} 找不到${what}。${hint}"
            fi
            MISSING=1
          }

          probe "共用 Cloud SQL instance「${SQL_INSTANCE}」" \
                "見 ci/README.md「開共用 instance」。" \
                gcloud sql instances describe "$SQL_INSTANCE" --project="$PROJECT"

          probe "database「${DB_NAME}」" \
                "跑 ci/scripts/provision-service.sh。" \
                gcloud sql databases describe "$DB_NAME" --instance="$SQL_INSTANCE" --project="$PROJECT"

          probe "執行身分「${RUNTIME_SA}」" \
                "跑 ci/scripts/provision-service.sh。" \
                gcloud iam service-accounts describe "${RUNTIME_SA}@${PROJECT}.iam.gserviceaccount.com" --project="$PROJECT"

          if [ "$MISSING" -ne 0 ]; then
            echo "::error::一次性資源不齊，停在 build 之前。一次補齊："
            echo "::error::  ci/scripts/provision-service.sh ${{ needs.verify.outputs.service }} ${RUNTIME_SA} ${DB_NAME}"
            exit 1
          fi
          echo "✅ ${PROJECT}：instance / database / 執行身分都在"
```

- [ ] **Step 2: 不做「順便看 prod」——理由寫進註解**

原設計想在 dev 路徑順便檢查 prod，好讓「prod 忘了 provision」不必等到打 tag。
**放棄這個做法**：這個 job 拿的是 dev 的憑證，看不到 prod，結果會是每次都警告，
而每次都出現的警告等於沒有警告。

真正的根因在別處，且已由 Task 3 解決：`provision-service.sh` 預設 `both`，
兩個環境一起備妥，「prod 忘了做」從一開始就不容易發生。

在 preflight 的註解裡寫明這個取捨，免得以後有人再想加：

```yaml
          # 刻意不順便檢查 prod：這個 job 拿的是本環境的憑證，看不到另一個專案，
          # 加上去只會變成每次都警告。「prod 忘了 provision」的根因在
          # provision-service.sh 預設就做兩個環境。
```

- [ ] **Step 3: 把 preflight 接進依賴鏈**

`build-push` 與 `resolve` 的 `needs` 各加 `preflight`。因為 preflight 在
沒有 `db:` 時被 `if` 跳過，下游要用 `always()` 搭配明確的失敗判斷：

```yaml
  build-push:
    needs: [verify, preflight]
    if: |
      github.event_name != 'pull_request' && github.ref_type == 'branch'
      && !contains(needs.*.result, 'failure')
```

`resolve` 同樣處理（`github.ref_type == 'tag'`）。

- [ ] **Step 4: 驗證 YAML**

```bash
python3 -c "import yaml;d=yaml.safe_load(open('ci/.github/workflows/deploy.yml'));print(list(d['jobs'].keys()))"
```

Expected：job 清單裡有 `preflight`。

- [ ] **Step 5: Commit**

```bash
cd ci && git add .github/workflows/deploy.yml
git commit -m "preflight：在 build 之前查一次性資源，並分清「不存在」與「API 沒開」"
```

---

### Task 3: `provision-service.sh`

**Files:**
- Create: `ci/scripts/provision-service.sh`

**Interfaces:**
- Produces: `provision-service.sh <service> <runtime_sa> <db_name> [dev|prod|both]`，Task 4 的 README 與 Task 2 的錯誤訊息都引用這個介面。

- [ ] **Step 1: 寫腳本**

```bash
#!/usr/bin/env bash
# 幫一個服務備妥「用 Cloud SQL 所需的一切」，兩個環境一次做完。
#
# 為什麼是腳本而不是 README 的步驟清單：這六步裡有三步的失敗模式
# 沒辦法用散文防範 —— 背景 proxy 的就緒等待、隱含的 API 相依、
# 專案 IAM policy 的 read-modify-write 併發。三個都實測踩過。
#
# **這支腳本 CI 永遠不會執行。** 它由 owner 用自己的 gcloud 跑，
# 因為它要做的正是部署身分刻意沒有權限做的事（建 SA、發角色）。
#
# 冪等：每一步先查再做，可以安全重跑。結尾驗收六項，任一不過就非零結束。
#
# 用法：
#   ci/scripts/provision-service.sh payment-foo run-payment-foo payment_foo
#   ci/scripts/provision-service.sh payment-foo run-payment-foo payment_foo prod
set -uo pipefail

SERVICE="${1:?用法: provision-service.sh <service> <runtime_sa> <db_name> [dev|prod|both]}"
SA="${2:?缺少 runtime_sa}"
DB="${3:?缺少 db_name}"
WHICH="${4:-both}"

REGION=asia-east1
INSTANCE=apps-pg
HUMAN="$(gcloud config get-value account 2>/dev/null)"
[ -n "$HUMAN" ] || { echo "gcloud 沒有登入帳號。先跑 gcloud auth login。" >&2; exit 1; }

# SA ID 的規則比 Cloud Run 服務名嚴格，先擋掉才不會做到一半失敗
printf '%s' "$SA" | grep -Eq '^[a-z][-a-z0-9]{4,28}[a-z0-9]$' || {
  echo "runtime_sa '$SA' 不合法：6-30 字元、小寫字母開頭、只能有小寫字母/數字/連字號。" >&2; exit 1; }

case "$WHICH" in
  dev|prod) ENVS="$WHICH" ;;
  both)     ENVS="dev prod" ;;
  *) echo "第四個參數只能是 dev / prod / both。" >&2; exit 1 ;;
esac

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
skip() { printf '  ⏭  %s（已存在）\n' "$*"; }

provision_env() {
  local P="adamsourceinfo-$1"
  local SA_EMAIL="${SA}@${P}.iam.gserviceaccount.com"
  local DB_USER="${SA}@${P}.iam"

  step "$P"

  # 0. API 相依。iam.googleapis.com 沒開的話，CI 的 SA 檢查會說「找不到」
  #    而不是「查不到」—— 專案 owner 自己呼叫得動，所以這個坑只在 CI 裡炸。
  for API in iam.googleapis.com sqladmin.googleapis.com secretmanager.googleapis.com; do
    if gcloud services list --enabled --project="$P" --format='value(config.name)' | grep -qx "$API"; then
      skip "API $API"
    else
      gcloud services enable "$API" --project="$P" --quiet && ok "啟用 API $API"
    fi
  done

  # 1. 執行身分
  if gcloud iam service-accounts describe "$SA_EMAIL" --project="$P" >/dev/null 2>&1; then
    skip "SA $SA"
  else
    gcloud iam service-accounts create "$SA" --project="$P" \
      --display-name="runtime for $SERVICE" --quiet && ok "建立 SA $SA"
  fi

  # 2. 連線路徑。**循序**做，不要放進背景 ——
  #    add-iam-policy-binding 是對專案 policy 做 read-modify-write，
  #    併發會撞 etag 而其中一筆靜靜地沒生效（實測八個掉一個）。
  for R in roles/cloudsql.client roles/cloudsql.instanceUser; do
    if gcloud projects get-iam-policy "$P" --flatten='bindings[].members' \
         --filter="bindings.members:${SA_EMAIL} AND bindings.role:${R}" \
         --format='value(bindings.role)' | grep -q .; then
      skip "$R"
    else
      gcloud projects add-iam-policy-binding "$P" --member="serviceAccount:${SA_EMAIL}" \
        --role="$R" --condition=None --quiet >/dev/null && ok "授 $R"
    fi
  done

  # 3. 讓部署身分能「使用」這個執行身分
  if gcloud iam service-accounts get-iam-policy "$SA_EMAIL" --project="$P" \
       --format='value(bindings.members)' 2>/dev/null | grep -q "github-deployer@${P}"; then
    skip "deployer 的 serviceAccountUser"
  else
    gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" --project="$P" \
      --member="serviceAccount:github-deployer@${P}.iam.gserviceaccount.com" \
      --role=roles/iam.serviceAccountUser --quiet >/dev/null && ok "綁 deployer serviceAccountUser"
  fi

  # 4. 機密。在專案 repo 裡跑的話自動從 .cicd/secrets.<env> 讀名字。
  local SECFILE=".cicd/secrets.$1"
  if [ -f "$SECFILE" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      local NAME="${line#*=}"; NAME="${NAME%%:*}"
      [ -n "$NAME" ] || continue
      if gcloud secrets get-iam-policy "$NAME" --project="$P" --format='value(bindings.members)' 2>/dev/null | grep -q "$SA_EMAIL"; then
        skip "secret $NAME"
      else
        gcloud secrets add-iam-policy-binding "$NAME" --project="$P" \
          --member="serviceAccount:${SA_EMAIL}" \
          --role=roles/secretmanager.secretAccessor --quiet >/dev/null && ok "授權 secret $NAME"
      fi
    done < <(grep -vE '^\s*(#|$)' "$SECFILE")
  else
    printf '  ℹ  找不到 %s（不在專案 repo 裡跑？）——有機密的話要自己授權給 %s\n' "$SECFILE" "$SA_EMAIL"
  fi

  # 5. database 與 IAM DB user。
  #    IAM 使用者要用去掉 .gserviceaccount.com 的短格式，否則 API 回 400。
  #    這個短格式正好就是 CI 注入的 DB_USER，兩邊必須逐字相同。
  if gcloud sql databases describe "$DB" --instance="$INSTANCE" --project="$P" >/dev/null 2>&1; then
    skip "database $DB"
  else
    gcloud sql databases create "$DB" --instance="$INSTANCE" --project="$P" --quiet >/dev/null && ok "建立 database $DB"
  fi
  if gcloud sql users list --instance="$INSTANCE" --project="$P" --format='value(name)' | grep -qx "$DB_USER"; then
    skip "DB user $DB_USER"
  else
    gcloud sql users create "$DB_USER" --instance="$INSTANCE" --project="$P" \
      --type=cloud_iam_service_account --quiet >/dev/null && ok "建立 DB user $DB_USER"
  fi

  # 6. REVOKE / GRANT。這步不能省 —— Postgres 預設讓 PUBLIC 連任何 database，
  #    共用 instance 下少了 REVOKE，每服務一個 SA 只是換了名字。
  local PW PORT PID
  PW="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
  PORT=$(( 5500 + RANDOM % 400 ))
  gcloud sql users set-password postgres --instance="$INSTANCE" --project="$P" \
    --password="$PW" --quiet >/dev/null
  cloud-sql-proxy "${P}:${REGION}:${INSTANCE}" --port "$PORT" \
    --token "$(gcloud auth print-access-token)" >/tmp/provision-proxy-$PORT.log 2>&1 &
  PID=$!
  # proxy 要一兩秒才開始監聽。少了這個等待就是 Connection refused（實測踩過）。
  local i=0
  until nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 30 ] && { echo "  ❌ proxy 起不來，看 /tmp/provision-proxy-$PORT.log" >&2; kill $PID 2>/dev/null; return 1; }
    sleep 1
  done

  PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q <<SQL && ok "REVOKE / GRANT"
REVOKE CONNECT ON DATABASE ${DB} FROM PUBLIC;
GRANT ALL PRIVILEGES ON DATABASE ${DB} TO "${DB_USER}";
GRANT ALL ON SCHEMA public TO "${DB_USER}";
GRANT CONNECT ON DATABASE ${DB} TO "${HUMAN}";
GRANT "${DB_USER}" TO "${HUMAN}";
SQL

  # ── 驗收六項 ──────────────────────────────────────────────────────
  local FAIL=0
  printf '\n  驗收：\n'
  chk() { if eval "$2" >/dev/null 2>&1; then printf '    ✅ %s\n' "$1"; else printf '    ❌ %s\n' "$1"; FAIL=1; fi; }

  chk "SA 存在" "gcloud iam service-accounts describe '$SA_EMAIL' --project='$P'"
  chk "cloudsql.client + instanceUser" \
      "[ \$(gcloud projects get-iam-policy '$P' --flatten='bindings[].members' --filter=\"bindings.members:${SA_EMAIL} AND bindings.role:roles/cloudsql\" --format='value(bindings.role)' | wc -l) -eq 2 ]"
  chk "deployer 的 serviceAccountUser" \
      "gcloud iam service-accounts get-iam-policy '$SA_EMAIL' --project='$P' --format='value(bindings.members)' | grep -q 'github-deployer@${P}'"
  chk "database $DB" "gcloud sql databases describe '$DB' --instance='$INSTANCE' --project='$P'"
  chk "DB user $DB_USER" \
      "gcloud sql users list --instance='$INSTANCE' --project='$P' --format='value(name)' | grep -qx '$DB_USER'"
  # PUBLIC 那筆（開頭是 =）不能有 c
  chk "PUBLIC 沒有 CONNECT" \
      "! PGPASSWORD='$PW' psql -h 127.0.0.1 -p $PORT -U postgres -d postgres -At -c \"SELECT array_to_string(datacl,' ') FROM pg_database WHERE datname='$DB'\" | tr ' ' '\n' | grep -qE '^=[A-Za-z]*c'"

  kill $PID 2>/dev/null
  [ "$FAIL" -eq 0 ] || { printf '\n  ❌ %s 驗收未通過\n' "$P" >&2; return 1; }
  printf '  ✅ %s 全部通過\n' "$P"
}

RC=0
for E in $ENVS; do provision_env "$E" || RC=1; done
printf '\n'
[ "$RC" -eq 0 ] && echo "完成。接著推一次 main（或 gh workflow run）觸發部署。" || echo "有環境未通過，見上面 ❌。" >&2
exit "$RC"
```

- [ ] **Step 2: 語法檢查**

```bash
bash -n ci/scripts/provision-service.sh && echo "語法 OK"
chmod +x ci/scripts/provision-service.sh
command -v shellcheck >/dev/null && shellcheck ci/scripts/provision-service.sh || echo "（本機沒 shellcheck，跳過）"
```

- [ ] **Step 3: 對已備妥的服務乾跑，驗冪等**

```bash
cd hello-probe && ../ci/scripts/provision-service.sh hello-probe run-hello-probe hello_probe
```

Expected：全部 `⏭ 已存在`，六項驗收全 ✅，結束碼 0。

- [ ] **Step 4: Commit**

```bash
cd ci && git add scripts/provision-service.sh
git commit -m "把一次性 runbook 換成可驗收的腳本"
```

---

### Task 4: README 改寫

**Files:**
- Modify: `ci/README.md`

- [ ] **Step 1: 責任分界表加一列**

在「你（owner）／建 repo、分支保護」那列之後插入：

```markdown
| **你（owner）** | 服務的執行身分、database、`GRANT` | 每服務每環境一次 | `ci/scripts/provision-service.sh` |
```

- [ ] **Step 2: 「開一個新專案」開頭加一句**

在 `gh repo create` 那個 code block 之前：

```markdown
> **服務要用資料庫的話，先跑 `ci/scripts/provision-service.sh` 再推第一版**，
> 否則第一次部署會停在 preflight 並告訴你缺什麼。硬失敗是設計，不是壞掉。
```

- [ ] **Step 3: 「一次性清單」整段換成腳本用法**

保留「為什麼 CI 不自動做」與「為什麼一定要 REVOKE」兩段說明，把六步的
指令換成：

```bash
# 在專案 repo 裡跑（這樣它讀得到 .cicd/secrets.* 自動授權機密）
../ci/scripts/provision-service.sh my-app run-my-app my_app
```

並列出它做了哪六件事與結尾驗收哪六項。加一句：可以安全重跑，每步先查再做。

- [ ] **Step 4: 新增「PR 綠燈不代表部署會過」**

放在「PR 拿不到憑證」那節後面：

```markdown
### PR 綠燈不代表部署會過

`verify` 刻意沒有 GCP 憑證（見上節），所以 `runtime_sa` 指向不存在的 SA、
database 還沒建這類問題，**PR 階段查不到**。最早的 GCP 檢查是 `preflight`，
它在 merge 進 main 之後、build 之前跑。

這是安全邊界的代價，不是疏漏：要讓 PR 查得到，就得讓 PR 拿得到雲端憑證。
```

- [ ] **Step 5: 常見錯誤表補 preflight 的訊息**

```markdown
| preflight `找不到 database「…」` | 還沒 provision。跑 `ci/scripts/provision-service.sh` |
| preflight `查不到… 沒有啟用 …googleapis.com` | 該專案缺 API，訊息裡有 enable 指令 |
```

- [ ] **Step 6: Commit**

```bash
cd ci && git add README.md
git commit -m "README：runbook 換成腳本，補上 PR 綠燈的預期"
```

---

### Task 5: Artifact Registry 清理政策

**Files:** 無檔案異動（GCP 設定）＋ README 一段

- [ ] **Step 1: 先 dry-run 看會刪什麼**

```bash
cat > /tmp/ar-policy.json <<'JSON'
[
  {"name":"keep-recent-tagged","action":{"type":"Keep"},
   "mostRecentVersions":{"keepCount":10}},
  {"name":"delete-old-untagged","action":{"type":"Delete"},
   "condition":{"tagState":"untagged","olderThan":"30d"}}
]
JSON
for P in adamsourceinfo-dev adamsourceinfo-prod; do
  gcloud artifacts repositories set-cleanup-policies apps \
    --location=asia-east1 --project="$P" --policy=/tmp/ar-policy.json --dry-run
done
```

Expected：只列出無 tag 且超過 30 天的項目。

- [ ] **Step 2: 正式套用**

```bash
for P in adamsourceinfo-dev adamsourceinfo-prod; do
  gcloud artifacts repositories set-cleanup-policies apps \
    --location=asia-east1 --project="$P" --policy=/tmp/ar-policy.json --no-dry-run
  gcloud artifacts repositories describe apps --location=asia-east1 --project="$P" \
    --format='value(cleanupPolicies)'
done
```

- [ ] **Step 3: 寫進 README 的「一次性設定」**

在 Artifact Registry 建立指令之後加上 cleanup policy 的設定，並說明理由：
每次 push 都新增 image，沒有回收的話只會單向成長。

- [ ] **Step 4: Commit**

```bash
cd ci && git add README.md
git commit -m "AR 加上清理政策：保留最近 10 個 tagged、刪 30 天前的 untagged"
```

---

### Task 6: 用 `hello-probe` 驗收

**Files:**
- Modify: `hello-probe/.cicd/config.yml`（暫時性，驗完還原）

- [ ] **Step 1: 行為不變**

`ci` 的分支合併進 main 後，推一次 `hello-probe` 的 main：

```bash
cd hello-probe && git commit --allow-empty -m "驗收：抽取後行為應不變" && git push
gh run list --repo adamsourceinfo-org/hello-probe --limit 1 --json status,conclusion
URL=$(gcloud run services describe hello-probe --project=adamsourceinfo-dev --region=asia-east1 --format='value(status.url)')
curl -s "$URL/" | python3 -m json.tool
```

Expected：`ok=true`、`instance` 是 `apps-pg`、`server_user` 是 `run-hello-probe@…`。

- [ ] **Step 2: preflight 擋得住缺件**

```bash
cd hello-probe && sed -i '' 's/name: hello_probe/name: hello_nope/' .cicd/config.yml
git commit -am "驗收：故意指向不存在的 database" && git push
gh run view --repo adamsourceinfo-org/hello-probe --log-failed | grep "##\[error\]"
```

Expected：`1.5 preflight` 失敗，訊息點名 `hello_nope`，且 `2 build-push` **沒有執行**。

- [ ] **Step 3: 還原**

```bash
cd hello-probe && sed -i '' 's/name: hello_nope/name: hello_probe/' .cicd/config.yml
git commit -am "還原" && git push
```

- [ ] **Step 4: 驗那條從沒跑過的「沒有 `db:`」路徑**

```bash
cd hello-probe && cp .cicd/config.yml /tmp/probe-config.bak
cat > .cicd/config.yml <<'EOF'
health_path: /
EOF
git commit -am "驗收：不宣告 db，應退回 run-runtime" && git push
```

Expected：`preflight` 被 `if` 跳過、部署成功、SA 是 `run-runtime`、
健康檢查回報 `db.configured: false`。

```bash
gcloud run services describe hello-probe --project=adamsourceinfo-dev --region=asia-east1 \
  --format="value(spec.template.spec.serviceAccountName)"
```

- [ ] **Step 5: 還原並確認回到有 DB 的狀態**

```bash
cd hello-probe && cp /tmp/probe-config.bak .cicd/config.yml
git commit -am "還原 db 設定" && git push
```

⚠️ 還原後仍會掛著 `run-runtime` 期間的殘留：`--service-account` 是取代式所以會自動換回，
但 `DB_NAME` 等環境變數是 `--update-env-vars`（合併式）不會消失。確認健康檢查
回到 `ok: true` 即可。

- [ ] **Step 6: tag 路徑**

```bash
cd hello-probe && git tag v0.2.0 && git push origin v0.2.0
URL=$(gcloud run services describe hello-probe --project=adamsourceinfo-prod --region=asia-east1 --format='value(status.url)')
curl -s "$URL/" | python3 -m json.tool
```

Expected：`version: v0.2.0`、`ok: true`。

- [ ] **Step 7: 腳本抓得到被破壞的狀態**

```bash
gcloud projects remove-iam-policy-binding adamsourceinfo-dev \
  --member="serviceAccount:run-hello-probe@adamsourceinfo-dev.iam.gserviceaccount.com" \
  --role=roles/cloudsql.client --condition=None --quiet
cd hello-probe && ../ci/scripts/provision-service.sh hello-probe run-hello-probe hello_probe dev
```

Expected：腳本補回該角色並在驗收中全部 ✅、結束碼 0。
