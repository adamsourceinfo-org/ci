# ci — adamsourceinfo-org 共用部署流程

所有 `adamsourceinfo-org` 底下的專案共用這一支 workflow。各專案只放一支 stub 呼叫它。

```
PR        → 只 build，證明建得起來（完全不碰 GCP）
push main → build → 推 dev Artifact Registry → 部署 adamsourceinfo-dev
push tag  → 取 main 建好的同一個 digest → 搬進 prod AR → 部署 adamsourceinfo-prod
```

**tag 永遠不重新 build。** prod 跑的 binary 逐位元組等於 dev 驗過的那一份 —— promote 用
`crane copy`（不是 `docker buildx imagetools create`，後者會把來源 manifest 再包一層 index，
digest 就變了），複製完還會比對 digest，不一致就中止。

---

## 責任分界

這個 repo **只裝最後一列**。其餘三列不是 CI 的職責，放進來只會讓部署身分需要它不該有的權限。

| 誰 | 做什麼 | 多久一次 | 用什麼憑證 |
|---|---|---|---|
| **你（owner）** | GCP 專案、API、WIF、SA、IAM、Cloud SQL instance | 一次 | 你自己的 `gcloud` |
| **你（owner）** | 建 repo、分支保護 | 每個新專案一次 | 你自己的 `gh` |
| **開發者** | 程式碼、`.cicd/` 設定、secret 的**值** | 日常 | 自己的 |
| **CI（本 repo）** | build → deploy → 掛設定 → smoke | 每次 push | WIF 換來的**短期**憑證 |

一條界線值得寫死：**部署身分沒有建 SA、授 IAM 的權限。** 有的話，部署流程被打穿就等於整個
專案管理員。代價是下面那份 runbook 得由人跑一次 —— 這是刻意的交換。

---

## 一次性設定（你，用自己的帳號）

兩個環境各跑一次，`ENV` 換成 `dev` / `prod`。

```bash
ENV=dev; PROJECT=adamsourceinfo-${ENV}; REGION=asia-east1; AR_REPO=apps
POOL=github; PROVIDER=adamsourceinfo-org
NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')

# 1. API。sqladmin 一定要開，即使還沒有 Cloud SQL —— 部署帶 --add-cloudsql-instances
#    時 gcloud 會要求它已啟用，在 CI 的 --quiet 下是直接「Aborted by user」。
gcloud services enable run.googleapis.com artifactregistry.googleapis.com \
  iamcredentials.googleapis.com sts.googleapis.com secretmanager.googleapis.com \
  cloudresourcemanager.googleapis.com sqladmin.googleapis.com \
  --project="$PROJECT" --quiet

# 2. Artifact Registry
gcloud artifacts repositories create "$AR_REPO" --repository-format=docker \
  --location="$REGION" --project="$PROJECT" --quiet

# 3. 兩個身分。執行身分刻意「不是」預設 compute SA —— 那個帶 Editor，
#    等於每個服務都是專案管理員。
gcloud iam service-accounts create run-runtime      --project="$PROJECT" --quiet
gcloud iam service-accounts create github-deployer  --project="$PROJECT" --quiet

DEPLOYER="github-deployer@${PROJECT}.iam.gserviceaccount.com"
RUNTIME="run-runtime@${PROJECT}.iam.gserviceaccount.com"

# 4. 部署身分的權限。注意沒有 iam.* —— 它不能建 SA、不能改 IAM。
for R in roles/run.admin roles/artifactregistry.writer roles/cloudsql.viewer; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${DEPLOYER}" --role="$R" --condition=None --quiet
done
# 只能「使用」執行身分，不能改它
gcloud iam service-accounts add-iam-policy-binding "$RUNTIME" \
  --member="serviceAccount:${DEPLOYER}" --role=roles/iam.serviceAccountUser \
  --project="$PROJECT" --quiet

# 5. WIF。這一段是唯一「不可能」交給 CI 的 —— workflow 要靠 WIF 才拿得到憑證，
#    不可能用 workflow 去建 WIF。
gcloud iam workload-identity-pools create "$POOL" --location=global \
  --project="$PROJECT" --quiet
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
  --location=global --workload-identity-pool="$POOL" --project="$PROJECT" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.job_workflow_ref=assertion.job_workflow_ref" \
  --attribute-condition="assertion.repository_owner=='adamsourceinfo-org'" --quiet

# 6. 信任綁定：只有 ci 的那一支 workflow 換得到憑證
gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER" --project="$PROJECT" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.job_workflow_ref/adamsourceinfo-org/ci/.github/workflows/deploy.yml@refs/heads/main" \
  --quiet
```

最後讓 prod 讀得到 dev 的 AR（promote 要跨專案複製同一個 digest）：

```bash
gcloud artifacts repositories add-iam-policy-binding apps \
  --location=asia-east1 --project=adamsourceinfo-dev \
  --member="serviceAccount:github-deployer@adamsourceinfo-prod.iam.gserviceaccount.com" \
  --role=roles/artifactregistry.reader --quiet
```

> 剛建好的 SA 不會立刻出現在 IAM policy API，`add-iam-policy-binding` 可能回
> "does not exist"。等幾秒重試即可。

---

## 開一個新專案

```bash
gh repo create adamsourceinfo-org/my-app --public --clone
mkdir -p my-app/.github/workflows my-app/.cicd
curl -sL https://raw.githubusercontent.com/adamsourceinfo-org/ci/main/templates/deploy.yml \
  -o my-app/.github/workflows/deploy.yml
curl -sL https://raw.githubusercontent.com/adamsourceinfo-org/ci/main/templates/config.yml \
  -o my-app/.cicd/config.yml
```

再自備 `Dockerfile`（容器要監聽 `$PORT`），推上 main 就會部署 dev。

**分支保護是 repo 自己的治理設定，不是這裡的事。** 在 GitHub 介面或 org ruleset 設定即可；
required check 用 `deploy / 2 build（PR）`。

> Free 方案的分支保護只對 public repo 有效。要 private + 保護得升級 GitHub Team。

---

## 專案端契約

```
my-app/
├─ Dockerfile              必要。容器要監聽 $PORT
├─ .github/workflows/
│  └─ deploy.yml           唯一的 stub，照抄不用改
└─ .cicd/
   ├─ config.yml           結構性設定：service / region / db…（選填）
   ├─ env.common           dev 與 prod 共用的非機密設定
   ├─ env.dev              只有 dev 要的，同名 key 蓋過 common
   ├─ env.prod
   ├─ secrets.common       機密「掛載表」，只有名字沒有值
   ├─ secrets.dev
   └─ secrets.prod
```

### `.cicd/config.yml`

放**一次性、不該 dev/prod 分歧**的東西。整份選填，沒有這個檔就用預設值。

```yaml
service: my-app            # 預設用 repo 名稱
region: asia-east1
health_path: /healthz      # 預設 /
dockerfile: Dockerfile
allow_unauthenticated: true

db:                        # 要用 Cloud SQL 才需要，只宣告一次
  instance: my-app-pg
  name: my_app
```

打錯的 key 會被擋下並列出可用名字 —— 設定檔最常見的失敗是「明明寫了卻沒生效」。

### 設定與機密

**CI 只負責掛載，不負責寫入機密值。** 要能寫入的話，值就得先躺在 GitHub secrets 裡 ——
憑空多一個外洩面，也違背用 WIF（無金鑰）的用意。

| 類型 | 放哪 | 誰寫 |
|---|---|---|
| 兩邊共用的非機密設定 | `.cicd/env.common` | 開發者，進版控 |
| 只有某環境要的 | `.cicd/env.<env>`，**同名蓋過 common** | 同上 |
| 機密的**值** | GCP Secret Manager | **開發者自己跑一次**（見下） |
| 機密的**名字** | `.cicd/secrets.<env>` | 開發者，進版控 |
| `APP_ENV` / `APP_VERSION` / DB 連線 | — | CI 依部署目標注入 |

寫一個機密的值 —— 這是開發時的事，跟 CI 無關：

```bash
gcloud secrets create my-app-api-key-dev --replication-policy=automatic --project=adamsourceinfo-dev
printf '%s' "$VALUE" | gcloud secrets versions add my-app-api-key-dev --data-file=- --project=adamsourceinfo-dev
gcloud secrets add-iam-policy-binding my-app-api-key-dev --project=adamsourceinfo-dev \
  --member="serviceAccount:run-runtime@adamsourceinfo-dev.iam.gserviceaccount.com" \
  --role=roles/secretmanager.secretAccessor
```

然後在 `.cicd/secrets.dev` 加一行 `API_KEY=my-app-api-key-dev:latest`。

**兩邊一樣的值寫在 `.common` 就好。** 抄兩遍的東西遲早會分歧 —— 這比打錯字常見得多。

### CI 永遠不覆蓋你的設定

一律用 `--update-env-vars` / `--update-secrets`（合併），**從不**用 `--set-*`（取代全部）。

| 你做的事 | 會發生什麼 |
|---|---|
| 在 Cloud Run 主控台加一個環境變數 | 保留 |
| 手動調 min/max instances、CPU、記憶體、concurrency | 保留（CI 從不傳這些參數） |
| 在 `.cicd/env.<env>` 加一行 | 下次部署套用 |
| 在 `.cicd/env.<env>` **刪掉**一行 | ⚠️ Cloud Run 上**不會**消失 |

最後一列是代價：`gcloud run services update <服務> --remove-env-vars=KEY`。

> `.cicd/*` 的值可以含逗號與 `@` —— 部署時用 `^@@^` 自訂分隔符。單字元的 `^@^` 碰到值裡
> 有 `@` 會噴 `Bad syntax for dict arg`，而 `DB_USER=run-runtime@…` 正好含 `@`。

---

## 服務要用資料庫

在 `.cicd/config.yml` 宣告**一次**（不是 dev/prod 各一份）：

```yaml
db:
  instance: my-app-pg
  name: my_app
```

連線字串、DB 帳號、Cloud SQL 掛載，CI 依「正在部署哪個環境」自己推導：

| CI 注入的環境變數 | 推導方式 | dev 實際拿到 |
|---|---|---|
| `INSTANCE_CONNECTION_NAME` | `<專案>:<區域>:<db.instance>` | `adamsourceinfo-dev:asia-east1:my-app-pg` |
| `DB_USER` | `run-runtime@<專案>.iam` | `run-runtime@adamsourceinfo-dev.iam` |

**為什麼不讓你自己寫連線字串**：那樣就有寫錯專案的機會。CI 本來就知道自己在部署哪個環境
（它已經用這個知識注入 `APP_ENV`），讓它一併推導，dev 連到 prod 的 DB 就從「會被抓到的錯」
變成**寫不出來的錯**。

> `INSTANCE_CONNECTION_NAME`、`DB_USER`、`DB_INSTANCE`、`DB_NAME` 在 `.cicd/env.*` 裡都被擋下。

### 沒有密碼

用 Cloud SQL **IAM 資料庫認證**：`run-runtime` SA 直接就是 Postgres 使用者，密碼是向
metadata server 要的 access token。Secret Manager 不放任何 DB 機密。

app 端要裝一個 Postgres driver。純 Python 的 `pg8000` 在 alpine 上不用編譯：

```dockerfile
FROM python:3.12-alpine
WORKDIR /app
RUN pip install --no-cache-dir pg8000==1.31.2
COPY app.py .
CMD ["python", "-u", "app.py"]
```

```python
import os, json, urllib.request, pg8000.dbapi

def _token():
    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1/"
        "instance/service-accounts/default/token",
        headers={"Metadata-Flavor": "Google"})
    return json.load(urllib.request.urlopen(req, timeout=5))["access_token"]

conn = pg8000.dbapi.connect(
    user=os.environ["DB_USER"],
    password=_token(),                 # access token 當密碼，會過期，別快取太久
    database=os.environ["DB_NAME"],
    unix_sock=f"/cloudsql/{os.environ['INSTANCE_CONNECTION_NAME']}/.s.PGSQL.5432",
)
```

### 開 instance（你，一次性）

**CI 刻意不自動建 instance** —— 要 10 分鐘、會計費，而且 `config.yml` 打錯一個字就多開一台。
沒有的話部署會停在 `verify` 之後並印出該跑的指令。（Cloud Run service 本身則相反：
`gcloud run deploy` 沒有就建、有就更新。）

```bash
PROJECT=adamsourceinfo-dev; INSTANCE=my-app-pg; DB=my_app

# --edition=ENTERPRISE 不能省：新 instance 預設 ENTERPRISE_PLUS，那個版本不收
# db-f1-micro 這類共享核心規格，會噴 Invalid Tier。
gcloud sql instances create "$INSTANCE" --project="$PROJECT" --region=asia-east1 \
  --edition=ENTERPRISE --database-version=POSTGRES_17 --tier=db-f1-micro \
  --storage-size=10 --storage-type=HDD \
  --database-flags=cloudsql.iam_authentication=on --quiet

gcloud sql databases create "$DB" --instance="$INSTANCE" --project="$PROJECT"

# IAM 使用者要用「去掉 .gserviceaccount.com」的短格式，否則 API 回 400。
# 這個短格式正好就是 CI 注入的 DB_USER，兩邊必須逐字相同。
gcloud sql users create "run-runtime@${PROJECT}.iam" --instance="$INSTANCE" \
  --project="$PROJECT" --type=cloud_iam_service_account

for R in roles/cloudsql.client roles/cloudsql.instanceUser; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:run-runtime@${PROJECT}.iam.gserviceaccount.com" \
    --role="$R" --condition=None --quiet
done
```

Postgres 15 之後 `public` schema 不再預設給 PUBLIC 建表權，所以**還要 `GRANT`**：

```bash
# 內建 postgres 帳號預設沒密碼，設一個一次性的（IAM 認證的 app 不需要它）
PGPASSWORD="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
gcloud sql users set-password postgres --instance="$INSTANCE" \
  --project="$PROJECT" --password="$PGPASSWORD" --quiet

# 一定要連進「目標 database」—— 每個 database 有自己的 public schema，
# 連到預設的 postgres 庫會成功但完全沒作用。
cloud-sql-proxy "${PROJECT}:asia-east1:${INSTANCE}" --port 5433 \
  --token "$(gcloud auth print-access-token)" &

export PGPASSWORD
psql -h 127.0.0.1 -p 5433 -U postgres -d "$DB" <<SQL
GRANT ALL ON SCHEMA public TO "run-runtime@${PROJECT}.iam";
GRANT ALL PRIVILEGES ON DATABASE ${DB} TO "run-runtime@${PROJECT}.iam";
SQL
```

> `--token` 不是多餘的：本機 ADC 過期時 proxy 會噴 `invalid_grant / invalid_rapt`，
> 但 gcloud CLI 自己的憑證通常還好好的。

dev 不用時可停機，只算儲存費：

```bash
gcloud sql instances patch my-app-pg --project=adamsourceinfo-dev --activation-policy=NEVER
```

### 怎麼確認接對了

讓服務回報一段健康資訊，其中 `server_user` 與 `database` 要由 **DB 自己回答**，
不能是環境變數回音，否則證明不了任何事：

```json
{ "env": "dev",
  "db": { "instance": "adamsourceinfo-dev:asia-east1:my-app-pg",
          "ok": true,
          "server_user": "run-runtime@adamsourceinfo-dev.iam",
          "database": "my_app" } }
```

dev 與 prod 各打一次，專案名要各自對得上自己的環境。兩邊跑的是同一個 image，
所以差異只可能來自 CI 推導 —— 這正是重點。

### 限制

| 限制 | 說明 |
|---|---|
| DB 與 Cloud Run 必須同區域 | 推導假設 `<專案>:asia-east1:<instance>` |
| 不支援跨專案 / 跨區域的 DB | 手動 `--add-cloudsql-instances`，疊加式旗標與 CI 並存不衝突 |
| 兩個環境的 instance 名字不能不同 | 刻意的 —— 分歧的餘地就是出錯的餘地 |
| 刪掉 `db:` | ⚠️ 掛載不會自動消失，要手動 `--remove-cloudsql-instances` |

---

## 權限模型

沒有 SA key JSON，GitHub 端**沒有任何 secret**。用 Workload Identity Federation 換臨時憑證：

```
attribute.job_workflow_ref ==
  adamsourceinfo-org/ci/.github/workflows/deploy.yml@refs/heads/main
```

**只有這個 repo 的這一支 workflow** 換得到憑證。

| | dev | prod |
|---|---|---|
| 部署身分 | `github-deployer@adamsourceinfo-dev` | `github-deployer@adamsourceinfo-prod` |
| 執行身分 | `run-runtime@adamsourceinfo-dev` | `run-runtime@adamsourceinfo-prod` |
| 部署權限 | `run.admin`、`artifactregistry.writer`、`cloudsql.viewer`、`serviceAccountUser`（限執行身分） | 同左 + dev AR 的 `artifactregistry.reader` |

**部署身分沒有 `iam.*`** —— 建 SA、授 IAM 都做不到。所以上面那份 runbook 才必須由人跑。

### PR 拿不到憑證

`deploy.yml` 同時服務 PR 與部署，界線由兩件事守住：

1. `build（PR）` 這個 job **沒有** `permissions: id-token: write`
2. 每一個碰 GCP 的 job 都有 `if: github.event_name != 'pull_request'`

這兩者是安全邊界的一部分，不是風格。改動 `deploy.yml` 時務必保持。

---

## 常見錯誤

| 訊息 | 原因 |
|---|---|
| `找不到 Dockerfile` | 每個專案都要自備 |
| `tag 'xxx' 格式不對` | 只收 `vX.Y.Z`。**刻意收所有 tag 再擋下來** —— 用 glob 過濾的話格式錯的 tag 會安靜地沒反應，比紅燈難查 |
| `tag 指向的 commit 不在 main 上` | prod 只部署 main 驗證過的東西 |
| `在 dev AR 找不到 sha-xxxxxxx` | 這個 commit 沒走過 main pipeline |
| `複製後 digest 不一致` | promote 的重點就是逐位元組相同，不一致必須中止 |
| dev 健康檢查失敗 | 容器沒監聽 `$PORT`（Cloud Run 注入，預設 8080） |
| `找不到 Cloud SQL instance` | 還沒開通。見「開 instance」 |
| `不可以自己設定 INSTANCE_CONNECTION_NAME` | CI 保留字。改在 `config.yml` 宣告 `db` |
| `Bad syntax for dict arg` | `.cicd/*` 的值裡有 `@@`，撞到自訂分隔符 |
| 部署時 `Aborted by user` | 該專案的 `sqladmin.googleapis.com` 沒開 |
| `permission denied for schema public` | IAM 使用者建了但沒 `GRANT`，或 `GRANT` 下在別的 database |
| `Database username ... without ".gserviceaccount.com"` | `sql users create` 要用短格式 `run-runtime@<專案>.iam` |
| `Invalid Tier (db-f1-micro) for (ENTERPRISE_PLUS)` | 建 instance 要加 `--edition=ENTERPRISE` |
| proxy `invalid_grant / invalid_rapt` | 本機 ADC 過期。加 `--token "$(gcloud auth print-access-token)"` |
