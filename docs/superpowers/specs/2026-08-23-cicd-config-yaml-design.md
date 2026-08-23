# `.cicd/config.yml`：結構性設定收斂成一份

日期：2026-08-23

## 問題

一個專案的設定散在 5 個地方：兩支 caller stub 的 `with:`（同樣的參數抄兩遍）、
`.cicd/env.{dev,prod}`、`.cicd/secrets.{dev,prod}`。沒有共用層，所以**兩個環境一樣的值
一定要抄兩遍**——而抄兩遍的東西遲早會分歧。這比打錯字常見得多。

Cloud SQL 的 `DB_INSTANCE` 是最明顯的例子：前一版要求「dev 與 prod 各寫一行、內容逐字相同」，
靠的是約定加警告，而不是結構。

## 決策

| 決策 | 選擇 | 理由 |
|---|---|---|
| 結構性設定放哪 | `.cicd/config.yml`（YAML，選填） | 一次性、不該分歧的東西宣告一次 |
| 日常環境變數放哪 | 維持 `.cicd/env.<env>`（KEY=VALUE） | 平鋪格式對非工程師比 YAML 不容易出錯 |
| 共用層 | 新增 `.cicd/{env,secrets}.common` | 解決「抄兩遍」，同名 key 由環境專屬覆蓋 |
| DB 宣告 | 搬進 `config.yml` 的 `db:` | 只寫一次，分歧變成不可能表達 |
| 解析器 | `yq`（runner 預裝 4.53.3） | 不用 pip install，不增加 job 時間 |
| 相容性 | 沒有 `config.yml` 就退回 stub 的 `with:` | 既有專案不用改任何東西 |

### 為什麼不整份都搬成 YAML

「pipeline 定義用 YAML」是業界標準，這個 repo 本來就是。但**每環境的應用設定**業界是分歧的：
Helm `values.yaml` 是 YAML，`.env` / 12-factor / Docker / Vercel 全是 `KEY=VALUE`。
真正的缺陷不是格式，是**沒有共用層**——那個缺陷換成 YAML 寫壞一樣會有。

所以切一刀：結構性的進 YAML，常改的維持平鋪。

## 契約

```yaml
# .cicd/config.yml —— 全部選填
service: my-app
region: asia-east1
health_path: /healthz
dockerfile: Dockerfile
allow_unauthenticated: true
db:
  instance: my-app-pg
  name: my_app
```

`verify` 解析後由 job outputs 傳給下游，取代原本各 job 直接讀 `inputs.*`。
不認得的 key 會被擋下並列出可用名字——設定檔最常見的失敗是「明明寫了卻沒生效」。

環境變數的合併順序：`env.common` → `env.<env>`（同名後者覆蓋），`secrets` 同理。

## 實作中抓到的兩個坑

- **`yq` 的 `//` 運算子把 `false` 當空值**。`.allow_unauthenticated // ""` 在值為 `false` 時
  回傳空字串，於是退回預設的 `true`——**服務會被靜靜開成公開**。改成不用 `//`，
  直接取值後判斷字串 `"null"`。本機用同版本 yq binary 實測才發現。
- **yq 失敗不能吞**。原本寫 `2>/dev/null || true`，config.yml 有問題時會靜靜退回預設值。
  改成讓它失敗，`set -e` 會停下來。

## 限制

- DB 與 Cloud Run 必須同區域（推導 `<專案>:<區域>:<instance>`）。
- 兩個環境的 instance 名字不能不同。刻意的：分歧的餘地就是出錯的餘地。
- 刪掉 `db:` 不會自動解除掛載，要手動 `--remove-cloudsql-instances`。

## 驗證計畫

`gh run rerun` 會沿用舊版 reusable workflow，一律推新 commit / 新 tag。

1. 沒有 `config.yml` 的專案行為不變（預設值那條路）
2. `config.yml` 的值蓋過 stub 的 `with:`
3. 打錯 key / `db` 缺 `name` / 不是 mapping → `verify` 擋下
4. `env.common` 被 `env.<env>` 覆蓋，兩者都進得了容器
5. hello-cicd 端對端：dev 與 prod 各自連上自己專案的 Cloud SQL
