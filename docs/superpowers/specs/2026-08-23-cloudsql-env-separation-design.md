# Cloud SQL 環境隔離設計

日期：2026-08-23

## 問題

服務要連 Cloud SQL 時，「dev 連到 prod 的 DB」是最不能發生的管理錯誤。

Cloud Run 連 Cloud SQL 不是設一個環境變數就好：容器裡沒有到 Cloud SQL 的網路路徑，必須在**服務層級**掛上 `--add-cloudsql-instances`，Cloud Run 才會在容器旁跑 Cloud SQL Auth Proxy，在 `/cloudsql/<connectionName>` 開 unix socket。這是部署時的旗標，app 自己設不到。

手動掛載可行（`--add-*` 是疊加的，CI 後續部署不會洗掉），但**手動掛載永遠不可能有驗證**：打錯專案就是打錯，錯誤沉在雲端狀態裡，沒有 diff、沒有 review、沒有紅燈。

## 決策

| 決策 | 選擇 | 理由 |
|---|---|---|
| 環境隔離層級 | dev / prod **各一台 instance**，各在自己的 GCP 專案 | `connectionName` 自帶 project ID，環境即識別碼；`run-runtime` SA 只在自己專案有 `cloudsql.client`，跨環境連線 fail closed |
| DB 認證 | Cloud SQL IAM 資料庫認證 | 全程無密碼，與 WIF「一把金鑰都不存」一致；SA 帳號名含專案，連線層再多一道環境識別 |
| 連線字串誰決定 | **CI 推導**，不由開發者書寫 | 寫錯專案變成「無法表達」，而非「會被抓到」 |
| 開關 | `.cicd/env.<env>` 有沒有 `DB_INSTANCE` | 不用 DB 的服務零成本、零認知負擔 |
| 掛載旗標 | `--add-cloudsql-instances`（疊加） | 沿用「CI 絕不覆蓋既有設定」原則 |
| dev 成本 | 最小規格，閒置時 `--activation-policy=NEVER` 停機 | 停機只算儲存費，隔離不打折 |

### 為什麼是 CI 推導（B）而不是守門檢查（A）

先前考慮過 A：開發者寫完整的 `INSTANCE_CONNECTION_NAME`，CI 斷言前綴等於本環境的專案。A 能抓錯，但 B 更強一級——

CI 的 dev 區塊寫死 `PROJECT: adamsourceinfo-dev`、prod 區塊寫死 `adamsourceinfo-prod`，**它本來就知道自己在部署哪個環境**，而且已經在用這個知識推導 `APP_ENV` 與 `APP_VERSION` 注入容器。把連線字串一併推導不是新模式，是既有模式的延伸。

結果：`.cicd/env.dev` 與 `.cicd/env.prod` 的 DB 設定**逐字相同**。沒有差異就沒有抄錯的機會，不是靠檢查，是靠沒有可寫錯的欄位。

## 契約

開發者在**兩個** `.cicd/env.<env>` 各寫兩行，內容一模一樣：

```
DB_INSTANCE=app-pg
DB_NAME=app
```

CI 在部署時推導並注入：

| 注入的環境變數 | 推導自 |
|---|---|
| `INSTANCE_CONNECTION_NAME` | `${PROJECT}:${REGION}:${DB_INSTANCE}` |
| `DB_USER` | `${RUNTIME_SA_ID}@${PROJECT}.iam` |

並加上 `--add-cloudsql-instances=${INSTANCE_CONNECTION_NAME}`。

app 端連 `/cloudsql/${INSTANCE_CONNECTION_NAME}/.s.PGSQL.5432`，使用者 `${DB_USER}`，密碼是向 metadata server 取得的 OAuth2 access token。

## 保留字

`INSTANCE_CONNECTION_NAME` 與 `DB_USER` 由 CI 擁有。開發者在 `.cicd/env.*` 手寫這兩個 key 會被 `verify` 擋下，訊息提示改用 `DB_INSTANCE`。

理由：兩者都會流進 `--update-env-vars` 的 `PAIRS`，重複的 key 誰贏未定義。擋下來比讓它安靜地不確定好。

> `APP_ENV` / `APP_VERSION` 有同樣的潛在衝突（既有問題）。本次不順手修，但也不複製這個缺陷。

## 對稱性：警告，不擋

`DB_INSTANCE` 只在一個環境宣告時，`verify` 發出警告並寫進 job summary，**不使部署失敗**。

「先在 dev 接上 DB 驗證，確認沒問題再開 prod」是合法且常見的漸進上線。擋下來會卡住正確的做法；靜靜放過又會讓「忘了開 prod」在 runtime 才炸。警告是這兩者之間唯一站得住的位置。

## 假設與限制

- **DB 與 Cloud Run 同區域**（都 `asia-east1`）。推導 `${PROJECT}:${REGION}:${DB_INSTANCE}` 建立在這個前提上。
- **跨區域或跨專案的 DB 不支援**，也刻意不做 override 機制。真的需要就手動 `gcloud run services update --add-cloudsql-instances`——疊加式旗標與 CI 並存不衝突。
- 從 `.cicd/env.<env>` **刪掉** `DB_INSTANCE`，Cloud Run 上的掛載不會自動消失，要手動 `--remove-cloudsql-instances`。與環境變數同一個已知取捨。
- 本設計不含 instance 開通自動化。開 instance / database / IAM user 目前是手動一次性作業。

## fail closed 的兩道鎖

即使掛載掛錯環境，資料也不會寫錯 DB：

1. `run-runtime@adamsourceinfo-dev` 在 prod 專案沒有 `cloudsql.client` → proxy 建不起連線
2. IAM 認證下 `run-runtime@adamsourceinfo-dev.iam` 不是 prod Postgres 的 user → 認證失敗

（2026-08-23 查證：兩個專案的 IAM policy 互相沒有對方的成員，也沒有任何 cloudsql 角色。）

這兩道鎖是拓撲白送的。但 fail closed 只代表「不會毀資料」，服務照樣起不來；而且第 1 道鎖的前提是沒人為了方便去開跨專案權限。CI 的推導是把錯誤擋在部署之前，跟這兩道鎖是不同層次的防線。

## 驗證計畫

`gh run rerun` 會沿用當初解析到的 reusable workflow 版本 —— 一律推新 commit / 新 tag 觸發全新 run。

1. **無 DB 路徑**：`.cicd/env.*` 沒有 `DB_INSTANCE` 時，部署行為與改動前逐字相同
2. **保留字**：手寫 `INSTANCE_CONNECTION_NAME=` 會被 `verify` 擋下
3. **推導與掛載**：部署後 `gcloud run services describe` 看得到正確的 cloudsql annotation 與注入的環境變數
4. **端對端**：hello-cicd 實際連上 dev 與 prod 各自的 Cloud SQL，且回應中的 project 與環境相符
5. **不被洗掉**：再推一次 main，掛載仍在
