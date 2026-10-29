#!/usr/bin/env bash
# Is the stack actually usable? Run this before blaming a workflow.
#
# Every line here answers a question that has already wasted somebody's
# evening: is the container up, is it up AND healthy, did Postgres take our
# schema, did n8n take its own, and is the encryption key present - because
# n8n starts perfectly well without it and then cannot read a single saved
# credential.

set -uo pipefail
cd "$(dirname "$0")/.."

ok=0
say() { printf '  %-44s %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then say "$1" "ok"; else say "$1" "FAIL  ($2)"; ok=1; fi; }

echo
echo "  charger-fault-intake"
echo

for c in intake-db n8n; do
    state=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo absent)
    check "container $c" "$state" "healthy"
done

api=$(curl -s --max-time 5 http://localhost:5678/healthz | tr -d '[:space:]')
check "n8n /healthz" "$api" '{"status":"ok"}'

ver=$(docker exec n8n n8n --version 2>/dev/null | tr -d '[:space:]')
pinned=$(grep -oE 'n8nio/n8n:[0-9.]+' docker-compose.yml | cut -d: -f2)
check "n8n version matches the pin ($pinned)" "$ver" "$pinned"

q() { docker exec intake-db psql -U "${POSTGRES_USER:-ops_owner}" -d "${POSTGRES_DB:-opsintake}" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

check "schema intake.report"         "$(q "select to_regclass('intake.report') is not null")" "t"
check "schema intake.classification" "$(q "select to_regclass('intake.classification') is not null")" "t"

n8n_tables=$(q "select count(*) > 50 from information_schema.tables where table_schema='n8n'")
check "n8n migrated into its own schema" "$n8n_tables" "t"

# Not the value. Just that it is there and long enough to be a real key.
keylen=$(docker exec n8n sh -c 'printf %s "${N8N_ENCRYPTION_KEY:-}" | wc -c' 2>/dev/null | tr -d '[:space:]')
if [ "${keylen:-0}" -ge 32 ]; then say "encryption key present ($keylen chars)" "ok"; else say "encryption key" "FAIL  (${keylen:-0} chars)"; ok=1; fi

echo
if [ "$ok" = 0 ]; then echo "  all good — http://localhost:5678"; else echo "  something is wrong above"; fi
echo
exit "$ok"
