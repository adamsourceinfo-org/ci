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
cd ~/repository/adamsourceinfo/ci
./scripts/new-project.sh my-app --dir ~/repository/adamsourceinfo
```

會建立 public repo、放進 stub 與 `.cicd/` 骨架、推上 main，並上 ruleset 保護 main（禁直推、禁 force push、強制 PR + 通過 ci 檢查）。

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
│  ├─ deploy.yml           caller stub
│  └─ ci.yml               caller stub
└─ .cicd/
   ├─ env.dev              非機密設定，KEY=VALUE，進版控
   ├─ env.prod
   ├─ secrets.dev          機密「掛載表」，只有名字沒有值
   └─ secrets.prod
```

### stub 可調參數

| 參數 | 預設 | 說明 |
|---|---|---|
| `service` | repo 名稱 | Cloud Run 服務名稱 |
| `region` | `asia-east1` | |
| `health_path` | `/` | smoke test 打的路徑 |
| `dockerfile` | `Dockerfile` | |
| `allow_unauthenticated` | `true` | 是否開放未驗證存取 |

---

## 設定與機密

**CI/CD 只負責掛載，不負責寫入機密值。** 機密要進 CI/CD 才能寫的話，就得先躺在 GitHub secrets 裡 — 憑空多一個外洩面，也違背用 WIF（無金鑰）的用意。

| 類型 | 放哪 | 誰寫 | 怎麼進 Cloud Run |
|---|---|---|---|
| 非機密設定 | `.cicd/env.<env>` | 開發者，進版控 | `--update-env-vars`（合併，不刪除） |
| 機密 | GCP Secret Manager | `scripts/set-secret.sh` 跑一次 | `--update-secrets`（只掛名字） |
| `APP_ENV` / `APP_VERSION` | — | CI 自動注入 | prod 的 `APP_VERSION` 是 tag |

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

在**兩個** `.cicd/env.<env>` 各加兩行，**內容完全一樣**：

```
DB_INSTANCE=my-app-pg
DB_NAME=my_app
```

就這樣。連線字串、DB 帳號、Cloud SQL 掛載，CI 依「正在部署哪個環境」自己推導：

| CI 注入的環境變數 | 推導方式 | dev 實際拿到 |
|---|---|---|
| `INSTANCE_CONNECTION_NAME` | `<專案>:<區域>:<DB_INSTANCE>` | `adamsourceinfo-dev:asia-east1:my-app-pg` |
| `DB_USER` | `run-runtime@<專案>.iam` | `run-runtime@adamsourceinfo-dev.iam` |

外加部署時掛上 `--add-cloudsql-instances`。

**為什麼不讓你自己寫連線字串**：因為那樣就有寫錯專案的機會。CI 本來就知道自己在部署哪個環境（它已經用這個知識注入 `APP_ENV`），讓它一併推導，dev 連到 prod 的 DB 就從「會被抓到的錯」變成**寫不出來的錯**。兩個 env 檔那兩行逐字相同，diff 沒有差異，連抄錯都不可能。

> `INSTANCE_CONNECTION_NAME` 與 `DB_USER` 是 CI 保留字。在 `.cicd/env.*` 手寫會被 `verify` 擋下。

### 沒有密碼

用 Cloud SQL **IAM 資料庫認證**：`run-runtime` SA 直接就是 Postgres 使用者，密碼是向 metadata server 要的 access token。Secret Manager 不用放任何 DB 機密，跟 WIF「一把金鑰都不存」是同一套邏輯。

app 端這樣連（Python + pg8000，走 Cloud Run 注入的 unix socket）：

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

```bash
PROJECT=adamsourceinfo-dev; INSTANCE=my-app-pg; DB=my_app
SA="run-runtime@${PROJECT}.iam.gserviceaccount.com"

# --edition=ENTERPRISE 不能省：新 instance 預設 ENTERPRISE_PLUS，那個版本不收
# db-f1-micro 這類共享核心規格，會噴 Invalid Tier 並要你改用 db-perf-optimized-N-*。
gcloud sql instances create "$INSTANCE" --project="$PROJECT" --region=asia-east1 \
  --edition=ENTERPRISE --database-version=POSTGRES_17 --tier=db-f1-micro \
  --storage-size=10 --storage-type=HDD \
  --database-flags=cloudsql.iam_authentication=on --quiet

gcloud sql databases create "$DB" --instance="$INSTANCE" --project="$PROJECT"

gcloud sql users create "$SA" --instance="$INSTANCE" --project="$PROJECT" \
  --type=cloud_iam_service_account

for ROLE in roles/cloudsql.client roles/cloudsql.instanceUser; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA}" --role="$ROLE" --condition=None --quiet
done
```

最後進 DB 授權（IAM 使用者建好後仍需要 `GRANT`）：

```sql
GRANT ALL ON SCHEMA public TO "run-runtime@<專案>.iam";
```

dev 不用的時候可以停機，只算儲存費：

```bash
gcloud sql instances patch my-app-pg --project=adamsourceinfo-dev --activation-policy=NEVER   # 停
gcloud sql instances patch my-app-pg --project=adamsourceinfo-dev --activation-policy=ALWAYS  # 開
```

### 限制

| 限制 | 說明 |
|---|---|
| DB 與 Cloud Run 必須同區域 | 推導假設 `<專案>:asia-east1:<instance>` |
| 不支援跨專案 / 跨區域的 DB | 真的需要就手動 `gcloud run services update --add-cloudsql-instances`，疊加式旗標與 CI 並存不衝突 |
| 只有一邊宣告 `DB_INSTANCE` | `verify` 警告但不擋 —— 「先在 dev 接上驗證再開 prod」是合法的漸進上線 |
| 刪掉 `DB_INSTANCE` | ⚠️ 掛載不會自動消失，要手動 `--remove-cloudsql-instances`（與環境變數同一個取捨） |

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
| DB 連線 `password authentication failed` | IAM 使用者建了但沒 `GRANT`，或 access token 過期了 |

<!-- self-test 驗證用 -->
