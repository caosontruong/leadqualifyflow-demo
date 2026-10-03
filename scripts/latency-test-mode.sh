#!/usr/bin/env bash
# Toggles the "latency test mode": turns off the 6 notification channels other than Slack (avoids spam and quota use
# when sending many test leads).
# Usage:  scripts/latency-test-mode.sh on            # turn off Discord/Telegram/ntfy/Email/Notion/WhatsApp
#         scripts/latency-test-mode.sh off           # reset the 6 channels to the default (empty = enabled)
#         scripts/latency-test-mode.sh backends-on   # enable writes to Postgres/Google Sheets/Baserow/Supabase (empty = enabled)
#         scripts/latency-test-mode.sh backends-off  # disable those 4 backends (=false), leaving only Airtable
# Only edits the ENABLE_* lines in .env, then recreates the n8n container. Never prints the contents of .env.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-}"
case "$mode" in
  on)           val="false"; keys="ENABLE_DISCORD_NOTIFY ENABLE_TELEGRAM_NOTIFY ENABLE_NTFY_NOTIFY ENABLE_EMAIL_NOTIFY ENABLE_NOTION_NOTIFY ENABLE_WHATSAPP_NOTIFY" ;;
  off)          val="";      keys="ENABLE_DISCORD_NOTIFY ENABLE_TELEGRAM_NOTIFY ENABLE_NTFY_NOTIFY ENABLE_EMAIL_NOTIFY ENABLE_NOTION_NOTIFY ENABLE_WHATSAPP_NOTIFY" ;;
  backends-on)  val="";      keys="ENABLE_POSTGRES_WRITE ENABLE_GOOGLE_SHEETS_WRITE ENABLE_BASEROW_WRITE ENABLE_SUPABASE_WRITE" ;;
  backends-off) val="false"; keys="ENABLE_POSTGRES_WRITE ENABLE_GOOGLE_SHEETS_WRITE ENABLE_BASEROW_WRITE ENABLE_SUPABASE_WRITE" ;;
  *) echo "Usage: $0 on|off|backends-on|backends-off"; exit 2 ;;
esac
[ -f .env ] || { echo "No .env file"; exit 1; }
for key in $keys; do
  if grep -q "^${key}=" .env; then sed -i "s/^${key}=.*/${key}=${val}/" .env; else printf '%s=%s\n' "$key" "$val" >> .env; fi
  echo "  $key=${val:-<empty>}"
done
echo "(other variables unchanged)"
echo "==> Recreating the n8n container to pick up the new environment"
set -a; . ./.env; set +a
docker compose up -d --force-recreate n8n >/dev/null
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:${N8N_HOST_PORT:-5679}/healthz || true)
  [ "$code" = "200" ] && { echo "OK — n8n healthz 200"; exit 0; }
  sleep 2
done
echo "n8n is not healthy after 60s; check: docker compose logs n8n"; exit 1
