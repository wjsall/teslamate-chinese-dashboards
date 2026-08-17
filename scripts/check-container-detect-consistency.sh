#!/usr/bin/env bash
# TeslaMate 容器检测：三份拷贝必须逐字一致 + 「认不出来就不猜」这条契约必须真的成立。
#
# 这套检测最终决定一件事：TeslaMate 自己的数据库迁移做完没有。做完了才装
# sql/install-unit-functions.sql；没做完必须跳过——上游那条建同名函数的迁移不带
# OR REPLACE，抢先建会让它撞 duplicate_function，TeslaMate 从此反复重启，**重跑脚本也修不好**。
#
# 历史上这里换过两版判据，两版各有一侧会输：
#   v1「docker ps -a + head -1」（按创建时间）—— 用户的 TeslaMate 在跑、旁边躺着个更晚
#      创建的死容器时选中死的 → 误判「起不来」→ 跳过 + 报「✗ 升级失败」。红横幅，可重跑，能自愈。
#   v2「运行中优先」—— 用户的 TeslaMate 已经崩了、旁边有个更早创建仍在运行的同名残留时
#      选中健康的假货 → 误判「健康」→ 照装不误 → 撞上面那个不可自愈的坑。**比 v1 更重。**
# 现在的契约是 v3：compose 能给出答案就用它；否则把运行中的和已停止的一起列为候选，
# **多于一个就不猜**（status=ambiguous），由调用方按「确认不了」处理并把候选打给用户看。
#
# 正本在 scripts/lib/detect-containers.sh。simple-deploy.sh 和 migrate-from-official.sh
# 是 curl|bash 远程执行的自包含脚本，source 不了本地文件，只能内联同样的实现。
#
# 三段检查：
#   ① 一致性：两个内联副本与正本逐字节相同，且每个被钉的函数在每份文件里**只被定义一次**
#      （只比对文本挡不住「追加一份写法不同的覆盖定义」——bash 里后定义的赢）。
#   ② 行为：真起容器，把五种形状逐个喂给**三份实现各自**跑一遍。只测正本等于放过了
#      真正 curl|bash 发给用户的那两份。
#   ③ 镜像档：容器名完全不匹配、只有镜像对得上时也必须探得到（那一档否则零覆盖）。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

LIB='scripts/lib/detect-containers.sh'
COPIES='simple-deploy.sh migrate-from-official.sh'
FAILED=0

fail() { echo "  ✗ $*"; FAILED=1; }
ok() { echo "  ✓ $*"; }
die_env() { echo; echo "✗ 环境不满足，本门没跑成（不是被测代码的问题）：$*"; exit 2; }

# 三份拷贝里必须逐字一致的全部函数。少钉一个，那个就能自由漂移。
PINNED_FUNCS='_teslamate_scan teslamate_container_candidates _teslamate_candidate_count teslamate_container_name teslamate_container_status teslamate_published_port'

extract_block() {
    local file="$1" fn
    for fn in $PINNED_FUNCS; do
        sed -n "/^${fn}() {/,/^}/p" "$file"
    done
}

# bash 允许好几种等价拼法（`name () {`、`function name {`、带缩进），逐字节比对的锚点
# 只认其中一种，于是「追加一份写法不同的覆盖定义」就能让行为退回去而门全绿——实测过。
count_definitions() {
    local file="$1" fn="$2"
    grep -cE "^[[:space:]]*(function[[:space:]]+)?${fn}[[:space:]]*\(?\)?[[:space:]]*\{" "$file" || true
}

echo "【① 三份拷贝逐字一致，且各只定义一次】"
[ -f "$LIB" ] || die_env "找不到正本 $LIB"
LIB_BLOCK=$(extract_block "$LIB")
[ -n "$LIB_BLOCK" ] || die_env "正本 $LIB 里一个被钉的函数都抠不到；要么改名了（请同步改 PINNED_FUNCS），要么删了"
echo "  正本 $LIB（$(printf '%s\n' "$LIB_BLOCK" | wc -l | tr -d ' ') 行 / $(echo $PINNED_FUNCS | wc -w | tr -d ' ') 个函数）"

for f in $LIB $COPIES scripts/upgrade.sh; do
    [ -f "$f" ] || { fail "$f 不存在"; continue; }
    for fn in $PINNED_FUNCS; do
        n=$(count_definitions "$f" "$fn")
        expect=1
        [ "$f" = "scripts/upgrade.sh" ] && expect=0     # 它 source 正本，不该自己再定义
        if [ "$n" != "$expect" ]; then
            fail "$f 里 ${fn} 被定义了 ${n} 次（期望 ${expect} 次）。bash 里后定义的赢，"
            echo "      追加一份覆盖定义就能让行为悄悄退回去，而逐字节比对看不出来。"
        fi
    done
done

for f in $COPIES; do
    [ -f "$f" ] || continue
    COPY_BLOCK=$(extract_block "$f")
    if [ "$COPY_BLOCK" = "$LIB_BLOCK" ]; then
        ok "$f 与正本逐字一致"
    else
        fail "$f 的内联副本与正本 $LIB 不一致，差异："
        diff <(printf '%s\n' "$LIB_BLOCK") <(printf '%s\n' "$COPY_BLOCK") | sed 's/^/      /'
    fi
done

echo
echo "【② 行为：五种形状 × 三份实现】"
docker info >/dev/null 2>&1 || die_env "连不上 docker daemon。只比对文本证明不了契约还在，所以这里不当「跳过」放行"

SUFFIX="$$"
LIVE="teslamate_${SUFFIX}"
DEAD="teslamate-${SUFFIX}"
IMGONLY="tm-by-image-${SUFFIX}"
IMGTAG="teslamate/teslamate:detect-selftest-${SUFFIX}"

cleanup() {
    docker rm -f "$LIVE" "$DEAD" "$IMGONLY" >/dev/null 2>&1 || true
    docker rmi "$IMGTAG" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# 宿主机洁净守卫。**用与被测代码无关的探针**——守卫要是调被测函数，被测函数瞎了守卫就跟着瞎，
# 还会把「被测代码看不见东西」说成「宿主机是干净的」。
# 这道守卫不是可有可无：不加的话，凡是在 dogfood 机、self-hosted runner、或任何真跑着
# TeslaMate 的机器上，这道门 100% 红，而红的话术会指着被测代码说它坏了。
DIRTY=$(docker ps -a --format '{{.Names}}	{{.Image}}' 2>/dev/null \
    | grep -iE '(^|[-_])teslamate([-_][0-9]+)?	|teslamate/teslamate' \
    | cut -f1 | grep -vxF "$LIVE" | grep -vxF "$DEAD" | grep -vxF "$IMGONLY" || true)
[ -z "$DIRTY" ] && ok "宿主机上没有别的 TeslaMate 形状容器" || die_env "宿主机上有别的 TeslaMate 形状容器，会混进检测结果：
$(printf '%s\n' "$DIRTY" | sed 's/^/      /')
    先停掉/删掉它们（docker rm -f <名字>），或换一台干净的机器再跑这道门。"

# 每份实现各自的探针：source 正本 / 从两个自包含脚本里抠出函数块 source 进子 shell。
# 只测正本等于放过了真正 curl|bash 发给用户的那两份——它们才是用户跑的东西。
probe() {   # $1 = 实现来源文件, $2 = 要问的函数
    local src="$1" fn="$2" tmp
    if [ "$src" = "$LIB" ]; then
        DC="no-compose-${SUFFIX}" bash -c "source '$LIB'; $fn" 2>/dev/null
    else
        tmp=$(mktemp)
        extract_block "$src" > "$tmp"
        DC="no-compose-${SUFFIX}" bash -c "source '$tmp'; $fn" 2>/dev/null
        rm -f "$tmp"
    fi
}

expect_status() {   # $1 = 场景名, $2 = 期望状态, $3 = 期望 name（留空表示必须为空）
    local label="$1" want_st="$2" want_name="$3" src st nm
    for src in $LIB $COPIES; do
        st=$(probe "$src" teslamate_container_status)
        nm=$(probe "$src" teslamate_container_name)
        if [ "$st" != "$want_st" ]; then
            fail "$label ／ $(basename "$src")：status=「${st}」，期望「${want_st}」"
        elif [ "$nm" != "$want_name" ]; then
            fail "$label ／ $(basename "$src")：name=「${nm}」，期望「${want_name}」"
        fi
    done
    [ "$FAILED" -eq 0 ] && ok "$label → status=${want_st} name=「${want_name}」（三份一致）"
}

# 场景 A：一个都没有
expect_status "A 没有任何候选" unknown ""

# 场景 B：只有一个运行中的
docker run -d --name "$LIVE" alpine sleep 600 >/dev/null 2>&1 || die_env "起不了样本容器 $LIVE"
expect_status "B 只有一个运行中的" running "$LIVE"

# 场景 C：运行中的 + 已停止的 → 不猜
# sleep 1 保证跨秒创建：docker ps -a 的亚秒排序是实现细节不是契约，别让判据踩在上面。
sleep 1
docker run --name "$DEAD" alpine true >/dev/null 2>&1 || die_env "起不了样本容器 $DEAD"
expect_status "C 一个运行中 + 一个已停止 → 拒绝猜测" ambiguous ""

# 场景 D：只剩已停止的 → 保护必须仍然看得见它
docker rm -f "$LIVE" >/dev/null 2>&1
expect_status "D 只剩已停止的（保护仍在）" exited "$DEAD"

docker rm -f "$DEAD" >/dev/null 2>&1

echo
echo "【③ 镜像档：名字完全不匹配，只有镜像对得上】"
# 这一档在注释里被点名「只有它能找到 teslamate-app」，却一直零覆盖：以前的样本容器
# 名字就命中第一档，镜像档一次都没被执行到。把镜像正则改坏（比如跟着上游把组织名从
# adriankumpf 换成 teslamate-org 时顺手改错）不会被任何断言逮到。
if docker tag alpine "$IMGTAG" >/dev/null 2>&1 \
   && docker run -d --name "$IMGONLY" "$IMGTAG" sleep 600 >/dev/null 2>&1; then
    for src in $LIB $COPIES; do
        nm=$(probe "$src" teslamate_container_name)
        [ "$nm" = "$IMGONLY" ] || fail "镜像档 ／ $(basename "$src")：name=「${nm}」，期望「${IMGONLY}」"
    done
    [ "$FAILED" -eq 0 ] && ok "名字不匹配、镜像匹配时仍探得到「${IMGONLY}」（三份一致）"
    docker rm -f "$IMGONLY" >/dev/null 2>&1
    docker rmi "$IMGTAG" >/dev/null 2>&1
else
    die_env "起不了镜像档样本容器（docker tag / run 失败）"
fi

echo
if [ "$FAILED" -ne 0 ]; then
    echo "✗ 容器检测一致性/行为检查未通过"
    exit 1
fi
echo "✓ 容器检测：三份逐字一致、各只定义一次；五种形状 × 三份实现行为一致；镜像档有覆盖"
