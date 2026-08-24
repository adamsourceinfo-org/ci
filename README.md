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
| **你（owner）** | 服務的執行身分、database、`GRANT` | 每服務一次 | `ci/scripts/provision-service.sh` |
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
# iam.googleapis.com 也不能省：部署會用 gcloud iam service-accounts describe
#    確認 runtime_sa 存在。沒開的話那個檢查一律失敗 —— 而且是「SA 明明在」
#    卻報找不到，最難查的那種。專案 owner 自己呼叫得動，所以不會在手動測試時暴露。
gcloud services enable run.googleapis.com artifactregistry.googleapis.com \
  iamcredentials.googleapis.com sts.googleapis.com secretmanager.googleapis.com \
  cloudresourcemanager.googleapis.com sqladmin.googleapis.com \
  iam.googleapis.com \
  --project="$PROJECT" --quiet

# 2. Artifact Registry
gcloud artifacts repositories create "$AR_REPO" --repository-format=docker \
  --location="$REGION" --project="$PROJECT" --quiet

#    清理政策。每次 push 都新增一個 image，沒有回收的話只會單向成長。
#    Keep 規則優先於 Delete，而 keepCount 是「每個 image 各保留 N 個」——
#    所以久未部署的服務，它正在跑的那個 image 仍在最新 10 個之內，不會被刪。
cat > /tmp/ar-policy.json <<'JSON'
[
  {"name":"keep-recent","action":{"type":"Keep"},
   "mostRecentVersions":{"keepCount":10}},
  {"name":"delete-untagged-30d","action":{"type":"Delete"},
   "condition":{"tagState":"untagged","olderThan":"30d"}},
  {"name":"delete-old-90d","action":{"type":"Delete"},
   "condition":{"tagState":"any","olderThan":"90d"}}
]
JSON
gcloud artifacts repositories set-cleanup-policies "$AR_REPO" \
  --location="$REGION" --project="$PROJECT" --policy=/tmp/ar-policy.json --no-dry-run

# 3. 兩個身分。執行身分刻意「不是」預設 compute SA —— 那個帶 Editor，
#    等於每個服務都是專案管理員。
#    run-runtime 是「沒有自己資料庫的服務」的預設執行身分，它刻意沒有任何
#    Cloud SQL 權限 —— 要用 DB 的服務要有自己的 SA，見「服務要用資料庫」。
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

> ⚠️ **`add-iam-policy-binding` 是對專案 policy 做 read-modify-write。** 併發跑（例如
> 用迴圈同時建好幾個 SA 的綁定）會撞 etag，**其中一筆可能靜靜地沒生效**。實測踩過：
> 八個 SA 有一個掉了綁定，症狀是部署成功但 DB 連線 `InterfaceError: communication error`。
> 不要把輸出丟進 `/dev/null`，收尾一定要複查：
>
> ```bash
> gcloud projects get-iam-policy "$PROJECT" --flatten="bindings[].members" \
>   --filter="bindings.members:run-my-app@" --format="value(bindings.role)"
> ```

### 開共用 instance（每個環境一台）

**一個環境一台，服務靠 database 分隔。** 收費按 instance 算、database 免費，
所以「一個服務一台」是純粹的浪費。名字兩個環境都叫 `apps-pg`——環境靠 project ID
識別，`connectionName` 前面就是它。

```bash
# --edition=ENTERPRISE 不能省：新 instance 預設 ENTERPRISE_PLUS，那個版本不收
# db-f1-micro 這類共享核心規格，會噴 Invalid Tier。
gcloud sql instances create apps-pg --project="$PROJECT" --region="$REGION" \
  --edition=ENTERPRISE --database-version=POSTGRES_17 --tier=db-f1-micro \
  --storage-size=10 --storage-type=HDD \
  --database-flags=cloudsql.iam_authentication=on \
  --backup-start-time=18:00 --quiet

# 管理用的人工帳號，之後每個 database 都要單獨 GRANT CONNECT 給它
gcloud sql users create adamsourceinfo@gmail.com --instance=apps-pg \
  --project="$PROJECT" --type=cloud_iam_user
```

`--backup-start-time` 順手開備份（時間是 UTC，18:00 = 台北 02:00）。備份費是
$0.08/GiB-月，這種規模等於幾分錢，沒有不開的理由。

---

## 開一個新專案

> **服務要用資料庫的話，先跑 `ci/scripts/provision-service.sh` 再推第一版**
> （見下面「服務要用資料庫」）。沒先跑的話第一次部署會停在 `preflight`
> 並告訴你缺什麼——硬失敗是設計，不是壞掉，但知道比較不心慌。

```bash
gh repo create adamsourceinfo-org/my-app --public --clone && cd my-app
mkdir -p .github/workflows .cicd

cat > .github/workflows/deploy.yml <<'YAML'
# 由 adamsourceinfo-org/ci 提供。部署邏輯全部在 ci repo，這裡只負責呼叫它。
#
# 改這個檔不會讓你拿到任何 GCP 權限 —— 換取雲端憑證的條件綁死在
# "adamsourceinfo-org/ci/.github/workflows/deploy.yml@refs/heads/main"。
#
# 三條路：
#   PR          → 只 build，證明建得起來（完全不碰 GCP）
#   push main   → build → 部署 adamsourceinfo-dev
#   push tag    → 把 main 建好的同一個 image 搬去 adamsourceinfo-prod（不重新 build）
name: deploy
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
    # 刻意收「所有」tag 再由 ci 驗格式。用 glob 過濾的話，推一個格式不對的 tag
    # 會安靜地什麼都不發生 —— 而「按了沒反應」比紅燈難查得多。
    tags: ["**"]
  workflow_dispatch:

jobs:
  deploy:
    permissions:
      contents: read
      id-token: write      # 換 WIF 憑證必要
    uses: adamsourceinfo-org/ci/.github/workflows/deploy.yml@main
    # 專案設定放 .cicd/config.yml，這支 stub 不用改。
YAML
```

再自備 `Dockerfile`（容器要監聽 `$PORT`），然後推上去：

```bash
git add -A && git commit -m "接上 adamsourceinfo-org/ci"
git branch -M main && git push -u origin main
```

`gh repo create` 出來的 repo 是空的（沒有 commit、沒有 main 分支），所以 `-M main` 不能省。

`.cicd/` 全部選填 —— 什麼都不放也能跑，格式見下面「專案端契約」。

**分支保護是 repo 自己的治理設定，不是這裡的事。** 在 GitHub 介面或 org ruleset 設定即可；
required check 用 `deploy / 1 verify` 與 `deploy / 2 build`。

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

runtime_sa: run-my-app     # 執行身分。要用 Cloud SQL 就必填
db:                        # 要用 Cloud SQL 才需要，只宣告一次
  name: my_app             # instance 由平台決定（一個環境一台 apps-pg）
```

**`runtime_sa` 在宣告 `db` 時必填。** 共用的 `run-runtime` 沒有 Cloud SQL 權限
——「你有自己的資料庫，就有自己的身分」。不用 DB 的服務整段省略，沿用 `run-runtime`。

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
  --member="serviceAccount:run-my-app@adamsourceinfo-dev.iam.gserviceaccount.com" \
  --role=roles/secretmanager.secretAccessor
```

> ⚠️ 授權對象是**這個服務的 `runtime_sa`**，不是共用的 `run-runtime`。從共用身分改成
> 專屬身分時最容易漏這一步 —— 漏了的話新 revision 讀不到機密、**直接起不來**，
> 而且是在切換當下才炸。

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

**一個環境一台 instance（`apps-pg`），服務靠 database 分隔。** 收費按 instance 算，
instance 裡開幾個 database 免費——所以「一個服務一台」是純粹的浪費。

在 `.cicd/config.yml` 宣告**一次**（不是 dev/prod 各一份）：

```yaml
runtime_sa: run-my-app
db:
  name: my_app
```

連線字串、DB 帳號、Cloud SQL 掛載，CI 依「正在部署哪個環境」自己推導：

| CI 注入的環境變數 | 推導方式 | dev 實際拿到 |
|---|---|---|
| `INSTANCE_CONNECTION_NAME` | `<專案>:<區域>:apps-pg` | `adamsourceinfo-dev:asia-east1:apps-pg` |
| `DB_USER` | `<runtime_sa>@<專案>.iam` | `run-my-app@adamsourceinfo-dev.iam` |
| `DB_NAME` | `db.name` 原樣 | `my_app` |

**為什麼不讓你自己寫連線字串**：那樣就有寫錯專案的機會。CI 本來就知道自己在部署哪個環境
（它已經用這個知識注入 `APP_ENV`），讓它一併推導，dev 連到 prod 的 DB 就從「會被抓到的錯」
變成**寫不出來的錯**。instance 同理——專案端根本沒有那個欄位。

> `INSTANCE_CONNECTION_NAME`、`DB_USER`、`DB_INSTANCE`、`DB_NAME` 在 `.cicd/env.*` 裡都被擋下。

### 隔離只來自 GRANT，不來自 IAM

四個服務共用一台 instance，所以每個 SA 都登得進去——`roles/cloudsql.client` 與
`roles/cloudsql.instanceUser` **只能綁在專案層**（Cloud SQL 沒有 instance 層級的
IAM policy，`gcloud sql instances add-iam-policy-binding` 這個指令不存在）。

這兩個角色不是防護，是**連線路徑本身**：少了 `client`，Cloud Run 旁的 Auth Proxy
建不起連線；少了 `instanceUser`，access token 不被當成密碼接受。

**真正的牆是 Postgres 的 `REVOKE CONNECT ON DATABASE … FROM PUBLIC`。**
Postgres 預設讓 `PUBLIC` 連任何 database，少了那道 `REVOKE`，每服務一個 SA
只是換了名字，隔離是假的。這是下面清單裡最不能省的一步。

### 沒有密碼

用 Cloud SQL **IAM 資料庫認證**：服務自己的 SA（`runtime_sa`）直接就是 Postgres 使用者，
密碼是向 metadata server 要的 access token。Secret Manager 不放任何 DB 機密。

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

### 一次性清單（你，每個服務跑一次）

**CI 刻意不自動做這些。** instance 要 10 分鐘且會計費；SA 更關鍵——一個能建 SA
又能發角色的部署身分，等於能把任何權限發給自己，WIF 那道「只有一支 workflow
換得到憑證」的鎖就白做了。所以 `github-deployer` 沒有任何 `iam.*` 權限。
缺什麼，部署會停在 `preflight` 並告訴你缺哪幾項。

**在專案 repo 裡跑**（這樣它讀得到 `.cicd/secrets.*`，自動把機密授權給新的 SA）：

```bash
cd my-app
../ci/scripts/provision-service.sh my-app run-my-app my_app
#                                  ↑服務名  ↑runtime_sa  ↑db.name
```

**預設兩個環境一起做。** 只想做一邊就加第四個參數 `dev` / `prod`。
可以安全重跑——每一步先查再做。

它做六件事：

| # | 做什麼 | 為什麼由人做 |
|---|---|---|
| 1 | 建執行身分 SA | deployer 沒有 `iam.*` |
| 2 | 授 `cloudsql.client` + `cloudsql.instanceUser` | 同上。**循序**做，避免併發撞 etag |
| 3 | 綁 deployer 的 `serviceAccountUser` | 沒有它 CI 用不了這個身分 |
| 4 | 把 `.cicd/secrets.*` 的機密授權給新 SA | 換 SA 後最容易漏，漏了新 revision 直接起不來 |
| 5 | 建 database 與 IAM DB user | DB user 要用去掉 `.gserviceaccount.com` 的短格式 |
| 6 | `REVOKE CONNECT FROM PUBLIC` + 逐服務 `GRANT` | **省了隔離就是假的**，見上一節 |

結尾**驗收六項**，任一不過就非零結束：SA 存在、兩個角色、`serviceAccountUser`、
database、DB user、`datacl` 的 PUBLIC 沒有 `c`。

**前三項是 CI 查不到的**——`getIamPolicy` 與 `cloudsql.users.list` 都不在部署身分
的權限裡，而那條邊界比早幾十秒發現錯誤更值得守。所以它們只能在這裡驗。

> 腳本會重設 `postgres` 帳號的密碼。那是**拋棄式的**，不用記——IAM 認證的 app
> 不需要它，下次跑又會換一個。

開通完成後**要重新觸發一次部署**——先前那次已經失敗，不會自己重跑：

```bash
gh workflow run deploy.yml --repo adamsourceinfo-org/my-app --ref main
```

（不要用 `gh run rerun`：它會沿用當初解析到的 ci workflow 版本。）

> **停機省不了錢。** `--activation-policy=NEVER` 之後 compute 歸零，但 IP 保留費
> （$0.01/hr ≈ $7.30/月）反而被啟用，加上照算的儲存費 $0.90 = $8.20，對照 running
> 的 $8.57 一個月只省 $0.37。關掉 public IP 也不行——那需要先設定 private IP。
> 要省錢只有減少 instance 數量，這正是合併成一台的理由。

### 怎麼確認接對了

讓服務回報一段健康資訊，其中 `server_user` 與 `database` 要由 **DB 自己回答**，
不能是環境變數回音，否則證明不了任何事：

```json
{ "env": "dev",
  "db": { "instance": "adamsourceinfo-dev:asia-east1:apps-pg",
          "ok": true,
          "server_user": "run-my-app@adamsourceinfo-dev.iam",
          "database": "my_app" } }
```

dev 與 prod 各打一次，專案名要各自對得上自己的環境。兩邊跑的是同一個 image，
所以差異只可能來自 CI 推導 —— 這正是重點。

`server_user` 是**這個服務自己的 SA**、`database` 是自己的 database，兩個都由
DB 回答。合併之後 `instance` 兩邊都是 `apps-pg`，所以真正證明隔離的是這兩個欄位。

### 限制

| 限制 | 說明 |
|---|---|
| DB 與 Cloud Run 必須同區域 | 推導假設 `<專案>:asia-east1:apps-pg` |
| 一個環境只有一台 instance | 專案端無法指定別台。真的需要就手動 `--add-cloudsql-instances`，疊加式旗標與 CI 並存不衝突 |
| 兩個環境的 instance 名字相同 | 刻意的 —— 分歧的餘地就是出錯的餘地，環境靠 project ID 識別 |
| 服務共用 instance 的連線數 | `db-f1-micro` 預設 `max_connections=25`，四個服務共用。撞到時：調小 `DB_POOL_MAX` / `maxScale` → 設 `max_connections` flag → 升 `db-g1-small` |
| 刪掉 `db:` | ⚠️ 掛載不會自動消失，要手動 `--remove-cloudsql-instances` |
| 改 `runtime_sa` | ⚠️ 舊 SA 的 secret 授權不會自動搬，新 SA 要重新授權 |

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
| 執行身分（有 DB） | `<runtime_sa>@adamsourceinfo-dev` | `<runtime_sa>@adamsourceinfo-prod` |
| 執行身分（沒有 DB） | `run-runtime@adamsourceinfo-dev` | `run-runtime@adamsourceinfo-prod` |
| 部署權限 | `run.admin`、`artifactregistry.writer`、`cloudsql.viewer`、`serviceAccountUser`（限**各個**執行身分，逐一綁定） | 同左 + dev AR 的 `artifactregistry.reader` |

**部署身分沒有 `iam.*`** —— 建 SA、授 IAM 都做不到。所以上面那份 runbook 才必須由人跑。

### PR 拿不到憑證

`deploy.yml` 同時服務 PR 與部署，界線由兩件事守住：

1. `build` 這個 job（PR 專用） **沒有** `permissions: id-token: write`
2. 每一個碰 GCP 的 job 都有 `if: github.event_name != 'pull_request'`

這兩者是安全邊界的一部分，不是風格。改動 `deploy.yml` 時務必保持。

### PR 綠燈不代表部署會過

`verify` 刻意沒有 GCP 憑證（見上節），所以 `runtime_sa` 指向不存在的 SA、
database 還沒建這類問題，**PR 階段查不到**。最早的 GCP 檢查是 `preflight`，
它在 merge 進 main 之後、build 之前跑。

這是安全邊界的代價，不是疏漏：要讓 PR 查得到，就得讓 PR 拿得到雲端憑證，
而那正是整個 WIF 設計要防的事。

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
| `找不到共用 Cloud SQL instance` | 該環境還沒開 `apps-pg`。見「開共用 instance」 |
| `找不到執行身分「run-…」` | SA 還沒建。照「一次性清單」跑一次 |
| `宣告了 db 就必須指定 runtime_sa` | 共用的 `run-runtime` 沒有 Cloud SQL 權限，要用 DB 就要有自己的身分 |
| `runtime_sa '…' 不是合法的 service account ID` | 6–30 字元、小寫字母開頭，只能有小寫字母/數字/連字號 |
| `db.instance 已移除` | 舊格式。刪掉那行，只留 `db.name` |
| `不可以自己設定 INSTANCE_CONNECTION_NAME` | CI 保留字。改在 `config.yml` 宣告 `db.name` 與 `runtime_sa` |
| `Bad syntax for dict arg` | `.cicd/*` 的值裡有 `@@`，撞到自訂分隔符 |
| 部署時 `Aborted by user` | 該專案的 `sqladmin.googleapis.com` 沒開 |
| `permission denied for schema public` | IAM 使用者建了但沒 `GRANT`，或 `GRANT` 下在別的 database |
| `permission denied for database` | 漏了 `GRANT CONNECT`，或 `runtime_sa` 指到別的服務的 SA（fail closed，不會讀到別人的資料） |
| Cloud Run revision 起不來、讀不到 secret | 換 `runtime_sa` 之後漏了 secret accessor 授權 |
| `Database username ... without ".gserviceaccount.com"` | `sql users create` 要用短格式 `<runtime_sa>@<專案>.iam` |
| `Invalid Tier (db-f1-micro) for (ENTERPRISE_PLUS)` | 建 instance 要加 `--edition=ENTERPRISE` |
| proxy `invalid_grant / invalid_rapt` | 本機 ADC 過期。加 `--token "$(gcloud auth print-access-token)"` |
| preflight `找不到 database「…」` / `找不到執行身分「…」` | 還沒 provision。跑 `ci/scripts/provision-service.sh` |
| preflight `查不到… 沒有啟用 …googleapis.com` | 該專案缺 API，訊息裡直接附了 enable 指令 |
| psql `Connection refused` on 127.0.0.1:5433 | `cloud-sql-proxy` 丟到背景後還沒開始監聽。等它：`until nc -z 127.0.0.1 5433; do sleep 1; done` |
| `找不到執行身分「run-…」`，但 SA 明明存在 | 該專案沒開 `iam.googleapis.com`。owner 自己呼叫得動，所以手動測試不會暴露 |
| 部署成功但 DB `InterfaceError: communication error` | SA 少了 `cloudsql.client` / `instanceUser`。併發下的 `add-iam-policy-binding` 可能靜靜掉一筆，複查 |
| 自己用 psql 看不到 app 建的表 | 表的擁有者是服務的 SA。`GRANT "<runtime_sa>@<專案>.iam" TO "<你的帳號>"` |
