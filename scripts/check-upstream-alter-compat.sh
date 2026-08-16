#!/usr/bin/env bash
# 上游 ALTER COLUMN 兼容性门：在最小 TeslaMate schema 上安装本项目全部 SQL，
# 再把三张上游表的每一列改成它当前的类型。这个操作对数据语义是 no-op，但 PostgreSQL
# 仍会执行依赖检查，因此能抓出 UPDATE OF 列清单、视图等对上游列建立的硬依赖。
#
# 跑两条路径，缺一不可：
#   ① 全新安装        —— 只装当前版本
#   ② 从上一个发行版升级 —— 先装上一个 tag 的全部 SQL，再装当前版本
# 只有 ① 的时候，这道门对「老版本建过、新版本不再创建、于是也没人删」的对象是全盲的。
# v1.9.6 就是这么放跑一个 P0 的：它把 charging_processes_v 从安装脚本里删掉了，全新
# 安装因此通过，而所有从旧版升上来的库里那个视图原样留着，TeslaMate 4.1.1 启动时的
# ALTER TABLE charging_processes ALTER COLUMN cost TYPE numeric(14,2) 照样被拒绝。
#
# 用法：bash scripts/check-upstream-alter-compat.sh
# 依赖：docker、git（要读上一个 tag 的 SQL，浅克隆需 fetch-depth: 0）
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PG_IMAGE="postgres:18-trixie"
CONTAINER="upstream-alter-compat-$$"
# 升级路径（路径②）的起点。
#
# 【语义：最后一个会创建 charging_processes_v 的版本】不是「上一个发行版」。
# 这个值**不该随发版往前移**：改成 v1.9.6 或更新之后，路径②装的那一版根本不会创建
# charging_processes_v，路径②就退化成路径①的复制品——两条路径都绿，而「老版本建过、
# 新版本不再清」这一整类问题重新变成盲区（v1.9.6 放跑 P0 的正是这个形状）。
# 只有当我们又引入一个新的「旧版创建、新版不再创建」的对象时，才需要重新考虑取哪个 tag。
LEGACY_TAG="v1.9.5"
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

# 把上一个发行版的 sql/install-*.sql 全部取到临时目录。
# 取不到就直接报红：悄悄跳过等于把升级路径这一整条腿变成走过场。
LEGACY_DIR="$TMP_ROOT/legacy-sql"
mkdir -p "$LEGACY_DIR"
LEGACY_FILES=()
echo "取 ${LEGACY_TAG} 的安装 SQL..."
legacy_list=$(git ls-tree --name-only "$LEGACY_TAG" sql/ 2>"$TMP_ROOT/git.err" \
    | grep -E '^sql/install-.*\.sql$')
if [ -z "$legacy_list" ]; then
    echo "❌ 取不到 ${LEGACY_TAG} 的 sql/install-*.sql，升级路径无法检查"
    sed 's/^/   /' "$TMP_ROOT/git.err"
    echo "   浅克隆（fetch-depth: 1）不带 tag，CI 的 checkout 需要 fetch-depth: 0。"
    exit 1
fi
while IFS= read -r path; do
    [ -n "$path" ] || continue
    name=${path##*/}
    if ! git show "${LEGACY_TAG}:${path}" >"$LEGACY_DIR/$name" 2>"$TMP_ROOT/git.err"; then
        echo "❌ 取不到 ${LEGACY_TAG}:${path}"
        sed 's/^/   /' "$TMP_ROOT/git.err"
        exit 1
    fi
    LEGACY_FILES+=("$LEGACY_DIR/$name")
    echo "  ✓ ${LEGACY_TAG}:${path}"
done <<<"$legacy_list"

# 最小 TeslaMate 表结构（与 scripts/test-tou-behavior.sh 同一份形状）
create_min_schema() {
    local db="$1"
    docker exec -i "$CONTAINER" psql -U teslamate -d "$db" \
            -q -v ON_ERROR_STOP=1 >"$TMP_ROOT/schema.out" 2>"$TMP_ROOT/schema.err" <<'SQL'
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
}

# 把一组 SQL 文件依次装进指定库
install_sql_files() {
    local db="$1" label="$2"
    shift 2
    local sql_file name
    for sql_file in "$@"; do
        name=${sql_file##*/}
        if docker exec -i "$CONTAINER" psql -U teslamate -d "$db" \
                -v ON_ERROR_STOP=1 <"$sql_file" \
                >"$TMP_ROOT/${db}-${name}.out" 2>"$TMP_ROOT/${db}-${name}.err"; then
            echo "  ✓ ${label} ${name}"
        else
            echo "  ❌ ${label} ${name} 安装失败"
            sed 's/^/     /' "$TMP_ROOT/${db}-${name}.err"
            return 1
        fi
    done
    return 0
}

TOTAL_CHECKED=0
TOTAL_FAILED=0

# 对一个库的上游三张表逐列执行「改成它自己当前的类型」，触发 PostgreSQL 依赖检查
run_alter_probe() {
    local db="$1" label="$2"
    local columns_file="$TMP_ROOT/${db}-columns.tsv"
    if ! docker exec "$CONTAINER" psql -U teslamate -d "$db" -AtF $'\t' \
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
" >"$columns_file" 2>"$TMP_ROOT/${db}-columns.err"; then
        echo "❌ 无法枚举上游表列（${label}）"
        sed 's/^/   /' "$TMP_ROOT/${db}-columns.err"
        exit 1
    fi

    # 一列都没枚举到 = 探针根本没跑在该跑的库上，必须报红而不是显示「0 列全过」
    if [ ! -s "$columns_file" ]; then
        echo "❌ ${label}：一列都没枚举到，探针没有跑在预期的库上"
        exit 1
    fi

    echo "逐列执行同类型 ALTER（${label}）..."
    local table_name column_name column_type alter_sql
    while IFS=$'\t' read -r table_name column_name column_type; do
        [ -n "$table_name" ] || continue
        TOTAL_CHECKED=$((TOTAL_CHECKED + 1))
        alter_sql="ALTER TABLE \"${table_name}\" ALTER COLUMN \"${column_name}\" TYPE ${column_type};"
        if docker exec "$CONTAINER" psql -U teslamate -d "$db" \
                -v ON_ERROR_STOP=1 -c "$alter_sql" \
                >"$TMP_ROOT/alter.out" 2>"$TMP_ROOT/alter.err"; then
            echo "  ✓ ${table_name}.${column_name} (${column_type})"
        else
            TOTAL_FAILED=$((TOTAL_FAILED + 1))
            echo "  ❌ ${table_name}.${column_name} (${column_type}) 被本项目 SQL 对象阻挡"
            sed 's/^/     /' "$TMP_ROOT/alter.err"
        fi
    done <"$columns_file"
}

# ---------------------------------------------------------------------------
# 路径①：全新安装
# ---------------------------------------------------------------------------
echo
echo "【路径① 全新安装】"
echo "建最小 TeslaMate schema..."
if ! create_min_schema teslamate; then
    echo "❌ 最小 TeslaMate schema 创建失败"
    sed 's/^/   /' "$TMP_ROOT/schema.err"
    exit 1
fi
echo "安装本项目全部 SQL..."
install_sql_files teslamate "当前版本" sql/install-*.sql || exit 1
run_alter_probe teslamate "全新安装"

# ---------------------------------------------------------------------------
# 路径②：先装上一个发行版，再装当前版本
# ---------------------------------------------------------------------------
echo
echo "【路径② 从 ${LEGACY_TAG} 升级】"
UPGRADE_DB="tou_upgrade_from_legacy"
docker exec "$CONTAINER" psql -U teslamate -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE ${UPGRADE_DB}" >/dev/null 2>"$TMP_ROOT/createdb.err" || {
        echo "❌ 无法创建升级路径夹具库"
        sed 's/^/   /' "$TMP_ROOT/createdb.err"
        exit 1
    }
echo "建最小 TeslaMate schema..."
if ! create_min_schema "$UPGRADE_DB"; then
    echo "❌ 最小 TeslaMate schema 创建失败（升级路径）"
    sed 's/^/   /' "$TMP_ROOT/schema.err"
    exit 1
fi
echo "先装 ${LEGACY_TAG} 的 SQL..."
install_sql_files "$UPGRADE_DB" "${LEGACY_TAG}" "${LEGACY_FILES[@]}" || exit 1

# 夹具自检：${LEGACY_TAG} 必须真的留下了那个会挡住上游 ALTER 的视图。
# 没有这一句，把 LEGACY_TAG 前移到一个不再创建 charging_processes_v 的版本之后，路径②
# 就退化成路径①的复制品——照样全绿，而升级路径重新变成盲区。
# 兄弟脚本 test-tou-behavior.sh / check-upstream-migration-e2e.sh 各有一处等价自检。
if ! docker exec "$CONTAINER" psql -U teslamate -d "$UPGRADE_DB" -tAc \
        "SELECT to_regclass('public.charging_processes_v')" 2>/dev/null \
        | grep -qx 'charging_processes_v'; then
    echo "❌ 夹具不成立：装完 ${LEGACY_TAG} 库里没有 charging_processes_v"
    echo "   路径②于是和路径①一模一样，验不到「老版本建过、新版本必须主动清掉」这一类。"
    echo "   LEGACY_TAG 的语义是「最后一个会创建 charging_processes_v 的版本」，不是"
    echo "   「上一个发行版」，不要随发版往前移（见文件开头 LEGACY_TAG 的注释）。"
    exit 1
fi
echo "  ✓ 夹具成立：库里有 ${LEGACY_TAG} 建的 charging_processes_v"

echo "再装当前版本的 SQL..."
install_sql_files "$UPGRADE_DB" "当前版本" sql/install-*.sql || exit 1
run_alter_probe "$UPGRADE_DB" "从 ${LEGACY_TAG} 升级"

echo
if [ "$TOTAL_FAILED" -eq 0 ]; then
    echo "✅ 上游 ALTER COLUMN 兼容性通过（两条路径共 ${TOTAL_CHECKED} 列）"
    exit 0
fi

echo "❌ 上游 ALTER COLUMN 兼容性失败：${TOTAL_FAILED} / ${TOTAL_CHECKED} 列被阻挡"
echo "   上面的 PostgreSQL DETAIL 会指出依赖列的触发器、视图或规则。"
echo "   只有「从 ${LEGACY_TAG} 升级」这条路径报红时，说明问题出在老版本留下、"
echo "   而当前版本没有主动清掉的对象——「新版不再创建」不等于「老库里已经没了」。"
exit 1
