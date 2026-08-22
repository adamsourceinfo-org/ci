# adamsourceinfo-org 共用 CI/CD 設計

日期：2026-08-23

## 問題

`adamsourceinfo-org` 底下未來會有多個專案，都要部署到 Cloud Run，需要一套共用流程：main 異動部署 dev，打 tag 發 prod，且 main 必須被保護。

## 決策

| 決策 | 選擇 | 理由 |
|---|---|---|
| 流程放哪 | 中央 `ci` repo 放 reusable workflow，專案放薄 stub | 改一次全org生效；沿用既有 house pattern（`cm-ailab-units-prod/ci`） |
| 認證 | Workload Identity Federation，信任綁 `job_workflow_ref` | 無長期金鑰；專案改自己的 workflow 換不到憑證 |
| repo 可見性 | public | org 是 Free 方案，分支保護只對 public repo 有效 |
| 分支保護 | 每個 repo 一份 ruleset，由 `new-project.sh` 建立 | org-level ruleset 需 Team 方案 |
| build 契約 | 一律要求 Dockerfile | 契約明確、行為可預測、CI 邏輯最簡單 |
| prod 策略 | promote by digest，tag 不重新 build | prod 跑的就是 dev 驗過的那份，逐位元組相同 |
| 測試 | CI 不跑 | 使用者決定：測試在開發時自行驗過才推 |
| 機密 | Secret Manager 為單一來源，CI 只掛載不寫入 | CI 要能寫入的話，秘密就得先進 GitHub secrets，多一個外洩面 |
| 跨專案搬 image | `docker buildx imagetools create` | `gcloud artifacts docker images copy` 不存在；兩個 AR 同一 registry host，走 blob mount |

## 節點

PR：`verify` → `build`（不推）
main：`verify` → `build-push` → `deploy-dev` → `smoke-dev`
tag：`verify` → `resolve` → `promote` → `deploy-prod` → `smoke-prod`

`resolve` 由 tag 的 commit 反查 dev AR 的 digest。查不到代表這個 commit 沒走過 main —— 擋下，不用重建蒙混。

## 安全邊界

信任條件 `attribute.job_workflow_ref == adamsourceinfo-org/ci/.github/workflows/deploy.yml@refs/heads/main`，加上 provider 層的 `assertion.repository_owner == 'adamsourceinfo-org'`。dev / prod 各自獨立 pool、provider、SA。Cloud Run 用專屬 `run-runtime` SA（無預設權限），不用 default compute SA。

## 已知限制

- Free 方案下 private repo 無法保護分支；要 private + 保護需升級 Team 並改用 org-level ruleset。
- `new-project.sh` 預設連 admin 都不能直推 main。單人開發若嫌卡，用 `--allow-admin-bypass`。
- prod 的 promote 依賴 dev 專案的 Artifact Registry 可讀。dev 專案若被刪除，prod 無法發新版（已跑的 revision 不受影響）。
