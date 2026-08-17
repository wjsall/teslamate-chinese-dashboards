#!/bin/bash
# TeslaMate 中文 Dashboard 一键安装脚本
# 5分钟完成 TeslaMate + 中文 Grafana Dashboard 部署

set -e
set -o pipefail

# 强制 docker compose project name = teslamate，
# 让容器名稳定为 teslamate-database-1 / teslamate-grafana-1 等，
# 与 README/QUICKSTART/TROUBLESHOOTING 文档里所有 docker exec 命令一致
export COMPOSE_PROJECT_NAME=teslamate

# ============================================================
# TARGET_REF：稳定安装的统一版本 ref —— 镜像 / SQL / backup.sh / config/versions.env
# 全部锁定同一个 ref，不会出现"正式版镜像 + main 分支 SQL"的混搭（详见 README「三种更新通道」）。
#
# 三条通道：
#   - 不传任何变量（默认）：自动解析 GitHub 最新正式 Release，SQL_REF / GRAFANA_IMAGE
#     都锁定这个 tag，镜像与 SQL 保证同版本。
#   - TARGET_REF=v1.8.4：显式锁定到指定正式版（不管当前最新版是多少）。
#   - TARGET_REF=main：滚动通道，SQL 与镜像都用 main 分支最新构建（CI 每次 push main 都
#     会构建一个 :main tag 镜像，与只在打正式 tag 时更新的 :latest 相互独立）。
#
# 优先级：单独设置 SQL_REF / GRAFANA_IMAGE 会覆盖 TARGET_REF 的推导结果（高级用户明确
# 要混搭版本时用，例如 CI 冒烟测试拿 SQL_REF=$GITHUB_SHA 配本次构建产物）；不单独设置
# 时两者都跟着 TARGET_REF 走。
#
# GitHub API 有速率限制（未认证 60 次/小时/IP）：先走 API，再走不吃限流的网页重定向
# 兜一次。两条都没解析出版本号（网络不通 / 代理拦截 / 仓库暂无 Release）就直接报错退出，
# 不会自动改用 main 分支——那等于让用户装上「正式版镜像 + 未发布 SQL」的混搭。
resolve_target_ref() {
    if [ -n "${TARGET_REF:-}" ]; then
        echo "ℹ️  TARGET_REF=${TARGET_REF}（用户指定，跳过自动解析）"
        return 0
    fi
    echo "🔍 解析最新正式 Release 版本..."
    local resp tag
    # 路子一：GitHub API。信息最全，但未认证时限流 60 次/小时/IP——国内共享出口、
    # 公司网络、NAS 都很容易撞上。
    resp=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/wjsall/teslamate-chinese-dashboards/releases/latest" 2>/dev/null) || resp=""
    # `|| true` 必须：resp 为空或没有 tag_name 字段时 grep -m1 找不到匹配会返回 1，
    # set -o pipefail 下会让整条管道判定失败，在 set -e 下直接终止脚本——不加这个会让
    # "API 不可达时的兜底"本身在兜底判断前就被 set -e 杀掉，兜底逻辑永远跑不到。
    tag=$(printf '%s' "$resp" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/') || true

    # 路子二：网页版 /releases/latest 会 302 到具体 tag，走的是普通网页通道、
    # 不吃 API 限流。API 被限流时这条通常还通，能救回绝大多数解析失败。
    if [ -z "$tag" ]; then
        echo "  · GitHub API 没解析出来（多半是限流），换免限流的方式再试一次"
        tag=$(curl -sSI --max-time 10 \
            "https://github.com/wjsall/teslamate-chinese-dashboards/releases/latest" 2>/dev/null \
            | grep -i '^location:' | tr -d '\r' | sed 's|.*/||') || true
        # 只接受 vX.Y.Z 形态，避免把 "latest"（没有任何 Release 时的重定向结果）当版本号用
        case "$tag" in
            v[0-9]*) : ;;
            *) tag="" ;;
        esac
    fi

    if [ -n "$tag" ]; then
        TARGET_REF="$tag"
        echo "  ✓ 最新正式版：${TARGET_REF}（SQL 锁定这个 tag，镜像用 latest——两者内容对齐同一版本）"
        return 0
    fi

    # 两条路都没解析出来 → 停下来，不猜。
    #
    # 这里曾经的做法是回退到 main：SQL 从 main 拉、镜像仍用 latest。那正好是版本契约
    # 明令禁止的混搭——用户拿到「正式版镜像 + 未发布的 SQL」，而这套组合从来没有被
    # 任何冒烟测试跑过。安装成功与否取决于此刻 main 上有没有半成品，这不该由一次
    # 网络抖动来决定。宁可让用户多打一个参数，也不要装出一套没人验证过的组合。
    echo ""
    echo "❌ 没能确定最新正式版本号（GitHub API 与网页两条路都没通）"
    echo ""
    echo "   常见原因：网络不通 GitHub、API 限流（未认证 60 次/小时/每 IP）、代理拦截。"
    echo ""
    echo "   两个办法，任选其一："
    echo "     1) 如果是限流（同一出口 IP 短时间请求多次），等一会儿再重试通常就好了"
    echo "     2) 如果是访问不了 GitHub（超时、被代理拦截、DNS 解析不了），等多久都没用，"
    echo "        直接指定版本号重跑；版本号可以从任意能打开 Releases 页面的设备上抄："
    echo "        https://github.com/wjsall/teslamate-chinese-dashboards/releases"
    echo "        TARGET_REF=v1.9.1 bash simple-deploy.sh"
    echo ""
    echo "   （不自动改用开发分支安装：那会让镜像和数据库脚本来自不同版本，"
    echo "     是这套版本机制专门要避免的组合。）"
    exit 1
}
# 只有 TARGET_REF 的推导结果会被实际用到时才发起网络请求：SQL_REF 和 GRAFANA_IMAGE
# 都已经被显式设置时（常见于 CI 冒烟测试，如 GRAFANA_IMAGE=teslamate-cn-ci:local
# SQL_REF=$GITHUB_SHA），TARGET_REF 不会被用在任何地方，跳过 GitHub API 调用，
# 避免给不需要它的调用方增加网络依赖 / API 限流风险。
#
# 记录 TARGET_REF 是否由用户显式传入——必须在 resolve_target_ref() 之前记，因为该函数
# 在未显式传入时会把解析结果写回 TARGET_REF 本身，之后就再也分不清"用户主动指定的版本"
# 和"自动解析出来的版本"。下面推导镜像 tag 要用这个区分（见下方注释）。
_TARGET_REF_EXPLICIT=0
[ -n "${TARGET_REF:-}" ] && _TARGET_REF_EXPLICIT=1
if [ -n "${SQL_REF:-}" ] && [ -n "${GRAFANA_IMAGE:-}" ]; then
    TARGET_REF="${TARGET_REF:-unused-both-refs-explicit}"
else
    resolve_target_ref
fi

# 镜像 tag 推导：
# - 用户显式传 TARGET_REF=main（滚动通道）→ 镜像用 :main，与同通道的 main 分支 SQL 配对。
# - 用户显式传 TARGET_REF=v1.8.4（钉具体版本）→ 镜像锁定该数字 tag，保证「镜像与 SQL
#   严格对齐到同一版本」这个显式钉版本场景的承诺（TROUBLESHOOTING.md「SQL 远程拉取的
#   信任模型」文档过的行为，不能破）。
# - 未显式传（默认通道，占绝大多数用户）→ 自动解析出的具体版本号只用来拉 SQL / 配套
#   脚本，镜像 tag 固定用 latest（解析不出版本号时 resolve_target_ref 已经报错退出，
#   走不到这里）。原因：
#   1）Docker Hub/GHCR 的 latest 只在打正式 tag 时才更新（ghcr-build.yml
#      type=raw,value=latest 只在 tag push 时 enable），语义上就是"当前最新正式版"，
#      与自动解析出的版本号等价。
#   2）latest 是可变 tag——升级模式的 `$DC pull` 之后会持续跟着新版本走；如果像早期
#      实现那样把解析出的具体版本号（如 :1.9.0）写进 compose，那是不可变 tag，装完
#      即永久停在当次版本，用户此后再怎么 pull 镜像都不会变，只有 SQL 会通过 upgrade
#      模式重新解析 TARGET_REF 往前走，造成镜像与 SQL 脱节、diagnose.sh 的 SQL revision
#      校验会指向错误的修复方向（应换镜像却提示重装 SQL）。
#   3）默认通道下镜像 tag 与"这次解析出了哪个版本号"无关，永远是 latest——一次 GitHub
#      API 抖动（未认证限流 60 次/小时/IP，NAS/公司共享出口 IP 很容易触发）不会把用户
#      从「最新正式版」这个更稳的默认通道悄悄挪到别的通道上去；真解析不出来时脚本是
#      直接停下报错，不会自己换通道。
if [ "$_TARGET_REF_EXPLICIT" = "1" ]; then
    if [ "$TARGET_REF" = "main" ]; then
        _DEFAULT_IMG_TAG="main"
    else
        _DEFAULT_IMG_TAG="${TARGET_REF#v}"
    fi
else
    _DEFAULT_IMG_TAG="latest"
fi

# SQL 文件拉取的 git ref（默认跟随 TARGET_REF；单独设置 SQL_REF 可覆盖，用于想让 SQL
# 和镜像版本分开锁定的高级场景，或 CI 冒烟测试拿具体 commit SHA）。
# 详见 README「SQL 远程拉取的信任模型」
SQL_REF="${SQL_REF:-$TARGET_REF}"
SQL_BASE="https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${SQL_REF}/sql"
# 仓库根 raw 基址（拉 scripts/backup.sh、config/versions.env 等非 SQL 文件用，与 SQL_REF
# 用同一个 ref——这两类文件必须来自同一次提交，否则 SQL_COMPAT_REVISION 校验会读到
# 不匹配的期望值）
REPO_BASE="https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${SQL_REF}"

# ============================================================
# 自举：确保真正执行的是**已发布版本**的这个脚本
#
# README 给用户的命令是 curl .../main/simple-deploy.sh | bash，所以拉到的脚本本体来自 main——
# 也就是说，SQL、辅助脚本、镜像都锁定到了正式版，唯独「安装逻辑本身」还是未发布代码。
# main 上的改动推上去那一刻就对所有新用户生效，而它此刻可能还没跑完冒烟测试。
#
# 这里在解析出正式版本号之后、做任何实际动作之前，换成那个 tag 下的同名脚本继续执行。
# 于是整套安装——脚本、SQL、镜像——全部来自同一次正式发布。
#
# 三个安全阀：
#   - TESLAMATE_CN_PINNED 防止无限自举（换过去的脚本带着这个变量，不会再换一次）
#   - 拉取失败就继续用当前这份（保持原有行为，不会因为网络问题装不了），但必须**说出来**：
#     拉不到正式版脚本的人，往往正是访问 GitHub 受限的那批，也就是最需要知道
#     "这次跑的安装逻辑来自开发分支"的人。静默继续等于把混搭藏起来。
#   - TARGET_REF=main（用户主动选滚动通道）时不自举，那是明确的意图
if [ -z "${TESLAMATE_CN_PINNED:-}" ] && [ "$TARGET_REF" != "main" ] \
   && [ "$TARGET_REF" != "unused-both-refs-explicit" ]; then
    _pinned=$(mktemp "${TMPDIR:-/tmp}/teslamate-cn-deploy.XXXXXX" 2>/dev/null) || _pinned=""
    if [ -n "$_pinned" ] && curl -fsSL --max-time 30 "$REPO_BASE/simple-deploy.sh" -o "$_pinned" 2>/dev/null \
       && [ -s "$_pinned" ] && head -1 "$_pinned" | grep -q '^#!/bin/bash'; then
        echo "  ↻ 改用 ${TARGET_REF} 版本的安装脚本继续（保证脚本与 SQL、镜像同版本）"
        export TESLAMATE_CN_PINNED=1
        export TARGET_REF
        exec bash "$_pinned" "$@"
    fi
    [ -n "$_pinned" ] && rm -f "$_pinned"
    # 走到这里 = 没能取到 ${TARGET_REF} 版本的安装脚本（下载失败，或本机临时目录不可写）。
    # 继续装是有意为之：拉不到就干脆不装，比这个更糟。但要说清楚现在是什么状态。
    echo ""
    echo "  ⚠️  没能下载 ${TARGET_REF} 版本的安装脚本，本次继续用当前这份脚本安装。"
    echo "     影响：数据库脚本和镜像仍然锁定 ${TARGET_REF}，但真正在跑的是当前这份脚本——"
    echo "     按 README 的一键命令安装时它来自开发分支 main，不是 ${TARGET_REF} 发布时"
    echo "     验证过的那一份。绝大多数情况下装出来是一样的。"
    echo "     想要完全一致的话：先把脚本下到本地再跑（在网络能通的机器上下载后拷过来也行）"
    echo "       curl -fsSL -o simple-deploy.sh \\"
    echo "         https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${TARGET_REF}/simple-deploy.sh"
    echo "       bash simple-deploy.sh"
    echo ""
fi

# 端口配置（支持环境变量覆盖，端口冲突时用：TM_PORT=14000 GF_PORT=13000 bash simple-deploy.sh）
TM_PORT="${TM_PORT:-4000}"
GF_PORT="${GF_PORT:-3000}"

# Grafana 镜像（默认通道用 :latest，显式 TARGET_REF 时跟随上面推导出的 tag，见上方
# _DEFAULT_IMG_TAG 说明；单独设置 GRAFANA_IMAGE 可覆盖，例如 CI 冒烟测试想验证本次构建
# 产物而非已发布镜像：GRAFANA_IMAGE=ghcr.io/wjsall/teslamate-chinese-dashboards:pr-123
# bash simple-deploy.sh）
GRAFANA_IMAGE="${GRAFANA_IMAGE:-bswlhbhmt816/teslamate-chinese-dashboards:${_DEFAULT_IMG_TAG}}"

# DRY_RUN=1：只打印本次会用到的所有远程 URL / 镜像 tag，不做任何 docker/系统改动。
# 用于验证"稳定安装时所有远程 URL 指向同一 ref"（Gate F，见 README 三种通道说明）。
if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "TARGET_REF=${TARGET_REF}"
    echo "SQL_REF=${SQL_REF}"
    echo "GRAFANA_IMAGE=${GRAFANA_IMAGE}"
    echo "SQL_BASE=${SQL_BASE}"
    echo "REPO_BASE=${REPO_BASE}"
    echo "urls:"
    echo "  ${SQL_BASE}/install-coord-functions.sql"
    echo "  ${SQL_BASE}/install-unit-functions.sql"
    echo "  ${SQL_BASE}/install-tou.sql"
    echo "  ${SQL_BASE}/install-indexes.sql"
    echo "  ${REPO_BASE}/scripts/backup.sh"
    echo "  ${REPO_BASE}/config/versions.env"
    exit 0
fi

# SQL 安装的 stderr 落盘：加了 ON_ERROR_STOP=1 之后，psql 的 ERROR 行就是排查唯一线索，
# 不能再像以前那样一起丢进 /dev/null（用户只看到「⚠ 装失败」，既没法自查也没法贴 issue）。
# 用 mktemp 而不是固定路径：固定路径在「先 sudo 跑过一次、之后不带 sudo 重跑」时会是
# root 属主，truncate 直接 Permission denied，而这行在 set -e 下会让脚本零解释猝死。
# mktemp 也失败就退到 /dev/null——丢日志可以接受，装不了不行。
SQL_ERR_LOG=$(mktemp "${TMPDIR:-/tmp}/teslamate-cn-sql-install.XXXXXX" 2>/dev/null) || SQL_ERR_LOG=/dev/null

# 旧版留下的 charging_processes_v 对账视图这次没能删掉（三种情形见 sql/install-tou.sql
# 2f 节）。本脚本没有 WARN_STEPS 那种告警数组，只有 SQL_OK / UPGRADE_SQL_OK 一个「装没装
# 成功」的二值开关——而这一条既不是「装失败」（我们该装的都装完了），也不能算「没事」：
# 它会阻断**用户的下一步**，TeslaMate 升到 4.1.1 时那句
#   ALTER TABLE charging_processes ALTER COLUMN cost TYPE numeric(14,2)
# 会被 PostgreSQL 拒绝，TeslaMate 起不来、容器反复重启、行车和充电全部停止记录。
# 所以这里给结尾横幅补出第三档「装完了但留了尾巴」：退出码保持 0（我们的活确实干完了，
# 不该让自动化把一次好的安装当成失败回滚），但横幅必须变、必须把后果写出来。
# 以前这句提示只在中间段落 echo 一行，结尾照打「✅ 安装完成！」——用户不可能看见。
LEGACY_VIEW_PENDING=0

# TeslaMate 容器当前状态（running / restarting / exited / unknown）。
# 等待函数必须看这个：崩溃重启中的 TeslaMate，schema_migrations 行数同样是恒定不变的，
# 只看行数会把「迁移撞崩、永久停在半途」判成「迁移已完成」，然后继续装 SQL、把问题坐实。
# 找 TeslaMate 主容器。三级探测，一级比一级不依赖命名约定：
#   ① compose 自己报（用户改过 project 名也准）
#   ② 名字正则（兼容没跑在 compose 里的情况）
#   ③ 按镜像找（用户给容器起了完全不相干的名字时的兜底）
# 探不到会让下面的存活判据退化成「不判」，所以这里要尽量探得到——实测过：容器叫
# teslamate-app 时只有 ③ 能找到，而少了它，一个正在崩溃重启的 TeslaMate 会被当成健康。
# 列出**全部**候选，不是挑一个。$1 = running（只看运行中）/ all（含已停止）。
# 刻意不用数组：NAS 和 macOS 上还有 Bash 3.2。
_teslamate_scan() {
    local scope="$1" rows="" by_name=""
    if [ "$scope" = "all" ]; then
        rows=$(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null || true)
    else
        rows=$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null || true)
    fi
    by_name=$(printf '%s\n' "$rows" | cut -f1 \
        | grep -iE '(^|[-_])teslamate([-_][0-9]+)?$' \
        | grep -viE 'database|postgres|grafana|mosquitto' || true)
    if [ -n "$by_name" ]; then
        printf '%s\n' "$by_name"
        return 0
    fi
    printf '%s\n' "$rows" \
        | grep -iE '(^|[[:space:]])teslamate/teslamate(:|[[:space:]]|$)' \
        | cut -f1 || true
}

# 候选清单。compose 给得出答案就用它——它知道自己的 project，唯一且权威。
# 否则**把运行中的和已停止的一起列出来**，不做任何偏好。
#
# 这里刻意不写「运行中优先」：那样会把一个已经崩掉的真身藏起来。实测过这个形状——
# 用户的 TeslaMate 已退出，旁边有个更早创建、仍在运行的同名残留（没停干净的旧栈、
# 上一次部署、迁移过程中还没下线的官方栈），「运行中优先」会确定性地选中那个健康的假货，
# 判定「迁移已完成」→ 照装 install-unit-functions.sql → 撞上游那条不带 OR REPLACE 的迁移 →
# duplicate_function → TeslaMate 从此反复重启，而且重跑脚本也修不好。
# 少列一个候选的代价，比多列一个大得多。
teslamate_container_candidates() {
    local c=""
    c=$(${DC:-docker compose} ps -q teslamate 2>/dev/null | head -1 || true)
    if [ -n "$c" ]; then
        printf '%s\n' "$c"
        return 0
    fi
    _teslamate_scan all | grep -v '^[[:space:]]*$' || true
    return 0
}

_teslamate_candidate_count() {
    teslamate_container_candidates | grep -c '[^[:space:]]' || true
}

# 唯一候选才返回名字。**多个候选一律返回空——不猜。**
#
# 为什么不能猜：这个名字最终决定「TeslaMate 自己的迁移做完没有」，而那一步决定要不要装
# install-unit-functions.sql。装早了会让上游那条不带 OR REPLACE 的迁移撞 duplicate_function，
# TeslaMate 从此反复重启、重跑脚本也修不好。两种猜法各有一侧会输：
#   按创建时间挑 → 用户的 TeslaMate 在跑、旁边躺着个更晚创建的死容器 → 误判成"起不来"，
#                  跳过单位换算函数并报「✗ 升级失败」（红横幅，用户能重跑，可自愈）；
#   按"运行中优先"挑 → 用户的 TeslaMate 已经崩了、旁边有个更早创建仍在跑的同名残留 →
#                  误判成"健康"，照装不误 → 撞上面那个不可自愈的坑。
# 所以多候选时不选边，交给 teslamate_container_status 报 ambiguous，由调用方按"确认不了"处理。
teslamate_container_name() {
    local list count
    list=$(teslamate_container_candidates)
    count=$(_teslamate_candidate_count)
    if [ "${count:-0}" -eq 1 ]; then
        printf '%s\n' "$list" | grep '[^[:space:]]' | head -1
        return 0
    fi
    echo ""
}

# 状态。0 个候选 → unknown；多个 → ambiguous（调用方必须按"确认不了"对待，不能当健康）。
teslamate_container_status() {
    local c count
    count=$(_teslamate_candidate_count)
    if [ "${count:-0}" -eq 0 ]; then
        echo unknown
        return 0
    fi
    if [ "${count:-0}" -gt 1 ]; then
        echo ambiguous
        return 0
    fi
    c=$(teslamate_container_name)
    docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo unknown
}

# TeslaMate 实际映射到宿主机的端口（拿不到就空）。用它而不是写死 4000：
# 用户可能用 TM_PORT 装在别的端口上，写死会探到无关服务、让等待瞬间"成功"。
teslamate_published_port() {
    local c p=""
    c=$(teslamate_container_name)
    [ -z "$c" ] && return 0
    p=$(docker port "$c" 4000/tcp 2>/dev/null | head -1 | sed 's/.*://')
    echo "$p"
}

wait_teslamate_migrated() {
    local db_container="$1"
    local i cur last="" stable=0 code tm_st tm_port bad=0

    # ① 等上游核心表出现（最多 180 秒；镜像已拉好的情况下通常 10-30 秒）
    for i in $(seq 1 60); do
        if docker exec "$db_container" psql -U teslamate -d teslamate -tAc \
            "SELECT 1 FROM pg_class WHERE relname='charging_processes'" 2>/dev/null | grep -qx 1; then
            break
        fi
        tm_st=$(teslamate_container_status)
        if [ "$tm_st" = "restarting" ] || [ "$tm_st" = "exited" ] || [ "$tm_st" = "ambiguous" ]; then
            bad=$((bad + 1))
            if [ "$bad" -ge 3 ]; then
                if [ "$tm_st" = "ambiguous" ]; then
                    echo "    ✗ 机器上有多个可能是 TeslaMate 的容器，认不出哪个是你正在用的："
                    teslamate_container_candidates | sed 's/^/          /'
                    echo "      为避免猜错，这一步按「确认不了」处理。请删掉用不上的那些（docker rm 名字），"
                    echo "      或在 TeslaMate 所在目录重跑本脚本，让 compose 直接给出答案。"
                    return 1
                fi
                echo "    ✗ TeslaMate 容器状态为 ${tm_st}（反复重启/已退出），它的迁移不可能完成"
                echo "      先看 docker logs 排掉 TeslaMate 自身的启动问题，再重跑本脚本"
                return 1
            fi
        else
            bad=0
        fi
        [ $((i % 10)) -eq 0 ] && echo "    …仍在等 TeslaMate 建表（已等 $((i * 3)) 秒，容器状态 ${tm_st}）"
        sleep 3
    done
    # 第一段跑完还没 break，说明表始终没出现——这时再进第二段也只会白等一个 180 秒的
    # 超时（实测总耗时 400 秒+）。直接返回"确认不了"，让调用方走跳过分支。
    if ! docker exec "$db_container" psql -U teslamate -d teslamate -tAc \
        "SELECT 1 FROM pg_class WHERE relname='charging_processes'" 2>/dev/null | grep -qx 1; then
        echo "  ✗ 等了 3 分钟，TeslaMate 仍未建好自己的数据表，无法确认迁移状态。"
        return 1
    fi


    # ② 主判据：TeslaMate 的 HTTP 端口能应答（最多 180 秒）
    #    次判据：schema_migrations 行数连续 8 次采样（24 秒）不变
    for i in $(seq 1 60); do
        tm_port=$(teslamate_published_port)
        if [ -n "$tm_port" ] && command -v curl >/dev/null 2>&1; then
            code=$(curl -sS --noproxy '*' -m 3 -o /dev/null -w '%{http_code}' \
                "http://127.0.0.1:${tm_port}/" 2>/dev/null)
            if [ -n "$code" ] && [ "$code" != "000" ]; then
                return 0
            fi
        fi
        tm_st=$(teslamate_container_status)
        if [ "$tm_st" = "restarting" ] || [ "$tm_st" = "exited" ] || [ "$tm_st" = "ambiguous" ]; then
            bad=$((bad + 1))
            if [ "$bad" -ge 3 ]; then
                if [ "$tm_st" = "ambiguous" ]; then
                    echo "    ✗ 机器上有多个可能是 TeslaMate 的容器，认不出哪个是你正在用的："
                    teslamate_container_candidates | sed 's/^/          /'
                    echo "      为避免猜错，这一步按「确认不了」处理。请删掉用不上的那些（docker rm 名字），"
                    echo "      或在 TeslaMate 所在目录重跑本脚本，让 compose 直接给出答案。"
                    return 1
                fi
                echo "    ✗ TeslaMate 容器状态为 ${tm_st}（反复重启/已退出），迁移停在半途"
                echo "      先看 docker logs 排掉 TeslaMate 自身的启动问题，再重跑本脚本"
                return 1
            fi
            stable=0
            last=""
            sleep 3
            continue
        fi
        bad=0
        cur=$(docker exec "$db_container" psql -U teslamate -d teslamate -tAc \
            "SELECT count(*) FROM schema_migrations" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$cur" ] && [ "$cur" = "$last" ]; then
            stable=$((stable + 1))
            if [ "$stable" -ge 8 ]; then
                return 0
            fi
        else
            stable=0
        fi
        last="$cur"
        [ $((i % 10)) -eq 0 ] && echo "    …仍在等 TeslaMate 完成迁移（已等 $((i * 3)) 秒，大库首次迁移会久一些）"
        sleep 3
    done
    return 1
}

# 三组兼容性 SQL 的对象是否真的在库里——记 revision 之前的最后一道校验。
#
# 为什么不能只信 psql 的退出码：psql 默认不是 ON_ERROR_STOP，脚本里某条语句失败它
# 照样 exit 0。本项目 2026-07 冒烟①就是这么假绿的——「✓ 分时电价表已装」印出来了、
# revision 也记了 1，实际 tou_rates 压根没建成。安装调用现在都加了 ON_ERROR_STOP=1，
# 这里再按对象查一遍作为第二道闸：revision 的全部意义就是「库里到底有没有」，
# 那就直接问库，不要转手信任任何中间信号。
# 谓词与 scripts/diagnose.sh 第 4 节语义一致（同样的三组对象、同样的哨兵），但不是逐字相同：
# 这几个脚本是 curl-piped 单文件、不能 source 公共库，各自内联了一份。改任何一处务必同步全部
# 四处（simple-deploy.sh / migrate-from-official.sh / scripts/upgrade.sh / scripts/diagnose.sh）。
sql_trio_objects_present() {
    local db_container="$1"
    docker exec "$db_container" psql -U teslamate -d teslamate -tAc \
        "SELECT count(DISTINCT proname) FROM pg_proc WHERE proname IN ('lat_for_map','lng_for_map','wgs84_to_gcj02_lat','wgs84_to_gcj02_lng','is_outside_china')" \
        2>/dev/null | grep -qx 5 || return 1
    # 只数 proname 是查不出东西的：convert_km/convert_celsius/convert_m/convert_tire_pressure
    # 这四个名字上游 TeslaMate 自己的迁移就会建（这正是"抢先建会撞车"的前提），所以任何迁移
    # 完成的库上那个计数都恒等于 4——这一腿等于没查。改查我们这版独有的特征：只有我们的
    # convert_tire_pressure 支持 kPa/kpa 单位。它又是 install-unit-functions.sql 的最后一个
    # 函数，装到它就说明整份文件都装完了，正好当哨兵。
    docker exec "$db_container" psql -U teslamate -d teslamate -tAc \
        "SELECT count(*) FROM pg_proc WHERE proname = 'convert_tire_pressure' AND prosrc LIKE '%kPa%'" \
        2>/dev/null | grep -qE '^[1-9][0-9]*$' || return 1
    docker exec "$db_container" psql -U teslamate -d teslamate -tAc \
        "SELECT 1 FROM pg_class WHERE relname='tou_rates'" \
        2>/dev/null | grep -qx 1 || return 1
    return 0
}

# SQL 兼容性 revision 记录（issue #23/#29 事故预防：镜像更新了但 SQL 没装的机制性校验）
#
# 只在坐标函数 + 单位换算函数 + 分时电价三组 SQL **全部**安装成功后调用（不含性能索引，
# 索引失败是 WARN，不影响这个 revision）。写入 teslamate_cn_extension_meta 表，
# scripts/diagnose.sh 用它比对镜像要求的 revision（config/versions.env，随镜像一起装进
# /opt/teslamate-cn/versions.env）和数据库里实际装到的 revision，不一致就报 DEGRADED。
#
# CREATE TABLE IF NOT EXISTS 是自愈的关键：老用户的数据库压根没有这张表，本函数第一次
# 跑起来时会自动建表 + 写入当前 revision，不需要任何手动迁移步骤、不会报错。
#
# 单一事实源是仓库里的 config/versions.env；本脚本是 curl-piped 单文件脚本，不能 source
# 本地文件，现场用同一个 SQL_REF 从 REPO_BASE 拉取，跟拉 SQL 文件同一套信任模型，避免在
# 这里手动硬编码数字造成漂移。
write_sql_compat_revision() {
    local db_container="$1"
    local rev ver_safe
    if ! sql_trio_objects_present "$db_container"; then
        echo "  ⚠ 三组兼容性 SQL 的对象没在库里查到，不记录 revision（跑 scripts/diagnose.sh 看缺哪一组）"
        # 返回 2 而不是 1：调用方据此把整体结论也置成失败。返回 1 留给「拉不到 revision
        # 数字」这种不影响已装好功能的情况。闸门真拦下东西时还打「✅ 安装完成」+ exit 0，
        # 正是这批改动要根除的「结论比证据乐观」。
        return 2
    fi
    rev=$(curl -fsSL "$REPO_BASE/config/versions.env" 2>/dev/null \
        | grep -m1 '^SQL_COMPAT_REVISION=' | cut -d= -f2 | tr -d '[:space:]\r') || true
    if [ -z "$rev" ]; then
        echo "  ⚠ 拉取 SQL 兼容性 revision 失败（网络问题？），跳过记录——不影响刚装好的 SQL 功能本身"
        return 1
    fi
    ver_safe="${SQL_REF//\'/}"
    if docker exec -i "$db_container" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQLEOF
CREATE TABLE IF NOT EXISTS teslamate_cn_extension_meta (
    id              INTEGER PRIMARY KEY DEFAULT 1,
    sql_revision    INTEGER NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    project_version TEXT,
    CONSTRAINT teslamate_cn_extension_meta_singleton CHECK (id = 1)
);
INSERT INTO teslamate_cn_extension_meta (id, sql_revision, updated_at, project_version)
VALUES (1, ${rev}, now(), '${ver_safe}')
ON CONFLICT (id) DO UPDATE SET
    sql_revision    = EXCLUDED.sql_revision,
    updated_at      = EXCLUDED.updated_at,
    project_version = EXCLUDED.project_version;
SQLEOF
    then
        echo "  ✓ SQL 兼容性 revision 已记录（${rev}）"
        return 0
    else
        echo "  ⚠ SQL 兼容性 revision 记录失败（不影响刚装好的 SQL 功能本身，diagnose 之后可能误报过期）"
        return 1
    fi
}

# 装完分时电价 SQL 之后**无条件**回算一次历史充电费用。
#
# 为什么必须在这里做：install-tou.sql 内部也有一次回算，但它被包在「删掉了旧版写进
# tou_rates 的全天规则」这个条件里。真正配了峰谷时段、踩了「电价缺口被当成 0 元算」
# 那个 bug 的用户，一条旧规则都没有，那次回算一次都不会跑——算法修好了，库里那批用
# 旧算法算出的低估值却没人清，界面继续显示错数。回算是唯一能清掉它们的动作。
#
# 大库上要几十秒，所以动手之前先说一句，别让用户以为卡住了。
run_tou_backfill() {
    local db_container="$1"
    local default_note
    local view_note
    echo "  → 重算历史充电的分时电价费用（充电记录多的话要几十秒，请稍候）"
    if ! docker exec -i "$db_container" psql -U teslamate -d teslamate -At -v ON_ERROR_STOP=1 \
            -c "SELECT format('  ✓ 已扫描 %s 笔充电，按分时电价算出 %s 笔，跳过 %s 笔（没有适用的分时电价规则）', processed, updated, skipped)
                    || CASE WHEN cleared > 0 THEN format(E'\n    · 其中 %s 笔原先存着按旧算法算出的费用，已清除；这些充电现在按 TeslaMate 记录的金额或默认电价显示，跟升级前会不一样', cleared) ELSE '' END
                    || CASE WHEN gapped  > 0 THEN format(E'\n    · %s 笔充电有时段没被你配的分时电价规则覆盖，算不出可信金额；想让它们按分时电价计费，去「⚡ 分时电价配置」仪表盘的「配置审计」看缺哪几个小时', gapped) ELSE '' END
                    || CASE WHEN sampling_gapped > 0 THEN format(E'\n    · %s 笔充电因采样断档跨过不同电价，无法可靠计算分时金额；这不是你的电价配置问题，也不需要修改配置，这些充电的费用已保持原样', sampling_gapped) ELSE '' END
                    || CASE WHEN failed  > 0 THEN format(E'\n    ⚠ %s 笔充电回算时出错，已跳过；这些充电的费用维持原样，可稍后手动跑 SELECT * FROM backfill_all_tou(); 重试', failed) ELSE '' END
                    FROM backfill_all_tou();" 2>>"$SQL_ERR_LOG"; then
        echo "  ⚠ 重算失败（不影响已装好的功能，可稍后手动跑 SELECT * FROM backfill_all_tou();）"
    fi
    # 两类提示是两个独立待办，分别读取：默认电价迁移那句话不能覆盖「旧版对账视图还没清掉」
    # 这句——后者不处理，TeslaMate 升到 4.1.1 会起不来，比前者严重得多。
    default_note=$(docker exec -i "$db_container" psql -U teslamate -d teslamate -At \
        -c "SELECT legacy_default_note FROM tou_settings WHERE legacy_default_note IS NOT NULL" 2>/dev/null) || default_note=""
    if [ -n "$default_note" ]; then
        echo "  $default_note"
    fi
    view_note=$(docker exec -i "$db_container" psql -U teslamate -d teslamate -At \
        -c "SELECT view_rebuild_note FROM tou_settings WHERE view_rebuild_note IS NOT NULL" 2>/dev/null) || view_note=""
    if [ -n "$view_note" ]; then
        echo "  $view_note"
        # 只 echo 不记账 = 结尾还是绿色「✅ 安装完成！」，用户以为没事，然后 TeslaMate
        # 起不来还找不到线索。必须让结尾横幅变色（见文件末尾两处汇总）。
        LEGACY_VIEW_PENDING=1
    fi
    return 0
}

# 「旧版对账视图没删掉」在两条路径（升级 / 全新安装）的结尾横幅里都要单独讲一段。
print_legacy_view_warning() {
    [ "$LEGACY_VIEW_PENDING" -eq 1 ] || return 0
    echo "   ⚠ 有一件事必须你亲自处理：数据库里那个旧版建的对账视图 charging_processes_v"
    echo "     这次没能删掉（原因见上面那段提示）。不处理会怎样：TeslaMate 升到 4.1.1 时"
    echo "     会启动失败、容器反复重启，行车和充电将全部停止记录。其余部分不受影响。"
    echo "     怎么做：照上面那段提示处理掉，然后重跑一次本脚本；那句提示会自己消失，"
    echo "     消失了才算处理干净。"
}

echo "=============================================="
echo "  TeslaMate 中文版 — Tesla 车主数据看板"
echo "=============================================="
echo ""
echo "📊 装完你能看到："
echo "  - 每次行程地图回放（高德/谷歌切换，国内不偏移）"
echo "  - 充电记录 + 分时电价省钱分析"
echo "  - 电池健康 / 续航衰减 / 回本分析"
echo "  - 45 个中文仪表盘（年度报告、多车对比、驾驶评分等）"
echo ""
echo "⏱️  耗时 5-10 分钟  💾 数据全在你机器上，不上传第三方"
echo ""
echo "📌 装完用 Auth for Tesla App 拿 access_token + refresh_token，"
echo "   到 TeslaMate 主页粘贴绑车（详见 QUICKSTART.md 第四步）。"
echo ""

# 检测平台用于 Docker 缺失时的 OS 适配安装方式
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos"; return ;;
        Linux) ;;
        *) echo "other"; return ;;
    esac
    if [ -f /etc/synoinfo.conf ]; then echo "synology"; return; fi
    if [ -f /etc/os-release ]; then
        local id
        id=$(. /etc/os-release; echo "$ID")
        case "$id" in
            ubuntu|debian|raspbian|centos|rhel|fedora|rocky|almalinux|linuxmint|pop)
                echo "linux-supported"; return ;;
        esac
    fi
    echo "linux-unknown"
}

PLATFORM=$(detect_platform)

# 检测是否在云主机上（AWS/GCP/Azure/阿里云/腾讯云/华为云等）
# 用于发版后提醒用户加固，不改默认行为
detect_cloud() {
    local vendor="" product=""
    [ -r /sys/class/dmi/id/sys_vendor ] && vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
    [ -r /sys/class/dmi/id/product_name ] && product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    case "${vendor}${product}" in
        *Google*|*Amazon*|*EC2*|*Microsoft*|*Alibaba*|*Tencent*|*HUAWEI*|*Huawei*|*Oracle*|*Vultr*|*DigitalOcean*|*Linode*|*Hetzner*)
            echo "cloud"; return ;;
    esac
    # metadata 端点（link-local，云厂商通用）— 1 秒内连得通基本是云
    # 不用 -f：AWS IMDSv2 默认对裸 GET 返 401，但 401 也证明端点存在；--noproxy 防止 SSRF 路径被 $http_proxy 接管
    if curl -sS --max-time 1 --noproxy '*' -o /dev/null http://169.254.169.254 2>/dev/null; then
        echo "cloud"; return
    fi
    echo "physical"
}

IS_CLOUD=$(detect_cloud)

# Linux 上一键装 Docker（用 docker.com 官方脚本，覆盖主流发行版）
install_docker_linux() {
    echo "🚀 正在安装 Docker（用 docker.com 官方一键脚本，1-2 分钟）..."
    local sudo_cmd=""
    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "❌ 当前不是 root 也没 sudo，请用 root 重跑此脚本"
            return 1
        fi
        sudo_cmd="sudo "
    fi
    if ! curl -fsSL https://get.docker.com | ${sudo_cmd}sh; then
        echo "❌ Docker 安装失败"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        ${sudo_cmd}systemctl enable --now docker >/dev/null 2>&1 || true
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "⚠️ Docker 已装但 daemon 没起（可能需要重启系统后再跑此脚本）"
        return 1
    fi
    echo "✅ Docker 已就绪"
    echo ""
}

# ============================================================
# 备份：把 backup.sh 拉到 $INSTALL_DIR，并（可选）设置每日定时备份。
# fresh-install 和 upgrade 两条路径都会调用。
# 设计约束：一键用户不 clone 仓库 → 本地没有 scripts/backup.sh，必须 curl 下来；
#          群晖 DSM 不认普通 crontab（程序化设置不持久）→ 改打印 DSM 任务计划步骤。
# ============================================================
setup_backup() {
    echo ""
    echo "💾 定期备份数据库（行车历史丢了不可逆，强烈建议）"

    # 1. 必修：拉/刷新备份脚本到本地（单文件即可跑，内置容器探测兜底）
    local backup_tmp
    if ! backup_tmp=$(mktemp "$INSTALL_DIR/.backup.sh.XXXXXX"); then
        echo "  ⚠ 无法创建临时文件，保留现有 $INSTALL_DIR/backup.sh"
        return 0
    fi
    if ! curl -fsSL "$REPO_BASE/scripts/backup.sh" -o "$backup_tmp" 2>/dev/null; then
        rm -f "$backup_tmp"
        echo "  ⚠ 备份脚本下载失败。手动拉：curl -fsSL $REPO_BASE/scripts/backup.sh -o $INSTALL_DIR/backup.sh"
        return 0
    fi
    if ! bash -n "$backup_tmp"; then
        rm -f "$backup_tmp"
        echo "  ⚠ 下载的备份脚本语法校验失败，保留现有 $INSTALL_DIR/backup.sh"
        return 0
    fi
    mv "$backup_tmp" "$INSTALL_DIR/backup.sh"
    chmod +x "$INSTALL_DIR/backup.sh"
    echo "  ✓ 备份脚本已就位：$INSTALL_DIR/backup.sh"

    local BK_DIR CRON_LINE choice inc_key KEY_ENV
    BK_DIR="$INSTALL_DIR/backups"
    inc_key=1   # 默认含密钥（备份能独立恢复）

    # 已设过定时（通用 Linux）→ 不再追问，避免每次升级都问
    if [ "$PLATFORM" != "synology" ] && command -v crontab >/dev/null 2>&1 \
        && crontab -l 2>/dev/null | grep -Fq "$INSTALL_DIR/backup.sh"; then
        echo "  ✓ 已有每日定时备份任务（crontab -l 可查），脚本已更新到最新"
        echo "    （想改成不含密钥：crontab -e 在该行命令最前面加 INCLUDE_CONFIG=0）"
        return 0
    fi

    # 2. 交互：是否设置每日自动备份 + 备份是否含密钥（一个菜单三选一，免去手敲 env）
    if [ "${AUTO_BACKUP:-}" = "1" ]; then
        # 非交互授权：默认含密钥；想不含则同时传 INCLUDE_CONFIG=0
        [ "${INCLUDE_CONFIG:-1}" = "0" ] && inc_key=0
        choice="set"
    elif [ -t 0 ]; then
        echo "  设置每日 03:00 自动备份？"
        echo "    1) 是，备份含密钥   —— 推荐：换机 / 重装也能用这一份备份独立恢复，不用记那串复杂密钥"
        echo "    2) 是，备份不含密钥 —— 更私密，但你必须自己另存 ENCRYPTION_KEY，否则恢复后 token 解不开"
        echo "    3) 否，暂不设置"
        read -r -p "  请选择 [1/2/3]（默认 1）：" choice || choice=""
        case "${choice:-1}" in
            2) inc_key=0; choice="set" ;;
            3) choice="skip" ;;
            *) inc_key=1; choice="set" ;;
        esac
    else
        # 非交互（curl|bash）：不擅自设定时，给指引
        echo "  ℹ 非交互模式跳过定时设置。启用：AUTO_BACKUP=1 重跑本脚本（默认含密钥，不含再加 INCLUDE_CONFIG=0），或见 TROUBLESHOOTING.md#db-backup"
        return 0
    fi

    if [ "$choice" = "skip" ]; then
        echo "  已跳过自动备份。以后想设见 TROUBLESHOOTING.md#db-backup"
        return 0
    fi

    # 不含密钥 → 命令最前面加 INCLUDE_CONFIG=0
    KEY_ENV=""
    [ "$inc_key" = "0" ] && KEY_ENV="INCLUDE_CONFIG=0 "
    CRON_LINE="0 3 * * * ${KEY_ENV}BACKUP_DIR=\"$BK_DIR\" KEEP=7 bash \"$INSTALL_DIR/backup.sh\" >> \"$BK_DIR/cron.log\" 2>&1"

    mkdir -p "$BK_DIR"

    if [ "$PLATFORM" = "synology" ]; then
        # 群晖：程序化写 crontab 不持久，改打印 DSM 任务计划步骤
        echo "  📋 群晖请用 DSM 任务计划（DSM 不认普通 crontab）："
        echo "     控制面板 ▸ 任务计划 ▸ 新增 ▸ 计划的任务 ▸ 用户定义的脚本"
        echo "     用户 root，每天 03:00，运行命令（整行复制）："
        echo "       ${KEY_ENV}BACKUP_DIR=\"$BK_DIR\" KEEP=7 bash \"$INSTALL_DIR/backup.sh\""
    elif ! command -v crontab >/dev/null 2>&1; then
        echo "  ⚠ 系统没有 crontab，无法自动设置。手动定时见 TROUBLESHOOTING.md#db-backup"
        echo "    备份命令：${KEY_ENV}BACKUP_DIR=\"$BK_DIR\" KEEP=7 bash \"$INSTALL_DIR/backup.sh\""
    else
        ( crontab -l 2>/dev/null; echo "$CRON_LINE" ) | crontab -
        echo "  ✓ 已设每日 03:00 自动备份 → ${BK_DIR}（保留 7 份）"
        echo "    查看：crontab -l    日志：$BK_DIR/cron.log"
    fi

    if [ "$inc_key" = "1" ]; then
        echo "  ℹ 备份含 docker-compose.yml（密钥）→ 能独立恢复；请保证备份目录私密、别公开分享"
    else
        echo "  ⚠ 你选了「不含密钥」→ 请务必自己另存 ENCRYPTION_KEY（在 $INSTALL_DIR/docker-compose.yml），否则恢复后 token 解不开"
    fi
}

# 检查 Docker 和 Docker Compose
if ! command -v docker &> /dev/null; then
    echo "ℹ️ Docker 未安装"
    case "$PLATFORM" in
        linux-supported)
            if [ "${AUTO_INSTALL_DOCKER:-}" = "1" ]; then
                install_docker_linux || exit 1
            elif [ -t 0 ]; then
                echo ""
                read -r -p "是否自动安装 Docker？[Y/n] " ans
                ans=${ans:-Y}
                if [[ "$ans" =~ ^[Yy] ]]; then
                    install_docker_linux || exit 1
                else
                    echo "已取消。手动安装后重跑此脚本："
                    echo "  curl -fsSL https://get.docker.com | sh"
                    exit 1
                fi
            else
                echo ""
                echo "非交互模式无法弹确认提示。两选一："
                echo "  1) 重跑时加环境变量授权自动装：AUTO_INSTALL_DOCKER=1 bash simple-deploy.sh"
                echo "  2) 先手动装 Docker：curl -fsSL https://get.docker.com | sh"
                exit 1
            fi
            ;;
        synology)
            echo ""
            echo "❌ 群晖 DSM 必须从套件中心装："
            echo "   - DSM 7.2+：「Container Manager」"
            echo "   - DSM 7.0/7.1：「Docker」"
            echo "命令行装会破坏 DSM 系统稳定性，不要硬装"
            exit 1
            ;;
        macos)
            echo ""
            echo "❌ macOS 请安装 Docker Desktop："
            echo "   https://www.docker.com/products/docker-desktop/"
            exit 1
            ;;
        *)
            echo ""
            echo "❌ 未识别的平台（$(uname -s)），请手动安装 Docker 后重跑此脚本"
            echo "   常规 Linux：curl -fsSL https://get.docker.com | sh"
            exit 1
            ;;
    esac
fi

# 检查 docker daemon 实际可访问（不只是命令存在）—— 群晖 SSH 用户没 docker 组权限会卡这里
if ! docker info >/dev/null 2>&1; then
    echo "❌ docker 命令存在但跑不动（没有 daemon 访问权限）"
    echo ""
    echo "可能原因 + 修法："
    echo "  - 群晖 SSH 用户：先在 DSM 控制面板开启 root SSH，sudo -i 切 root 后重跑此脚本"
    echo "    或改用 Container Manager「项目」模式 GUI 部署（不用命令行）"
    echo "  - Linux 用户：sudo usermod -aG docker \$USER && newgrp docker"
    echo "  - 任何系统：用 sudo bash $(basename "$0")"
    echo ""
    exit 1
fi

# 检查 Docker Compose 是 v1 还是 v2，并把命令名存到 $DC（后续所有命令通过 $DC 调用）
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
    echo "⚠️ 检测到 docker-compose v1（已过时），建议升级到 v2（docker compose）"
    echo "   v2 安装：sudo apt install docker-compose-plugin（或参考 docker.com 官方文档）"
    echo "   本脚本仍兼容 v1，但部分命令可能稍慢"
    echo ""
else
    echo "❌ Docker Compose 未安装（v1 / v2 都没找到）"
    echo ""
    echo "请先安装 Docker Compose v2（推荐）："
    echo "  sudo apt install docker-compose-plugin"
    exit 1
fi

# 创建工作目录
INSTALL_DIR="${HOME}/teslamate-chinese"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# TeslaMate 数据导入功能需要 ./import 绑定挂载（compose 里 - ./import:/opt/app/import）。
# Synology DSM / 部分 Docker 不会自动创建缺失的绑定源目录 → 必须显式建，
# 否则 docker compose up 直接报 "Bind mount failed: .../import does not exist"。
# 放在升级检测之前，让「全新安装」和「升级」两条路径的 up 都先有这个目录。
mkdir -p "$INSTALL_DIR/import"

echo "📁 工作目录: $INSTALL_DIR"
echo ""

# ============================================================
# 已存在检测：如果 docker-compose.yml 已经存在，转升级模式
# 避免覆盖用户的 ENCRYPTION_KEY、Tesla CN API 配置等
# ============================================================
if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    echo "🔄 检测到已有安装，进入升级模式（不会改你的配置）..."
    echo ""
    echo "  → 拉取最新镜像"
    $DC pull
    echo ""
    echo "  → 重启服务（应用新镜像）"
    $DC up -d
    echo ""
    echo "  → 等数据库就绪"
    DB_CONTAINER=$($DC ps -q database 2>/dev/null | head -1)
    [ -z "$DB_CONTAINER" ] && DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE 'teslamate.*database' | head -1)
    DB_READY=0
    for i in $(seq 1 30); do
        if docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -c "SELECT 1" >/dev/null 2>&1; then
            DB_READY=1
            break
        fi
        sleep 2
    done

    if [ "$DB_READY" -eq 1 ]; then
        # 先让 TeslaMate 把自己的迁移跑完，再装我们的 SQL（见 wait_teslamate_migrated 注释：
        # 抢在它前面会让 tou 装不上、并让上游迁移撞 duplicate_function 崩掉）
        echo "  → 等 TeslaMate 完成自身数据库迁移（首次安装通常 10-30 秒）"
        TM_MIGRATED=1
        if ! wait_teslamate_migrated "$DB_CONTAINER"; then
            TM_MIGRATED=0
            echo "  ⚠ 没能确认 TeslaMate 迁移已完成。为避免和它的迁移撞车，这次跳过单位换算函数"
            echo "    （撞车会让 TeslaMate 自己起不来）。等 TeslaMate 正常启动后重跑本脚本即可补上。"
        fi
    fi
    echo ""
    UPGRADE_SQL_OK=1
    if [ "$DB_READY" -eq 1 ]; then
        echo "  → 安装/更新坐标转换函数"
        if curl -fsSL "$SQL_BASE/install-coord-functions.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 >/dev/null 2>>"$SQL_ERR_LOG"; then
            echo "  ✓ 坐标函数已更新（地图源切换/纠偏）"
        else
            echo "  ⚠ 坐标函数更新失败"
            UPGRADE_SQL_OK=0
        fi

        echo "  → 安装/更新单位换算函数"
        # TM_MIGRATED=0 时必须真的跳过：这组函数与上游 TeslaMate 迁移建的是同名函数，我们抢先
        # CREATE OR REPLACE 之后，上游那条不带 OR REPLACE 的迁移会撞 duplicate_function 崩掉，
        # TeslaMate 从此反复重启、迁移永久停在半途，重跑本脚本也修不好（要手工 DROP FUNCTION）。
        # 少装这组函数只是地图/单位显示不对，比把 TeslaMate 搞停轻得多。
        if [ "${TM_MIGRATED:-1}" -eq 0 ]; then
            echo "  ⏭ 跳过单位换算函数（上面没能确认 TeslaMate 迁移已完成）"
            UPGRADE_SQL_OK=0
        elif curl -fsSL "$SQL_BASE/install-unit-functions.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 >/dev/null 2>>"$SQL_ERR_LOG"; then
            echo "  ✓ 单位换算函数已更新（km/mi、℃/℉、m/ft、胎压）"
        else
            echo "  ⚠ 单位换算函数更新失败"
            UPGRADE_SQL_OK=0
        fi

        echo "  → 安装/更新分时电价表 + 函数（v1.5.0+）"
        if curl -fsSL "$SQL_BASE/install-tou.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 >/dev/null 2>>"$SQL_ERR_LOG"; then
            echo "  ✓ 分时电价已就绪（首次装好后到「⚡ 分时电价配置」仪表盘填规则）"
            run_tou_backfill "$DB_CONTAINER"
        else
            echo "  ⚠ 分时电价更新失败，TOU 仪表盘可能不可用"
            UPGRADE_SQL_OK=0
        fi

        # 三组兼容性 SQL 全部成功才记录 revision（性能索引不算，见函数定义处注释）
        if [ "$UPGRADE_SQL_OK" -eq 1 ]; then
            _rev_rc=0
            write_sql_compat_revision "$DB_CONTAINER" || _rev_rc=$?
            [ "$_rev_rc" -eq 2 ] && UPGRADE_SQL_OK=0
        fi

        echo "  → 安装/更新性能优化索引（v1.6.1+）"
        if curl -fsSL "$SQL_BASE/install-indexes.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 >/dev/null 2>>"$SQL_ERR_LOG"; then
            echo "  ✓ 索引已就绪（电池健康/天气-能耗等查询提速）"
        else
            echo "  ⚠ 索引安装失败（不影响功能，仅性能略差）"
        fi
        echo ""
        echo "  → 重启 Grafana（让新仪表盘生效）"
        GRAFANA_CONTAINER=$($DC ps -q grafana 2>/dev/null | head -1)
        [ -z "$GRAFANA_CONTAINER" ] && GRAFANA_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE 'teslamate.*grafana' | head -1)
        [ -n "$GRAFANA_CONTAINER" ] && docker restart "$GRAFANA_CONTAINER" >/dev/null
    else
        echo ""
        echo "  ❌ 数据库 60 秒内未就绪，SQL 函数没装上"
        echo "     等服务起来后**重跑此脚本**（自动进入升级模式重试）："
        echo "     curl -fsSL https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/simple-deploy.sh | bash"
        exit 1
    fi
    echo ""
    echo "============================================="
    if [ "$UPGRADE_SQL_OK" -eq 1 ] && [ "$LEGACY_VIEW_PENDING" -eq 0 ]; then
        echo "✅ 升级完成"
        UPGRADE_EXIT=0
    elif [ "$UPGRADE_SQL_OK" -eq 1 ]; then
        # 第三档：该装的都装完了，但库里留着一个会挡住 TeslaMate 升级的旧对象。
        # 退出码仍是 0（我们的活干完了），但横幅不能是绿色的「✅ 升级完成」。
        echo "⚠️ 升级完成，但留了一个尾巴给你"
        print_legacy_view_warning
        UPGRADE_EXIT=0
    else
        echo "⚠️ 升级部分完成：坐标、单位或分时电价 SQL 未全部安装成功"
        print_legacy_view_warning
        # stderr 已经落盘（见 SQL_ERR_LOG 定义处），这里必须把路径告诉用户——否则加了
        # ON_ERROR_STOP 之后唯一的排查线索就藏在一个没人知道的文件里。
        [ -s "$SQL_ERR_LOG" ] && echo "   psql 的具体报错在：$SQL_ERR_LOG"
        echo "   跑 bash scripts/diagnose.sh 可以看到具体缺哪一组对象"
        UPGRADE_EXIT=2
    fi
    echo "============================================="
    echo ""
    # 从现有配置读回密钥再显示一遍：首跑中途失败没看到、或忘了记的用户，重跑即可拿回。
    # （都在本机终端，安全；|| true 防 set -e 下 grep 无匹配时整脚本中断）
    GF_PASS_NOW=$(grep -m1 'GF_SECURITY_ADMIN_PASSWORD=' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null | sed 's/.*GF_SECURITY_ADMIN_PASSWORD=//; s/[[:space:]]*$//' || true)
    KEY_NOW=$(grep -m1 'ENCRYPTION_KEY=' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null | sed 's/.*ENCRYPTION_KEY=//; s/[[:space:]]*$//' || true)
    if [ -n "$GF_PASS_NOW" ] || [ -n "$KEY_NOW" ]; then
        echo "🔑 你的密钥（请妥善保存，也存在 $INSTALL_DIR/docker-compose.yml）："
        [ -n "$GF_PASS_NOW" ] && echo "   Grafana 登录:   admin / $GF_PASS_NOW"
        [ -n "$KEY_NOW" ] && echo "   ENCRYPTION_KEY = $KEY_NOW"
        echo ""
    fi
    echo "下一步: 浏览器 Ctrl+Shift+R 强刷，看「地图源」下拉框是否就绪"
    echo ""
    echo "📚 完整发版说明: https://github.com/wjsall/teslamate-chinese-dashboards/releases/latest"
    setup_backup
    exit "$UPGRADE_EXIT"
fi

# ============================================================
# 全新安装流程
# ============================================================

# 端口预检：4000 (TeslaMate) / 3000 (Grafana) 必须空闲，否则容器起来直接 conflict
# 群晖 DSM 高发：DSM 自带服务、其他 docker 容器（Portainer/Bitwarden）也可能占
# macOS 高发：3000 被 Vite/Next.js/Rails 默认占
# 检测优先 lsof（macOS / Linux 都准），其次 ss（Linux 现代发行版），最后 netstat（兼容老系统）
# 同 scripts/diagnose.sh 的 check_port_listen：只查监听表会漏——Docker 28 可以不起
# docker-proxy 用户态进程（nftables 直接转发），端口实际被占着但 lsof/ss 里什么都看不到，
# 预检会说"空闲"，然后 compose up 报 port is already allocated，用户拿到的是难懂的报错
# 而不是这里友好的冲突提示。所以先真连一次：连得上一定是被占了。
check_port_free() {
    local port=$1
    if command -v curl >/dev/null 2>&1; then
        local code
        # --noproxy 必须：curl 不为 127.0.0.1 自动绕过 http_proxy。带代理的 shell 里
        # 不加这个会让代理的响应被当成「端口被占用」，两个端口全判冲突、直接中止安装。
        code=$(curl -sS --noproxy '*' -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null)
        [ -n "$code" ] && [ "$code" != "000" ] && return 0
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$port" -sTCP:LISTEN -P -n >/dev/null 2>&1
    elif command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    elif command -v netstat >/dev/null 2>&1; then
        # GNU netstat -tln 才输出 LISTEN，BSD/macOS netstat 行为不同（已优先走 lsof 规避）
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    else
        return 2  # 无工具检测，跳过
    fi
}

PORT_CONFLICT=0
for port in "$TM_PORT" "$GF_PORT"; do
    # || rc=$? 让 check_port_free 的非零返回不触发 set -e（端口空闲返回 1 是正常情况）
    rc=0
    check_port_free "$port" || rc=$?
    case $rc in
        0)
            echo "❌ 端口 ${port} 已被占用（TeslaMate / Grafana 启动会失败）"
            PORT_CONFLICT=1
            if command -v lsof >/dev/null 2>&1; then
                echo "   占用进程：$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n 2>/dev/null | tail -1)"
            elif command -v ss >/dev/null 2>&1; then
                echo "   占用进程：$(ss -tlnp 2>/dev/null | grep -E ":${port}\b" | head -1)"
            fi
            ;;
        2)
            echo "⚠️ 系统没装 lsof/ss/netstat 任一工具，跳过端口 ${port} 预检"
            ;;
    esac
done

if [ "$PORT_CONFLICT" -eq 1 ]; then
    echo ""
    echo "⚠️  解决方案（推荐 A，B 进阶）："
    echo "   A. 关掉占用 ${TM_PORT}/${GF_PORT} 的服务后重跑此脚本（最简单）"
    echo "      - 群晖 DSM 用户：Portainer / Bitwarden 默认占 3000"
    echo "      - macOS：Vite / Next.js / Rails 默认 3000"
    echo "   B. 用环境变量改端口重跑：TM_PORT=14000 GF_PORT=13000 bash simple-deploy.sh"
    echo "      （脚本会自动把 docker-compose.yml 的端口映射改成你指定的值）"
    exit 1
fi
echo ""

# 生成 docker-compose.yml
echo "📝 生成配置文件..."

cat > docker-compose.yml << 'EOF'
services:
  teslamate:
    image: teslamate/teslamate:latest
    restart: always
    cap_drop:
      - all
    ports:
      - 4000:4000
    volumes:
      - ./import:/opt/app/import
    environment:
      - ENCRYPTION_KEY=INSERT_RANDOM_KEY_HERE
      - DATABASE_USER=teslamate
      - DATABASE_PASS=password
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - MQTT_HOST=mosquitto
      # 通常不需要手动设置：TeslaMate 3.0 会从 access_token 自动识别中国区 / 国际，
      # 国内 token 自动用 owner-api.vn.cloud.tesla.cn / streaming.vn.cloud.tesla.cn。
      # 仅在走自建 Fleet API 网关或代理时取消注释（参考 TROUBLESHOOTING.md「公网部署专项」）：
      # - TESLA_API_HOST=https://owner-api.vn.cloud.tesla.cn
      # - TESLA_WSS_HOST=wss://streaming.vn.cloud.tesla.cn
      # 国内用户强烈建议取消下一行注释 + 填代理地址：nominatim.openstreetmap.org 国内常超时
      # 会让行程列表起始/结束地址列大量为空。详见 TROUBLESHOOTING.md#nominatim-proxy
      # - NOMINATIM_PROXY=http://你的代理IP:7890
      - TZ=Asia/Shanghai

  database:
    image: postgres:18-trixie
    restart: always
    volumes:
      - teslamate-db:/var/lib/postgresql
    environment:
      - POSTGRES_USER=teslamate
      - POSTGRES_PASSWORD=password
      - POSTGRES_DB=teslamate

  grafana:
    image: bswlhbhmt816/teslamate-chinese-dashboards:latest
    restart: always
    ports:
      - 3000:3000
    volumes:
      - teslamate-grafana-data:/var/lib/grafana
    environment:
      - DATABASE_USER=teslamate
      - DATABASE_PASS=password
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - GF_SECURITY_ADMIN_PASSWORD=INSERT_GRAFANA_PASSWORD_HERE
      - GF_USERS_DEFAULT_LANGUAGE=zh-Hans

  mosquitto:
    image: eclipse-mosquitto:2
    restart: always
    command: mosquitto -c /mosquitto-no-auth.conf
    volumes:
      - mosquitto-conf:/mosquitto/config
      - mosquitto-data:/mosquitto/data

volumes:
  teslamate-db:
  teslamate-grafana-data:
  mosquitto-conf:
  mosquitto-data:
EOF

# 生成随机加密密钥 + 随机 DB 密码 + 随机 Grafana admin 密码（兼容 Linux 和 macOS）
ENCRYPTION_KEY=$(openssl rand -hex 32)
DB_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
GRAFANA_PASS=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-18)
# sed in-place 包装：GNU 用 `-i`，BSD/macOS 用 `-i ""`。
# 占位符列表只写一次，未来加新密码字段不会漏写一边（v1.6.9 第一版 BSD 分支漏 GRAFANA_PASS 教训）
if sed --version 2>/dev/null | grep -q GNU; then
  sed_inplace() { sed -i "$@"; }
else
  sed_inplace() { sed -i "" "$@"; }
fi

sed_inplace "s/INSERT_RANDOM_KEY_HERE/$ENCRYPTION_KEY/"        docker-compose.yml
sed_inplace "s/DATABASE_PASS=password/DATABASE_PASS=$DB_PASS/g" docker-compose.yml
sed_inplace "s/POSTGRES_PASSWORD=password/POSTGRES_PASSWORD=$DB_PASS/" docker-compose.yml
sed_inplace "s/INSERT_GRAFANA_PASSWORD_HERE/$GRAFANA_PASS/"    docker-compose.yml
# 端口映射（默认 4000/3000，TM_PORT/GF_PORT 环境变量可覆盖）
sed_inplace "s|- 4000:4000|- ${TM_PORT}:4000|" docker-compose.yml
sed_inplace "s|- 3000:3000|- ${GF_PORT}:3000|" docker-compose.yml
# Grafana 镜像（默认 bswlhbhmt816/teslamate-chinese-dashboards:latest，GRAFANA_IMAGE 环境变量可覆盖；
# heredoc 是 quoted 'EOF' 不会展开变量，跟端口一样用生成后 sed 替换的方式支持覆盖）
sed_inplace "s|image: bswlhbhmt816/teslamate-chinese-dashboards:latest|image: ${GRAFANA_IMAGE}|" docker-compose.yml

# 限制 docker-compose.yml 文件权限（含 ENCRYPTION_KEY + DB 密码 + 后续 Tesla token）
chmod 600 docker-compose.yml

echo ""
echo "✅ 配置文件已生成（含随机密钥 + 随机 DB 密码 + 文件权限 600）"
echo ""

# 启动服务
echo "🚀 启动服务（首次启动需要下载镜像，请耐心等待 2-5 分钟）..."
echo "   如果长时间卡在拉取镜像，请参考文末说明配置 Docker 镜像代理。"
$DC up -d

# 检查服务状态
echo ""
echo "📊 服务状态:"
$DC ps

# ============================================================
# 安装 SQL：坐标函数 + 分时电价表 + 性能索引
# ============================================================
echo ""
echo "📍 安装 SQL（坐标函数 / 分时电价 / 性能索引）..."

# 等数据库就绪（最多 60 秒）
DB_CONTAINER=$($DC ps -q database 2>/dev/null | head -1)
if [ -z "$DB_CONTAINER" ]; then
    DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE 'teslamate.*database' | head -1)
fi

DB_READY=0
SQL_OK=1
for i in $(seq 1 30); do
    if docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -c "SELECT 1" >/dev/null 2>&1; then
        DB_READY=1
        break
    fi
    sleep 2
done

if [ "$DB_READY" -eq 1 ]; then
    # 先让 TeslaMate 把自己的迁移跑完，再装我们的 SQL（见 wait_teslamate_migrated 注释：
    # 抢在它前面会让 tou 装不上、并让上游迁移撞 duplicate_function 崩掉）
    echo "  → 等 TeslaMate 完成自身数据库迁移（首次安装通常 10-30 秒）"
    TM_MIGRATED=1
    if ! wait_teslamate_migrated "$DB_CONTAINER"; then
        TM_MIGRATED=0
        echo "  ⚠ 没能确认 TeslaMate 迁移已完成。为避免和它的迁移撞车，这次跳过单位换算函数"
        echo "    （撞车会让 TeslaMate 自己起不来）。等 TeslaMate 正常启动后重跑本脚本即可补上。"
    fi
fi

if [ "$DB_READY" -eq 1 ]; then
    if curl -fsSL "$SQL_BASE/install-coord-functions.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 >/dev/null 2>>"$SQL_ERR_LOG"; then
        echo "  ✓ 坐标转换函数已装（地图源切换+GCJ-02 自动纠偏）"
    else
        echo "  ⚠ 坐标函数安装失败"
        SQL_OK=0
    fi

    # TM_MIGRATED=0 时必须真的跳过：这组函数与上游 TeslaMate 迁移建的是同名函数，我们抢先
    # CREATE OR REPLACE 之后，上游那条不带 OR REPLACE 的迁移会撞 duplicate_function 崩掉，
    # TeslaMate 从此反复重启、迁移永久停在半途，重跑本脚本也修不好（要手工 DROP FUNCTION）。
    # 少装这组函数只是地图/单位显示不对，比把 TeslaMate 搞停轻得多。
    if [ "${TM_MIGRATED:-1}" -eq 0 ]; then
        echo "  ⏭ 跳过单位换算函数（上面没能确认 TeslaMate 迁移已完成）"
        SQL_OK=0
    elif curl -fsSL "$SQL_BASE/install-unit-functions.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 >/dev/null 2>>"$SQL_ERR_LOG"; then
        echo "  ✓ 单位换算函数已装（km/mi、℃/℉、m/ft、胎压）"
    else
        echo "  ⚠ 单位换算函数安装失败"
        SQL_OK=0
    fi

    if curl -fsSL "$SQL_BASE/install-tou.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 >/dev/null 2>>"$SQL_ERR_LOG"; then
        echo "  ✓ 分时电价表+函数已装（v1.5.0+，首次装好后到「⚡ 分时电价配置」仪表盘填规则）"
        run_tou_backfill "$DB_CONTAINER"
    else
        echo "  ⚠ 分时电价安装失败，TOU 仪表盘可能不可用"
        SQL_OK=0
    fi

    # 三组兼容性 SQL 全部成功才记录 revision（性能索引不算，见函数定义处注释）
    if [ "$SQL_OK" -eq 1 ]; then
        _rev_rc=0
        write_sql_compat_revision "$DB_CONTAINER" || _rev_rc=$?
        [ "$_rev_rc" -eq 2 ] && SQL_OK=0
    fi

    if curl -fsSL "$SQL_BASE/install-indexes.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 >/dev/null 2>>"$SQL_ERR_LOG"; then
        echo "  ✓ 性能索引已装（v1.6.1+，电池健康/天气-能耗等查询提速）"
    else
        echo "  ⚠ 索引安装失败（不影响功能，仅性能略差）"
    fi

    if [ "$SQL_OK" -eq 0 ]; then
        echo ""
        echo "    psql 的具体报错在：$SQL_ERR_LOG"
        echo "    部分 SQL 安装失败，可手动重跑（按需选）："
        echo "    for f in install-coord-functions install-unit-functions install-tou install-indexes; do"
        echo "      curl -fsSL $SQL_BASE/\$f.sql | docker exec -i $DB_CONTAINER psql -U teslamate -d teslamate -v ON_ERROR_STOP=1"
        echo "    done"
    fi
else
    echo "  ⚠ 数据库 60 秒内未就绪，跳过 SQL 安装"
    echo "    服务起来后重跑此脚本（自动进入升级模式）即可装上 SQL"
    SQL_OK=0
fi

echo ""
echo "=============================================="
if [ "$SQL_OK" -eq 1 ] && [ "$LEGACY_VIEW_PENDING" -eq 0 ]; then
    echo "✅ 安装完成！"
    INSTALL_EXIT=0
elif [ "$SQL_OK" -eq 1 ]; then
    # 第三档：该装的都装完了，但库里留着一个会挡住 TeslaMate 升级的旧对象。
    # 退出码仍是 0（我们的活干完了），但横幅不能是绿色的「✅ 安装完成！」。
    echo "⚠️ 安装完成，但留了一个尾巴给你"
    print_legacy_view_warning
    INSTALL_EXIT=0
else
    echo "⚠️ 安装部分完成：坐标、单位或分时电价 SQL 未全部安装成功"
    print_legacy_view_warning
    INSTALL_EXIT=2
fi
echo "=============================================="
echo ""

# 云主机检测：在凭据展示前先打安全警告（最容易被看见）
if [ "$IS_CLOUD" = "cloud" ]; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  检测到本机是云服务器（公网 IP 暴露）                  ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "   TeslaMate (4000) / Grafana (3000) 端口默认绑 0.0.0.0，"
    echo "   任何扫描你公网 IP 的人都能直接看到登录页。"
    echo ""
    echo "   立刻做的两件事："
    echo "   1) 云厂商安全组只放白名单 IP 访问 4000/3000，不要全公网开放"
    echo "   2) 加反向代理 + HTTPS（Caddy / Traefik）+ basic-auth，"
    echo "      参考 TROUBLESHOOTING.md「公网部署专项」章节"
    echo ""
fi

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  🚨🚨🚨 必须立刻抄录！下面凭据仅显示这一次！  🚨🚨🚨       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  ENCRYPTION_KEY = $ENCRYPTION_KEY"
echo "  DATABASE_PASS  = $DB_PASS"
echo "  GRAFANA_PASS   = $GRAFANA_PASS"
echo ""
echo "  📁 docker-compose.yml 备份位置：$INSTALL_DIR/docker-compose.yml"
echo "     （已设 mode 600，仅当前用户可读）"
echo "     ↑ 上面三项也都写在这个文件里，没抄到可随时从这里找回（只要这个目录还在）"
echo ""
echo "  ❌ ENCRYPTION_KEY 丢失 → 所有 Tesla Token 永远解密不出 → 必须重新授权"
echo "  ❌ DATABASE_PASS 丢失 → 数据库迁移/恢复全部失败"
echo "  ❌ GRAFANA_PASS 丢失 → Grafana 后台进不去，需 docker exec 重置"
echo ""
echo "  👉 立刻抄到密码管理器（1Password / Keychain / Bitwarden）"
echo ""
echo "════════════════════════════════════════════════════════════"
echo ""
echo "📱 访问地址："
echo "  - TeslaMate:  http://localhost:${TM_PORT}"
echo "  - Grafana:    http://localhost:${GF_PORT}"
echo ""
echo "🔐 Grafana 登录信息："
echo "  - 用户名: admin"
echo "  - 密码: $GRAFANA_PASS  （已自动生成强随机，不再是默认 admin）"
echo ""
echo "📝 下一步："
echo "  1. 拿 Token：推荐 https://github.com/adriankumpf/tesla_auth/releases （桌面版，TeslaMate 主作者维护）"
echo "     - macOS / Linux / Windows 都有原生二进制；下载后双击运行，登录 Tesla 账号即可看到 access_token + refresh_token"
echo "     - 国内 iOS 用户也可用「Auth for Tesla」App（需要美区/港区 Apple ID）"
echo "  2. 访问 TeslaMate http://localhost:${TM_PORT}，把两段 token 粘贴到登录页"
echo "  3. 车辆会自动开始同步数据"
echo "  4. 几分钟后访问 Grafana 查看中文仪表盘"
echo "  5. 打开任一含地图仪表盘（足迹地图/驾驶记录追踪等），顶部「地图源」"
echo "     下拉框试试切换到「高德地图」/「谷歌卫星」"
echo ""
setup_backup
echo ""
echo "📚 相关文档（在线）："
echo "  https://github.com/wjsall/teslamate-chinese-dashboards"
echo ""
echo "🆘 遇到问题？"
echo "  查看日志: $DC logs -f"
echo "  重启服务: $DC restart"
echo ""
echo "🍓 树莓派用户提示："
echo "  必须使用 64 位系统（64-bit Raspberry Pi OS），32 位系统不支持。"
echo "  树莓派 4 / 5 均可正常运行，树莓派 3 建议升级到 64 位系统后使用。"
echo ""
echo "⚠️  中国大陆用户提示："
echo "  1. 如果镜像拉取失败，在 /etc/docker/daemon.json 中添加镜像代理："
echo "     { \"registry-mirrors\": [\"https://docker.1ms.run\", \"https://docker.m.daocloud.io\"] }"
echo "     然后执行: sudo systemctl daemon-reload && sudo systemctl restart docker"
echo "  2. TeslaMate 3.0 起仅支持「粘贴 Token」登录，先在手机装 Auth for Tesla App"
echo "     生成 token，再到 http://你的IP:4000 粘贴 Access Token / Refresh Token"
echo "     国内账号不需要改环境变量（TeslaMate 会从 token 自动识别）"
echo "  3. 行程列表地址列经常空 = nominatim.openstreetmap.org 国内访问超时。"
echo "     修法见 TROUBLESHOOTING.md#nominatim-proxy（加一行 NOMINATIM_PROXY env 即可）"
echo "  4. 配置文件路径: $INSTALL_DIR/docker-compose.yml"
echo ""
exit "$INSTALL_EXIT"
