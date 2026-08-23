# CI repo 的職責邊界

日期：2026-08-23

## 問題

ci repo 長到 10 個檔案：3 支 workflow、4 支 shell script、3 個樣板。對照參考架構
（`cm-ailab-units-prod/ci`，服務 44 個真實產品）只有 1 支 workflow + README。

問題不是檔案數，是**分類方式錯了**：按「主題」歸類（凡是跟部署沾邊的都放進來），
而不是按「誰負責、多久做一次、用什麼憑證」。結果四種完全不同生命週期的東西擠在一起。

## 責任分界

| 誰 | 做什麼 | 多久一次 | 憑證 | 該住哪 |
|---|---|---|---|---|
| owner | GCP 專案、API、WIF、SA、IAM、Cloud SQL instance | 一次 | 人的 gcloud | README runbook |
| owner | 建 repo、分支保護 | 每專案一次 | 人的 gh | GitHub 設定 |
| 開發者 | 程式碼、`.cicd/`、secret 的值 | 日常 | 自己的 | 專案 repo |
| **CI** | build → deploy → 掛設定 → smoke | 每次 push | WIF 短期憑證 | **本 repo，只有這列** |

## 決策

| 檔案 | 處置 | 理由 |
|---|---|---|
| `ci.yml` | 併進 `deploy.yml` | 消掉 72 行複製貼上。專案端也從 2 支 stub 變 1 支 |
| `self-test.yml` | 刪 | 它唯一的作用是滿足 CI 自己加上去的分支保護。基礎設施的基礎設施 |
| `protect-ci-repo.sh` | 刪 | 分支保護是 repo 治理，不是部署 |
| `set-secret.sh` | 刪 | 寫 secret 的值是開發時的事。CI 只負責掛載 |
| `bootstrap-gcp.sh` | 刪，變成 README runbook | 是人用自己帳號跑的一次性動作，不是 CI 的程式碼 |
| `new-project.sh` | 刪，變成 README 四行指令 | 建 repo 是一次性動作 |

同時把 ci repo 自己的 main ruleset 的 required status check 拿掉（它指向已刪除的
`self-test.yml`）。`deletion` / `non_fast_forward` / `pull_request` 全部保留。

## 為什麼部署身分不給 iam.*

runbook 由人跑是刻意的交換。若部署身分有權建 SA、`add-iam-policy-binding`，它就能自己
給自己加任何權限 —— 部署流程被打穿等於整個專案管理員。

同理，**Cloud SQL instance CI 不自動建**：要 10 分鐘、會計費，`config.yml` 打錯一個字
就多開一台。改成部署時偵測不存在 → 停下來並印出該跑的指令。
Cloud Run service 則相反：`gcloud run deploy` 沒有就建、有就更新，本來就是這樣。

## 合併 ci.yml 的安全代價

WIF 信任綁在 `deploy.yml@refs/heads/main`。合併後 PR 也會觸發這支 workflow，
所以「PR 碰不到 GCP」這個保證從「檔案層級隔離」降級成兩個必須維持正確的條件：

1. `build（PR）` job **沒有** `permissions: id-token: write`
2. 每個碰 GCP 的 job 都有 `if: github.event_name != 'pull_request'`

這兩者是安全邊界的一部分。改 `deploy.yml` 時必須一起檢查 —— 已在 README 寫明。

## 結果

10 個檔案 → 4 個（`deploy.yml`、README、2 個樣板）。專案端 2 支 stub → 1 支。
