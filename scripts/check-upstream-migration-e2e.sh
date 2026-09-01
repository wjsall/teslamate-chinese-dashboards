#!/usr/bin/env bash
# 上游升级端到端门：用真的 TeslaMate 镜像跑真的数据库迁移，证明装了本项目 SQL 的库
# 仍然能让 TeslaMate 升级成功。
#
# 两条流程都要通过：
#
# 正常升级：
#   ① 起 postgres
#   ② teslamate:3.1.0 跑迁移      → 建出 issue #39 备份起点的真实表结构（cost 是 numeric(6,2)）
#   ③ 装上一个发行版的全部 SQL     → 用户升级前的库形状
#   ④ 装当前版本的全部 SQL         → 用户这次升级做的事
#   ⑤ teslamate:4.2.0 跑迁移      → 必须退出码 0
#   ⑥ 复核 charging_processes.cost 真的变成了 numeric(14,2)
#
# 备份恢复（issue #39）：
#   ① 把上面的旧库复制成一份恢复库
#   ② 直接启动 4.2.0             → 必须复现旧版数据库对象阻挡迁移
#   ③ 执行 TROUBLESHOOTING 恢复步骤里的非 CASCADE 清理
#   ④ 再启动 4.2.0               → 必须迁移成功
#   ⑤ 迁移完成后装当前 SQL         → 必须成功，旧视图不得复活
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
# 升级的起点与终点：4.2.0 包含 4.1.1 引入的
# ALTER TABLE charging_processes ALTER COLUMN cost TYPE numeric(14,2)，也就是 issue #39 实际使用的版本。
TESLAMATE_FROM="teslamate/teslamate:3.1.0"
TESLAMATE_TO="teslamate/teslamate:4.2.0"
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
RESTORE_DB_NAME="teslamate_restore"
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
    local sql="$1" db="${2:-$DB_NAME}"
    docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$db" -tAX -v ON_ERROR_STOP=1 -c "$sql"
}

# TeslaMate 镜像的 entrypoint 自己会等 postgres 就绪、然后跑迁移；把迁移命令再作为
# CMD 传一遍，退出码就等于「迁移成功与否」，容器也不会常驻。
run_teslamate_migration() {
    local image="$1" log="$2" db="${3:-$DB_NAME}"
    docker run --rm --network "$NETWORK" \
        -e DATABASE_USER="$DB_USER" \
        -e DATABASE_PASS="$DB_PASS" \
        -e DATABASE_NAME="$db" \
        -e DATABASE_HOST="$PG_CONTAINER" \
        -e ENCRYPTION_KEY="migration-e2e-not-a-real-key" \
        -e DISABLE_MQTT=true \
        "$image" bin/teslamate eval "TeslaMate.Release.migrate" >"$log" 2>&1
}

install_current_sql() {
    local db="$1" label="$2" sql_file name
    for sql_file in sql/install-*.sql; do
        name=${sql_file##*/}
        if docker exec -i "$PG_CONTAINER" psql -U "$DB_USER" -d "$db" -v ON_ERROR_STOP=1 \
                <"$sql_file" >"$TMP_ROOT/${label}-${name}.log" 2>&1; then
            echo "   ✓ ${label} ${name}"
        else
            tail -20 "$TMP_ROOT/${label}-${name}.log" | sed 's/^/     /'
            fail "${label} 的 ${name} 装不上"
        fi
    done
}

# 这段不是只查一句话有没有写：下面的恢复路径会把文档中的 SQL 原样拿去跑真数据库。
# 顺序也必须是 pg_restore 之后、start teslamate 之前，否则就是 issue #39 的原故障。
RESTORE_DOC_SECTION=$(awk '
    /^\*\*恢复步骤（新机器上）\*\*：$/ { found=1 }
    found { print }
    found && /^> \*\*如果你已经按旧版流程恢复过/ { exit }
' TROUBLESHOOTING.md)
DOC_RESTORE_LINE=$(printf '%s\n' "$RESTORE_DOC_SECTION" | grep -nF 'pg_restore -U teslamate -d teslamate' | head -1 | cut -d: -f1)
DOC_TRIGGER_LINE=$(printf '%s\n' "$RESTORE_DOC_SECTION" | grep -nF 'DROP TRIGGER IF EXISTS tou_recalc ON public.charging_processes;' | head -1 | cut -d: -f1)
DOC_CLEANUP_LINE=$(printf '%s\n' "$RESTORE_DOC_SECTION" | grep -nF 'DROP VIEW IF EXISTS public.charging_processes_v;' | head -1 | cut -d: -f1)
DOC_START_LINE=$(printf '%s\n' "$RESTORE_DOC_SECTION" | grep -nF 'docker compose start teslamate' | head -1 | cut -d: -f1)
[ -n "$DOC_RESTORE_LINE" ] || fail "恢复文档里找不到 pg_restore 步骤"
[ -n "$DOC_TRIGGER_LINE" ] || fail "恢复文档漏了旧版 tou_recalc 的启动前清理"
[ -n "$DOC_CLEANUP_LINE" ] || fail "恢复文档漏了 charging_processes_v 的启动前清理（issue #39）"
[ -n "$DOC_START_LINE" ] || fail "恢复文档里找不到 start teslamate 步骤"
[ "$DOC_RESTORE_LINE" -lt "$DOC_CLEANUP_LINE" ] && [ "$DOC_CLEANUP_LINE" -lt "$DOC_START_LINE" ] \
    || fail "恢复文档必须在 pg_restore 之后、start teslamate 之前清理 charging_processes_v"
if printf '%s\n' "$RESTORE_DOC_SECTION" | grep -Ei 'DROP VIEW .*charging_processes_v.*CASCADE' >/dev/null; then
    fail "恢复文档不准用 CASCADE 删除 charging_processes_v"
fi
printf '%s\n' "$RESTORE_DOC_SECTION" | grep -E '不要加.*CASCADE' >/dev/null \
    || fail "恢复文档必须明确：清理失败时停止，不要加 CASCADE"
DOC_TRIGGER_SQL=$(printf '%s\n' "$RESTORE_DOC_SECTION" \
    | grep -F 'DROP TRIGGER IF EXISTS tou_recalc ON public.charging_processes;' | head -1 \
    | sed -E 's/.*(DROP TRIGGER IF EXISTS tou_recalc ON public\.charging_processes;).*/\1/')
DOC_VIEW_SQL=$(printf '%s\n' "$RESTORE_DOC_SECTION" \
    | grep -F 'DROP VIEW IF EXISTS public.charging_processes_v;' | head -1 \
    | sed -E 's/.*(DROP VIEW IF EXISTS public\.charging_processes_v;).*/\1/')
DOC_CLEANUP_SQL="${DOC_TRIGGER_SQL} ${DOC_VIEW_SQL}"

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

# 从此处分一份“刚恢复完旧备份”的库：它没有机会先运行当前项目 SQL，正是 issue #39 的形状。
docker exec "$PG_CONTAINER" createdb -U "$DB_USER" -T "$DB_NAME" "$RESTORE_DB_NAME" \
    || fail "无法复制 issue #39 恢复库夹具"

echo "③ 装当前版本的全部 SQL（用户这次升级做的事）..."
install_current_sql "$DB_NAME" "当前版本"

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
echo "===== issue #39：恢复旧库后直接启动 TeslaMate 4.2.0 ====="
echo "⑥ 不做预清理直接迁移，必须复现报告人的原错误..."
if run_teslamate_migration "$TESLAMATE_TO" "$TMP_ROOT/restore-before-cleanup.log" "$RESTORE_DB_NAME"; then
    fail "恢复库带着旧版分时电价对象却迁移成功了，issue #39 夹具没有复现原故障"
fi
grep -F 'cannot alter type of a column used' "$TMP_ROOT/restore-before-cleanup.log" >/dev/null \
    || { tail -30 "$TMP_ROOT/restore-before-cleanup.log" | sed 's/^/   /'; fail "恢复库虽迁移失败，但不是旧版数据库对象阻挡 cost 类型迁移"; }
grep -E 'tou_recalc|charging_processes_v' "$TMP_ROOT/restore-before-cleanup.log" >/dev/null \
    || fail "恢复库错误没有点名本项目的旧版触发器或视图"
echo "   ✓ 已复现：旧版 tou_recalc / charging_processes_v 阻挡 cost 精度迁移"

echo "⑦ 用户对象仍依赖旧视图时，预清理必须失败且一个对象都不丢..."
psql_q "CREATE VIEW issue39_user_report AS SELECT id, cost_effective FROM charging_processes_v" "$RESTORE_DB_NAME" >/dev/null \
    || fail "无法建立 issue #39 下游依赖夹具"
if psql_q "$DOC_CLEANUP_SQL" "$RESTORE_DB_NAME" >"$TMP_ROOT/restore-dependent-cleanup.log" 2>&1; then
    fail "有用户视图依赖时，恢复文档的预清理不该成功"
fi
grep -F 'issue39_user_report' "$TMP_ROOT/restore-dependent-cleanup.log" >/dev/null \
    || fail "预清理失败信息没有指出仍依赖旧视图的用户对象"
[ "$(psql_q "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.charging_processes'::regclass AND tgname = 'tou_recalc'" "$RESTORE_DB_NAME")" = "1" ] \
    || fail "删除旧视图失败时，前一句删除 tou_recalc 没有随事务回滚"
[ "$(psql_q "SELECT to_regclass('public.charging_processes_v') IS NOT NULL AND to_regclass('public.issue39_user_report') IS NOT NULL" "$RESTORE_DB_NAME")" = "t" ] \
    || fail "删除旧视图失败时，旧视图或用户视图被误删"
psql_q "DROP VIEW issue39_user_report" "$RESTORE_DB_NAME" >/dev/null \
    || fail "无法移除 issue #39 下游依赖夹具"
echo "   ✓ 清理安全失败，旧对象和用户对象全部保留"

echo "⑧ 执行恢复文档里的非 CASCADE 预清理..."
psql_q "$DOC_CLEANUP_SQL" "$RESTORE_DB_NAME" >/dev/null \
    || fail "恢复文档里的 charging_processes_v 预清理执行失败"
[ "$(psql_q "SELECT to_regclass('public.charging_processes_v') IS NULL" "$RESTORE_DB_NAME")" = "t" ] \
    || fail "恢复文档跑完后 charging_processes_v 仍存在"
[ "$(psql_q "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.charging_processes'::regclass AND tgname = 'tou_recalc'" "$RESTORE_DB_NAME")" = "0" ] \
    || fail "恢复文档跑完后旧版 tou_recalc 仍存在"

echo "⑨ 再跑 ${TESLAMATE_TO} 迁移..."
if ! run_teslamate_migration "$TESLAMATE_TO" "$TMP_ROOT/restore-after-cleanup.log" "$RESTORE_DB_NAME"; then
    tail -30 "$TMP_ROOT/restore-after-cleanup.log" | sed 's/^/   /'
    fail "按恢复文档预清理后 ${TESLAMATE_TO} 仍迁移失败"
fi
RESTORE_AFTER_TYPE=$(psql_q "SELECT format_type(atttypid, atttypmod)
                               FROM pg_attribute
                              WHERE attrelid = 'charging_processes'::regclass
                                AND attname = 'cost'" "$RESTORE_DB_NAME")
[ "$RESTORE_AFTER_TYPE" = "$EXPECTED_COST_TYPE" ] \
    || fail "恢复路径迁移后 cost 是 ${RESTORE_AFTER_TYPE}（期望 ${EXPECTED_COST_TYPE}）"

echo "⑩ TeslaMate 迁移完成后安装当前 SQL..."
install_current_sql "$RESTORE_DB_NAME" "恢复后当前版本"
[ "$(psql_q "SELECT to_regclass('public.charging_processes_v') IS NULL" "$RESTORE_DB_NAME")" = "t" ] \
    || fail "恢复后安装当前 SQL 又创建了 charging_processes_v"
[ "$(psql_q "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.charging_processes'::regclass AND tgname = 'tou_recalc' AND cardinality(tgattr) = 0" "$RESTORE_DB_NAME")" = "1" ] \
    || fail "恢复后安装当前 SQL 没有重建安全的 tou_recalc"

echo
echo "✅ 上游升级端到端通过：${TESLAMATE_FROM} → 装 ${LEGACY_TAG} → 装当前版本 → ${TESLAMATE_TO} 迁移成功"
echo "   charging_processes.cost：${BEFORE_TYPE} → ${AFTER_TYPE}"
echo "✅ issue #39 恢复路径通过：旧库 → 文档预清理 → ${TESLAMATE_TO} → 装当前 SQL"
exit 0
