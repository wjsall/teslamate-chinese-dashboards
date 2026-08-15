#!/usr/bin/env bash
# 上游 ALTER COLUMN 兼容性门：在最小 TeslaMate schema 上安装本项目全部 SQL，
# 再把三张上游表的每一列改成它当前的类型。这个操作对数据语义是 no-op，但 PostgreSQL
# 仍会执行依赖检查，因此能抓出 UPDATE OF 列清单、视图等对上游列建立的硬依赖。
#
# 用法：bash scripts/check-upstream-alter-compat.sh
# 依赖：docker
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PG_IMAGE="postgres:18-trixie"
CONTAINER="upstream-alter-compat-$$"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/upstream-alter-compat.XXXXXX") || exit 1

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -r -- "$TMP_ROOT"
}
trap cleanup EXIT

echo "起隔离 postgres..."
docker run -d --name "$CONTAINER" \
    -e POSTGRES_USER=teslamate -e POSTGRES_PASSWORD=test -e POSTGRES_DB=teslamate \
    "$PG_IMAGE" >/dev/null || {
        echo "❌ 无法启动隔离 postgres"
        exit 1
    }

ready=0
for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" psql -U teslamate -d teslamate -c 'SELECT 1' \
            >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "❌ 隔离 postgres 60 秒内未就绪"
    exit 1
fi

echo "建最小 TeslaMate schema..."
if ! docker exec -i "$CONTAINER" psql -U teslamate -d teslamate \
        -q -v ON_ERROR_STOP=1 >"$TMP_ROOT/schema.out" 2>"$TMP_ROOT/schema.err" <<'SQL'; then
CREATE TABLE geofences (
  id SERIAL PRIMARY KEY,
  name TEXT
);
CREATE TABLE charging_processes (
  id SERIAL PRIMARY KEY,
  cost NUMERIC,
  start_date TIMESTAMP,
  end_date TIMESTAMP,
  charge_energy_added NUMERIC,
  charge_energy_used NUMERIC,
  car_id INT,
  geofence_id INT REFERENCES geofences(id),
  position_id INT,
  address_id INT
);
CREATE TABLE charges (
  id SERIAL PRIMARY KEY,
  charging_process_id INT REFERENCES charging_processes(id),
  date TIMESTAMP,
  charger_power NUMERIC,
  charger_phases INT,
  charge_energy_added NUMERIC NOT NULL,
  battery_level INT
);
CREATE TABLE positions (
  id SERIAL PRIMARY KEY,
  car_id INT,
  date TIMESTAMP
);
SQL
    echo "❌ 最小 TeslaMate schema 创建失败"
    sed 's/^/   /' "$TMP_ROOT/schema.err"
    exit 1
fi

echo "安装本项目全部 SQL..."
for sql_file in sql/install-*.sql; do
    name=${sql_file##*/}
    if docker exec -i "$CONTAINER" psql -U teslamate -d teslamate \
            -v ON_ERROR_STOP=1 <"$sql_file" \
            >"$TMP_ROOT/${name}.out" 2>"$TMP_ROOT/${name}.err"; then
        echo "  ✓ $name"
    else
        echo "  ❌ $name 安装失败"
        sed 's/^/     /' "$TMP_ROOT/${name}.err"
        exit 1
    fi
done

columns_file="$TMP_ROOT/columns.tsv"
if ! docker exec "$CONTAINER" psql -U teslamate -d teslamate -AtF $'\t' \
        -v ON_ERROR_STOP=1 -c "
SELECT c.relname,
       a.attname,
       format_type(a.atttypid, a.atttypmod)
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('charging_processes', 'charges', 'geofences')
  AND a.attnum > 0
  AND NOT a.attisdropped
ORDER BY c.relname, a.attnum;
" >"$columns_file" 2>"$TMP_ROOT/columns.err"; then
    echo "❌ 无法枚举上游表列"
    sed 's/^/   /' "$TMP_ROOT/columns.err"
    exit 1
fi

echo "逐列执行同类型 ALTER（触发 PostgreSQL 依赖检查）..."
checked=0
failed=0
while IFS=$'\t' read -r table_name column_name column_type; do
    [ -n "$table_name" ] || continue
    checked=$((checked + 1))
    alter_sql="ALTER TABLE \"${table_name}\" ALTER COLUMN \"${column_name}\" TYPE ${column_type};"
    if docker exec "$CONTAINER" psql -U teslamate -d teslamate \
            -v ON_ERROR_STOP=1 -c "$alter_sql" \
            >"$TMP_ROOT/alter.out" 2>"$TMP_ROOT/alter.err"; then
        echo "  ✓ ${table_name}.${column_name} (${column_type})"
    else
        failed=$((failed + 1))
        echo "  ❌ ${table_name}.${column_name} (${column_type}) 被本项目 SQL 对象阻挡"
        sed 's/^/     /' "$TMP_ROOT/alter.err"
    fi
done <"$columns_file"

echo
if [ "$failed" -eq 0 ]; then
    echo "✅ 上游 ALTER COLUMN 兼容性通过（${checked} 列）"
    exit 0
fi

echo "❌ 上游 ALTER COLUMN 兼容性失败：${failed} / ${checked} 列被阻挡"
echo "   上面的 PostgreSQL DETAIL 会指出依赖列的触发器、视图或规则。"
exit 1
