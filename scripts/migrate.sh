#!/usr/bin/env bash
# Applies db/migrations/*.sql in filename order, skipping the ones already
# recorded in intake.schema_migration. Safe to run repeatedly.
#
# Each file is its own transaction (the begin/commit lives in the SQL), so a
# failure half way leaves the schema exactly as it was. ON_ERROR_STOP is what
# makes psql honour that - without it psql reports the error, keeps going, and
# commits the rest.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; . ./.env; set +a

psql_q() {
    docker compose exec -T db psql -v ON_ERROR_STOP=1 -tAq \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"
}

for file in db/migrations/*.sql; do
    name=$(basename "$file")

    # Missing table on the first run is expected, not an error.
    done_already=$(psql_q -c \
        "select 1 from intake.schema_migration where filename = '$name'" 2>/dev/null || true)

    if [ -n "$done_already" ]; then
        printf '  skip   %s\n' "$name"
        continue
    fi

    printf '  apply  %s ... ' "$name"
    psql_q < "$file" > /dev/null
    printf 'ok\n'
done

echo
echo "  applied so far:"
psql_q -c "select '    ' || filename || '  ' || to_char(applied_at, 'YYYY-MM-DD HH24:MI')
           from intake.schema_migration order by filename" 2>/dev/null || echo "    (none)"
