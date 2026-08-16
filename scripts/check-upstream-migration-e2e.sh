#!/usr/bin/env bash
# 上游升级端到端门：用真的 TeslaMate 镜像跑真的数据库迁移，证明装了本项目 SQL 的库
# 仍然能让 TeslaMate 升级成功。
#
# 流程（就是用户机器上真实发生的事）：
#   ① 起 postgres
#   ② teslamate:4.0.1 跑迁移      → 建出真实的 TeslaMate 表结构（cost 是 numeric(6,2)）
#   ③ 装上一个发行版的全部 SQL     → 用户升级前的库形状
#   ④ 装当前版本的全部 SQL         → 用户这次升级做的事
#   ⑤ teslamate:4.1.1 跑迁移      → 必须退出码 0
#   ⑥ 复核 charging_processes.cost 真的变成了 numeric(14,2)
#
# 为什么 ⑥ 不能省：迁移「没报错」有两种可能——真的改成功了，或者那句 ALTER 根本没跑到。
# 只看退出码的话，第二种会伪装成绿色。
#
# 为什么必须有这道门：v1.9.6 修的正是「我们的 SQL 对象钉住了 charging_processes.cost，
# 上游 4.1.1 的 ALTER COLUMN 被 PostgreSQL 拒绝、TeslaMate 起不来」。当时只验证了全新
# 安装，而绝大多数受害者是从旧版升上来的——他们库里那个 charging_processes_v 视图是老版本
# 建的，新版本「不再创建」救不了他们。这道门从旧版装起，专门盯住这条路径。
#
# 用法：bash scripts/check-upstream-migration-e2e.sh
# 依赖：docker（会拉 teslamate 镜像）、git（读上一个 tag 的 SQL，浅克隆需 fetch-depth: 0）
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PG_IMAGE="postgres:18-trixie"
# 升级的起点与终点：4.1.1 就是那个会执行
# ALTER TABLE charging_processes ALTER COLUMN cost TYPE numeric(14,2) 的版本。
TESLAMATE_FROM="teslamate/teslamate:4.0.1"
TESLAMATE_TO="teslamate/teslamate:4.1.1"
EXPECTED_COST_TYPE="numeric(14,2)"
# 用户升级前库里装的那一版。
#
# 【语义：最后一个会创建 charging_processes_v 的版本】不是「上一个发行版」。
# 这个值**不该随发版往前移**：改成 v1.9.6 或更新之后，②装的那一版根本不会创建
# charging_processes_v，这道门就验不到「老版本建过、新版本必须主动清掉」那条升级路径了
# （下面第 ② 步末尾的「夹具不成立」自检会当场把这种情况拦下报红）。
# 只有当我们又引入一个新的「旧版创建、新版不再创建」的对象时，才需要重新考虑取哪个 tag。
LEGACY_TAG="v1.9.5"

SUFFIX=$$
NETWORK="tm-migration-e2e-net-${SUFFIX}"
PG_CONTAINER="tm-migration-e2e-pg-${SUFFIX}"
DB_USER="teslamate"
DB_PASS="migration_e2e_pass"
DB_NAME="teslamate"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/upstream-migration-e2e.XXXXXX") || exit 1

cleanup() {
    docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -r -- "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "❌ $1"
    exit 1
}

psql_q() {
    docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAX -v ON_ERROR_STOP=1 -c "$1"
}

# TeslaMate 镜像的 entrypoint 自己会等 postgres 就绪、然后跑迁移；把迁移命令再作为
# CMD 传一遍，退出码就等于「迁移成功与否」，容器也不会常驻。
run_teslamate_migration() {
    local image="$1" log="$2"
    docker run --rm --network "$NETWORK" \
        -e DATABASE_USER="$DB_USER" \
        -e DATABASE_PASS="$DB_PASS" \
        -e DATABASE_NAME="$DB_NAME" \
        -e DATABASE_HOST="$PG_CONTAINER" \
        -e ENCRYPTION_KEY="migration-e2e-not-a-real-key" \
        -e DISABLE_MQTT=true \
        "$image" bin/teslamate eval "TeslaMate.Release.migrate" >"$log" 2>&1
}

echo "拉取镜像（已有就直接用）..."
for image in "$PG_IMAGE" "$TESLAMATE_FROM" "$TESLAMATE_TO"; do
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        docker pull "$image" >/dev/null 2>&1 || fail "拉不到镜像 $image"
    fi
    echo "  ✓ $image"
done

echo "取 ${LEGACY_TAG} 的安装 SQL..."
LEGACY_DIR="$TMP_ROOT/legacy-sql"
mkdir -p "$LEGACY_DIR"
LEGACY_FILES=()
legacy_list=$(git ls-tree --name-only "$LEGACY_TAG" sql/ 2>"$TMP_ROOT/git.err" \
    | grep -E '^sql/install-.*\.sql$')
if [ -z "$legacy_list" ]; then
    sed 's/^/   /' "$TMP_ROOT/git.err"
    echo "   浅克隆（fetch-depth: 1）不带 tag，CI 的 checkout 需要 fetch-depth: 0。"
    fail "取不到 ${LEGACY_TAG} 的 sql/install-*.sql，升级路径无法验证"
fi
while IFS= read -r path; do
    [ -n "$path" ] || continue
    name=${path##*/}
    git show "${LEGACY_TAG}:${path}" >"$LEGACY_DIR/$name" 2>"$TMP_ROOT/git.err" \
        || { sed 's/^/   /' "$TMP_ROOT/git.err"; fail "取不到 ${LEGACY_TAG}:${path}"; }
    LEGACY_FILES+=("$LEGACY_DIR/$name")
    echo "  ✓ ${LEGACY_TAG}:${path}"
done <<<"$legacy_list"

echo "起隔离网络 + postgres..."
docker network create "$NETWORK" >/dev/null 2>&1 || fail "无法创建隔离网络"
docker run -d --name "$PG_CONTAINER" --network "$NETWORK" \
    -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASS" -e POSTGRES_DB="$DB_NAME" \
    "$PG_IMAGE" >/dev/null || fail "无法启动隔离 postgres"

ready=0
for _ in $(seq 1 60); do
    if docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c 'SELECT 1' \
            >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
[ "$ready" -eq 1 ] || fail "隔离 postgres 60 秒内未就绪"

echo "① ${TESLAMATE_FROM} 跑迁移（建真实 TeslaMate 表结构）..."
run_teslamate_migration "$TESLAMATE_FROM" "$TMP_ROOT/migrate-from.log" || {
    tail -30 "$TMP_ROOT/migrate-from.log" | sed 's/^/   /'
    fail "起点版本 ${TESLAMATE_FROM} 的迁移就失败了（与本项目无关，先看上面的日志）"
}
BEFORE_TYPE=$(psql_q "SELECT format_type(atttypid, atttypmod)
                        FROM pg_attribute
                       WHERE attrelid = 'charging_processes'::regclass
                         AND attname = 'cost'")
echo "   charging_processes.cost = ${BEFORE_TYPE}"
if [ "$BEFORE_TYPE" = "$EXPECTED_COST_TYPE" ]; then
    fail "起点版本的 cost 已经是 ${EXPECTED_COST_TYPE}，这道门验不到那次 ALTER；请调整 TESLAMATE_FROM"
fi

echo "② 装 ${LEGACY_TAG} 的全部 SQL（用户升级前的库）..."
for sql_file in "${LEGACY_FILES[@]}"; do
    name=${sql_file##*/}
    if docker exec -i "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
            <"$sql_file" >"$TMP_ROOT/legacy-${name}.log" 2>&1; then
        echo "   ✓ ${LEGACY_TAG} ${name}"
    else
        tail -20 "$TMP_ROOT/legacy-${name}.log" | sed 's/^/     /'
        fail "${LEGACY_TAG} 的 ${name} 装不上"
    fi
done

# 夹具自检：老版本必须真的留下了那个会挡住升级的视图，否则这道门是空跑。
LEGACY_VIEW=$(psql_q "SELECT COALESCE(to_regclass('public.charging_processes_v')::text, '<无>')")
[ "$LEGACY_VIEW" = "charging_processes_v" ] \
    || fail "夹具不成立：装完 ${LEGACY_TAG} 库里没有 charging_processes_v（这道门就验不到升级路径了）"
echo "   ✓ 夹具成立：库里有 ${LEGACY_TAG} 建的 charging_processes_v"

echo "③ 装当前版本的全部 SQL（用户这次升级做的事）..."
for sql_file in sql/install-*.sql; do
    name=${sql_file##*/}
    if docker exec -i "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
            <"$sql_file" >"$TMP_ROOT/current-${name}.log" 2>&1; then
        echo "   ✓ 当前版本 ${name}"
    else
        tail -20 "$TMP_ROOT/current-${name}.log" | sed 's/^/     /'
        fail "当前版本的 ${name} 装不上"
    fi
done

echo "④ ${TESLAMATE_TO} 跑迁移（这一步在 v1.9.6 上是失败的）..."
if ! run_teslamate_migration "$TESLAMATE_TO" "$TMP_ROOT/migrate-to.log"; then
    echo
    echo "   TeslaMate 迁移日志末尾："
    tail -30 "$TMP_ROOT/migrate-to.log" | sed 's/^/     /'
    echo
    echo "   这意味着装了本项目 SQL 的库会让 TeslaMate 启动失败、容器反复重启，"
    echo "   行车与充电全部停止记录。上面的 PostgreSQL DETAIL 会指出是哪个对象钉住了列。"
    fail "上游 ${TESLAMATE_TO} 迁移失败"
fi

AFTER_TYPE=$(psql_q "SELECT format_type(atttypid, atttypmod)
                       FROM pg_attribute
                      WHERE attrelid = 'charging_processes'::regclass
                        AND attname = 'cost'")
echo "⑤ 复核 charging_processes.cost = ${AFTER_TYPE}"
[ "$AFTER_TYPE" = "$EXPECTED_COST_TYPE" ] \
    || fail "迁移退出码是 0，但 cost 仍是 ${AFTER_TYPE}（期望 ${EXPECTED_COST_TYPE}）——那句 ALTER 根本没跑到，绿色是假的"

echo
echo "✅ 上游升级端到端通过：${TESLAMATE_FROM} → 装 ${LEGACY_TAG} → 装当前版本 → ${TESLAMATE_TO} 迁移成功"
echo "   charging_processes.cost：${BEFORE_TYPE} → ${AFTER_TYPE}"
exit 0
