#!/bin/bash
# PostgreSQL 函数签名兼容性测试：固定 PG15 与 PG16 的真实边界。
set -uo pipefail

PG15_CONTAINER="postgres-compatibility-15-$$"
PG16_CONTAINER="postgres-compatibility-16-$$"
PASS=0
FAIL=0

cleanup() {
    docker rm -f "$PG15_CONTAINER" "$PG16_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass_test() {
    echo "  ✅ $1"
    PASS=$((PASS + 1))
}

fail_test() {
    echo "  ❌ $1"
    FAIL=$((FAIL + 1))
}

start_postgres() {
    local image="$1" container="$2"
    local attempt=0
    docker run -d --name "$container" -e POSTGRES_HOST_AUTH_METHOD=trust "$image" >/dev/null || return 1
    while [ "$attempt" -lt 60 ]; do
        if docker exec "$container" psql -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    return 1
}

run_sql() {
    local container="$1" sql="$2"
    docker exec "$container" psql -U postgres -d postgres -tAX -v ON_ERROR_STOP=1 -c "$sql"
}

echo "启动 PostgreSQL 15.18 与 16.14..."
start_postgres postgres:15.18 "$PG15_CONTAINER" || { echo "❌ PostgreSQL 15 未就绪"; exit 1; }
start_postgres postgres:16.14 "$PG16_CONTAINER" || { echo "❌ PostgreSQL 16 未就绪"; exit 1; }

DATE_TRUNC_SQL="SELECT date_trunc('day', TIMESTAMPTZ '2024-03-10 08:30:00+00', 'America/Chicago') IS NOT NULL;"
SERIES_SQL="SELECT string_agg(to_char(point AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD HH24:MI'), ',') FROM generate_series(TIMESTAMPTZ '2024-03-10 00:00:00 America/Chicago', TIMESTAMPTZ '2024-03-12 00:00:00 America/Chicago', INTERVAL '1 day', 'America/Chicago') AS point;"

echo "函数签名断言：三参数 date_trunc 自 PG15 可用"
for version in 15 16; do
    container_var="PG${version}_CONTAINER"
    container="${!container_var}"
    if [ "$(run_sql "$container" "$DATE_TRUNC_SQL")" = "t" ]; then
        pass_test "PostgreSQL ${version} 支持 date_trunc(text, timestamptz, text)"
    else
        fail_test "PostgreSQL ${version} 支持 date_trunc(text, timestamptz, text)"
    fi
done

echo "函数签名断言：四参数 generate_series 自 PG16 可用"
if run_sql "$PG15_CONTAINER" "$SERIES_SQL" >/dev/null 2>&1; then
    fail_test "PostgreSQL 15 必须拒绝四参数 generate_series"
else
    pass_test "PostgreSQL 15 拒绝四参数 generate_series"
fi
if [ "$(run_sql "$PG16_CONTAINER" "$SERIES_SQL")" = "2024-03-10 00:00,2024-03-11 00:00,2024-03-12 00:00" ]; then
    pass_test "PostgreSQL 16 支持四参数 generate_series 并保留 DST 本地零点"
else
    fail_test "PostgreSQL 16 支持四参数 generate_series 并保留 DST 本地零点"
fi

echo "PostgreSQL 兼容性测试：通过 ${PASS} 项，失败 ${FAIL} 项"
[ "$FAIL" -eq 0 ]
