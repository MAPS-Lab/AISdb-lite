#!/bin/bash
# Benchmark: parallel-worker scaling on ais_global_dynamic (2-week dataset).
#
# The `time` column stores Unix epoch SECONDS (see timescale_createtable_dynamic.sql
# and aisdb_lib/src/db.rs), so the window bounds below are epoch values.
# Credentials come from the standard libpq environment variables
# (PGHOST/PGUSER/PGPASSWORD); nothing is hardcoded here.
set -u

PGHOST="${PGHOST:-localhost}"
PGUSER="${PGUSER:-postgres}"
DB_NAME="${DB_NAME:-aisdb_brin_2weeks_robust}"

if [ -z "${PGPASSWORD:-}" ]; then
    echo "ERROR: set PGPASSWORD (or use ~/.pgpass) before running this benchmark" >&2
    exit 1
fi

# Query windows over October 2020, expressed as Unix epoch seconds.
# 2020-10-01 12:00:00 UTC (GNU and BSD date variants)
T0=$(date -u -d '2020-10-01 12:00:00' +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M:%S' '2020-10-01 12:00:00' +%s)
MIDNIGHT=$((T0 - 43200)) # 2020-10-01 00:00:00 UTC

run_query() {
    local workers="$1" label="$2" t_start="$3" t_end="$4"
    echo "Query $label:"
    psql -h "$PGHOST" -U "$PGUSER" -d "$DB_NAME" <<SQL 2>/dev/null | grep "Execution Time"
SET max_parallel_workers_per_gather = $workers;
SET parallel_tuple_cost = 0.01;
EXPLAIN ANALYZE
SELECT COUNT(*) FROM ais_global_dynamic
WHERE time >= $t_start AND time <= $t_end;
SQL
}

echo "=========================================="
echo "PARALLEL WORKERS BENCHMARK (2 WEEKS)"
echo "=========================================="
echo "Database: $DB_NAME"
echo "Testing parallel workers: 2, 4, 8"

for WORKERS in 2 4 8; do
    echo ""
    echo "========================================="
    echo "Testing: parallel_workers=$WORKERS"
    echo "========================================="

    run_query "$WORKERS" "1h" "$T0" "$((T0 + 3600))"
    run_query "$WORKERS" "6h" "$T0" "$((T0 + 21600))"
    run_query "$WORKERS" "24h" "$MIDNIGHT" "$((MIDNIGHT + 86400))"
    run_query "$WORKERS" "1week" "$MIDNIGHT" "$((MIDNIGHT + 604800))"
    run_query "$WORKERS" "2weeks" "$MIDNIGHT" "$((MIDNIGHT + 1209600))"
done

echo "=========================================="
echo "Benchmark complete"
echo "=========================================="
