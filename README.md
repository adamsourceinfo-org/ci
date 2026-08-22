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
| 非機密設定 | `.cicd/env.<env>` | 開發者，進版控 | `--set-env-vars`（宣告式） |
| 機密 | GCP Secret Manager | `scripts/set-secret.sh` 跑一次 | `--set-secrets`（只掛名字） |
| `APP_ENV` / `APP_VERSION` | — | CI 自動注入 | prod 的 `APP_VERSION` 是 tag |

```bash
# 1. 寫值（值不經過 GitHub、不進版控、不出現在 log）
./scripts/set-secret.sh prod my-app-db-password

# 2. 在專案的 .cicd/secrets.prod 掛名字
echo 'DB_PASSWORD=my-app-db-password:latest' >> .cicd/secrets.prod
```

改設定 = 改檔案 + PR，有版控有 review。改機密 = 跑一次腳本，不用動 code、不用重 build。

> `.cicd/env.*` 與 `.cicd/secrets.*` 的值可以含逗號 — 部署時用 `^@^` 自訂分隔符。

### 不想讓 CI 管設定也可以

| 專案有沒有 `.cicd/env.<env>` | CI 行為 |
|---|---|
| **有** | `--set-env-vars`：檔案是唯一真相。從檔案刪掉一行，Cloud Run 上也會消失 |
| **沒有** | `--update-env-vars`：只補 `APP_ENV` / `APP_VERSION`，**完全不動**你自己在 Cloud Run 設的任何變數 |

沒有 `.cicd/secrets.<env>` 就完全不下 `--set-secrets`。所以「專案自己在 Cloud Run 裡設定」這條路是通的，CI 不會干擾。

注意：一旦建立了 `.cicd/env.<env>`，就等於宣告「這個檔案管全部」—— 手動在主控台加的變數會在下次部署被抹掉。這是宣告式的代價，也是它的價值。

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
./scripts/bootstrap-gcp.sh    # 可重複執行
```

開 API、建 Artifact Registry、建兩組 SA、建 WIF pool/provider 與信任綁定，以及跨專案的 promote 讀取權。

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
