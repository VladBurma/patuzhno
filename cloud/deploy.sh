#!/bin/bash
# Розгортає сервер «патужно» на вашому безкоштовному акаунті Cloudflare (Workers + D1) і підключає Telegram-бота.
# Запускати з папки cloud/ на Mac або Linux. Потрібні: curl, python3.
# Перший запуск створює базу та сервер, наступні — лише оновлюють код (можна запускати скільки завгодно разів).
#
# Що потрібно підготувати (один раз):
#  1. Акаунт Cloudflare (dash.cloudflare.com) і API-токен: My Profile → API Tokens → Create Token → "Edit Cloudflare Workers"
#     (цей шаблон дає права на Workers і D1; Account ID видно на головній сторінці dash).
#  2. Telegram-бот: напишіть @BotFather → /newbot → отримаєте токен виду 123456:ABC… і ім'я бота (без @).
# Усе це можна вписати у файл cloud/.env (див. .env.example) або ввести під час запуску.
set -eu
cd "$(dirname "$0")"
[ -f .env ] && . ./.env
ask() { local v="${!1:-}"; if [ -z "$v" ]; then read -r -p "$2: " v; fi; printf -v "$1" '%s' "$v"; }
ask CF_ACCOUNT_ID "Cloudflare Account ID"
ask CF_API_TOKEN "Cloudflare API Token"
ask TG_TOKEN "Telegram bot token (від @BotFather)"
ask BOT_NAME "Ім'я бота без @ (напр. my_station_bot)"
NAME="${WORKER_NAME:-patuzhno}"
API="https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID"
cf() { curl -sS "$API$1" -H "Authorization: Bearer $CF_API_TOKEN" "${@:2}"; }
ok() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("result"))) if d.get("success") else (print("ПОМИЛКА:", d.get("errors"), file=sys.stderr), sys.exit(1))'; }

echo "== база D1"
DB_ID=$(cf "/d1/database?name=$NAME" | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin).get("result",[]) if x["name"]==sys.argv[1]]; print(r[0]["uuid"] if r else "")' "$NAME")
if [ -z "$DB_ID" ]; then
  DB_ID=$(cf "/d1/database" -H "Content-Type: application/json" -d "{\"name\":\"$NAME\"}" | ok | python3 -c 'import json,sys; print(json.load(sys.stdin)["uuid"])')
  echo "створено базу $DB_ID"
else echo "база є: $DB_ID"; fi

echo "== завантажую сервер"
# секрет для адреси вебхука Telegram — створюється один раз і зберігається в .env
if [ -z "${TG_SECRET:-}" ]; then TG_SECRET=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))'); echo "TG_SECRET=$TG_SECRET" >> .env; fi
META=$(mktemp)
cat > "$META" <<EOF
{"main_module":"worker.js","compatibility_date":"2024-09-01",
 "bindings":[{"type":"d1","name":"DB","id":"$DB_ID"},
             {"type":"plain_text","name":"BOT_NAME","text":"$BOT_NAME"},
             {"type":"secret_text","name":"TG_TOKEN","text":"$TG_TOKEN"},
             {"type":"secret_text","name":"TG_SECRET","text":"$TG_SECRET"}]}
EOF
cf "/workers/scripts/$NAME" -X PUT -F "metadata=@$META;type=application/json" \
   -F "worker.js=@worker.js;type=application/javascript+module" \
   -F "panel.html=@../app/panel.html;type=text/plain" \
   -F "logo.png=@../app/logo.png;type=application/octet-stream" | ok >/dev/null
rm -f "$META"

echo "== адреса й розклад"
cf "/workers/scripts/$NAME/subdomain" -X POST -H "Content-Type: application/json" -d '{"enabled":true,"previews_enabled":false}' | ok >/dev/null
SUB=$(cf "/workers/subdomain" | ok | python3 -c 'import json,sys; print(json.load(sys.stdin)["subdomain"])')
cf "/workers/scripts/$NAME/schedules" -X PUT -H "Content-Type: application/json" -d '[{"cron":"* * * * *"}]' | ok >/dev/null
URL="https://$NAME.$SUB.workers.dev"

echo "== Telegram webhook"
for i in 1 2 3 4 5 6; do curl -s -o /dev/null -m 10 "$URL/" && break; sleep 10; done   # сертифікат нової адреси видається не одразу
curl -sS "https://api.telegram.org/bot$TG_TOKEN/setWebhook" --data-urlencode "url=$URL/tg/$TG_SECRET" >/dev/null

grep -q "^CF_ACCOUNT_ID=" .env 2>/dev/null || cat >> .env <<EOF
CF_ACCOUNT_ID=$CF_ACCOUNT_ID
CF_API_TOKEN=$CF_API_TOKEN
TG_TOKEN=$TG_TOKEN
BOT_NAME=$BOT_NAME
EOF
echo "$URL" > ../server.url
echo
echo "ГОТОВО. Адресу сервера записано у server.url: $URL"
echo "Тепер запустіть build_app.command — програма збереться вже з вашим сервером."
echo "Дані для повторного запуску збережено в cloud/.env (не публікуйте цей файл)."
