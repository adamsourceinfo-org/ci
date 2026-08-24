# Cloud SQL 合併：一環境一台，用 database 分服務

日期：2026-08-24

本文修訂 [2026-08-23 Cloud SQL 環境隔離設計](2026-08-23-cloudsql-env-separation-design.md)
與 [2026-08-23 .cicd/config.yml 設計](2026-08-23-cicd-config-yaml-design.md) 中
「每個服務一台 instance」與 `db.instance` 欄位的部分。環境隔離的原則不變，變的是
**同一個環境內部**怎麼擺。

## 問題

「一個服務一台 Cloud SQL instance」在四個服務時已經是 8 台，而 Cloud SQL 的收費
**按 instance 算，instance 裡開幾個 database 完全免費**：

| SKU（asia-east1，2026-08-24 查 Cloud Billing Catalog API） | 單價 |
|---|---|
| `F893-F486-E6E1` Zonal Micro instance | $0.0105/hr |
| `2FAE-DAED-89EC` Zonal Low cost storage（PD_HDD） | $0.09/GiB-月 |

每台 = $7.67 + $0.90 = **$8.57/月**。8 台 = $68.52/月。合併成 2 台 = $17.14/月，
**省 $51.42/月（$617/年）**。

停機省不了錢：`activationPolicy=NEVER` 之後 compute 歸零，但 IP 保留費
（`09EB-F535-4DBA`，$0.01/hr = $7.30/月）反而被啟用，加上照算的儲存費 $0.90 = $8.20，
一台一個月只省 $0.37。關掉 public IP 也不行——官方限制是「You can disable public IP,
but only if your instance is also configured to use Private IP」，而這些 instance
都沒有 private IP。**要省錢只有減少 instance 數量**。

## 決策

| 決策 | 選擇 | 理由 |
|---|---|---|
| 環境隔離 | **不變**：dev / prod 各自的 GCP 專案、各一台 | `connectionName` 自帶 project ID，環境即識別碼 |
| 環境內分服務 | **一個 database 一個服務**，同一台 instance | database 免費；`public` schema 各自獨立 |
| instance 名稱 | `apps-pg`（dev/prod 同名） | 環境靠 project ID 識別，名字相同讓兩邊設定逐字一致 |
| instance 誰宣告 | **平台**（`deploy.yml` 的 `SQL_INSTANCE`），專案端移除 `db.instance` | 「連錯 instance」從「會被抓到的錯」變成**寫不出來的錯** |
| 執行身分 | **一個服務一個 SA**，在 `.cicd/config.yml` 明寫 `runtime_sa` | 見下節「為什麼隔離只能靠 GRANT」 |
| 沒有 `db:` 的服務 | 沿用共用的 `run-runtime` | 新專案維持零設定即可部署；要用 DB 才需要那張一次性清單 |
| SA 誰申請 | **人工，CI 硬失敗並印出指令** | 見下節「為什麼 CI 不能代為申請 SA」 |
| 連線數 | 不預先調，寫進風險與監控 | 見「風險：連線數預算」 |

## 為什麼隔離只能靠 GRANT

合併之後，四個服務的 SA 都必須連得到同一台 `apps-pg`。這代表：

1. **IAM 給不了隔離。** `roles/cloudsql.client` 與 `roles/cloudsql.instanceUser`
   只能綁在**專案層**——Cloud SQL 沒有 instance 層級的 IAM policy
   （`gcloud sql instances add-iam-policy-binding` 這個指令不存在）。所以每個 SA
   都登得進那一台。這兩個角色不是防護層，是**連線路徑本身**：少了 `client`，
   Cloud Run 旁的 Auth Proxy 建不起連線；少了 `instanceUser`，IAM 認證的 access token
   不被當成密碼接受。

2. **唯一的牆是 Postgres 的 GRANT。** Postgres 預設讓 `PUBLIC` 連任何 database，
   所以每個 database 建完必須：

   ```sql
   REVOKE CONNECT ON DATABASE <db> FROM PUBLIC;
   GRANT ALL PRIVILEGES ON DATABASE <db> TO "<sa>@<project>.iam";
   GRANT ALL ON SCHEMA public TO "<sa>@<project>.iam";
   ```

   **少了第一行的 `REVOKE`，每服務一個 SA 只是換了名字，隔離是假的。**
   這是整份設計最不能省的一步。

3. 合併前的隔離是拓撲白送的（不同 instance + 沒掛 `--add-cloudsql-instances` 就連不到）。
   合併之後那道牆消失，必須用 GRANT 顯式重建。這是這次改動最主要的風險轉移。

`postgres` 這個維護用 database 維持 `PUBLIC` 可連——它是空的，可接受。

### 附帶收緊

新模型下 `run-runtime` 只服務「沒有宣告 `db:` 的服務」，永遠不需要碰 Cloud SQL。
它現在身上的 `roles/cloudsql.client` 與 `roles/cloudsql.instanceUser` 應**撤掉**。

## 為什麼 CI 不能代為申請 SA

`github-deployer` 刻意沒有任何 `iam.*` 權限（見 README「一次性設定」）。要讓 CI 建 SA，
得給它 `serviceAccountAdmin` ＋ 專案 IAM 的授權權限 ＋ `secretmanager.admin`。
**一個能建 SA 又能發角色的部署身分，等於能把任何權限發給自己**——WIF 那道
「只有一支 workflow 換得到憑證」的鎖就白做了。用 $51/月的節省換這個，不划算。

沿用既有做法：**CI 偵測到缺什麼就硬失敗，並印出該跑的指令**，跟現在 instance
不存在時的行為一致。

（真要自動化，不破壞模型的做法是另開一支只能人工 `workflow_dispatch` 觸發、
綁自己 WIF 條件的高權限 workflow。那是把權限搬家不是消除，四個服務不值得這個複雜度。）

## 為什麼 `runtime_sa` 明寫而不推導

推導（`SA = service` 或 `run-<service>`）的好處是無法錯配，但有兩個弱點：SA ID
限制 6–30 字元而服務名允許到 49；以及改服務名等於改身分。**選擇明寫**，並靠三道
檢查讓寫錯不會安靜地錯：

1. `verify` 驗格式 `^[a-z][-a-z0-9]{4,28}[a-z0-9]$`
2. 部署前檢查該 SA 在目標專案**確實存在**，否則硬失敗
3. 指到別的服務的 SA 會在連 DB 時被 Postgres 擋掉（沒有 `CONNECT`）——**fail closed**，
   不會出現「跑起來了但讀到別人的資料」

宣告了 `db:` 卻沒給 `runtime_sa` 要擋下來：否則會退回 `run-runtime`，而它已經沒有
cloudsql 權限，變成上線才發現連不上。

## 專案端契約的變化

```yaml
# 之前
db:
  instance: payment-paypal-pg
  name: payment_paypal

# 之後
runtime_sa: run-payment-paypal
db:
  name: payment_paypal
```

`db.instance` 出現時 `verify` 給明確的遷移錯誤，不是「不認得的設定」。

## CI 改動

`deploy.yml` 六處。**第 5、6 項在 deploy-dev 與 promote 各有一份複製貼上的程式碼
（L376 與 L664、L409 與 L697），兩處都要改**，漏掉一處就是 dev 與 prod 行為不一致。

| # | 位置 | 改什麼 |
|---|---|---|
| 1 | `env:` | 加 `SQL_INSTANCE: apps-pg`；`RUNTIME_SA_ID: run-runtime` 保留為預設 |
| 2 | config 解析 | `ALLOWED` 加 `runtime_sa`；`db` 子 key 只剩 `name`；`db.instance` 給遷移錯誤；讀 `runtime_sa` 並驗格式；「宣告 `db:` 就必須給 `runtime_sa`」 |
| 3 | outputs | 拿掉 `db_instance`，加 `runtime_sa` |
| 4 | `.cicd` 契約檢查 | `DB_INSTANCE` 錯誤訊息改成「instance 由平台決定，你只要 `db.name`」 |
| 5 | Cloud SQL 推導段 ×2 | 觸發條件改 `DB_NAME`；ICN 用 `SQL_INSTANCE`；**新增 SA 存在檢查**；`DB_USER` 用 `runtime_sa`；不再注入 `DB_INSTANCE` |
| 6 | `--service-account` ×2 | 改用 `runtime_sa` |

不再注入 `DB_INSTANCE`：已確認四個 app 都只讀 `INSTANCE_CONNECTION_NAME` / `DB_USER` /
`DB_NAME`，沒有任何一個讀 `DB_INSTANCE`。

`README.md` 五段：「一次性設定」（`run-runtime` 重新定位、撤掉其 cloudsql 角色、
新增開 `apps-pg`）、「`.cicd/config.yml` 契約」、「服務要用資料庫」整段重寫成一次性
清單、「設定與機密」的 secret 授權對象、「權限模型」表與「常見錯誤」。

## 遷移

資料全部可重建（2026-08-24 確認：四個服務 dev/prod 都還沒有真實交易），所以不做
dump/restore，改成建空 database 後重跑各專案既有的 migration。

**Phase 0 — 一次性 GCP 資源**（人工，dev/prod 各一輪）
1. 建 `apps-pg`（帶 `--backup-start-time`：現有 8 台備份全關，新建順手開，成本每月幾分錢）
2. 建 `adamsourceinfo@gmail.com` 人工 IAM user（現在存在於 payment 兩台上，供手動連線）
3. 四個服務各跑一次七步：建 SA → `cloudsql.client` + `instanceUser` →
   deployer 的 `serviceAccountUser` → **secret accessor** → 建 database →
   建 IAM DB user → `REVOKE`/`GRANT`

   secret accessor 這步最容易漏：六個 secret 現在全授權給 `run-runtime`，
   換 SA 那一刻若沒補授權，**新 revision 直接起不來**，而且是在 cutover 當下才炸。

**Phase 1 — CI**：`ci` 開 PR 改 `deploy.yml` + `README.md`，合併進 main。
合併後四個專案的 config 還是舊格式，CI 會硬失敗並提示遷移——這是安全的，不是壞掉。

**Phase 2 — 逐一切換**：`hello-db` → `hello-cicd` → `payment-ecpay` → `payment-paypal`
（金流最後，paypal 掛 live webhook 所以殿後）。每個都是改 config → push main →
驗 dev → 打 tag → 驗 prod → 才換下一個。

**Phase 3 — 清理**（四個都穩了再做）
1. 每個服務 `--remove-cloudsql-instances=<舊 instance>`（CI 是疊加式，舊掛載不會自己消失）
2. 每個服務 `--remove-env-vars=DB_INSTANCE`（CI 不再注入，但舊值不會自己消失）
3. 撤掉 `run-runtime` 的 `cloudsql.client` / `cloudsql.instanceUser`
4. 刪掉 8 台舊 instance

## 風險

**連線數預算。** db-f1-micro 預設 `max_connections=25`（Cloud SQL 依記憶體推導，
0.6GB → 25）。合併前是每個服務獨享 25，合併後四個服務共用 25。

理論最壞情況：`payment-paypal` 光 maxScale 10 × `DB_POOL_MAX` 3 = 30 就超過 25。
實際安全的理由：minScale 八個服務全都沒設（無常駐容器）、`payment-*` 的 pool 是
lazy 的 `LifoQueue`、`hello-*` 是每次請求開關連線、流量趨近零。

**不預先調整**，改為寫進監控。真的撞到時的階梯：
1. 調小 `DB_POOL_MAX` / `maxScale`（不花錢）
2. 設 `max_connections` database flag（0.6GB RAM 下每個 backend 吃幾 MB，調太高會 OOM）
3. 升 db-g1-small（`D46D-EDAD-F725`，$0.035/hr = $26.45/台/月；兩台 $52.90 仍比
   現在 8 台的 $68.52 便宜）

**回退**：Phase 3 之前舊 instance 完全不動，回退就是把 `config.yml` 改回去再部署一次。

## 驗證計畫

`gh run rerun` 會沿用當初解析到的 reusable workflow 版本——一律推新 commit / 新 tag
觸發全新 run。

1. **無 DB 路徑不受影響**：沒有 `db:` 的服務部署行為與改動前逐字相同，仍用 `run-runtime`
2. **遷移錯誤**：留著 `db.instance` 的 config 被 `verify` 擋下並印出遷移指示
3. **缺 `runtime_sa`**：宣告 `db:` 但沒給 `runtime_sa` 被 `verify` 擋下
4. **SA 不存在**：`runtime_sa` 指向不存在的 SA 時部署硬失敗並印出建立指令
5. **端對端**：四個服務在 dev 與 prod 都連上 `apps-pg`，健康檢查回報的
   `server_user` 是各自的新 SA、`database` 是各自的 database
6. **隔離**：用 A 服務的 SA 連 B 服務的 database 被拒絕（`REVOKE CONNECT` 生效）
7. **不被洗掉**：再推一次 main，掛載與身分仍在
