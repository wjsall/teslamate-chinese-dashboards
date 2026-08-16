#!/usr/bin/env bash
# 升级结尾横幅契约门：真的把 scripts/upgrade.sh 整段跑一遍，断言「旧版对账视图没删掉」
# 这件事**不会**以绿色「✓ 升级完成！」收场。
#
# 为什么必须真跑而不是静态 grep：
# 这道门要防的缺陷长成这样——sql/install-tou.sql 删不掉旧版的 charging_processes_v 时，
# 会往 tou_settings.view_rebuild_note 留一句话；upgrade.sh 把它 echo 出来了，但没计入
# WARN_STEPS，于是结尾走的是 else 分支：绿色「✓ 升级完成！」+ 退出码 0。
# 也就是说「纯装饰性的 TOU 历史费用回算失败」会让横幅变黄，而「这个视图会让 TeslaMate
# 反复重启、行车充电全部停止记录」只在中间段落 echo 一行。轻重倒挂，用户不可能看见。
# 缺陷不在任何单独一行里，而在「echo 的地方」和「结尾判分支的地方」之间的连线上——
# 只有把两头一起跑起来才测得到。
#
# 两条路径都跑，缺一不可：
#   ① 对照组：视图删得掉  → 必须是绿色「✓ 升级完成！」
#   ② 实验组：视图删不掉  → 必须**不是**绿色，且必须把后果写出来
# 只有 ② 的时候，这道门分不清「因为视图报黄」和「因为环境里别的东西报黄」——对照组绿了，
# ② 的黄色才归因得到那个视图上（feedback「先证实验有效」同一条教训）。
#
# 用法：bash scripts/check-upgrade-warn-banner.sh
# 依赖：docker、git（要 git show 上一个建过该视图的 tag，浅克隆需 fetch-depth: 0）
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PG_IMAGE="postgres:18-trixie"
# 容器名必须能被 scripts/lib/detect-containers.sh 的 detect_db_container 认出来
# （正则 'teslamate.*database'）——upgrade.sh 就是用它找库的，认不出来这道门等于没跑。
CONTAINER="teslamate-database-upgbanner-$$"
# 起点版本的语义与 test-tou-behavior.sh / check-upstream-alter-compat.sh 完全一致：
# 【最后一个会创建 charging_processes_v 的版本】，不是「上一个发行版」，不随发版前移。
LEGACY_TAG="v1.9.5"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/upgrade-warn-banner.XXXXXX") || exit 1
STUB_BIN="$TMP_ROOT/stub-bin"

FAIL=0

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -r -- "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

die() {
    echo "❌ $1"
    exit 1
}

psql_q() {
    docker exec "$CONTAINER" psql -U teslamate -d teslamate -tAc "$1" 2>/dev/null \
        | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# git 桩：upgrade.sh 开头会 `git diff-index --quiet HEAD --`（工作区有未提交改动就
# 直接 exit 1）再 `git pull --rebase`。这道门测的是结尾横幅，不是 git 交互，所以把这
# 几个调用桩掉。桩只在本脚本起的子进程 PATH 里生效，不影响仓库。
# 注意：夹具用的 `git show <tag>:...` 走的是真 git，在桩生效之前就取好了。
# ---------------------------------------------------------------------------
make_git_stub() {
    mkdir -p "$STUB_BIN"
    cat >"$STUB_BIN/git" <<'STUB'
#!/bin/sh
case "$1" in
    diff-index) exit 0 ;;
    pull)       echo "[stub] git pull --rebase 已跳过"; exit 0 ;;
    describe)   echo "v0.0.0-upgbanner-test"; exit 0 ;;
    *)          exit 0 ;;
esac
STUB
    chmod +x "$STUB_BIN/git"
}

# 最小 TeslaMate 表结构（与 test-tou-behavior.sh / check-upstream-alter-compat.sh 同一份
# 形状）。多一张 schema_migrations：upgrade.sh 的 wait_teslamate_migrated 会数它的行数，
# 表不存在时那个循环要空转满 60 轮（180 秒）才放弃。
MIN_SCHEMA_SQL=$(cat <<'SQL'
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
CREATE TABLE schema_migrations (
  version BIGINT PRIMARY KEY,
  inserted_at TIMESTAMP
);
INSERT INTO schema_migrations (version, inserted_at) VALUES (20200101000000, NOW());
SQL
)

# 把 teslamate 库恢复成「用户升级前」的形状：最小 schema + ${LEGACY_TAG} 的 TOU SQL。
# upgrade.sh 把库名/用户名写死成 teslamate，所以只能原地重建这一个库，不能换库名。
reset_legacy_db() {
    docker exec "$CONTAINER" psql -U teslamate -d postgres -v ON_ERROR_STOP=1 \
        -c "DROP DATABASE IF EXISTS teslamate WITH (FORCE)" \
        -c "CREATE DATABASE teslamate OWNER teslamate" \
        >/dev/null 2>"$TMP_ROOT/resetdb.err" \
        || { sed 's/^/   /' "$TMP_ROOT/resetdb.err"; die "无法重建 teslamate 夹具库"; }
    printf '%s\n' "$MIN_SCHEMA_SQL" \
        | docker exec -i "$CONTAINER" psql -U teslamate -d teslamate -q -v ON_ERROR_STOP=1 \
            >/dev/null 2>"$TMP_ROOT/schema.err" \
        || { sed 's/^/   /' "$TMP_ROOT/schema.err"; die "最小 TeslaMate schema 创建失败"; }
    docker exec -i "$CONTAINER" psql -U teslamate -d teslamate -q -v ON_ERROR_STOP=1 \
        <"$LEGACY_TOU_SQL" >/dev/null 2>"$TMP_ROOT/legacy-install.err" \
        || { tail -20 "$TMP_ROOT/legacy-install.err" | sed 's/^/   /'
             die "${LEGACY_TAG} 的 install-tou.sql 装不上"; }
    # 夹具自检：起点版本必须真的留下了那个视图，否则两条路径都退化成「视图本来就不在」，
    # 这道门变成空跑。LEGACY_TAG 被人随发版前移时，这里就是报警点。
    [ "$(psql_q "SELECT to_regclass('public.charging_processes_v')")" = "charging_processes_v" ] \
        || die "夹具不成立：装完 ${LEGACY_TAG} 库里没有 charging_processes_v（LEGACY_TAG 选错了？它的语义是「最后一个会创建该视图的版本」）"
}

# 整段跑一次 upgrade.sh，输出落盘，退出码回填到 $RUN_RC
RUN_RC=0
run_upgrade() {
    local out="$1"
    PATH="$STUB_BIN:$PATH" bash scripts/upgrade.sh </dev/null >"$out" 2>&1
    RUN_RC=$?
}

# 断言封装：contains / not-contains，失败时把实际输出的关键几行打出来
assert_contains() {
    local label="$1" file="$2" needle="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "  ✓ ${label}"
    else
        echo "  ✗ ${label}：输出里找不到「${needle}」"
        FAIL=1
    fi
}

assert_not_contains() {
    local label="$1" file="$2" needle="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "  ✗ ${label}：输出里**出现了**「${needle}」"
        grep -nF -- "$needle" "$file" | sed 's/^/      /'
        FAIL=1
    else
        echo "  ✓ ${label}"
    fi
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ ${label}"
    else
        echo "  ✗ ${label}：期望「${expected}」实际「${actual}」"
        FAIL=1
    fi
}

# ---------------------------------------------------------------------------
# 准备
# ---------------------------------------------------------------------------
LEGACY_TOU_SQL="$TMP_ROOT/install-tou-${LEGACY_TAG}.sql"
echo "取 ${LEGACY_TAG} 的 sql/install-tou.sql..."
git show "${LEGACY_TAG}:sql/install-tou.sql" >"$LEGACY_TOU_SQL" 2>"$TMP_ROOT/git-show.err" \
    || { sed 's/^/   /' "$TMP_ROOT/git-show.err"
         echo "   浅克隆（fetch-depth: 1）不带 tag，CI 里这个 job 的 checkout 需要 fetch-depth: 0。"
         die "取不到 ${LEGACY_TAG} 的 sql/install-tou.sql"; }
grep -q 'VIEW charging_processes_v' "$LEGACY_TOU_SQL" \
    || die "${LEGACY_TAG} 的 install-tou.sql 里没有 charging_processes_v，夹具不成立"

make_git_stub

echo "起隔离 postgres（${CONTAINER}）..."
docker run -d --name "$CONTAINER" \
    -e POSTGRES_USER=teslamate -e POSTGRES_PASSWORD=test -e POSTGRES_DB=teslamate \
    "$PG_IMAGE" >/dev/null || die "无法启动隔离 postgres"

ready=0
for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" psql -U teslamate -d teslamate -c 'SELECT 1' >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
[ "$ready" -eq 1 ] || die "postgres 60 秒内没就绪"

# 前置自检：upgrade.sh 是用 detect_db_container 找库的，它必须找到**我们这个**容器。
# 找到别的（比如本机上真的跑着一套 TeslaMate），这道门就跑在了别人的库上——那既危险
# 又毫无意义，必须当场停，而不是继续跑出一个漂亮的绿色。
# shellcheck source=lib/detect-containers.sh
source "scripts/lib/detect-containers.sh"
DETECTED=$(detect_db_container)
[ "$DETECTED" = "$CONTAINER" ] \
    || die "detect_db_container 找到的是「${DETECTED:-<空>}」而不是「${CONTAINER}」；本机上有别的 teslamate 数据库容器在跑？先停掉再跑这道门"

# 同一件事的另一半，而且这一半会**改别人的状态**：upgrade.sh 第 8 步是无条件的
#   GRAFANA_CONTAINER=$(detect_grafana_container); docker restart "$GRAFANA_CONTAINER"
# （正则 'teslamate.*grafana|^grafana$'）。这道门跑的是真的 upgrade.sh，一跑到第 8 步就
# 会把它检测到的那个 Grafana 重启掉。在本机 dogfood 机或 self-hosted runner 上，那就是
# 用户正在看的 Grafana——一道 lint 门绝不该有这种副作用。
# 本门只起 postgres、从不起 grafana，所以这里唯一正确的答案是「什么都没检测到」；
# 检测到任何东西，那都是别人的容器，当场停，不要跑下去。
DETECTED_GF=$(detect_grafana_container)
[ -z "$DETECTED_GF" ] \
    || die "detect_grafana_container 找到了「${DETECTED_GF}」，那不是本门起的容器；跑下去会执行 upgrade.sh 第 8 步的 docker restart 把它重启掉。先停掉该容器（或换一台没跑 TeslaMate Grafana 的机器）再跑这道门"

# ---------------------------------------------------------------------------
# ① 对照组：视图删得掉（没有任何用户对象依赖它）
# ---------------------------------------------------------------------------
echo
echo "【① 对照组：旧视图删得掉】"
reset_legacy_db
run_upgrade "$TMP_ROOT/control.log"
echo "  upgrade.sh 退出码 = ${RUN_RC}"
assert_eq "对照组：退出码 0" "0" "$RUN_RC"
assert_eq "对照组：旧视图确实被删掉了" "" "$(psql_q "SELECT to_regclass('public.charging_processes_v')")"
# 这条是「实验有效性」的锚：对照组必须是绿的，② 的黄色才归因得到那个视图。
# 它红了不代表本次改动坏了，多半是环境（比如本机有 exited 的 teslamate 容器让
# wait_teslamate_migrated 判失败）——看 control.log 里前几段就知道。
if ! grep -qF -- "✓ 升级完成！" "$TMP_ROOT/control.log"; then
    echo "  ✗ 对照组不是绿色「✓ 升级完成！」——实验不成立，② 的结论无从归因"
    echo "    upgrade.sh 结尾输出："
    tail -25 "$TMP_ROOT/control.log" | sed 's/^/      /'
    exit 1
fi
echo "  ✓ 对照组：结尾是绿色「✓ 升级完成！」"
assert_not_contains "对照组：不该留任何待办提示" "$TMP_ROOT/control.log" "留了一个尾巴"

# ---------------------------------------------------------------------------
# ② 实验组：用户自建对象依赖它 → 删不掉（sql/install-tou.sql 2f 节三种情形之一）
# ---------------------------------------------------------------------------
echo
echo "【② 实验组：用户自建视图依赖旧视图，删不掉】"
reset_legacy_db
docker exec -i "$CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 \
    -c "CREATE VIEW my_charging_report AS
          SELECT id, cost_effective, cost_mode FROM charging_processes_v" >/dev/null 2>&1 \
    || die "无法创建依赖旧视图的用户视图夹具"
run_upgrade "$TMP_ROOT/blocked.log"
echo "  upgrade.sh 退出码 = ${RUN_RC}"

# 夹具自检：库里必须真的留下了那句待办，否则下面断的是空气
assert_eq "实验组夹具成立：库里确实留了 view_rebuild_note" \
    "1" "$(psql_q "SELECT (view_rebuild_note IS NOT NULL)::int FROM tou_settings")"
assert_eq "实验组：旧视图仍在（不许 CASCADE 连坐用户的东西）" \
    "charging_processes_v" "$(psql_q "SELECT to_regclass('public.charging_processes_v')")"
assert_eq "实验组：用户自己建的视图必须还在" \
    "my_charging_report" "$(psql_q "SELECT to_regclass('public.my_charging_report')")"

# —— 核心断言：结尾不能是绿色的「升级完成」 ——
assert_not_contains "实验组：结尾**不是**绿色「✓ 升级完成！」" \
    "$TMP_ROOT/blocked.log" "✓ 升级完成！"
assert_contains "实验组：计入了告警项（结尾横幅因此变黄）" \
    "$TMP_ROOT/blocked.log" "旧版对账视图未清理"
assert_contains "实验组：横幅点名这件事要用户亲自处理" \
    "$TMP_ROOT/blocked.log" "必须你亲自处理"
# 后果必须写在结尾横幅里，不能只在中间段落——用户滚回去找不到
TAIL_LOG="$TMP_ROOT/blocked-tail.log"
tail -20 "$TMP_ROOT/blocked.log" >"$TAIL_LOG"
assert_contains "实验组：结尾横幅写明「TeslaMate 升到 4.1.1 会启动失败」" \
    "$TAIL_LOG" "4.1.1"
assert_contains "实验组：结尾横幅写明「反复重启」的后果" \
    "$TAIL_LOG" "反复重启"
assert_contains "实验组：结尾横幅告诉用户处理完要重跑" \
    "$TAIL_LOG" "重新跑一次 bash scripts/upgrade.sh"
# 警告档而不是失败档：我们该装的全装完了，退出码 0 才不会让自动化把一次好的安装当失败回滚。
# 真正被阻断的是用户的下一步（升级 TeslaMate），所以靠横幅和文案，不靠退出码。
assert_eq "实验组：退出码仍是 0（警告档，不是失败档）" "0" "$RUN_RC"

# ---------------------------------------------------------------------------
echo
if [ "$FAIL" -eq 0 ]; then
    echo "✅ 升级结尾横幅契约通过：旧对账视图删不掉时，upgrade.sh 结尾不再是绿色「升级完成」"
    exit 0
fi
echo "❌ 升级结尾横幅契约失败"
echo "   对照组输出：$TMP_ROOT/control.log（脚本退出后会被清理，需要看请先改 cleanup）"
echo "   实验组输出末 25 行："
tail -25 "$TMP_ROOT/blocked.log" | sed 's/^/     /'
exit 1
