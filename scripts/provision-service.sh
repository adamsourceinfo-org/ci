#!/usr/bin/env bash
# 幫一個服務備妥「用 Cloud SQL 所需的一切」，兩個環境一次做完。
#
# 為什麼是腳本而不是 README 的步驟清單：這六步裡有三步的失敗模式沒辦法用
# 散文防範 —— 背景 proxy 的就緒等待、隱含的 API 相依、專案 IAM policy 的
# read-modify-write 併發。三個都實測踩過，而且其中兩個的症狀會指向錯的方向。
#
# **這支腳本 CI 永遠不會執行。** 它由 owner 用自己的 gcloud 跑，因為它做的
# 正是部署身分刻意沒有權限做的事（建 SA、發角色）。責任分界沒有改變 ——
# 只是把「怎麼做」從散文換成可執行、可驗收的形式。
#
# 冪等：每一步先查再做，可以安全重跑。結尾驗收六項，任一不過就非零結束。
#
# 用法：
#   ci/scripts/provision-service.sh <service> <runtime_sa> <db_name> [dev|prod|both]
#
# 例：
#   cd payment-foo && ../ci/scripts/provision-service.sh payment-foo run-payment-foo payment_foo
#
# 在專案 repo 裡跑的話，它會讀 .cicd/secrets.<env> 自動把機密授權給新的 SA。
set -uo pipefail

SERVICE="${1:-}"
SA="${2:-}"
DB="${3:-}"
WHICH="${4:-both}"

if [ -z "$SERVICE" ] || [ -z "$SA" ] || [ -z "$DB" ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

REGION=asia-east1
INSTANCE=apps-pg

HUMAN="$(gcloud config get-value account 2>/dev/null)"
[ -n "$HUMAN" ] || { echo "gcloud 沒有登入帳號。先跑 gcloud auth login。" >&2; exit 1; }

for BIN in gcloud cloud-sql-proxy psql python3 nc; do
  command -v "$BIN" >/dev/null || { echo "缺少 $BIN。" >&2; exit 1; }
done

# SA ID 的規則比 Cloud Run 服務名嚴格（6-30 字元），先擋掉才不會做到一半失敗。
printf '%s' "$SA" | grep -Eq '^[a-z][-a-z0-9]{4,28}[a-z0-9]$' || {
  echo "runtime_sa '$SA' 不合法：6-30 字元、小寫字母開頭、只能有小寫字母/數字/連字號。" >&2
  exit 1; }

# CI 的 verify 只接受 run-<服務名>（服務名綁定 repo，見 README「權限模型」）。
# 在這裡先擋，不然會備妥一個 CI 永遠不肯用的身分。
[ "$SA" = "run-${SERVICE}" ] || {
  echo "runtime_sa 必須是 run-${SERVICE}（收到 '$SA'）—— CI 只接受這個名字。" >&2
  exit 1; }

case "$WHICH" in
  dev|prod) ENVS="$WHICH" ;;
  both)     ENVS="dev prod" ;;
  *) echo "第四個參數只能是 dev / prod / both。" >&2; exit 1 ;;
esac

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
skip() { printf '  ⏭  %s（已就緒）\n' "$*"; }
info() { printf '  ℹ  %s\n' "$*"; }

provision_env() {
  local E="$1"
  local P="adamsourceinfo-${E}"
  local SA_EMAIL="${SA}@${P}.iam.gserviceaccount.com"
  local DB_USER="${SA}@${P}.iam"

  step "${P}"

  # 0. API 相依。iam.googleapis.com 沒開的話，CI 的 SA 檢查會說「找不到」而不是
  #    「查不到」—— 專案 owner 自己呼叫得動，所以這個坑只在 CI 裡炸（實測踩過）。
  local ENABLED
  ENABLED="$(gcloud services list --enabled --project="$P" --format='value(config.name)' 2>/dev/null)"
  local API
  for API in iam.googleapis.com sqladmin.googleapis.com secretmanager.googleapis.com; do
    if printf '%s\n' "$ENABLED" | grep -qx "$API"; then
      skip "API ${API}"
    else
      gcloud services enable "$API" --project="$P" --quiet >/dev/null 2>&1 \
        && ok "啟用 API ${API}" || { echo "  ❌ 無法啟用 ${API}" >&2; return 1; }
    fi
  done

  # 1. 執行身分
  if gcloud iam service-accounts describe "$SA_EMAIL" --project="$P" >/dev/null 2>&1; then
    skip "SA ${SA}"
  else
    gcloud iam service-accounts create "$SA" --project="$P" \
      --display-name="runtime for ${SERVICE}" --quiet >/dev/null 2>&1 \
      && ok "建立 SA ${SA}" || { echo "  ❌ 建 SA 失敗" >&2; return 1; }
    # 新建的 SA 不會立刻出現在 IAM policy API，下一步會拿到 "does not exist"。
    sleep 5
  fi

  # 2. 連線路徑。**循序**做，不要放進背景 —— add-iam-policy-binding 是對專案
  #    policy 做 read-modify-write，併發會撞 etag 而其中一筆靜靜地沒生效。
  #    實測八個 SA 掉了一個，症狀是部署成功、身分正確，然後 DB 回
  #    InterfaceError: communication error —— 完全指不到真正的病因。
  local R
  for R in roles/cloudsql.client roles/cloudsql.instanceUser; do
    if gcloud projects get-iam-policy "$P" --flatten='bindings[].members' \
         --filter="bindings.members:${SA_EMAIL} AND bindings.role:${R}" \
         --format='value(bindings.role)' 2>/dev/null | grep -q .; then
      skip "$R"
    else
      gcloud projects add-iam-policy-binding "$P" --member="serviceAccount:${SA_EMAIL}" \
        --role="$R" --condition=None --quiet >/dev/null 2>&1 \
        && ok "授 $R" || { echo "  ❌ 授 $R 失敗" >&2; return 1; }
    fi
  done

  # 3. 讓部署身分能「使用」這個執行身分。deployer 沒有 iam.*，所以要你來綁。
  if gcloud iam service-accounts get-iam-policy "$SA_EMAIL" --project="$P" \
       --format='value(bindings.members)' 2>/dev/null | grep -q "github-deployer@${P}"; then
    skip "deployer 的 serviceAccountUser"
  else
    gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" --project="$P" \
      --member="serviceAccount:github-deployer@${P}.iam.gserviceaccount.com" \
      --role=roles/iam.serviceAccountUser --quiet >/dev/null 2>&1 \
      && ok "綁 deployer serviceAccountUser" || { echo "  ❌ 綁定失敗" >&2; return 1; }
  fi

  # 4. 機密。換 SA 之後最容易漏的一步 —— 漏了的話新 revision 讀不到機密、直接
  #    起不來，而且是在切換當下才炸。在專案 repo 裡跑就自動處理。
  local SECFILE=".cicd/secrets.${E}"
  local FOUND=0 line NAME
  for SECFILE in ".cicd/secrets.common" ".cicd/secrets.${E}"; do
    [ -f "$SECFILE" ] || continue
    FOUND=1
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      NAME="${line#*=}"; NAME="${NAME%%:*}"
      [ -n "$NAME" ] || continue
      if gcloud secrets get-iam-policy "$NAME" --project="$P" \
           --format='value(bindings.members)' 2>/dev/null | grep -q "$SA_EMAIL"; then
        skip "secret ${NAME}"
      else
        gcloud secrets add-iam-policy-binding "$NAME" --project="$P" \
          --member="serviceAccount:${SA_EMAIL}" \
          --role=roles/secretmanager.secretAccessor --quiet >/dev/null 2>&1 \
          && ok "授權 secret ${NAME}" || echo "  ⚠️  secret ${NAME} 授權失敗（它存在嗎？）" >&2
      fi
    done < <(grep -vE '^[[:space:]]*(#|$)' "$SECFILE")
  done
  [ "$FOUND" -eq 1 ] || info "找不到 .cicd/secrets.*（不在專案 repo 裡跑？）—— 有機密的話要自己授權給 ${SA_EMAIL}"

  # 5. database 與 IAM DB user。IAM 使用者要用去掉 .gserviceaccount.com 的短格式，
  #    否則 API 回 400。這個短格式正好就是 CI 注入的 DB_USER，兩邊必須逐字相同。
  if gcloud sql databases describe "$DB" --instance="$INSTANCE" --project="$P" >/dev/null 2>&1; then
    skip "database ${DB}"
  else
    gcloud sql databases create "$DB" --instance="$INSTANCE" --project="$P" --quiet >/dev/null 2>&1 \
      && ok "建立 database ${DB}" || { echo "  ❌ 建 database 失敗（apps-pg 存在嗎？）" >&2; return 1; }
  fi
  if gcloud sql users list --instance="$INSTANCE" --project="$P" \
       --format='value(name)' 2>/dev/null | grep -qx "$DB_USER"; then
    skip "DB user ${DB_USER}"
  else
    gcloud sql users create "$DB_USER" --instance="$INSTANCE" --project="$P" \
      --type=cloud_iam_service_account --quiet >/dev/null 2>&1 \
      && ok "建立 DB user ${DB_USER}" || { echo "  ❌ 建 DB user 失敗" >&2; return 1; }
  fi

  # 6. REVOKE / GRANT。這步不能省 —— Postgres 預設讓 PUBLIC 連任何 database，
  #    共用 instance 下少了 REVOKE，每服務一個 SA 只是換了名字，隔離是假的。
  local PW PORT PID i
  PW="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
  PORT=$(( 5500 + RANDOM % 400 ))
  # 內建 postgres 帳號預設沒密碼。這是一次性的拋棄式密碼，不用記 ——
  # IAM 認證的 app 不需要它，下次跑這支腳本又會換一個。
  gcloud sql users set-password postgres --instance="$INSTANCE" --project="$P" \
    --password="$PW" --quiet >/dev/null 2>&1 || { echo "  ❌ 設定 postgres 密碼失敗" >&2; return 1; }

  cloud-sql-proxy "${P}:${REGION}:${INSTANCE}" --port "$PORT" \
    --token "$(gcloud auth print-access-token)" >"/tmp/provision-proxy-${PORT}.log" 2>&1 &
  PID=$!
  # proxy 要一兩秒才開始監聽。少了這個等待就是 Connection refused（實測踩過，
  # 而且是照 README 逐字跑出來的）。
  i=0
  until nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
    i=$((i+1))
    if [ "$i" -gt 30 ]; then
      echo "  ❌ proxy 起不來，看 /tmp/provision-proxy-${PORT}.log" >&2
      kill "$PID" 2>/dev/null; return 1
    fi
    sleep 1
  done

  if PGPASSWORD="$PW" psql -h 127.0.0.1 -p "$PORT" -U postgres -d "$DB" \
       -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<SQL
REVOKE CONNECT ON DATABASE ${DB} FROM PUBLIC;
GRANT ALL PRIVILEGES ON DATABASE ${DB} TO "${DB_USER}";
GRANT ALL ON SCHEMA public TO "${DB_USER}";
GRANT CONNECT ON DATABASE ${DB} TO "${HUMAN}";
GRANT "${DB_USER}" TO "${HUMAN}";
SQL
  then ok "REVOKE / GRANT"
  else echo "  ❌ REVOKE/GRANT 失敗（${HUMAN} 是這台的 IAM user 嗎？）" >&2; kill "$PID" 2>/dev/null; return 1
  fi

  # ── 驗收 ────────────────────────────────────────────────────────────────
  # 六項全部查一遍。前三項是 CI 因為權限邊界查不到的，所以只能在這裡驗。
  local FAIL=0
  printf '\n  驗收：\n'
  chk() { if eval "$2" >/dev/null 2>&1; then printf '    ✅ %s\n' "$1"; else printf '    ❌ %s\n' "$1"; FAIL=1; fi; }

  chk "SA 存在" \
      "gcloud iam service-accounts describe '${SA_EMAIL}' --project='${P}'"
  chk "cloudsql.client + cloudsql.instanceUser" \
      "[ \$(gcloud projects get-iam-policy '${P}' --flatten='bindings[].members' --filter=\"bindings.members:${SA_EMAIL} AND bindings.role:roles/cloudsql\" --format='value(bindings.role)' | wc -l) -eq 2 ]"
  chk "deployer 的 serviceAccountUser" \
      "gcloud iam service-accounts get-iam-policy '${SA_EMAIL}' --project='${P}' --format='value(bindings.members)' | grep -q 'github-deployer@${P}'"
  chk "database ${DB}" \
      "gcloud sql databases describe '${DB}' --instance='${INSTANCE}' --project='${P}'"
  chk "DB user ${DB_USER}" \
      "gcloud sql users list --instance='${INSTANCE}' --project='${P}' --format='value(name)' | grep -qx '${DB_USER}'"
  # datacl 裡 PUBLIC 那筆開頭是 '='，它不能含 c（CONNECT）。
  chk "PUBLIC 沒有 CONNECT（隔離成立）" \
      "! PGPASSWORD='${PW}' psql -h 127.0.0.1 -p ${PORT} -U postgres -d postgres -At -c \"SELECT array_to_string(datacl,' ') FROM pg_database WHERE datname='${DB}'\" | tr ' ' '\n' | grep -qE '^=[a-zA-Z]*c'"

  kill "$PID" 2>/dev/null
  if [ "$FAIL" -ne 0 ]; then printf '\n  ❌ %s 驗收未通過\n' "$P" >&2; return 1; fi
  printf '  ✅ %s 六項全過\n' "$P"
}

RC=0
for E in $ENVS; do provision_env "$E" || RC=1; done
printf '\n'
if [ "$RC" -eq 0 ]; then
  echo "完成。接著推一次 main（或 gh workflow run deploy.yml）觸發部署。"
else
  echo "有環境未通過，見上面的 ❌。修好後可以直接重跑這支腳本。" >&2
fi
exit "$RC"
