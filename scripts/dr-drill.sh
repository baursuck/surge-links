#!/usr/bin/env bash
# Disaster-recovery drill against the local compose stack:
# backup -> simulate losing the database -> restore -> verify -> report RTO.
# The same steps, with RDS snapshots / point-in-time restore, are in docs/runbook.md.
set -euo pipefail

PG="docker compose exec -T postgres"
DB=surge
USER=surge
BACKUP=/tmp/surge-dr-$(date +%Y%m%d-%H%M%S).dump

count() { $PG psql -U "$USER" -d "$DB" -tAc "SELECT count(*) || ':' || coalesce(sum(clicks),0) FROM links"; }

echo "1/5 baseline"
BEFORE=$(count)
echo "    links:clicks = $BEFORE"

echo "2/5 backup (pg_dump, custom format)"
$PG pg_dump -U "$USER" -d "$DB" -Fc -f "$BACKUP"

echo "3/5 disaster: drop the database"
docker compose stop app >/dev/null
START=$(date +%s)
$PG psql -U "$USER" -d postgres -c "DROP DATABASE $DB WITH (FORCE)" >/dev/null

echo "4/5 restore"
$PG psql -U "$USER" -d postgres -c "CREATE DATABASE $DB" >/dev/null
$PG pg_restore -U "$USER" -d "$DB" "$BACKUP"
docker compose start app >/dev/null
until curl -sf localhost:8000/readyz >/dev/null; do sleep 0.5; done
END=$(date +%s)

echo "5/5 verify"
AFTER=$(count)
echo "    links:clicks = $AFTER"
if [[ "$BEFORE" != "$AFTER" ]]; then
  echo "FAIL: data differs after restore" >&2
  exit 1
fi
echo "OK: data identical, RTO = $((END - START)) s (drop -> app ready). RPO = time since backup."
