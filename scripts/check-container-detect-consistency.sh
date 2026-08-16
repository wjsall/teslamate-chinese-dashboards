#!/usr/bin/env bash
# TeslaMate 容器检测：三份拷贝必须逐字一致 + 「优先选运行中的」必须真的成立。
#
# 为什么要这道门：
#   detect_db_container / detect_grafana_container 用 `docker ps`（只看运行中），而
#   teslamate_container_name 必须能看见已停止的容器——「TeslaMate 反复重启/已退出时
#   拒绝安装单位换算函数」这条保护就靠它。两个需求叠在一起，写法很容易退化成只扫
#   `docker ps -a` + `head -1`：docker ps -a 按创建时间倒序，宿主机上只要躺着一个更晚
#   创建、已经停掉的 TeslaMate（改过名的旧栈、试过一次的部署、跑过一遍的测试），选中的
#   就是那个死的 → 判定「它的迁移不可能完成」→ 跳过单位换算函数 + 报「✗ 升级失败」，
#   而用户真正在跑的 TeslaMate 一切正常。
#
#   正本在 scripts/lib/detect-containers.sh。simple-deploy.sh 和 migrate-from-official.sh
#   是 curl|bash 远程执行的自包含脚本，source 不了本地文件，只能内联同样的实现——靠注释
#   提醒「记得同步」是留不住的，所以这里逐字节比对。
#
# 两段检查：
#   ① 一致性：两个内联副本与正本逐字节相同。
#   ② 行为：真起两个容器（一个运行中、一个更晚创建且已停止），断言选中的是运行中那个。
#      只比对文本不做行为测，等于只钉住写法、钉不住「优先运行中」这条契约本身。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

LIB='scripts/lib/detect-containers.sh'
COPIES='simple-deploy.sh migrate-from-official.sh'
FAILED=0

fail() { echo "  ✗ $*"; FAILED=1; }
ok() { echo "  ✓ $*"; }

# 从一份脚本里抠出这两个函数的定义块（含中间的注释），用于逐字节比对。
extract_block() {
    sed -n '/^_teslamate_scan() {/,/^}/p;/^teslamate_container_name() {/,/^}/p' "$1"
}

echo "【① 三份拷贝逐字一致】"
[ -f "$LIB" ] || { echo "  ✗ 找不到正本 $LIB"; exit 1; }
LIB_BLOCK=$(extract_block "$LIB")
if [ -z "$LIB_BLOCK" ]; then
    echo "  ✗ 正本 $LIB 里抠不到 _teslamate_scan / teslamate_container_name；"
    echo "    要么函数被改名了（请同步改本门的 extract_block），要么被删了。"
    exit 1
fi
echo "  正本 $LIB（$(printf '%s\n' "$LIB_BLOCK" | wc -l | tr -d ' ') 行）"

for f in $COPIES; do
    if [ ! -f "$f" ]; then fail "$f 不存在"; continue; fi
    COPY_BLOCK=$(extract_block "$f")
    if [ -z "$COPY_BLOCK" ]; then
        fail "$f 里没有内联副本。它是 curl|bash 远程执行的自包含脚本，source 不了 $LIB，必须内联。"
        continue
    fi
    if [ "$COPY_BLOCK" = "$LIB_BLOCK" ]; then
        ok "$f 与正本逐字一致"
    else
        fail "$f 的内联副本与正本 $LIB 不一致，差异："
        diff <(printf '%s\n' "$LIB_BLOCK") <(printf '%s\n' "$COPY_BLOCK") | sed 's/^/      /'
    fi
done

# upgrade.sh 走 source，不该再有内联副本（有的话晚定义的会盖掉正本，正本就白改了）
if [ -n "$(extract_block scripts/upgrade.sh)" ]; then
    fail "scripts/upgrade.sh 又出现了内联副本。它 source 了 $LIB，内联副本定义在后面会盖掉正本——删掉内联的那份。"
else
    ok "scripts/upgrade.sh 走 source，无内联副本"
fi

echo
echo "【② 行为：运行中的优先于已停止的】"
if ! docker info >/dev/null 2>&1; then
    echo "  ✗ 连不上 docker daemon，这段行为测跑不了。"
    echo "    不把它当「跳过」放行：只比对文本证明不了「优先运行中」这条契约还在。"
    exit 1
fi

SUFFIX="$$"
LIVE="teslamate-detect-live-${SUFFIX}"
DEAD="teslamate-detect-dead-${SUFFIX}"
cleanup() { docker rm -f "$LIVE" "$DEAD" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

# 名字都要能被第一档正则 '(^|[-_])teslamate([-_][0-9]+)?$' 命中，才测得到「同档内怎么挑」。
LIVE="teslamate_${SUFFIX}"
DEAD="teslamate-${SUFFIX}"
cleanup

docker run -d --name "$LIVE" alpine sleep 600 >/dev/null 2>&1 \
    || { echo "  ✗ 起不了运行中的样本容器"; exit 1; }
# 后创建、且已停止 —— docker ps -a 会把它排在运行中那个前面，这正是要防的形状。
docker run --name "$DEAD" alpine true >/dev/null 2>&1 \
    || { echo "  ✗ 起不了已停止的样本容器"; exit 1; }

FIRST_IN_PS_A=$(docker ps -a --format '{{.Names}}' | grep -E "^teslamate[-_]${SUFFIX}$" | head -1)
if [ "$FIRST_IN_PS_A" != "$DEAD" ]; then
    echo "  ⚠ 本次 docker ps -a 的顺序没把已停止那个排在前面（实得「${FIRST_IN_PS_A}」）；"
    echo "    这一轮测不到要防的形状，判为失败而不是放行——请重跑。"
    FAILED=1
else
    ok "已构造出要防的形状：docker ps -a 里排第一的是已停止的「${DEAD}」"

    # shellcheck source=lib/detect-containers.sh
    DC="docker-compose-does-not-exist-$$" source "$LIB"
    PICKED=$(DC="docker-compose-does-not-exist-$$" teslamate_container_name)
    if [ "$PICKED" = "$LIVE" ]; then
        ok "teslamate_container_name 选中运行中的「${LIVE}」"
    else
        fail "teslamate_container_name 选中了「${PICKED}」，期望运行中的「${LIVE}」。"
        echo "      这就是那个真实故障：用户的 TeslaMate 明明在跑，upgrade.sh 却去读了一个"
        echo "      已停止的同名容器的状态，跳过单位换算函数并报「✗ 升级失败」。"
    fi

    # 反向：运行中的没了，必须还能看见已停止的——否则「反复重启/已退出」的保护就瞎了。
    docker rm -f "$LIVE" >/dev/null 2>&1
    PICKED2=$(DC="docker-compose-does-not-exist-$$" teslamate_container_name)
    if [ "$PICKED2" = "$DEAD" ]; then
        ok "一个都没运行时回落到已停止的「${DEAD}」，重启/退出保护仍然看得见"
    else
        fail "没有运行中的容器时选中了「${PICKED2}」，期望「${DEAD}」；回落档被改坏了。"
    fi
fi

echo
if [ "$FAILED" -ne 0 ]; then
    echo "✗ 容器检测一致性/行为检查未通过"
    exit 1
fi
echo "✓ 容器检测一致性 + 优先运行中行为，全部通过"
