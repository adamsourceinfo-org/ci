# ci — adamsourceinfo-org 共用 CI/CD

所有 `adamsourceinfo-org` 底下的專案共用這一套部署流程。各專案只放一支十幾行的 caller stub，邏輯全部在這裡。

```
push main      → build → 推 dev Artifact Registry → 部署 adamsourceinfo-dev
push tag vX.Y.Z → 取 main 建好的同一個 digest → 搬進 prod AR → 部署 adamsourceinfo-prod
```

**tag 永遠不重新 build。** prod 跑的 binary 逐位元組等於 dev 驗過的那一份 —— promote 用 `crane copy`（不是 `docker buildx imagetools create`，後者會把來源 manifest 再包一層 index，digest 就變了），複製完還會比對 digest，不一致就中止。

---

## 開一個新專案

```bash
# 第一次要先把本 repo 拉下來（腳本在這裡面）
git clone https://github.com/adamsourceinfo-org/ci.git ~/repository/adamsourceinfo/ci

cd ~/repository/adamsourceinfo/ci
./scripts/new-project.sh my-app --dir ~/repository/adamsourceinfo
```

會建立 public repo、放進 stub 與 `.cicd/` 骨架、推上 main，並上 ruleset 保護 main（禁直推、禁 force push、強制 PR + 通過 ci 檢查）。

需要 `gh` 已登入、且對 `adamsourceinfo-org` 有建 repo 的權限。

> Free 方案的分支保護只對 public repo 有效，所以專案一律開 public。要讓 private repo 也能保護，得升級 GitHub Team。

---

## 流程節點

**PR**（`ci.yml`，完全不碰 GCP，是 main 的 required status check）

| # | 節點 | 內容 |
|---|---|---|
| 1 | `verify` | Dockerfile 在不在、service 名稱合不合 Cloud Run 規則、`.cicd/` 格式對不對 |
| 2 | `build` | `docker build` 建得起來，不推 |

**main / tag**（`deploy.yml`）

| # | 節點 | 觸發 | 內容 |
|---|---|---|---|
| 1 | `verify` | main + tag | 契約檢查；tag 另驗 `vX.Y.Z` 格式且必須指向 main 上的 commit |
| 2 | `build-push` | main | build → 推 dev AR（`sha-<short>` + `latest`），輸出 digest |
| 3 | `deploy-dev` | main | 用 **digest** 部署 `adamsourceinfo-dev` |
| 4 | `smoke-dev` | main | HTTP 健康檢查 + job summary |
| 5 | `resolve` | tag | 由 tag 的 commit 反查 dev AR 的 digest，查不到就擋下 |
| 6 | `promote` | tag | 同一 digest 複製進 prod AR，複製後比對 digest 一致 |
| 7 | `deploy-prod` | tag | 同一 digest 部署 `adamsourceinfo-prod` |
| 8 | `smoke-prod` | tag | HTTP 健康檢查 + job summary |

CI **不跑測試**。測試是開發時自己該驗完才推上來的事，pipeline 只保證「建得起來、部得上去、活著」。

---

## 專案端契約

```
my-app/
├─ Dockerfile              必要。容器要監聽 $PORT
├─ .github/workflows/
│  ├─ deploy.yml           caller stub，照抄不用改
│  └─ ci.yml               caller stub，照抄不用改
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

放**一次性、不該 dev/prod 分歧**的東西。整份都是選填，沒有這個檔就用預設值。

```yaml
service: my-app            # 預設用 repo 名稱
region: asia-east1
health_path: /healthz      # smoke test 打的路徑，預設 /
dockerfile: Dockerfile
allow_unauthenticated: true

db:                        # 要用 Cloud SQL 才需要，只宣告一次
  instance: my-app-pg
  name: my_app
```

打錯的 key 會被 `verify` 擋下並列出可用的名字 —— 設定檔最常見的失敗是「明明寫了卻沒生效」。

### caller stub 長什麼樣

`new-project.sh` 會自動放好。要手動把既有專案接上來的話，這兩支照抄即可：

`.github/workflows/deploy.yml`
```yaml
name: deploy
on:
  push:
    branches: [main]
    tags: ["**"]           # 刻意收所有 tag 再由 ci 驗格式
  workflow_dispatch:
jobs:
  deploy:
    permissions:
      contents: read
      id-token: write      # 換 WIF 憑證必要
    uses: adamsourceinfo-org/ci/.github/workflows/deploy.yml@main
```

`.github/workflows/ci.yml`
```yaml
name: ci
on:
  pull_request:
    branches: [main]
jobs:
  ci:
    uses: adamsourceinfo-org/ci/.github/workflows/ci.yml@main
```

改這兩個檔不會讓你拿到任何 GCP 權限 —— 見下面的權限模型。

---

## 設定與機密

**CI/CD 只負責掛載，不負責寫入機密值。** 機密要進 CI/CD 才能寫的話，就得先躺在 GitHub secrets 裡 — 憑空多一個外洩面，也違背用 WIF（無金鑰）的用意。

| 類型 | 放哪 | 誰寫 | 怎麼進 Cloud Run |
|---|---|---|---|
| 兩邊共用的非機密設定 | `.cicd/env.common` | 開發者，進版控 | `--update-env-vars`（合併，不刪除） |
| 只有某環境要的 | `.cicd/env.<env>` | 同上，**同名 key 蓋過 common** | 同上 |
| 機密 | GCP Secret Manager | `scripts/set-secret.sh` 跑一次 | `--update-secrets`（只掛名字） |
| `APP_ENV` / `APP_VERSION` | — | CI 自動注入 | prod 的 `APP_VERSION` 是 tag |
| DB 連線字串 / 帳號 | — | CI 依部署目標推導 | 見「服務要用資料庫」 |

**兩邊一樣的值寫在 `env.common` 就好。** 抄兩遍的東西遲早會分歧 —— 這是設定檔最常見的 bug，比打錯字常見得多。

```bash
# 1. 寫值（值不經過 GitHub、不進版控、不出現在 log）
./scripts/set-secret.sh prod my-app-db-password

# 2. 在專案的 .cicd/secrets.prod 掛名字
echo 'DB_PASSWORD=my-app-db-password:latest' >> .cicd/secrets.prod
```

改設定 = 改檔案 + PR，有版控有 review。改機密 = 跑一次腳本，不用動 code、不用重 build。

> `.cicd/env.*` 與 `.cicd/secrets.*` 的值可以含逗號與 `@` — 部署時用 `^@@^` 自訂分隔符。
> （單字元的 `^@^` 碰到值裡有 `@` 會噴 `Bad syntax for dict arg`。`DB_USER=run-runtime@…` 正好含 `@`。）

### CI 永遠不覆蓋你的設定

一律用 `--update-env-vars` / `--update-secrets`（合併），**從不**用 `--set-*`（取代全部）。CI 只新增或更新它認得的鍵，絕不刪除它不知道的東西。

| 你做的事 | 會發生什麼 |
|---|---|
| 在 Cloud Run 主控台加一個環境變數 | 保留，之後每次部署都還在 |
| 手動調 min/max instances、CPU、記憶體、concurrency | 保留（CI 從不傳這些參數） |
| 在 `.cicd/env.<env>` 加一行 | 下次部署套用 |
| 在 `.cicd/env.<env>` **刪掉**一行 | ⚠️ Cloud Run 上**不會**消失 |

最後一列是這個選擇的代價。要真的移除一個變數：

```bash
gcloud run services update <服務> --region=asia-east1 --project=<專案> --remove-env-vars=KEY
```

（實測驗證過：手動設 `min=1`、`concurrency=40`、`memory=1Gi`，連續兩次 CI 部署後三個值都還在。）

---

## 服務要用資料庫

在 `.cicd/config.yml` 宣告**一次**（不是 dev/prod 各一份）：

```yaml
db:
  instance: my-app-pg
  name: my_app
```

就這樣。連線字串、DB 帳號、Cloud SQL 掛載，CI 依「正在部署哪個環境」自己推導：

| CI 注入的環境變數 | 推導方式 | dev 實際拿到 |
|---|---|---|
| `INSTANCE_CONNECTION_NAME` | `<專案>:<區域>:<DB_INSTANCE>` | `adamsourceinfo-dev:asia-east1:my-app-pg` |
| `DB_USER` | `run-runtime@<專案>.iam` | `run-runtime@adamsourceinfo-dev.iam` |

外加部署時掛上 `--add-cloudsql-instances`。

**為什麼不讓你自己寫連線字串**：因為那樣就有寫錯專案的機會。CI 本來就知道自己在部署哪個環境（它已經用這個知識注入 `APP_ENV`），讓它一併推導，dev 連到 prod 的 DB 就從「會被抓到的錯」變成**寫不出來的錯**。

> `INSTANCE_CONNECTION_NAME`、`DB_USER`、`DB_INSTANCE`、`DB_NAME` 在 `.cicd/env.*` 裡都是禁止的 —— 前兩個由 CI 推導，後兩個宣告在 `config.yml`。手寫會被 `verify` 擋下並告訴你該寫哪裡。

### 沒有密碼

用 Cloud SQL **IAM 資料庫認證**：`run-runtime` SA 直接就是 Postgres 使用者，密碼是向 metadata server 要的 access token。Secret Manager 不用放任何 DB 機密，跟 WIF「一把金鑰都不存」是同一套邏輯。

app 端要裝一個 Postgres driver。純 Python 的 `pg8000` 在 alpine 上不用編譯：

```dockerfile
FROM python:3.12-alpine
WORKDIR /app
RUN pip install --no-cache-dir pg8000==1.31.2
COPY app.py .
CMD ["python", "-u", "app.py"]
```

然後這樣連（走 Cloud Run 注入的 unix socket，不是 IP）：

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

### 一次性開通（還沒自動化）

> **這步需要 GCP 權限，而且要先做。** 順序是：有 GCP 權限的人先把 instance 開好 →
> 開發者（或 agent）才寫 `config.yml` 那三行與 app 程式碼。反過來的話部署會成功、
> 但 app 一連線就炸。

```bash
PROJECT=adamsourceinfo-dev; INSTANCE=my-app-pg; DB=my_app
SA="run-runtime@${PROJECT}.iam.gserviceaccount.com"   # IAM 綁定用全名

# --edition=ENTERPRISE 不能省：新 instance 預設 ENTERPRISE_PLUS，那個版本不收
# db-f1-micro 這類共享核心規格，會噴 Invalid Tier 並要你改用 db-perf-optimized-N-*。
gcloud sql instances create "$INSTANCE" --project="$PROJECT" --region=asia-east1 \
  --edition=ENTERPRISE --database-version=POSTGRES_17 --tier=db-f1-micro \
  --storage-size=10 --storage-type=HDD \
  --database-flags=cloudsql.iam_authentication=on --quiet

gcloud sql databases create "$DB" --instance="$INSTANCE" --project="$PROJECT"

# 注意：IAM 使用者要用「去掉 .gserviceaccount.com」的短格式，否則 API 會回 400。
# 這個短格式正好就是 CI 注入的 DB_USER，兩邊必須逐字相同。
gcloud sql users create "run-runtime@${PROJECT}.iam" --instance="$INSTANCE" \
  --project="$PROJECT" --type=cloud_iam_service_account

for ROLE in roles/cloudsql.client roles/cloudsql.instanceUser; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA}" --role="$ROLE" --condition=None --quiet
done
```

最後進 DB 授權。Postgres 15 之後 `public` schema 不再預設給 PUBLIC 建表權，
所以建完 IAM 使用者**還是要 `GRANT`**，否則 app 連得上但一建表就 permission denied：

```bash
# 內建的 postgres 帳號預設沒有密碼，先設一個一次性的（用完就沒用了，
# IAM 認證的 app 完全不需要它；之後要再用就再設一次）。
PGPASSWORD="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
gcloud sql users set-password postgres --instance="$INSTANCE" \
  --project="$PROJECT" --password="$PGPASSWORD" --quiet

# 一定要連進「目標 database」下 GRANT —— 每個 database 有自己的 public schema，
# 連到預設的 postgres 庫下的話會成功但完全沒作用。
cloud-sql-proxy "${PROJECT}:asia-east1:${INSTANCE}" --port 5433 \
  --token "$(gcloud auth print-access-token)" &

export PGPASSWORD
psql -h 127.0.0.1 -p 5433 -U postgres -d "$DB" <<SQL
GRANT ALL ON SCHEMA public TO "run-runtime@${PROJECT}.iam";
GRANT ALL PRIVILEGES ON DATABASE ${DB} TO "run-runtime@${PROJECT}.iam";
SQL
```

> `--token` 那段不是多餘的：本機 ADC 過期時 proxy 會噴 `invalid_grant / invalid_rapt`，
> 但 gcloud CLI 自己的憑證通常還好好的，直接餵 token 就不用重跑 ADC 登入。

dev 不用的時候可以停機，只算儲存費：

```bash
gcloud sql instances patch my-app-pg --project=adamsourceinfo-dev --activation-policy=NEVER   # 停
gcloud sql instances patch my-app-pg --project=adamsourceinfo-dev --activation-policy=ALWAYS  # 開
```

### 怎麼確認接對了

服務起來之後，讓它回報一個像這樣的健康資訊（`server_user` 與 `database` 要由 **DB 自己回答**，
不能是環境變數回音，否則證明不了任何事）：

```json
{
  "env": "dev",
  "db": {
    "instance": "adamsourceinfo-dev:asia-east1:my-app-pg",
    "ok": true,
    "server_user": "run-runtime@adamsourceinfo-dev.iam",
    "database": "my_app"
  }
}
```

dev 與 prod 各打一次，`instance` 與 `server_user` 的專案名要各自對得上自己的環境。
兩邊跑的是同一個 image（tag 走 digest promote），所以差異只可能來自 CI 推導 —— 這正是重點。

### 限制

| 限制 | 說明 |
|---|---|
| DB 與 Cloud Run 必須同區域 | 推導假設 `<專案>:asia-east1:<instance>` |
| 不支援跨專案 / 跨區域的 DB | 真的需要就手動 `gcloud run services update --add-cloudsql-instances`，疊加式旗標與 CI 並存不衝突 |
| 兩個環境的 instance 名字不能不同 | `config.yml` 只宣告一次。這是刻意的 —— 分歧的餘地就是出錯的餘地 |
| 刪掉 `db:` 那段 | ⚠️ 掛載不會自動消失，要手動 `--remove-cloudsql-instances`（與環境變數同一個取捨） |

---

## 權限模型

沒有 SA key JSON，GitHub 端**沒有任何 secret**。用 Workload Identity Federation 換臨時憑證，信任條件是：

```
attribute.job_workflow_ref ==
  adamsourceinfo-org/ci/.github/workflows/deploy.yml@refs/heads/main
```

意思是**只有這個 repo 的這一支 workflow** 換得到憑證。你在自己專案 repo 裡改 workflow、或從別的 workflow 呼叫，都換不到。

每個環境各自獨立一組 pool / provider / SA：

| | dev | prod |
|---|---|---|
| 部署身分 | `github-deployer@adamsourceinfo-dev` | `github-deployer@adamsourceinfo-prod` |
| 執行身分 | `run-runtime@adamsourceinfo-dev` | `run-runtime@adamsourceinfo-prod` |
| 部署權限 | `run.admin`, `artifactregistry.writer`, `serviceAccountUser`(限執行身分) | 同左 + dev AR 的 `artifactregistry.reader` |

Cloud Run 用專屬的 `run-runtime` 執行，不用 default compute SA（那個帶 Editor，等於每個服務都是專案管理員）。

---

## GCP 環境設定

```bash
./scripts/bootstrap-gcp.sh      # 可重複執行
./scripts/protect-ci-repo.sh    # 保護本 repo 自己的 main
```

開 API、建 Artifact Registry、建兩組 SA、建 WIF pool/provider 與信任綁定，以及跨專案的 promote 讀取權。

`protect-ci-repo.sh` 是獨立的一支，因為**本 repo 自己的 main 就是整個安全模型的根** —— GCP 的信任條件釘在 `ci/.github/workflows/deploy.yml@refs/heads/main`，能推這裡的 main 就等於能改寫兩個 GCP 專案所信任的部署邏輯。它不能沿用 `new-project.sh` 那份 ruleset：那份要求 `ci / 1 verify` 與 `ci / 2 build`，但本 repo 的 workflow 是 `workflow_call` 專用、在自己的 PR 上不會執行，那兩個 check 永遠不會回報，PR 會被永久卡住。所以本 repo 改用 `self-test.yml` 的 `check`。

---

## 常見錯誤

| 訊息 | 原因 |
|---|---|
| `找不到 Dockerfile` | 每個專案都要自備 |
| `tag 'xxx' 格式不對` | 只收 `vX.Y.Z`。**刻意收所有 tag 再擋下來** — 用 glob 過濾的話格式錯的 tag 會安靜地沒反應，比紅燈難查 |
| `tag 指向的 commit 不在 main 上` | prod 只部署 main 驗證過的東西 |
| `在 dev AR 找不到 sha-xxxxxxx` | 這個 commit 沒走過 main pipeline。先讓它進 main、dev 部署成功再打 tag |
| `複製後 digest 不一致` | promote 的重點就是逐位元組相同，不一致必須中止 |
| dev 健康檢查失敗 | 容器沒監聽 `$PORT`（Cloud Run 注入，預設 8080） |
| `不可以自己設定 INSTANCE_CONNECTION_NAME` | 這是 CI 保留字。改宣告 `DB_INSTANCE=<instance 名稱>` |
| `Bad syntax for dict arg` | `.cicd/env.*` 的值裡有 `@@`，撞到自訂分隔符 |
| 部署時 `Aborted by user` | 該專案的 `sqladmin.googleapis.com` 沒開。跑 `bootstrap-gcp.sh` |
| DB 連線 `permission denied for schema public` | IAM 使用者建了但沒 `GRANT`，或 `GRANT` 下在別的 database |
| `Database username ... should be created without \".gserviceaccount.com\" suffix` | `gcloud sql users create` 要用短格式 `run-runtime@<專案>.iam` |
| `Invalid Tier (db-f1-micro) for (ENTERPRISE_PLUS) Edition` | 建 instance 要加 `--edition=ENTERPRISE` |
| proxy `invalid_grant / invalid_rapt` | 本機 ADC 過期。加 `--token "$(gcloud auth print-access-token)"` |

<!-- self-test 驗證用 -->
