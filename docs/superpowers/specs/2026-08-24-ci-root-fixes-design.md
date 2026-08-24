# ci 根因修復：抽取、前置驗證、runbook 腳本化

日期：2026-08-24

照 `ci/README.md` 從零建立 `hello-probe` 做端對端驗收，找出 10 個問題。
本文把它們收斂成三個根因並給對策。已在驗收當下修掉的那個（REVOKE/GRANT
少了等 proxy 起來，PR #13）不再重述。

## 根因

| 根因 | 症狀 |
|---|---|
| **A. deploy 邏輯有兩份** | `deploy-dev`（L346–462）與 `deploy-prod`（L647–764）各 117/118 行，`diff` 只有 7 行、其中 4 行是輸入值 |
| **B. GCP 前置條件驗得太晚、訊息太粗** | build-push 先跑完 36s 並把 image 推上 AR，才在 deploy 撞牆；SA 檢查把「不存在」與「查不到 IAM」印成同一句；`verify` 沒有 GCP 憑證，PR 綠燈不代表部署會過 |
| **C. 一次性設定是散文 runbook** | 章節順序保證新專案第一次紅燈；清單只寫 dev；第 4 步是註解不是指令；跑完沒有驗收。實測六步裡三步出錯：proxy race、`iam.googleapis.com` 沒開、`add-iam-policy-binding` 撞 etag |

C 的三個實測失敗都不是「看文件不夠仔細」，是文件無法用散文表達的東西：
等待條件、API 相依、併發語意。

## 決策

| 決策 | 選擇 | 理由 |
|---|---|---|
| 消除重複 | 抽成 composite action，`deploy.yml` 兩處都 `uses:` 它 | 110/117 行逐字相同，只差 4 個輸入值 |
| action 引用方式 | `adamsourceinfo-org/ci/.github/actions/deploy-service@main` | reusable workflow 執行時 runner 上是**呼叫端**的 code，路徑式 `./…` 會解析錯 |
| 安全邊界 | `permissions` 與 `if:` **留在 job 層** | composite action 裡設不了 permissions；邊界要留在 `deploy.yml` 看得見的地方 |
| 提早驗證 | 新增 `preflight` job，verify 之後、build-push 之前 | 換掉一次無用的 build 與一個永久留在 AR 的 image |
| preflight 查什麼 | instance、database、SA **三項** | 實測 `cloudsql.viewer` 只有 `instances.get` / `databases.get`，**沒有 `users.list`** |
| 不查的三項 | 角色綁定、DB user、GRANT → 交給 provisioning 腳本 | **刻意不擴權**：給 deployer `getIamPolicy` 會侵蝕「部署身分沒有 `iam.*`」 |
| 錯誤回報 | 一次列出全部缺項，並區分「不存在」與「API 沒開」 | 撞到第一個就 exit 會讓人來回三趟 |
| runbook | 腳本化為 `ci/scripts/provision-service.sh` | 見下節 |
| AR | 加 cleanup policy | dev 已 38 image / 470MB，只增不減 |

## 為什麼這次可以有腳本

ci 曾刻意從 10 個檔砍到 2 個，`bootstrap-gcp.sh`、`new-project.sh`、`set-secret.sh`
都是那時被刪的，理由是「人用自己帳號跑的一次性動作不屬於 CI」。

**這次不同的是頻率與可驗證性**：

- 合併成一台 instance 之後，provisioning 從「偶爾開一台 instance」變成
  **每服務 × 每環境**。五個服務已經跑了 10 次，往後每個新服務再兩次。
- 六個步驟裡有三個的失敗模式**無法用散文防範**：背景程序的就緒等待、
  隱含的 API 相依、專案 IAM policy 的 read-modify-write 併發。
- 腳本驗得到 README 驗不到的東西：角色綁定是否真的落地、`GRANT` 是否生效。
  這正是 CI 因為權限邊界而**不能**查的那三項。

**責任分界不變**：腳本**放在** ci，但由 owner 用自己的 `gcloud` 跑，
CI 永遠不執行它。README 保留「為什麼」，腳本承接「怎麼做」。
責任分界表新增一列講明這件事。

## 元件

### `ci/.github/actions/deploy-service/action.yml`

| input | 來源（dev） | 來源（prod） |
|---|---|---|
| `digest` | `needs.build-push.outputs.digest` | `needs.promote.outputs.digest` |
| `app_version` | 未傳（預設 `(dev build)`） | `github.ref_name` |
| `env_name` | `dev` | `prod` |
| `project` | `adamsourceinfo-dev` | `adamsourceinfo-prod` |

**composite action 不繼承 workflow 層的 `env:`**，所以 `AR_HOST` / `AR_REPO` /
`SQL_INSTANCE` 也必須變成 input。完整 12 個：

| 來源 | inputs |
|---|---|
| job 的環境差異 | `digest`、`app_version`（選填）、`env_name`、`project` |
| `needs.verify.outputs.*` | `service`、`region`、`allow_unauthenticated`、`runtime_sa`、`db_name` |
| workflow `env:` | `ar_host`、`ar_repo`、`sql_instance` |

`app_version` 選填：dev 不傳，現行程式碼本來就是
`[ -n "${APP_VERSION:-}" ] && PAIRS="${PAIRS}@@APP_VERSION=…"`。
`health_path` 不是這個 action 的輸入 —— 它只給 smoke job 用。

輸出 `url`。

內容就是現在那 117 行：合併 `.cicd/env.*`、推導 Cloud SQL、組 `gcloud run deploy`
參數、部署、取 URL。**行為不變**，只是從兩份變一份。

### `preflight` job

```
needs: verify
if: github.event_name != 'pull_request' && needs.verify.outputs.db_name != ''
permissions: {contents: read, id-token: write}
```

沒有宣告 `db:` 的服務整個 job 被 `if` 跳過——零成本。

目標專案依 `github.ref_type` 決定（`branch`→dev、`tag`→prod）。
**刻意不順便檢查 prod**：這個 job 拿的是本環境的憑證，看不到另一個專案，
加上去只會變成每次都警告，而每次都出現的警告等於沒有警告。
「prod 忘了 provision」的根因由 `provision-service.sh` 預設做兩個環境解決。

檢查三項，全部跑完再一次回報：

1. `gcloud sql instances describe $SQL_INSTANCE`
2. `gcloud sql databases describe $DB_NAME --instance=$SQL_INSTANCE`
3. `gcloud iam service-accounts describe $RUNTIME_SA@$PROJECT...`

每項把 stderr 收進變數，命中 `SERVICE_DISABLED` / `has not been used in project`
就改印「該專案沒開 `<api>`」而不是「找不到」。

`deploy-dev` / `deploy-prod` 裡原本的 instance 與 SA 檢查**保留**——
preflight 是加速回饋，不是唯一防線；tag 路徑若有人跳過 main 直接打 tag，
deploy 端仍要擋。

### `ci/scripts/provision-service.sh`

```
用法：provision-service.sh <service> <runtime_sa> <db_name> [dev|prod|both]
```

預設 `both`。每個環境依序做六步，每步**先查再做**（冪等）：

1. SA
2. `cloudsql.client` + `cloudsql.instanceUser`（**循序**，不併發，避免 etag 撞）
3. deployer 的 `serviceAccountUser`
4. secret accessor —— 從呼叫端 repo 的 `.cicd/secrets.<env>` 讀出 secret 名字自動授權；
   不在 repo 裡跑就印出該跑的指令
5. database + IAM DB user
6. `REVOKE CONNECT FROM PUBLIC` + 逐服務 `GRANT` + 人工帳號 `GRANT CONNECT`
   （含 proxy 就緒等待）

結尾**驗收六項**並列表回報，任一項未通過就以非零結束：
SA 存在、兩個角色、serviceAccountUser、database、DB user、`datacl` 的 PUBLIC 沒有 `c`。

前置檢查：`iam.googleapis.com` 是否啟用（沒開就直接說，不要等到 CI 才炸）。

### AR cleanup policy

兩個專案的 `apps` repo 各加兩條：保留最近 10 個 tagged、刪除 30 天前的 untagged。
先用 `--dry-run` 跑一次確認刪除清單合理，再正式套用。

## README 的變化

- 責任分界表新增「owner／服務的 SA、database、GRANT／每服務每環境一次／
  `ci/scripts/provision-service.sh`」一列
- 「開一個新專案」開頭加一句：要用 DB 的話先跑 provision，否則第一次部署會紅
- 「一次性清單」整段換成腳本用法 + 它做了什麼 + 為什麼是這六步（保留 REVOKE 的理由）
- 新增一段講明 `verify` 沒有 GCP 憑證，PR 綠燈不代表部署會過，最早的 GCP 檢查是 preflight
- 常見錯誤表補 preflight 的訊息

## 驗證計畫

`gh run rerun` 會沿用舊版 reusable workflow —— 一律推新 commit / 新 tag。

1. **行為不變**：`hello-probe` 推一次 main，dev 部署結果與改動前逐字相同
2. **preflight 擋得住**：`hello-probe` 的 `db.name` 改成不存在的值，
   應在 build-push **之前**失敗，且訊息同時列出缺的 database
3. **API 訊息的解析邏輯**：不去停用正在用的 API（會波及其他服務）。
   改用真實的 `SERVICE_DISABLED` 錯誤字串在本機餵給同一段 `grep -E`，
   確認它挑得出 API 名稱並走「沒開 API」那條分支
4. **無 DB 路徑**（從未被執行過）：`hello-probe` 暫時拿掉 `db:`，
   應跳過 preflight、用 `run-runtime` 部署成功、健康檢查回報 `configured: false`
5. **腳本冪等**：對已 provision 好的 `hello-probe` 重跑 `provision-service.sh`，
   應全部略過並通過六項驗收
6. **腳本抓得到破壞**：手動撤掉 `run-hello-probe` 的一個 cloudsql 角色，
   重跑腳本應補回並在驗收中指出
7. **tag 路徑**：`hello-probe` 打新 tag，prod 部署成功
8. **AR policy**：`--dry-run` 的刪除清單只含預期項目
