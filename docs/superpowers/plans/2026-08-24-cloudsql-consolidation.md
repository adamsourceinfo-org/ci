# Cloud SQL 合併實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 dev/prod 的 8 台 Cloud SQL instance 合併成各一台 `apps-pg`，服務靠 database 分隔、靠每服務一個 SA 與 Postgres GRANT 做隔離，每月省 $51.42。

**Architecture:** instance 由平台（`deploy.yml` 的 `SQL_INSTANCE`）宣告，專案端只在 `.cicd/config.yml` 宣告 `db.name` 與 `runtime_sa`。隔離不來自 IAM（Cloud SQL 沒有 instance 層級 policy），只來自 `REVOKE CONNECT ON DATABASE … FROM PUBLIC` 加上逐服務 `GRANT`。SA 與 database 是人工一次性資源，CI 偵測不到就硬失敗並印出指令。

**Tech Stack:** GCP Cloud SQL for PostgreSQL 17、Cloud Run、GitHub Actions（reusable workflow）、`gcloud`、`cloud-sql-proxy`、`psql`、`yq`（runner 端）

**Spec:** `ci/docs/superpowers/specs/2026-08-24-cloudsql-consolidation-design.md`

## Global Constraints

- 區域一律 `asia-east1`；instance 名稱兩個環境都叫 `apps-pg`
- 服務 ↔ SA ↔ database 對照（dev/prod 相同）：
  | 服務 | `runtime_sa` | `db.name` |
  |---|---|---|
  | `hello-cicd` | `run-hello-cicd` | `hello_cicd` |
  | `hello-db` | `run-hello-db` | `hello_db` |
  | `payment-paypal` | `run-payment-paypal` | `payment_paypal` |
  | `payment-ecpay` | `run-payment-ecpay` | `payment_ecpay` |
- IAM DB user 一律用去掉 `.gserviceaccount.com` 的短格式 `<sa>@<project>.iam`，必須與 CI 注入的 `DB_USER` 逐字相同
- `REVOKE CONNECT ON DATABASE <db> FROM PUBLIC` 不可省略——少了它隔離是假的
- CI 一律 `--update-*` / `--add-*`，從不 `--set-*`
- Phase 3 之前不刪除任何舊 instance
- `gh run rerun` 會沿用舊版 reusable workflow，一律推新 commit / 新 tag 觸發
- **tag 規則**：CI 只收 `vX.Y.Z`，`v20260824-1` 這種會被擋下。打之前先 `git tag -l` 看現有的再遞增。
  現況（2026-08-24）：`hello-db` v1.0.0、`hello-cicd` v0.6.0、`payment-ecpay` v0.1.0、`payment-paypal` v0.2.1
- **`gh run watch` 不帶 run id 會進互動模式**，在非互動 shell 會失敗。改用
  `gh run list --repo <repo> --limit 1 --json databaseId,status,conclusion` 輪詢
- **prod 兩個金流 database 完全是空的**（只有 `schema_migrations`），dev 有測試資料。
  migration 由 app 啟動時自動套用（`run_migrations()` + advisory lock），不需人工跑；
  但 migration 失敗**不會擋住啟動**，所以驗證要看健康檢查的 `db.ok`，不能只看 HTTP 200

---

### Task 1: dev 的 Phase 0 一次性資源

**Files:**
- 無檔案異動（純 GCP 資源）
- 驗證腳本：`/tmp` 內臨時，不進版控

**Interfaces:**
- Consumes: 已建立的 `adamsourceinfo-dev:asia-east1:apps-pg`
- Produces: 四個 SA（`run-hello-cicd` / `run-hello-db` / `run-payment-paypal` / `run-payment-ecpay`）、四個 database、四個 IAM DB user、逐 database 的 GRANT。Task 6–9 的部署依賴這些存在。

- [ ] **Step 1: 等 instance 就緒**

```bash
until [ "$(gcloud sql instances describe apps-pg --project=adamsourceinfo-dev --format='value(state)')" = RUNNABLE ]; do sleep 20; done
echo dev apps-pg RUNNABLE
```

- [ ] **Step 2: 建人工 IAM user**

```bash
gcloud sql users create adamsourceinfo@gmail.com \
  --instance=apps-pg --project=adamsourceinfo-dev --type=cloud_iam_user
```

- [ ] **Step 3: 建四個 SA、授兩個 cloudsql 角色、綁 deployer 的 serviceAccountUser**

```bash
P=adamsourceinfo-dev
for PAIR in "hello-cicd:run-hello-cicd" "hello-db:run-hello-db" \
            "payment-paypal:run-payment-paypal" "payment-ecpay:run-payment-ecpay"; do
  SVC="${PAIR%%:*}"; SA="${PAIR##*:}"
  gcloud iam service-accounts create "$SA" --project="$P" \
    --display-name="runtime: $SVC" --quiet
  for R in roles/cloudsql.client roles/cloudsql.instanceUser; do
    gcloud projects add-iam-policy-binding "$P" \
      --member="serviceAccount:${SA}@${P}.iam.gserviceaccount.com" \
      --role="$R" --condition=None --quiet >/dev/null
  done
  gcloud iam service-accounts add-iam-policy-binding \
    "${SA}@${P}.iam.gserviceaccount.com" --project="$P" \
    --member="serviceAccount:github-deployer@${P}.iam.gserviceaccount.com" \
    --role=roles/iam.serviceAccountUser --quiet >/dev/null
done
```

- [ ] **Step 4: 補 secret accessor（最容易漏的一步）**

```bash
P=adamsourceinfo-dev
gcloud secrets add-iam-policy-binding payment-paypal-client-secret-dev --project="$P" \
  --member="serviceAccount:run-payment-paypal@${P}.iam.gserviceaccount.com" \
  --role=roles/secretmanager.secretAccessor --quiet >/dev/null
for S in payment-ecpay-hash-iv-dev payment-ecpay-hash-key-dev; do
  gcloud secrets add-iam-policy-binding "$S" --project="$P" \
    --member="serviceAccount:run-payment-ecpay@${P}.iam.gserviceaccount.com" \
    --role=roles/secretmanager.secretAccessor --quiet >/dev/null
done
```

- [ ] **Step 5: 建四個 database 與四個 IAM DB user**

```bash
P=adamsourceinfo-dev
for PAIR in "hello_cicd:run-hello-cicd" "hello_db:run-hello-db" \
            "payment_paypal:run-payment-paypal" "payment_ecpay:run-payment-ecpay"; do
  DB="${PAIR%%:*}"; SA="${PAIR##*:}"
  gcloud sql databases create "$DB" --instance=apps-pg --project="$P" --quiet
  gcloud sql users create "${SA}@${P}.iam" --instance=apps-pg --project="$P" \
    --type=cloud_iam_service_account --quiet
done
```

- [ ] **Step 6: 設一次性 postgres 密碼、起 proxy、下 REVOKE/GRANT**

```bash
P=adamsourceinfo-dev
export PGPASSWORD="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
gcloud sql users set-password postgres --instance=apps-pg --project="$P" \
  --password="$PGPASSWORD" --quiet
cloud-sql-proxy "${P}:asia-east1:apps-pg" --port 5433 \
  --token "$(gcloud auth print-access-token)" &
sleep 8
for PAIR in "hello_cicd:run-hello-cicd" "hello_db:run-hello-db" \
            "payment_paypal:run-payment-paypal" "payment_ecpay:run-payment-ecpay"; do
  DB="${PAIR%%:*}"; SA="${PAIR##*:}"
  psql -h 127.0.0.1 -p 5433 -U postgres -d "$DB" -v ON_ERROR_STOP=1 <<SQL
REVOKE CONNECT ON DATABASE ${DB} FROM PUBLIC;
GRANT ALL PRIVILEGES ON DATABASE ${DB} TO "${SA}@${P}.iam";
GRANT ALL ON SCHEMA public TO "${SA}@${P}.iam";
GRANT CONNECT ON DATABASE ${DB} TO "adamsourceinfo@gmail.com";
SQL
done
```

`GRANT CONNECT … TO "adamsourceinfo@gmail.com"` 是刻意的：`REVOKE … FROM PUBLIC`
之後人工帳號也連不進去，這一行把管理用途留回來。

- [ ] **Step 7: 驗證隔離真的生效**

```bash
psql -h 127.0.0.1 -p 5433 -U postgres -d postgres -t -c \
  "SELECT datname, datacl FROM pg_database WHERE datname LIKE 'hello%' OR datname LIKE 'payment%';"
```

Expected：每個 database 的 `datacl` 只含 `postgres`、對應的 `run-*@…iam`、
`adamsourceinfo@gmail.com`，**不含 `=Tc/`（PUBLIC 的 CONNECT）**。

- [ ] **Step 8: 收掉 proxy**

```bash
kill %1 2>/dev/null; unset PGPASSWORD
```

---

### Task 2: prod 的 Phase 0 一次性資源

**Files:** 無檔案異動

**Interfaces:**
- Consumes: 已建立的 `adamsourceinfo-prod:asia-east1:apps-pg`
- Produces: 與 Task 1 對稱的四個 SA / database / DB user / GRANT

- [ ] **Step 1: 等 instance 就緒**

```bash
until [ "$(gcloud sql instances describe apps-pg --project=adamsourceinfo-prod --format='value(state)')" = RUNNABLE ]; do sleep 20; done
echo prod apps-pg RUNNABLE
```

- [ ] **Step 2: 建人工 IAM user、四個 SA、角色與綁定**

```bash
P=adamsourceinfo-prod
gcloud sql users create adamsourceinfo@gmail.com \
  --instance=apps-pg --project="$P" --type=cloud_iam_user
for PAIR in "hello-cicd:run-hello-cicd" "hello-db:run-hello-db" \
            "payment-paypal:run-payment-paypal" "payment-ecpay:run-payment-ecpay"; do
  SVC="${PAIR%%:*}"; SA="${PAIR##*:}"
  gcloud iam service-accounts create "$SA" --project="$P" \
    --display-name="runtime: $SVC" --quiet
  for R in roles/cloudsql.client roles/cloudsql.instanceUser; do
    gcloud projects add-iam-policy-binding "$P" \
      --member="serviceAccount:${SA}@${P}.iam.gserviceaccount.com" \
      --role="$R" --condition=None --quiet >/dev/null
  done
  gcloud iam service-accounts add-iam-policy-binding \
    "${SA}@${P}.iam.gserviceaccount.com" --project="$P" \
    --member="serviceAccount:github-deployer@${P}.iam.gserviceaccount.com" \
    --role=roles/iam.serviceAccountUser --quiet >/dev/null
done
```

- [ ] **Step 3: secret accessor（名稱結尾是 `-prod`）**

```bash
P=adamsourceinfo-prod
gcloud secrets add-iam-policy-binding payment-paypal-client-secret-prod --project="$P" \
  --member="serviceAccount:run-payment-paypal@${P}.iam.gserviceaccount.com" \
  --role=roles/secretmanager.secretAccessor --quiet >/dev/null
for S in payment-ecpay-hash-iv-prod payment-ecpay-hash-key-prod; do
  gcloud secrets add-iam-policy-binding "$S" --project="$P" \
    --member="serviceAccount:run-payment-ecpay@${P}.iam.gserviceaccount.com" \
    --role=roles/secretmanager.secretAccessor --quiet >/dev/null
done
```

- [ ] **Step 4: 建四個 database 與四個 IAM DB user**

```bash
P=adamsourceinfo-prod
for PAIR in "hello_cicd:run-hello-cicd" "hello_db:run-hello-db" \
            "payment_paypal:run-payment-paypal" "payment_ecpay:run-payment-ecpay"; do
  DB="${PAIR%%:*}"; SA="${PAIR##*:}"
  gcloud sql databases create "$DB" --instance=apps-pg --project="$P" --quiet
  gcloud sql users create "${SA}@${P}.iam" --instance=apps-pg --project="$P" \
    --type=cloud_iam_service_account --quiet
done
```

- [ ] **Step 5: REVOKE/GRANT（proxy 用 5434，與 dev 的 5433 錯開）**

```bash
P=adamsourceinfo-prod
export PGPASSWORD="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
gcloud sql users set-password postgres --instance=apps-pg --project="$P" \
  --password="$PGPASSWORD" --quiet
cloud-sql-proxy "${P}:asia-east1:apps-pg" --port 5434 \
  --token "$(gcloud auth print-access-token)" &
sleep 8
for PAIR in "hello_cicd:run-hello-cicd" "hello_db:run-hello-db" \
            "payment_paypal:run-payment-paypal" "payment_ecpay:run-payment-ecpay"; do
  DB="${PAIR%%:*}"; SA="${PAIR##*:}"
  psql -h 127.0.0.1 -p 5434 -U postgres -d "$DB" -v ON_ERROR_STOP=1 <<SQL
REVOKE CONNECT ON DATABASE ${DB} FROM PUBLIC;
GRANT ALL PRIVILEGES ON DATABASE ${DB} TO "${SA}@${P}.iam";
GRANT ALL ON SCHEMA public TO "${SA}@${P}.iam";
GRANT CONNECT ON DATABASE ${DB} TO "adamsourceinfo@gmail.com";
SQL
done
```

- [ ] **Step 6: 驗證隔離並收掉 proxy**

```bash
psql -h 127.0.0.1 -p 5434 -U postgres -d postgres -t -c \
  "SELECT datname, datacl FROM pg_database WHERE datname LIKE 'hello%' OR datname LIKE 'payment%';"
kill %1 2>/dev/null; unset PGPASSWORD
```

Expected：每個 database 的 `datacl` 不含 `=Tc/`（PUBLIC 的 CONNECT）。

---

### Task 3: `deploy.yml` 六處改造

**Files:**
- Modify: `ci/.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: Task 1/2 建立的 SA 與 database
- Produces: `verify` job 新增 output `runtime_sa`、移除 `db_instance`；deploy-dev 與 promote 都改用 `SQL_INSTANCE` 與 `runtime_sa`

- [ ] **Step 1: `env:` 加 `SQL_INSTANCE`**

在 `RUNTIME_SA_ID: run-runtime` 下一行加：

```yaml
  # 一個環境一台。服務靠 database 分隔，instance 由平台決定 ——
  # 專案端沒有這個欄位可以寫錯。
  SQL_INSTANCE: apps-pg
```

- [ ] **Step 2: config 解析：`ALLOWED` 加 `runtime_sa`，`db` 子 key 只剩 `name`**

```bash
ALLOWED="service region health_path dockerfile allow_unauthenticated runtime_sa db"
```

`db` 子 key 迴圈改成只接受 `name`，並對 `instance` 給遷移訊息：

```bash
for K in $(yq -r '.db // {} | keys | .[]' "$CFG"); do
  case "$K" in
    name) ;;
    instance)
      echo "::error::${CFG} 的 db.instance 已移除 —— instance 現在由平台決定"
      echo "::error::（一個環境一台，服務靠 database 分隔）。請刪掉這一行，只留 db.name。"
      exit 1 ;;
    *) echo "::error::${CFG} 的 db 底下有不認得的設定 '${K}'。可用的是：name"; exit 1 ;;
  esac
done
```

- [ ] **Step 3: 讀 `runtime_sa`、驗格式、驗「宣告 db 就必須給 runtime_sa」**

把 `DB_INSTANCE="$(cfg '.db.instance' '')"` 整行刪掉，改成：

```bash
DB_NAME="$(cfg '.db.name' '')"
RUNTIME_SA="$(cfg '.runtime_sa' "$RUNTIME_SA_ID")"

if [ -n "$DB_NAME" ] && [ "$RUNTIME_SA" = "$RUNTIME_SA_ID" ]; then
  echo "::error::${CFG} 宣告了 db 就必須指定 runtime_sa —— 共用的 ${RUNTIME_SA_ID} 沒有 Cloud SQL 權限。"
  echo "::error::  runtime_sa: run-<服務名>"
  exit 1
fi
if ! printf '%s' "$RUNTIME_SA" | grep -Eq '^[a-z][-a-z0-9]{4,28}[a-z0-9]$'; then
  echo "::error::runtime_sa '${RUNTIME_SA}' 不是合法的 service account ID（6-30 字元，小寫字母開頭，只能有小寫字母/數字/連字號）。"
  exit 1
fi
```

原本 `if [ -n "$DB_INSTANCE" ] && [ -z "$DB_NAME" ]` 那段整個刪掉（`db.instance` 已不存在）。

- [ ] **Step 4: outputs 換掉**

`echo "db_instance=$DB_INSTANCE"` → `echo "runtime_sa=$RUNTIME_SA"`；
job 的 `outputs:` 區塊同步把 `db_instance` 改成 `runtime_sa`；
`[ -n "$DB_INSTANCE" ] && echo "   Cloud SQL：…"` 那行改成：

```bash
[ -n "$DB_NAME" ] && echo "   Cloud SQL：${SQL_INSTANCE} / ${DB_NAME}（執行身分 ${RUNTIME_SA}）"
```

- [ ] **Step 5: `.cicd` 契約檢查的錯誤訊息**

`DB_INSTANCE` / `DB_NAME` 那個迴圈的提示改成：

```bash
echo "::error::  db:"
echo "::error::    name: <database 名稱>   # instance 由平台決定，不用寫"
```

- [ ] **Step 6: 兩處 Cloud SQL 推導段（deploy-dev 與 promote）**

兩處都把整段換成：

```bash
if [ -n "${DB_NAME:-}" ]; then
  ICN="${PROJECT}:${REGION}:${SQL_INSTANCE}"

  if ! gcloud sql instances describe "$SQL_INSTANCE" --project="$PROJECT" >/dev/null 2>&1; then
    echo "::error::${PROJECT} 找不到共用 Cloud SQL instance「${SQL_INSTANCE}」。"
    echo "::error::這是平台級的一次性資源，見 ci/README.md「開共用 instance」。"
    exit 1
  fi

  # 執行身分也是一次性資源。CI 沒有 iam.* 權限，刻意不自動建立 ——
  # 一個能建 SA 又能發角色的部署身分等於能把任何權限發給自己。
  if ! gcloud iam service-accounts describe \
       "${RUNTIME_SA}@${PROJECT}.iam.gserviceaccount.com" --project="$PROJECT" >/dev/null 2>&1; then
    echo "::error::${PROJECT} 找不到執行身分「${RUNTIME_SA}」（.cicd/config.yml 的 runtime_sa）。"
    echo "::error::這是一次性資源，要有 GCP 權限的人跑一次，不是 CI 的職責："
    echo "::error::  gcloud iam service-accounts create ${RUNTIME_SA} --project=${PROJECT}"
    echo "::error::還要授 cloudsql.client / cloudsql.instanceUser、綁 deployer 的 serviceAccountUser、"
    echo "::error::補 secret accessor、建 database、建 IAM DB user、下 REVOKE/GRANT ——"
    echo "::error::完整步驟見 ci/README.md「服務要用資料庫」。"
    exit 1
  fi

  PAIRS="${PAIRS}@@DB_NAME=${DB_NAME}"
  PAIRS="${PAIRS}@@INSTANCE_CONNECTION_NAME=${ICN}@@DB_USER=${RUNTIME_SA}@${PROJECT}.iam"
  echo "已推導 Cloud SQL：${ICN} / ${DB_NAME}（DB 帳號 ${RUNTIME_SA}@${PROJECT}.iam）"
fi
```

兩處 job 的 `env:` 區塊把 `DB_INSTANCE: ${{ needs.verify.outputs.db_instance }}`
改成 `RUNTIME_SA: ${{ needs.verify.outputs.runtime_sa }}`，並加
`SQL_INSTANCE: ${{ env.SQL_INSTANCE }}` 若該 step 取不到。

- [ ] **Step 7: 兩處 `--service-account`**

```bash
--service-account="${RUNTIME_SA}@${PROJECT}.iam.gserviceaccount.com"
```

- [ ] **Step 8: 語法驗證**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('ci/.github/workflows/deploy.yml')); print('YAML OK')"
grep -c 'RUNTIME_SA}' ci/.github/workflows/deploy.yml   # 期望 ≥ 6（兩處推導 + 兩處 service-account + 訊息）
grep -c 'DB_INSTANCE' ci/.github/workflows/deploy.yml    # 期望只剩契約檢查那幾行
```

- [ ] **Step 9: Commit**

```bash
cd ci && git add .github/workflows/deploy.yml
git commit -m "CI：instance 由平台決定，執行身分改為每服務一個 SA"
```

---

### Task 4: `README.md` 五段改寫

**Files:**
- Modify: `ci/README.md`

**Interfaces:**
- Consumes: Task 3 定下的 `runtime_sa` 契約
- Produces: 開發者照著就能自助完成一次性設定的清單

- [ ] **Step 1: 「一次性設定」段**

`run-runtime` 的註解改成「**沒有自己資料庫的服務**的預設執行身分」，並把它的兩個
cloudsql 角色從一次性設定裡拿掉（改到 Phase 3 撤銷）。新增「開共用 instance」：

```bash
# 5.5 每個環境一台 Cloud SQL。服務靠 database 分隔，不是靠 instance。
gcloud sql instances create apps-pg --project="$PROJECT" --region=asia-east1 \
  --edition=ENTERPRISE --database-version=POSTGRES_17 --tier=db-f1-micro \
  --storage-size=10 --storage-type=HDD \
  --database-flags=cloudsql.iam_authentication=on \
  --backup-start-time=18:00 --quiet
```

- [ ] **Step 2: 「`.cicd/config.yml`」契約段**

```yaml
service: my-app            # 預設用 repo 名稱
region: asia-east1
health_path: /healthz      # 預設 /
dockerfile: Dockerfile
allow_unauthenticated: true

runtime_sa: run-my-app     # 要用 Cloud SQL 就必填；沒有 db 時預設 run-runtime
db:                        # 要用 Cloud SQL 才需要，只宣告一次
  name: my_app             # instance 由平台決定（一個環境一台 apps-pg）
```

- [ ] **Step 3: 「服務要用資料庫」整段重寫**

改成一張七步的一次性清單（建 SA → 兩個 cloudsql 角色 → deployer 的 serviceAccountUser
→ secret accessor → 建 database → 建 IAM DB user → REVOKE/GRANT），並把
`REVOKE CONNECT … FROM PUBLIC` 標成不可省略。刪掉舊的「開 instance」與
「dev 不用時可停機」兩段（停機省不了錢，理由寫進去）。

- [ ] **Step 4: 「設定與機密」段**

secret 授權對象從 `run-runtime` 改成該服務的 SA：

```bash
gcloud secrets add-iam-policy-binding my-app-api-key-dev --project=adamsourceinfo-dev \
  --member="serviceAccount:run-my-app@adamsourceinfo-dev.iam.gserviceaccount.com" \
  --role=roles/secretmanager.secretAccessor
```

- [ ] **Step 5: 「權限模型」表與「常見錯誤」**

權限模型的「執行身分」列改成「`run-<服務>`（有 DB）／`run-runtime`（沒有 DB）」。
常見錯誤新增三條：

| 症狀 | 原因 |
|---|---|
| `找不到執行身分「run-…」` | SA 還沒建，照「服務要用資料庫」跑一次 |
| `runtime_sa '…' 不是合法的 service account ID` | 6–30 字元、小寫字母開頭 |
| 部署成功但連 DB 得到 `permission denied for database` | 漏了 `GRANT`，或 SA 指到別的服務（fail closed） |

- [ ] **Step 6: Commit**

```bash
cd ci && git add README.md && git commit -m "README：合併後的一次性清單與 runtime_sa 契約"
```

---

### Task 5: 開 PR 並合併

- [ ] **Step 1: 推分支開 PR**

```bash
cd ci && git push -u origin cloudsql-consolidation
gh pr create --repo adamsourceinfo-org/ci --base main --head cloudsql-consolidation \
  --title "Cloud SQL 合併：一環境一台，用 database 分服務" \
  --body-file <(sed -n '1,40p' docs/superpowers/specs/2026-08-24-cloudsql-consolidation-design.md)
```

- [ ] **Step 2: 等 PR 檢查通過後合併**

```bash
gh pr checks --repo adamsourceinfo-org/ci --watch
gh pr merge --repo adamsourceinfo-org/ci --squash --delete-branch
```

合併後四個專案的 config 還是舊格式，下一次部署會硬失敗並提示遷移——這是預期行為。

---

### Task 6: `hello-db` 切換（白老鼠）

**Files:**
- Modify: `hello-db/.cicd/config.yml`

- [ ] **Step 1: 改 config**

```yaml
health_path: /

runtime_sa: run-hello-db
db:
  name: hello_db
```

- [ ] **Step 2: push main，等 dev 部署**

```bash
cd hello-db && git add .cicd/config.yml \
  && git commit -m "切到共用 apps-pg 與專屬執行身分" && git push
gh run list --repo adamsourceinfo-org/hello-db --limit 1 --json databaseId,status,conclusion
```

- [ ] **Step 3: 驗 dev**

```bash
URL=$(gcloud run services describe hello-db --project=adamsourceinfo-dev --region=asia-east1 --format='value(status.url)')
curl -s "$URL/" | python3 -m json.tool
```

Expected：`instance` 是 `adamsourceinfo-dev:asia-east1:apps-pg`、
`server_user` 是 `run-hello-db@adamsourceinfo-dev.iam`、`database` 是 `hello_db`、`ok: true`

- [ ] **Step 4: 打 tag 上 prod 並驗證**

```bash
cd hello-db && git tag vX.Y.Z && git push --tags   # 見下方「tag 規則」
gh run list --repo adamsourceinfo-org/hello-db --limit 1 --json databaseId,status,conclusion
URL=$(gcloud run services describe hello-db --project=adamsourceinfo-prod --region=asia-east1 --format='value(status.url)')
curl -s "$URL/" | python3 -m json.tool
```

Expected：同上，但專案是 `adamsourceinfo-prod`、`server_user` 是 `run-hello-db@adamsourceinfo-prod.iam`

---

### Task 7: `hello-cicd` 切換

**Files:**
- Modify: `hello-cicd/.cicd/config.yml`

- [ ] **Step 1: 改 config**

```yaml
health_path: /

runtime_sa: run-hello-cicd
db:
  name: hello_cicd
```

- [ ] **Step 2: push main，等 dev 部署**

```bash
cd hello-cicd && git add .cicd/config.yml \
  && git commit -m "切到共用 apps-pg 與專屬執行身分" && git push
gh run list --repo adamsourceinfo-org/hello-cicd --limit 1 --json databaseId,status,conclusion
```

- [ ] **Step 3: 驗 dev**

```bash
URL=$(gcloud run services describe hello-cicd --project=adamsourceinfo-dev --region=asia-east1 --format='value(status.url)')
curl -s "$URL/" | python3 -m json.tool
```

Expected：`instance` 是 `adamsourceinfo-dev:asia-east1:apps-pg`、
`db_user` 是 `run-hello-cicd@adamsourceinfo-dev.iam`

- [ ] **Step 4: 打 tag 上 prod 並驗證**

```bash
cd hello-cicd && git tag vX.Y.Z && git push --tags   # 見下方「tag 規則」
gh run list --repo adamsourceinfo-org/hello-cicd --limit 1 --json databaseId,status,conclusion
URL=$(gcloud run services describe hello-cicd --project=adamsourceinfo-prod --region=asia-east1 --format='value(status.url)')
curl -s "$URL/" | python3 -m json.tool
```

Expected：`db_user` 是 `run-hello-cicd@adamsourceinfo-prod.iam`

---

### Task 8: `payment-ecpay` 切換

**Files:**
- Modify: `payment-ecpay/.cicd/config.yml`

- [ ] **Step 0: 修掉硬寫舊 instance 名的操作腳本**

`scripts/add-caller.sh` 的 `INSTANCE="payment-ecpay-pg"` 要改成 `apps-pg`，
註解裡的 `--instance=` 與「表的擁有者是 run-runtime」也一併改成新 SA。
舊 instance 一刪，這支腳本就會連到不存在的東西。

- [ ] **Step 1: 改 config**

```yaml
service: payment-ecpay
health_path: /health
allow_unauthenticated: true

runtime_sa: run-payment-ecpay
db:
  name: payment_ecpay
```

- [ ] **Step 2: push main、`gh run watch`**
- [ ] **Step 3: 驗 dev `/health`，確認 DB 連得上且 secret 掛得起來**

secret 是這個服務的關鍵驗證點：`payment-ecpay-hash-iv-dev` / `-hash-key-dev`
必須以新 SA 讀得到，否則 revision 起不來。revision 起得來就代表 accessor 補對了。

```bash
gcloud run revisions list --service=payment-ecpay --project=adamsourceinfo-dev \
  --region=asia-east1 --limit=1 --format="value(metadata.name,status.conditions[0].status)"
```

- [ ] **Step 4: 打 tag、驗 prod**

- [ ] **Step 5: 重發 dev 的測試 API key**

新 database 是空的，`api_keys` 沒有任何 caller。切換前 dev 有一個
`smoke-test`（scopes `orders:read,orders:write,subscriptions:read,subscriptions:write,events:read`，
備註「端對端測試用」）。key hash 不可逆，只能重發：

```bash
cd payment-ecpay && ./scripts/add-caller.sh dev smoke-test \
  "orders:read,orders:write,subscriptions:read,subscriptions:write,events:read" "端對端測試用"
```

明文 key 只會出現這一次，記得收好。prod 原本就沒有任何 caller，不用補。

---

### Task 9: `payment-paypal` 切換（最後，掛 live webhook）

**Files:**
- Modify: `payment-paypal/.cicd/config.yml`

- [ ] **Step 0: 修掉硬寫舊 instance 名的操作腳本**

`scripts/add-caller.sh` 的 `INSTANCE="payment-paypal-pg"` 與 `README.md` 裡的
`--instance=payment-paypal-pg` 都要改成 `apps-pg`，SA 也從 `run-runtime` 換成
`run-payment-paypal`。

- [ ] **Step 1: 改 config**

```yaml
service: payment-paypal
health_path: /health
allow_unauthenticated: true

runtime_sa: run-payment-paypal
db:
  name: payment_paypal
```

- [ ] **Step 2: push main、`gh run watch`、驗 dev `/health`**
- [ ] **Step 3: 打 tag、驗 prod `/health`**
- [ ] **Step 4: 確認 live webhook 端點仍可達**

```bash
URL=$(gcloud run services describe payment-paypal --project=adamsourceinfo-prod --region=asia-east1 --format='value(status.url)')
curl -s -o /dev/null -w '%{http_code}\n' "$URL/health"
```

Expected：`200`

- [ ] **Step 5: 重發 dev 的兩個測試 API key**

切換前 dev 有 `smoke-test`（全 scopes，「sandbox 實測用」）與
`other-caller`（`orders:read,orders:write`，「隔離測試用」）：

```bash
cd payment-paypal
./scripts/add-caller.sh dev smoke-test \
  "orders:read,orders:write,plans:read,plans:write,subscriptions:read,subscriptions:write,events:read" "sandbox 實測用"
./scripts/add-caller.sh dev other-caller "orders:read,orders:write" "隔離測試用"
```

prod 原本就沒有任何 caller，不用補。

---

### Task 10: Phase 3 清理

**Interfaces:**
- Consumes: Task 6–9 全部驗證通過
- Produces: 8 台舊 instance 刪除，帳單降到 $17.14/月

- [ ] **Step 1: 解除舊掛載與殘留環境變數**

CI 是疊加式的，切過去之後舊的 cloudsql 掛載與 `DB_INSTANCE` 環境變數都還在。

```bash
for P in adamsourceinfo-dev adamsourceinfo-prod; do
  for PAIR in "hello-cicd:hello-cicd-pg" "hello-db:hello-db-pg" \
              "payment-paypal:payment-paypal-pg" "payment-ecpay:payment-ecpay-pg"; do
    SVC="${PAIR%%:*}"; OLD="${PAIR##*:}"
    gcloud run services update "$SVC" --project="$P" --region=asia-east1 --quiet \
      --remove-cloudsql-instances="${P}:asia-east1:${OLD}" \
      --remove-env-vars=DB_INSTANCE
  done
done
```

- [ ] **Step 2: 確認每個服務只剩 `apps-pg` 一個掛載**

```bash
for P in adamsourceinfo-dev adamsourceinfo-prod; do
  for S in hello-cicd hello-db payment-paypal payment-ecpay; do
    printf "%-40s " "$P/$S"
    gcloud run services describe "$S" --project="$P" --region=asia-east1 \
      --format="value(spec.template.metadata.annotations['run.googleapis.com/cloudsql-instances'])"
  done
done
```

Expected：每行都只有 `<專案>:asia-east1:apps-pg`

- [ ] **Step 3: 撤掉 `run-runtime` 的 cloudsql 角色**

```bash
for P in adamsourceinfo-dev adamsourceinfo-prod; do
  for R in roles/cloudsql.client roles/cloudsql.instanceUser; do
    gcloud projects remove-iam-policy-binding "$P" \
      --member="serviceAccount:run-runtime@${P}.iam.gserviceaccount.com" \
      --role="$R" --condition=None --quiet >/dev/null
  done
done
```

- [ ] **Step 4: 刪掉 8 台舊 instance**

```bash
for P in adamsourceinfo-dev adamsourceinfo-prod; do
  for I in hello-cicd-pg hello-db-pg payment-paypal-pg payment-ecpay-pg; do
    gcloud sql instances delete "$I" --project="$P" --quiet
  done
done
```

- [ ] **Step 5: 確認最終狀態**

```bash
for P in adamsourceinfo-dev adamsourceinfo-prod; do
  gcloud sql instances list --project="$P" --format="value(name,state)" | sed "s|^|$P/|"
done
```

Expected：每個專案只剩 `apps-pg RUNNABLE`

- [ ] **Step 6: 更新記憶**

`adamsourceinfo-gcp-envs.md` 的 Cloud SQL 段改成合併後的事實；
`adamsourceinfo-cicd.md` 補上 `runtime_sa` 契約。
順便修掉一條錯的：`ci/scripts/set-secret.sh` **不存在**，README 是直接寫 gcloud 指令。
