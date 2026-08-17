#!/usr/bin/env bash
# 从官方源 TeslaMate 迁移到中文 Dashboard 版（teslamate-chinese-dashboards）
# 一键脚本：找 docker-compose.yml → 备份 → 改 grafana image + ENV → 重启 grafana → 装 SQL
#
# 数据零丢失。完全可逆。
# 跑：bash migrate-from-official.sh
#
# 安全提示：脚本通过 https 拉远程 SQL（GitHub raw）。如担心仓库被劫持，
# 把 REPO_REF 设成具体 commit SHA：REPO_REF=abc123... bash migrate-from-official.sh
#
# 非交互运行（CI / 自动化，无 tty）：ASSUME_YES=1 bash migrate-from-official.sh（或 --yes / -y）
# 所有 y/N 确认点会走安全默认值（详见脚本内各确认点旁的注释），不设置时行为与交互模式完全一致。

set -euo pipefail

# ── 配置 ────────────────────────────────────────────────────────────
#
# TARGET_REF：稳定迁移的统一版本 ref —— NEW_IMAGE / REPO_REF（SQL + config/versions.env）
# 全部锁定同一个 ref，避免"正式版镜像 + main 分支 SQL"混搭（详见 README「三种更新通道」）。
#
# 三条通道：
#   - 不传任何变量（默认）：自动解析 GitHub 最新正式 Release，NEW_IMAGE / REPO_REF 都锁定
#     这个 tag。
#   - TARGET_REF=v1.8.4：显式锁定到指定正式版。
#   - TARGET_REF=main：滚动通道，两者都用 main 分支最新构建（CI 每次 push main 都会构建
#     一个 :main tag 镜像，与只在打正式 tag 时更新的 :latest 相互独立）。
#
# 优先级：单独设置 NEW_IMAGE / REPO_REF 会覆盖 TARGET_REF 的推导结果（高级用户明确要
# 混搭版本时用，或想让 SQL 与镜像版本严格匹配到某个 commit SHA）；不单独设置时两者都
# 跟着 TARGET_REF 走。
#
# GitHub API 有速率限制（未认证 60 次/小时/IP）：先走 API，再走不吃限流的网页重定向
# 兜一次。两条都没解析出版本号（网络不通 / 代理拦截 / 仓库暂无 Release）就直接报错退出，
# 不会自动改用 main 分支——那等于让用户拿到「正式版镜像 + 未发布 SQL」的混搭。
resolve_target_ref() {
    if [[ -n "${TARGET_REF:-}" ]]; then
        echo "ℹ️  TARGET_REF=${TARGET_REF}（用户指定，跳过自动解析）"
        return 0
    fi
    echo "🔍 解析最新正式 Release 版本..."
    local resp tag
    resp=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/wjsall/teslamate-chinese-dashboards/releases/latest" 2>/dev/null) || resp=""
    # `|| true` 必须：resp 为空或没有 tag_name 字段时 grep -m1 找不到匹配会返回 1，
    # set -o pipefail 下会让整条管道判定失败，在 set -e 下直接终止脚本——不加这个会让
    # "API 不可达时的兜底"本身在兜底判断前就被 set -e 杀掉，兜底逻辑永远跑不到。
    tag=$(printf '%s' "$resp" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/') || true

    # 路子二：网页版 /releases/latest 会 302 到具体 tag，不吃 API 限流。
    # API 被限流（国内共享出口很常见）时这条通常还通。
    if [[ -z "$tag" ]]; then
        echo "  · GitHub API 没解析出来（多半是限流），换免限流的方式再试一次"
        tag=$(curl -sSI --max-time 10 \
            "https://github.com/wjsall/teslamate-chinese-dashboards/releases/latest" 2>/dev/null \
            | grep -i '^location:' | tr -d '\r' | sed 's|.*/||') || true
        case "$tag" in
            v[0-9]*) : ;;
            *) tag="" ;;
        esac
    fi

    if [[ -n "$tag" ]]; then
        TARGET_REF="$tag"
        echo "  ✓ 最新正式版：${TARGET_REF}（SQL 锁定这个 tag，镜像用 latest——两者内容对齐同一版本）"
        return 0
    fi

    # 两条路都没通 → 停下来，不猜。改用 main 会让用户拿到「正式版镜像 + 未发布 SQL」
    # 的混搭，而这套组合没有被任何冒烟测试跑过；装成什么样取决于此刻 main 上有没有
    # 半成品，不该由一次网络抖动决定。
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
    echo "        TARGET_REF=v1.9.1 bash migrate-from-official.sh"
    echo ""
    echo "   （不自动改用开发分支：那会让镜像和数据库脚本来自不同版本。）"
    exit 1
}
# 只有 TARGET_REF 的推导结果会被实际用到时才发起网络请求：NEW_IMAGE 和 REPO_REF 都已经
# 被显式设置时（常见于 CI 冒烟测试，如 NEW_IMAGE=ghcr.io/.../candidate-<run_id>
# REPO_REF=$GITHUB_SHA），TARGET_REF 不会被用在任何地方，跳过 GitHub API 调用，
# 避免给不需要它的调用方增加网络依赖 / API 限流风险。
#
# 记录 TARGET_REF 是否由用户显式传入——必须在 resolve_target_ref() 之前记，理由同
# simple-deploy.sh 对应位置的注释：该函数在未显式传入时会把解析结果写回 TARGET_REF
# 本身，之后就分不清"用户主动指定的版本"和"自动解析出来的版本"。
_TARGET_REF_EXPLICIT=0
[[ -n "${TARGET_REF:-}" ]] && _TARGET_REF_EXPLICIT=1
if [[ -n "${NEW_IMAGE:-}" && -n "${REPO_REF:-}" ]]; then
    TARGET_REF="${TARGET_REF:-unused-both-refs-explicit}"
else
    resolve_target_ref
fi

# 镜像 tag 推导（与 simple-deploy.sh 完全一致，理由见那边的详细注释）：
# - 用户显式传 TARGET_REF=main（滚动通道）→ 镜像用 :main。
# - 用户显式传 TARGET_REF=v1.8.4（钉具体版本）→ 镜像锁定该数字 tag，保证「镜像与 SQL
#   严格对齐到同一版本」这个显式钉版本场景的承诺不被打破。
# - 未显式传（默认通道，占绝大多数用户；解析出的版本号只用来拉 SQL，解析不出来时上面
#   已经报错退出）→ 镜像 tag 固定用 latest，避免钉死不可变数字 tag 后用户永久停在迁移时
#   的版本（本脚本只在「官方源 → 我们镜像」那一次替换 image 行，此后重跑只走 SQL 升级
#   分支，不会再改 compose 里的 image，所以镜像 tag 必须是本身就会跟着新版本走的可变
#   tag），也避免一次 GitHub API 抖动就把镜像挪到别的通道上去。
if [[ "$_TARGET_REF_EXPLICIT" == "1" ]]; then
    if [[ "$TARGET_REF" == "main" ]]; then
        _DEFAULT_IMG_TAG="main"
    else
        _DEFAULT_IMG_TAG="${TARGET_REF#v}"
    fi
else
    _DEFAULT_IMG_TAG="latest"
fi

NEW_IMAGE="${NEW_IMAGE:-bswlhbhmt816/teslamate-chinese-dashboards:${_DEFAULT_IMG_TAG}}"
# 「已经在我们镜像上」的识别模式：从 NEW_IMAGE 去掉 :tag 后派生，并转义正则元字符。
# 不能硬编码 bswlhbhmt816/... —— CI 用 NEW_IMAGE 覆盖成 ghcr.io/... 时，二次运行会识别不出
# 「已是我们的镜像」，导致幂等性判断失效。
OUR_IMAGE_RE=$(printf '%s' "${NEW_IMAGE%%:*}" | sed 's|[.[\*^$/]|\\&|g')
# REPO_REF 默认跟随 TARGET_REF；单独设置可覆盖（例如锁到具体 commit SHA，连同 NEW_IMAGE
# 一起锁成同一个版本号，才能保证 SQL 与镜像严格匹配）
REPO_REF="${REPO_REF:-$TARGET_REF}"
# ============================================================
# 自举：确保真正执行的是**已发布版本**的这个脚本
#
# README 给的命令是 curl .../main/migrate-from-official.sh | bash，脚本本体来自 main——
# SQL、镜像都锁定到了正式版，唯独「迁移逻辑本身」还是未发布代码，推上 main 那一刻就对
# 所有用户生效，而它此刻可能还没跑完冒烟测试。这里换成正式版的同名脚本继续执行。
# 三个安全阀同 simple-deploy.sh：防无限自举 / 拉取失败继续用当前份（但必须显式提示，
# 拉不到的人往往正是访问 GitHub 受限的那批）/ 滚动通道不自举。
if [[ -z "${TESLAMATE_CN_PINNED:-}" && "$REPO_REF" != "main" \
      && "$REPO_REF" != "unused-both-refs-explicit" ]]; then
    _pinned=$(mktemp "${TMPDIR:-/tmp}/teslamate-cn-migrate.XXXXXX" 2>/dev/null) || _pinned=""
    _url="https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/migrate-from-official.sh"
    if [[ -n "$_pinned" ]] && curl -fsSL --max-time 30 "$_url" -o "$_pinned" 2>/dev/null \
       && [[ -s "$_pinned" ]] && head -1 "$_pinned" | grep -q '^#!/'; then
        echo "  ↻ 改用 ${REPO_REF} 版本的迁移脚本继续（保证脚本与 SQL、镜像同版本）"
        export TESLAMATE_CN_PINNED=1
        export TARGET_REF REPO_REF
        exec bash "$_pinned" "$@"
    fi
    [[ -n "$_pinned" ]] && rm -f "$_pinned"
    # 走到这里 = 没能取到 ${REPO_REF} 版本的迁移脚本（下载失败，或本机临时目录不可写）。
    # 继续迁移是有意为之：拉不到就干脆不迁，比这个更糟。但要说清楚现在是什么状态。
    echo ""
    echo "  ⚠️  没能下载 ${REPO_REF} 版本的迁移脚本，本次继续用当前这份脚本迁移。"
    echo "     影响：数据库脚本和镜像仍然锁定 ${REPO_REF}，但真正在跑的是当前这份脚本——"
    echo "     按 README 的一键命令迁移时它来自开发分支 main，不是 ${REPO_REF} 发布时"
    echo "     验证过的那一份。绝大多数情况下结果是一样的。"
    echo "     想要完全一致的话：先把脚本下到本地再跑（在网络能通的机器上下载后拷过来也行）"
    echo "       curl -fsSL -o migrate-from-official.sh \\"
    echo "         ${_url}"
    echo "       bash migrate-from-official.sh"
    echo ""
fi

OFFICIAL_IMAGE_RE='teslamate/grafana(:[a-zA-Z0-9._-]*)?'
COMPOSE_FILE="${COMPOSE_FILE:-}"

# DRY_RUN=1：只打印本次会用到的所有远程 URL / 镜像 tag，不做任何 docker/系统改动。
# 用于验证"稳定迁移时所有远程 URL 指向同一 ref"（Gate F，见 README 三种通道说明）。
# 放在 tty 检测之前，这样非交互 (curl|bash 风格) 也能直接拿到结果，不需要 ASSUME_YES。
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "TARGET_REF=${TARGET_REF}"
    echo "NEW_IMAGE=${NEW_IMAGE}"
    echo "REPO_REF=${REPO_REF}"
    echo "urls:"
    echo "  https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-coord-functions.sql"
    echo "  https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-unit-functions.sql"
    echo "  https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-tou.sql"
    echo "  https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-indexes.sql"
    echo "  https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/config/versions.env"
    exit 0
fi

# 非交互模式：ASSUME_YES=1（或 --yes / -y 参数）表示所有确认点走默认答案，不再等 tty 输入。
# 用于 CI 冒烟测试等无终端场景；不设置时完全不影响交互行为。
ASSUME_YES="${ASSUME_YES:-0}"
for _arg in "$@"; do
    case "$_arg" in
        --yes|-y) ASSUME_YES=1 ;;
    esac
done

# 失败步骤累计（最后汇总）：FAILED_STEPS 影响退出码，WARN_STEPS 仅告警不影响退出码
FAILED_STEPS=()
WARN_STEPS=()
# 旧版留下的 charging_processes_v 对账视图这次没能删掉（三种情形见 sql/install-tou.sql
# 2f 节）。它不阻断本脚本装的任何东西，但会阻断**用户的下一步**：TeslaMate 升到 4.1.1 时
# 那句 ALTER TABLE charging_processes ALTER COLUMN cost TYPE numeric(14,2) 会被 PostgreSQL
# 拒绝，TeslaMate 起不来、容器反复重启、行车和充电全部停止记录。
# 单独一个标记而不是只往 WARN_STEPS 里塞一个词：结尾横幅那句「非关键项告警（不影响核心
# 功能）」放在这一条上是错的，得换一段把后果讲清楚的话。
LEGACY_VIEW_PENDING=0
MIGRATION_STAGE="pre-change"

# ── 辅助函数 ────────────────────────────────────────────────────────

# 探测 docker compose 命令（v2 推荐 `docker compose`，老系统是 `docker-compose`）
detect_compose_cli() {
    if docker compose version >/dev/null 2>&1; then
        DC="docker compose"
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DC="docker-compose"
    else
        echo "❌ 没找到 docker compose 命令。"
        echo "   v2: 装 'docker compose plugin'  v1: 装 docker-compose 二进制"
        exit 1
    fi
}

# 探测 docker daemon 是否在跑
preflight_docker() {
    if ! docker info >/dev/null 2>&1; then
        echo "❌ docker daemon 没起来（或当前用户没权限）。"
        echo "   Linux:   sudo systemctl start docker"
        echo "   Mac/Win: 启动 Docker Desktop"
        echo "   权限:    把当前用户加到 docker 组（sudo usermod -aG docker \$USER），然后重新登录"
        exit 1
    fi
}

# 找 docker-compose.yml — 支持 v2 新默认 compose.yml
find_compose_file() {
    if [[ -n "$COMPOSE_FILE" ]]; then
        [[ -f "$COMPOSE_FILE" ]] || { echo "❌ COMPOSE_FILE=$COMPOSE_FILE 不存在"; exit 1; }
        return 0
    fi
    local candidates=(
        "$PWD/docker-compose.yml"
        "$PWD/docker-compose.yaml"
        "$PWD/compose.yml"
        "$PWD/compose.yaml"
        "$HOME/teslamate/docker-compose.yml"
        "$HOME/teslamate/compose.yml"
        "$HOME/teslamate-chinese/docker-compose.yml"
        "/opt/teslamate/docker-compose.yml"
        "/srv/teslamate/docker-compose.yml"
    )
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then COMPOSE_FILE="$c"; return 0; fi
    done
    echo "❌ 找不到 docker-compose.yml / compose.yml。"
    echo "   不知道在哪？跑这个找："
    echo "   sudo find / -name 'docker-compose.y*ml' -o -name 'compose.y*ml' 2>/dev/null | head -5"
    echo "   找到后："
    echo "   COMPOSE_FILE=/路径/docker-compose.yml bash migrate-from-official.sh"
    exit 1
}

# 探测 database 容器名 — project name 不一定是 teslamate
detect_db_container() {
    if [[ -n "${DB_CONTAINER:-}" ]]; then return 0; fi
    # 优先用 docker compose 自己解析当前项目
    DB_CONTAINER=$(cd "$COMPOSE_DIR" && $DC ps -q database 2>/dev/null | head -1 || true)
    if [[ -n "$DB_CONTAINER" ]]; then
        DB_CONTAINER=$(docker inspect --format '{{.Name}}' "$DB_CONTAINER" 2>/dev/null | sed 's|^/||' || true)
    fi
    # fallback：扫所有 running 容器找 database/postgres
    if [[ -z "$DB_CONTAINER" ]]; then
        DB_CONTAINER=$(docker ps --filter "status=running" --format '{{.Names}}' \
            | grep -E '(^|[-_])database([-_]|$)|postgres' | head -1 || true)
    fi
    if [[ -z "$DB_CONTAINER" ]]; then
        echo "⚠️  探测不到 database 容器名（可能没 running）。SQL 安装步骤会跳过。"
        echo "   起来之后重跑：DB_CONTAINER=你的容器名 bash migrate-from-official.sh"
        return 1
    fi
    return 0
}

# 探测 PG 版本 — 新装默认 18；项目的技术下限是 PG 16。
# PG 15 已支持 3-arg date_trunc；下限来自 4-arg generate_series(..., interval, timezone)。
check_pg_version() {
    if [[ -z "${DB_CONTAINER:-}" ]]; then return 0; fi
    local ver
    ver=$(docker exec -i "$DB_CONTAINER" psql -U "${DB_USER:-teslamate}" -d "${DB_NAME:-teslamate}" \
        -tAc "SHOW server_version_num" 2>/dev/null | tr -d '[:space:]' || true)
    [[ -z "$ver" ]] && return 0  # 探测失败不阻塞
    local major=$(( ver / 10000 ))
    if (( major >= 18 )); then
        echo "✓ PostgreSQL ${major}（与官方对齐）"
        return 0
    fi
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if (( major <= 15 )); then
        echo "❌ 检测到 PostgreSQL $major — 该版本不支持本项目所需的四参数 generate_series"
        echo "   受影响函数签名：generate_series(timestamptz, timestamptz, interval, timezone)（PG 16+）"
        echo "   不要仅凭 date_trunc 报错判断需要升级；请先核对完整错误中的函数签名。"
    else
        echo "⚠️  检测到 PostgreSQL $major — 建议升级到 18（与官方 teslamate-org 对齐）"
        echo "   PG 16/17 能跑本项目所有仪表盘，但官方 docker-compose.yml 已默认 postgres:18-trixie"
    fi
    echo
    echo "📦 升级流程（必须先备份！）："
    echo
    echo "   # 1. 完整备份当前数据库（PG $major 格式）"
    echo "   docker exec $DB_CONTAINER pg_dumpall -U ${DB_USER:-teslamate} > teslamate-backup-pg${major}-\$(date +%Y%m%d).sql"
    echo
    echo "   # 2. 检查备份文件大小（应该几百 KB ~ 几十 MB，0 字节就是失败）"
    echo "   ls -lh teslamate-backup-pg${major}-*.sql"
    echo
    echo "   # 3. 探测 database 实际挂载的 Docker 卷，并逐项确认（不可逆）"
    echo "   cd \"$(dirname "$COMPOSE_FILE")\""
    echo "   DB_ID=\$($DC ps -q database)"
    echo "   PROJECT_NAME=\$(docker inspect --format '{{ index .Config.Labels \"com.docker.compose.project\" }}' \"\$DB_ID\")"
    echo "   DB_VOLUMES=\$(docker inspect --format '{{ range .Mounts }}{{ if eq .Type \"volume\" }}{{ println .Name }}{{ end }}{{ end }}' \"\$DB_ID\")"
    echo "   echo \"Compose 项目：\$PROJECT_NAME\""
    echo "   echo \"database 容器实际卷：\"; printf '     %s\\n' \$DB_VOLUMES"
    echo "   docker volume ls --filter \"label=com.docker.compose.project=\$PROJECT_NAME\" --format '     {{.Name}}'"
    echo "   read -r -p '从上面输入要删除的 database 卷完整名：' DB_VOLUME"
    echo "   printf '%s\\n' \$DB_VOLUMES | grep -Fxq \"\$DB_VOLUME\" || { echo '不是 database 当前挂载卷，拒绝删除'; exit 1; }"
    echo "   read -r -p \"确认永久删除 \$DB_VOLUME？输入 DELETE：\" confirm_volume"
    echo "   [ \"\$confirm_volume\" = DELETE ] || { echo '已取消'; exit 1; }"
    echo "   $DC down"
    echo "   docker volume rm \"\$DB_VOLUME\""
    echo
    echo "   # 4. 改 docker-compose.yml：image: postgres:$major... → image: postgres:18-trixie"
    echo
    echo "   # 5. 启 database + 等 30 秒（让 PG 18 初始化）"
    echo "   $DC up -d database"
    echo "   sleep 30"
    echo
    echo "   # 6. 恢复数据"
    echo "   cat teslamate-backup-pg${major}-*.sql | docker exec -i \$($DC ps -q database) psql -U ${DB_USER:-teslamate}"
    echo
    echo "   # 7. 启全部服务"
    echo "   $DC up -d"
    echo
    echo "   # 8. 升级完成后重跑此迁移脚本"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    if (( major <= 15 )); then
        echo "由于会有仪表盘报错，脚本退出。先升级 PG 再回来。"
        exit 1
    fi
    # ASSUME_YES 默认走"继续"：PG 16/17 本项目所有仪表盘均可正常运行（仅与官方栈版本不一致），
    # 不是数据风险项，符合"非交互默认走安全值"——这里的安全值就是不中断迁移。
    if [[ "$ASSUME_YES" == "1" ]]; then
        pg_skip="y"
        echo "继续迁移而不升级 PG（推荐升级后再来）？ [y/N] y（ASSUME_YES=1 非交互默认：PG $major 功能完整，继续）"
    else
        read -rp "继续迁移而不升级 PG（推荐升级后再来）？ [y/N] " pg_skip </dev/tty
    fi
    if [[ "$pg_skip" != "y" && "$pg_skip" != "Y" ]]; then
        echo "已取消，先升级 PG 到 18。"
        exit 0
    fi
    echo "⚠️  跳过升级，继续。仪表盘可正常用，但与官方栈版本不一致。"
}

# 装单个 SQL：失败把真实 stderr 露出来 + 累计到 FAILED_STEPS（或 WARN_STEPS）
# level: critical（默认，计入 FAILED_STEPS，影响最终退出码）｜ warning（计入 WARN_STEPS，仅告警，不影响退出码）
# 索引（indexes-sql）失败走 warning，与 simple-deploy.sh / scripts/upgrade.sh 的「索引仅告警」口径一致；
# 坐标 / 单位换算 / 分时电价三件仍是 critical。
# 等 TeslaMate 自己的 Ecto 迁移跑完，再装我们的 SQL。
# 理由同 simple-deploy.sh：install-tou.sql 依赖 charging_processes（TeslaMate 迁移建的），
# 而 install-unit-functions.sql 抢先建 convert_* 会让上游那条不带 OR REPLACE 的迁移撞
# duplicate_function、TeslaMate 起不来。判据：等 charging_processes 出现，再等
# schema_migrations 行数连续 8 次采样（24 秒）不变——窗口取短了会在一条耗时长的迁移
# 中途误判成已完成。
# TeslaMate 容器当前状态（running / restarting / exited / unknown）。
# 崩溃重启中的 TeslaMate，schema_migrations 行数同样恒定不变，只看行数会把「迁移撞崩、
# 永久停在半途」判成「迁移已完成」，然后继续装 SQL 把问题坐实。
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
    local db="$1" u="$2" d="$3"
    local i cur last="" stable=0 code tm_st tm_port bad=0
    for i in $(seq 1 60); do
        if docker exec "$db" psql -U "$u" -d "$d" -tAc \
            "SELECT 1 FROM pg_class WHERE relname='charging_processes'" 2>/dev/null | grep -qx 1; then
            break
        fi
        tm_st=$(teslamate_container_status)
        if [ "$tm_st" = "restarting" ] || [ "$tm_st" = "exited" ] || [ "$tm_st" = "ambiguous" ]; then
            bad=$((bad + 1))
            if [ "$bad" -ge 3 ]; then
                if [ "$tm_st" = "ambiguous" ]; then
                    echo "  ✗ 机器上有多个可能是 TeslaMate 的容器，认不出哪个是你正在用的："
                    teslamate_container_candidates | sed 's/^/        /'
                    echo "    为避免猜错，这一步按「确认不了」处理。请删掉用不上的那些（docker rm 名字），"
                    echo "    或在 TeslaMate 所在目录重跑本脚本，让 compose 直接给出答案。"
                    return 1
                fi
                echo "  ✗ TeslaMate 容器状态为 ${tm_st}（反复重启/已退出），它的迁移不可能完成。"
                echo "    先看 docker logs 排掉 TeslaMate 自身的启动问题，再重跑本脚本。"
                return 1
            fi
        else
            bad=0
        fi
        sleep 3
    done
    # 第一段跑完还没 break，说明表始终没出现——这时再进第二段也只会白等一个 180 秒的
    # 超时（实测总耗时 400 秒+）。直接返回"确认不了"，让调用方走跳过分支。
    if ! docker exec "$db" psql -U "$u" -d "$d" -tAc \
        "SELECT 1 FROM pg_class WHERE relname='charging_processes'" 2>/dev/null | grep -qx 1; then
        echo "  ✗ 等了 3 分钟，TeslaMate 仍未建好自己的数据表，无法确认迁移状态。"
        return 1
    fi

    for i in $(seq 1 60); do
        # 主判据：TeslaMate 的 HTTP 端口能应答。它的 entrypoint 是先跑完整套迁移
        # 再 exec 启动服务，所以端口一应答就等于迁移结束——比数迁移行数准得多。
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
                    echo "  ✗ 机器上有多个可能是 TeslaMate 的容器，认不出哪个是你正在用的："
                    teslamate_container_candidates | sed 's/^/        /'
                    echo "    为避免猜错，这一步按「确认不了」处理。请删掉用不上的那些（docker rm 名字），"
                    echo "    或在 TeslaMate 所在目录重跑本脚本，让 compose 直接给出答案。"
                    return 1
                fi
                echo "  ✗ TeslaMate 容器状态为 ${tm_st}（反复重启/已退出），它的迁移不可能完成。"
                echo "    先看 docker logs 排掉 TeslaMate 自身的启动问题，再重跑本脚本。"
                return 1
            fi
            stable=0
            last=""
            sleep 3
            continue
        fi
        bad=0
        cur=$(docker exec "$db" psql -U "$u" -d "$d" -tAc \
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
        sleep 3
    done
    return 1
}

install_sql() {
    local label="$1" url="$2" key="$3" level="${4:-critical}"
    echo
    echo "→ 装${label}..."
    if [[ -z "${DB_CONTAINER:-}" ]]; then
        echo "⚠️  跳过：database 容器没探测到"
        if [[ "$level" == "warning" ]]; then WARN_STEPS+=("$key"); else FAILED_STEPS+=("$key"); fi
        return 1
    fi
    # 留 stderr 让用户看到真实错误（schema 不兼容 / auth 失败 等）
    # ON_ERROR_STOP=1 必须：psql 默认某条语句失败也照样 exit 0，会让「✓ 装好」印在
    # 一次实际失败的安装上（2026-07 冒烟①实测到的假绿）。四个 install-*.sql 都是幂等的
    # （CREATE OR REPLACE / IF NOT EXISTS / DROP TRIGGER IF EXISTS），重复跑不会有语句报错。
    if curl -fsSL "$url" | docker exec -i "$DB_CONTAINER" psql -U "${DB_USER:-teslamate}" -d "${DB_NAME:-teslamate}" -v ON_ERROR_STOP=1 >/dev/null; then
        echo "✓ ${label}装好"
        return 0
    fi
    if [[ "$level" == "warning" ]]; then
        echo "⚠️  ${label}装失败（不影响核心功能，仅性能/次要体验略差）。重新跑（带 stderr）："
        echo "    curl -fsSL $url | docker exec -i $DB_CONTAINER psql -U ${DB_USER:-teslamate} -d ${DB_NAME:-teslamate} -v ON_ERROR_STOP=1"
        WARN_STEPS+=("$key")
    else
        echo "⚠️  ${label}装失败。重新跑（带 stderr）："
        echo "    curl -fsSL $url | docker exec -i $DB_CONTAINER psql -U ${DB_USER:-teslamate} -d ${DB_NAME:-teslamate} -v ON_ERROR_STOP=1"
        FAILED_STEPS+=("$key")
    fi
    return 1
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
    local default_note
    local view_note
    if [[ -z "${DB_CONTAINER:-}" ]]; then
        return 0
    fi
    echo "→ 重算历史充电的分时电价费用（充电记录多的话要几十秒，请稍候）"
    if ! docker exec -i "$DB_CONTAINER" psql -U "${DB_USER:-teslamate}" -d "${DB_NAME:-teslamate}" -At -v ON_ERROR_STOP=1 \
            -c "SELECT format('✓ 已扫描 %s 笔充电，按分时电价算出 %s 笔，跳过 %s 笔（没有适用的分时电价规则）', processed, updated, skipped)
                    || CASE WHEN cleared > 0 THEN format(E'\n  · 其中 %s 笔原先存着按旧算法算出的费用，已清除；这些充电现在按 TeslaMate 记录的金额或默认电价显示，跟之前会不一样', cleared) ELSE '' END
                    || CASE WHEN gapped  > 0 THEN format(E'\n  · %s 笔充电有时段没被你配的分时电价规则覆盖，算不出可信金额；想让它们按分时电价计费，去「⚡ 分时电价配置」仪表盘的「配置审计」看缺哪几个小时', gapped) ELSE '' END
                    || CASE WHEN sampling_gapped > 0 THEN format(E'\n  · %s 笔充电因采样断档跨过不同电价，无法可靠计算分时金额；这不是你的电价配置问题，也不需要修改配置，这些充电的费用已保持原样', sampling_gapped) ELSE '' END
                    || CASE WHEN failed  > 0 THEN format(E'\n  ⚠ %s 笔充电回算时出错，已跳过；这些充电的费用维持原样，可稍后手动跑 SELECT * FROM backfill_all_tou(); 重试', failed) ELSE '' END
                    FROM backfill_all_tou();"; then
        echo "⚠️  重算失败（不影响已装好的功能，可稍后手动跑 SELECT * FROM backfill_all_tou();）"
        WARN_STEPS+=("tou-backfill")
    fi
    # 两类提示是两个独立待办，分别读取：默认电价迁移那句话不能覆盖「旧版对账视图还没清掉」
    # 这句——后者不处理，TeslaMate 升到 4.1.1 会起不来，比前者严重得多。
    default_note=$(docker exec -i "$DB_CONTAINER" psql -U "${DB_USER:-teslamate}" -d "${DB_NAME:-teslamate}" -At \
        -c "SELECT legacy_default_note FROM tou_settings WHERE legacy_default_note IS NOT NULL" 2>/dev/null) || default_note=""
    if [[ -n "$default_note" ]]; then
        echo "$default_note"
    fi
    view_note=$(docker exec -i "$DB_CONTAINER" psql -U "${DB_USER:-teslamate}" -d "${DB_NAME:-teslamate}" -At \
        -c "SELECT view_rebuild_note FROM tou_settings WHERE view_rebuild_note IS NOT NULL" 2>/dev/null) || view_note=""
    if [[ -n "$view_note" ]]; then
        echo "$view_note"
        # 只 echo 不记账 = 结尾还是「🎉 迁移完成」，用户以为没事，然后 TeslaMate 起不来
        # 还找不到线索。必须让结尾横幅变色（见文件末尾汇总）。
        LEGACY_VIEW_PENDING=1
        # 「告警项：...」这一行是打给用户看的，不是给程序看的：这里必须写人话，而且要跟
        # scripts/upgrade.sh 对同一件事的说法完全一致（那边写的就是「旧版对账视图未清理」）。
        # 同一个 P0 待办在两条路径上叫两个名字，用户没法把两次输出对上号。
        # 本文件其余条目（coord-sql / unit-sql / tou-sql）是 install_sql 的 key，同时被
        # sql_trio_ok 按字面匹配，属于机器标识，不在这次统一范围内。
        WARN_STEPS+=("旧版对账视图未清理")
    fi
    return 0
}

# 「旧版对账视图没删掉」在两处结尾横幅里都要单独讲一段：它和「性能索引没装上」不是一个
# 量级的事，不能被「非关键项告警（不影响核心功能）」那句话盖过去。
print_legacy_view_warning() {
    [[ "$LEGACY_VIEW_PENDING" -eq 1 ]] || return 0
    echo "    ⚠ 有一件事必须你亲自处理：数据库里那个旧版建的对账视图 charging_processes_v"
    echo "      这次没能删掉（原因见上面那段提示）。不处理会怎样：TeslaMate 升到 4.1.1 时"
    echo "      会启动失败、容器反复重启，行车和充电将全部停止记录。这次迁移的其余部分不受影响。"
    echo "      怎么做：照上面那段提示处理掉，然后重跑一次本脚本；那句提示会自己消失，"
    echo "      消失了才算处理干净。"
}

# 三组兼容性 SQL（coord-sql / unit-sql / tou-sql）是否全部装成功——用于判断能不能记录
# SQL 兼容性 revision。FAILED_STEPS 是全局数组，可能混着别的失败项（如 volkov-plugin），
# 所以必须逐个 key 精确比对，不能只看数组是否为空。indexes-sql 不在这三个 key 里，
# 与 simple-deploy.sh / scripts/upgrade.sh 的口径一致（性能索引不算进这个 revision）。
sql_trio_ok() {
    # 用 case + 空格分隔字符串匹配而不是数组遍历：Synology/老系统常见的 bash 3.2 在
    # set -u 下遍历「已声明但零元素」的数组会报 unbound variable，字符串匹配没有这个坑
    # （CLAUDE.md「Bash 3.2 兼容」条款同类教训）。
    case " ${FAILED_STEPS[*]:-} " in
        *" coord-sql "*|*" unit-sql "*|*" tou-sql "*) return 1 ;;
    esac
    return 0
}

# SQL 兼容性 revision 记录（issue #23/#29 事故预防：镜像更新了但 SQL 没装的机制性校验）
#
# 只在三组兼容性 SQL 全部成功（sql_trio_ok）时调用。写入 teslamate_cn_extension_meta 表，
# scripts/diagnose.sh 用它比对镜像要求的 revision（config/versions.env，随镜像一起装进
# /opt/teslamate-cn/versions.env）和数据库里实际装到的 revision，不一致就报 DEGRADED。
#
# CREATE TABLE IF NOT EXISTS 是自愈的关键：老用户的数据库压根没有这张表，本函数第一次
# 跑起来时会自动建表 + 写入当前 revision，不需要任何手动迁移步骤、不会报错。
#
# 单一事实源是仓库里的 config/versions.env；本脚本是 curl-piped 单文件脚本，不能 source
# 本地文件，现场用同一个 REPO_REF 拉取，跟拉 SQL 文件同一套信任模型，避免在这里手动硬编码
# 数字造成漂移。
# 三组兼容性 SQL 的对象是否真的在库里——记 revision 之前的最后一道校验。
# psql 的退出码不够：默认不是 ON_ERROR_STOP 时语句失败也 exit 0（2026-07 冒烟①实测到
# 「✓ 已装」+ revision=1 但 tou_rates 根本没建的假绿）。安装调用都加了 ON_ERROR_STOP=1，
# 这里再直接问库一遍作为第二道闸。谓词与 scripts/diagnose.sh 第 4 节语义一致（同样的三组对象、
# 同样的哨兵），但不是逐字相同：curl-piped 单文件脚本不能 source 公共库，各自内联了一份。
# 改任一处务必同步全部四处（simple-deploy.sh / migrate-from-official.sh / upgrade.sh / diagnose.sh）。
sql_trio_objects_present() {
    local u="${DB_USER:-teslamate}" d="${DB_NAME:-teslamate}"
    [[ -n "${DB_CONTAINER:-}" ]] || return 1
    docker exec "$DB_CONTAINER" psql -U "$u" -d "$d" -tAc \
        "SELECT count(DISTINCT proname) FROM pg_proc WHERE proname IN ('lat_for_map','lng_for_map','wgs84_to_gcj02_lat','wgs84_to_gcj02_lng','is_outside_china')" \
        2>/dev/null | grep -qx 5 || return 1
    # 只数 proname 是查不出东西的：convert_km/convert_celsius/convert_m/convert_tire_pressure
    # 这四个名字上游 TeslaMate 自己的迁移就会建（这正是"抢先建会撞车"的前提），所以任何迁移
    # 完成的库上那个计数都恒等于 4——这一腿等于没查。改查我们这版独有的特征：只有我们的
    # convert_tire_pressure 支持 kPa/kpa 单位。它又是 install-unit-functions.sql 的最后一个
    # 函数，装到它就说明整份文件都装完了，正好当哨兵。
    docker exec "$DB_CONTAINER" psql -U "$u" -d "$d" -tAc \
        "SELECT count(*) FROM pg_proc WHERE proname = 'convert_tire_pressure' AND prosrc LIKE '%kPa%'" \
        2>/dev/null | grep -qE '^[1-9][0-9]*$' || return 1
    docker exec "$DB_CONTAINER" psql -U "$u" -d "$d" -tAc \
        "SELECT 1 FROM pg_class WHERE relname='tou_rates'" \
        2>/dev/null | grep -qx 1 || return 1
    return 0
}

write_sql_compat_revision() {
    if ! sql_trio_objects_present; then
        echo "⚠️  三组兼容性 SQL 的对象没在库里查到，不记录 revision（跑 scripts/diagnose.sh 看缺哪一组）"
        return 2
    fi
    if [[ -z "${DB_CONTAINER:-}" ]]; then
        return 1
    fi
    local rev ver_safe
    rev=$(curl -fsSL "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/config/versions.env" 2>/dev/null \
        | grep -m1 '^SQL_COMPAT_REVISION=' | cut -d= -f2 | tr -d '[:space:]\r') || true
    if [[ -z "$rev" ]]; then
        echo "⚠️  拉取 SQL 兼容性 revision 失败（网络问题？），跳过记录——不影响刚装好的 SQL 功能本身"
        return 1
    fi
    ver_safe="${REPO_REF//\'/}"
    if docker exec -i "$DB_CONTAINER" psql -U "${DB_USER:-teslamate}" -d "${DB_NAME:-teslamate}" -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQLEOF
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
        echo "✓ SQL 兼容性 revision 已记录（${rev}）"
        return 0
    else
        echo "⚠️  SQL 兼容性 revision 记录失败（不影响刚装好的 SQL 功能本身，diagnose 之后可能误报过期）"
        return 1
    fi
}

# Pinned volkov-form-panel 版本，需与 Dockerfile 同步（也是 scripts/upgrade.sh 的来源）
VOLKOV_FORM_PANEL_VERSION="6.3.2"

# 等 grafana 容器可 docker exec（最多 maxsec 秒，每秒 poll 一次）
wait_grafana_ready() {
    local grafana_ct="$1" maxsec="${2:-20}"
    local i
    for ((i=0; i<maxsec; i++)); do
        if docker exec "$grafana_ct" true 2>/dev/null; then return 0; fi
        sleep 1
    done
    return 1
}

# 确保 volkovlabs-form-panel 插件已装到 Grafana 实际读取的插件目录
#
# 背景：修复 issue #20/#21 前 Dockerfile 把 plugin 装在 /var/lib/grafana/plugins，该路径
# 正是 grafana volume 挂载点。从官方迁移用户的旧 volume（来自 teslamate/grafana）覆盖镜像
# 里的 plugin 目录 → 5 个 form panel 报「panel not found」。修复后插件挪到 volume 外的
# /opt/grafana-plugins（GF_PATHS_PLUGINS 覆盖），新镜像不会再被 volume 覆盖；本函数仍保留
# 检测 + 自愈，兼容还在跑老镜像的用户（此函数有两个调用点：一个是刚 pull 完 $NEW_IMAGE 之后
# 调用，另一个是「已经在我们镜像上」分支，可能还没 pull 最新版）。
#
# 注意 1：调用必须用 `|| true` 包，否则失败时触发 set -e + on_error trap
# 注意 2：grafana 容器探测逻辑与 scripts/upgrade.sh 同款，volkov 版本号变更需同步更新两处
# 注意 3：`grafana cli plugins install` 走 grafana.com，国内网络偶尔超时；
#         失败时保留 stderr 让用户能看到真实错误（与 install_sql 同款约定）
# 注意 4：插件目录不硬编码——现场用 `docker exec` 读容器自己的 GF_PATHS_PLUGINS（新镜像=
#         /opt/grafana-plugins；老镜像没设这个 env，grafana 自身默认值就是
#         /var/lib/grafana/plugins），新老镜像都能测准、装对地方。
ensure_volkov_plugin() {
    local grafana_ct
    grafana_ct=$(cd "$COMPOSE_DIR" && $DC ps -q grafana 2>/dev/null | head -1 || true)
    if [[ -n "$grafana_ct" ]]; then
        grafana_ct=$(docker inspect --format '{{.Name}}' "$grafana_ct" 2>/dev/null | sed 's|^/||' || true)
    fi
    if [[ -z "$grafana_ct" ]]; then
        grafana_ct=$(docker ps --filter "status=running" --format '{{.Names}}' \
            | grep -E '(^|[-_])grafana([-_]|$)' | head -1 || true)
    fi
    if [[ -z "$grafana_ct" ]]; then
        echo "⚠️  探测不到 grafana 容器，跳过 volkov 插件检查"
        FAILED_STEPS+=("volkov-plugin")
        return 1
    fi

    echo
    echo "→ 检查 volkovlabs-form-panel 插件（分时电价 5 个 form panel 需要）..."

    # 等容器能 exec（避免 8 秒硬等不够 / 太久无谓阻塞）
    if ! wait_grafana_ready "$grafana_ct" 20; then
        echo "⚠️  grafana 容器 20 秒内未就绪：$($DC ps grafana 2>/dev/null | tail -1)"
        echo "    手动确认状态后重跑本脚本"
        FAILED_STEPS+=("volkov-plugin")
        return 1
    fi

    # 容器实际配置的插件目录（见上方注意 4）
    local plugin_dir
    plugin_dir=$(docker exec "$grafana_ct" sh -c 'echo "${GF_PATHS_PLUGINS:-/var/lib/grafana/plugins}"' 2>/dev/null) || true
    plugin_dir="${plugin_dir:-/var/lib/grafana/plugins}"

    if docker exec "$grafana_ct" test -d "${plugin_dir}/volkovlabs-form-panel" 2>/dev/null \
       || docker exec "$grafana_ct" test -d /var/lib/grafana/plugins/volkovlabs-form-panel 2>/dev/null; then
        echo "✓ volkov-form-panel 已就位"
        return 0
    fi

    echo "⚠️  Grafana 插件目录（${plugin_dir}）缺 volkov-form-panel（迁移/老镜像用户常踩的 volume 覆盖坑）"
    echo "    正在装（--user root 仅本次 docker exec，命令退出后恢复 grafana user）..."
    # 保留 stderr：网络超时 / signature 错 / 磁盘满都能看到真实原因
    if docker exec --user root "$grafana_ct" \
            grafana cli --pluginsDir "$plugin_dir" plugins install volkovlabs-form-panel "$VOLKOV_FORM_PANEL_VERSION" >/dev/null; then
        if $DC restart grafana >/dev/null 2>&1; then
            echo "✓ volkov-form-panel 已装好，grafana 已重启"
            return 0
        fi
        echo "⚠️  插件已装但 grafana 重启失败。手动跑：$DC restart grafana"
        FAILED_STEPS+=("grafana-restart")
        return 1
    fi

    echo "⚠️  自动装插件失败（grafana.com 国内常超时）。两条修复路："
    echo
    echo "  路径 A — 从镜像本地复制（推荐，无外网依赖）："
    echo "    docker pull $NEW_IMAGE"
    echo "    docker create --name volkov-tmp $NEW_IMAGE"
    echo "    docker cp volkov-tmp:/opt/grafana-plugins/volkovlabs-form-panel /tmp/volkovlabs-form-panel"
    echo "    docker rm volkov-tmp"
    echo "    docker cp /tmp/volkovlabs-form-panel $grafana_ct:${plugin_dir}/"
    echo "    docker exec --user root $grafana_ct chown -R 472:472 ${plugin_dir}/volkovlabs-form-panel"
    echo "    $DC restart grafana && rm -rf /tmp/volkovlabs-form-panel"
    echo
    echo "  路径 B — 重试 grafana cli（看真实错误）："
    echo "    docker exec --user root $grafana_ct grafana cli --pluginsDir ${plugin_dir} plugins install volkovlabs-form-panel $VOLKOV_FORM_PANEL_VERSION"
    echo "    $DC restart grafana"
    FAILED_STEPS+=("volkov-plugin")
    return 1
}

# ── Trap：脚本中段失败 / Ctrl+C 给 actionable 退路 ───────────────────
on_error() {
    local rc=$?
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -n "${BACKUP_FILE:-}" && -f "$BACKUP_FILE" ]]; then
        echo "❌ 中途失败（exit ${rc}）。回滚命令："
        echo "   cp \"$BACKUP_FILE\" \"$COMPOSE_FILE\""
        [[ -n "${COMPOSE_DIR:-}" && -n "${DC:-}" ]] && echo "   cd \"$COMPOSE_DIR\" && $DC up -d grafana"
    else
        echo "❌ 中途失败（exit ${rc}）。还没改任何东西。"
    fi
    echo "💬 求助：https://t.me/+BeOASgmvE_IyNzNl（Telegram 群）"
    exit $rc
}
on_interrupt() {
    echo
    case "$MIGRATION_STAGE" in
        pre-change)
            echo "已中断；尚未修改 Compose 文件。"
            ;;
        backup-created)
            echo "已中断；已创建备份，但尚未修改 Compose 文件：$BACKUP_FILE"
            ;;
        *)
            echo "已中断；Compose 文件可能已修改，Grafana 也可能已切换。回滚命令："
            echo "   cp \"$BACKUP_FILE\" \"$COMPOSE_FILE\""
            echo "   cd \"$COMPOSE_DIR\" && $DC up -d grafana"
            ;;
    esac
    exit 130
}
trap on_error ERR
trap on_interrupt INT

# ── Main ────────────────────────────────────────────────────────────
echo "🇨🇳 TeslaMate 中文仪表盘迁移脚本（从官方源 → 我们的源）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# 1. tty 检测（防 curl|bash 误用）；ASSUME_YES=1（或 --yes/-y）可跳过，用于 CI / 自动化
if [[ ! -t 0 && "$ASSUME_YES" != "1" ]]; then
    echo "❌ 检测到 stdin 不是终端，可能是 curl|bash 跑的。"
    echo "   请先 wget 下来再 bash 执行（脚本中段需要 y/N 确认）："
    echo "   wget https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/migrate-from-official.sh"
    echo "   bash migrate-from-official.sh"
    echo
    echo "   或非交互运行（CI / 自动化，所有确认走安全默认值）："
    echo "   ASSUME_YES=1 bash migrate-from-official.sh"
    exit 1
fi

# 2. preflight：docker daemon + compose CLI（在改任何文件之前）
preflight_docker
detect_compose_cli
echo "✓ docker daemon 在跑"
echo "✓ docker compose CLI: $DC"

# 3. 找 compose 文件
find_compose_file
COMPOSE_DIR=$(dirname "$COMPOSE_FILE")
echo "✓ 找到 compose 文件：$COMPOSE_FILE"

# 4. 检测当前 image — 锚定到行首 + 排除注释
CURRENT_IMAGE=""
if grep -m1 -qE "^[[:space:]]+image:[[:space:]]*${OFFICIAL_IMAGE_RE}" "$COMPOSE_FILE"; then
    CURRENT_IMAGE=$(grep -m1 -oE "^[[:space:]]+image:[[:space:]]*${OFFICIAL_IMAGE_RE}" "$COMPOSE_FILE" \
        | sed 's|^[[:space:]]*image:[[:space:]]*||')
    echo "✓ 检测到官方 grafana 镜像：$CURRENT_IMAGE"
elif grep -m1 -qE "^[[:space:]]+image:[[:space:]]*${OUR_IMAGE_RE}" "$COMPOSE_FILE"; then
    echo "ℹ️  你已经在我们的镜像上了，image 不需要改。"
    echo
    # ASSUME_YES 默认走"重装"：SQL 安装脚本 + 插件修补均幂等（重复跑不丢数据/不报错），
    # 是这条路径里唯一有实际意义的动作，跳过等于整条路径空跑，故不算危险操作。
    if [[ "$ASSUME_YES" == "1" ]]; then
        sql_confirm="y"
        echo "要重装/升级 SQL（坐标函数 + 单位换算 + 分时电价 + 性能索引）+ 修补 volkov 插件吗？ [y/N] y（ASSUME_YES=1 非交互默认：重装，SQL/插件安装均幂等）"
    else
        read -rp "要重装/升级 SQL（坐标函数 + 单位换算 + 分时电价 + 性能索引）+ 修补 volkov 插件吗？ [y/N] " sql_confirm </dev/tty
    fi
    if [[ "$sql_confirm" == "y" || "$sql_confirm" == "Y" ]]; then
        cd "$COMPOSE_DIR"
        # 先修 volkov 插件兜底（若 grafana volume 缺，自动装；同样适用于先前版本没跑这段的迁移用户）
        ensure_volkov_plugin || true
        detect_db_container || true
        if [[ -n "${DB_CONTAINER:-}" ]]; then
            echo "→ 等 TeslaMate 完成自身数据库迁移（已在跑的实例通常几秒就确认）"
            TM_MIGRATED=1
            if ! wait_teslamate_migrated "$DB_CONTAINER" "${DB_USER:-teslamate}" "${DB_NAME:-teslamate}"; then
                TM_MIGRATED=0
                echo "⚠️  没能确认 TeslaMate 迁移已完成。为避免和它的迁移撞车，这次跳过单位换算函数"
                echo "    （撞车会让 TeslaMate 自己起不来，且重跑本脚本也修不好）。等它正常启动后重跑即可补上。"
            fi
        fi
        install_sql "坐标转换函数（地图轨迹纠偏）" \
            "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-coord-functions.sql" \
            "coord-sql" || true
        # TM_MIGRATED=0 时必须真的跳过，不能只打印一句（这组函数与上游同名，抢先建会让
        # TeslaMate 的迁移撞 duplicate_function 而永久起不来）
        if [[ "${TM_MIGRATED:-1}" -eq 0 ]]; then
            echo "⏭ 跳过单位换算函数（没能确认 TeslaMate 迁移已完成）"
            FAILED_STEPS+=("unit-sql")
        else
            install_sql "单位换算函数（km/mi、温度、海拔、胎压）" \
                "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-unit-functions.sql" \
                "unit-sql" || true
        fi
        if install_sql "分时电价旁路表（不动 TeslaMate 任何表）" \
                "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-tou.sql" \
                "tou-sql"; then
            run_tou_backfill
        fi
        install_sql "性能优化索引（positions 表 car_id+date btree）" \
            "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-indexes.sql" \
            "indexes-sql" "warning" || true
        if sql_trio_ok; then
            _rev_rc=0
            write_sql_compat_revision || _rev_rc=$?
            [[ "$_rev_rc" -eq 2 ]] && FAILED_STEPS+=("sql-object-check")
        fi
    fi
    echo
    if [[ ${#FAILED_STEPS[@]} -eq 0 ]]; then
        if [[ "$LEGACY_VIEW_PENDING" -eq 1 ]]; then
            echo "⚠️  装完了，但留了一个尾巴给你"
        else
            echo "✓ 完成"
        fi
        print_legacy_view_warning
        # 不再写「不影响核心功能」：「旧版对账视图未清理」这一项恰恰会影响用户的下一步。
        [[ ${#WARN_STEPS[@]} -eq 0 ]] || echo "  ⚠ 告警项：${WARN_STEPS[*]}"
    else
        echo "⚠️  ${#FAILED_STEPS[@]} 项 SQL 没装成功，看上面输出"
        print_legacy_view_warning
        exit 2
    fi
    exit 0
else
    echo "⚠️  没识别出官方 grafana image。当前 image 行："
    grep -nE "^[[:space:]]+image:" "$COMPOSE_FILE" | sed 's/\(password\|key\|secret\|token\)=[^[:space:]"]*/\1=***/gI'
    echo
    echo "   这个脚本只处理「官方源 → 我们」的迁移。其他情况按 README 方法 C 手动改。"
    exit 1
fi

# 5a. PG 版本检测（在备份/改文件之前，给用户机会先升级）
detect_db_container || true
check_pg_version

# 5b. 改过 dashboard 提醒
echo
echo "⚠️  迁移会用我们的仪表盘替换官方版本。如果你在 Grafana 里手动改过面板，"
echo "   先到 Grafana → 仪表盘 → ⋮ → Export 备份 JSON，迁移完再 Import 回去。"
echo

# 6. 预览改动
echo "📋 我会做这 5 件事："
echo "   1) 备份 docker-compose.yml.bak.\$(date +%Y%m%d-%H%M%S)（mode 600，含 ENCRYPTION_KEY）"
echo "   2) 改 grafana image：$CURRENT_IMAGE  →  $NEW_IMAGE"
echo "   3) $DC pull grafana && $DC up -d grafana"
echo "   4) 检查 + 自动装 volkov-form-panel 插件（修「分时电价配置」5 个 form panel 报 panel not found 的 volume 覆盖坑）"
echo "   5) 装 4 个 SQL（坐标函数 + 单位换算 + 分时电价 + 性能索引，重复跑不会丢数据）"
echo
echo "⚠️  TeslaMate / Postgres / MQTT 容器完全不动。ENCRYPTION_KEY、Tesla token、"
echo "    所有数据 0 丢失。万一不满意：把 image 改回去重启 grafana 即回滚。"
echo
# ASSUME_YES 默认走"继续"：上面 5 步预览已明确写出全部动作，且脚本自身保证
# 数据零丢失/完全可逆（备份 mode 600 + TeslaMate/Postgres/MQTT 容器不动），
# 是整个脚本唯一的核心动作，跳过等于脚本空转，故不算危险操作。
if [[ "$ASSUME_YES" == "1" ]]; then
    confirm="y"
    echo "继续？ [y/N] y（ASSUME_YES=1 非交互默认：执行迁移，见上方 5 步预览）"
else
    read -rp "继续？ [y/N] " confirm </dev/tty
fi
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "已取消，没动任何东西。"; exit 0; }

# 7. 备份（mode 600 避免 ENCRYPTION_KEY 全局可读）
BACKUP_FILE="${COMPOSE_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
install -m 600 "$COMPOSE_FILE" "$BACKUP_FILE" 2>/dev/null \
    || { cp "$COMPOSE_FILE" "$BACKUP_FILE"; chmod 600 "$BACKUP_FILE"; }
echo "✓ 已备份到 ${BACKUP_FILE}（mode 600）"
MIGRATION_STAGE="backup-created"

# 8. sed 改 image — 用 | 当分隔符避免 NEW_IMAGE/路径里的 / 冲突
# （image: 行不含 |；BSD/GNU sed 都接受 | 当分隔符，比 \x01 兼容性好）
MIGRATION_STAGE="compose-changing"
sed -i.tmp -E "s|^([[:space:]]+image:[[:space:]]*)${OFFICIAL_IMAGE_RE}|\1${NEW_IMAGE}|" "$COMPOSE_FILE"
rm -f "${COMPOSE_FILE}.tmp"
MIGRATION_STAGE="compose-modified"
echo "✓ image 已替换"

# 9. 拉新镜像 + 重启 grafana
cd "$COMPOSE_DIR"
echo
echo "→ 拉新镜像 + 重启 grafana..."
$DC pull grafana
$DC up -d grafana
MIGRATION_STAGE="grafana-restarted"
echo "✓ grafana 已切到中文版镜像"

# 9b. volkov-form-panel 插件兜底（修官方迁移的 volume 覆盖坑）
# 函数内部用 poll loop 等 grafana 就绪，最多 20 秒
ensure_volkov_plugin || true

# 10. 装 SQL（探测 DB 容器名 → install_sql × 4）
detect_db_container || true
TM_MIGRATED=1
if [[ -n "${DB_CONTAINER:-}" ]]; then
    echo "→ 等 TeslaMate 完成自身数据库迁移"
    if ! wait_teslamate_migrated "$DB_CONTAINER" "${DB_USER:-teslamate}" "${DB_NAME:-teslamate}"; then
        TM_MIGRATED=0
        echo "⚠️  没能确认 TeslaMate 迁移已完成，这次跳过单位换算函数（抢先建同名函数会让 TeslaMate 起不来）"
    fi
fi
install_sql "坐标转换函数（地图轨迹纠偏）" \
    "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-coord-functions.sql" \
    "coord-sql" || true
if [[ "${TM_MIGRATED:-1}" -eq 0 ]]; then
    echo "⏭ 跳过单位换算函数（没能确认 TeslaMate 迁移已完成）"
    FAILED_STEPS+=("unit-sql")
else
    install_sql "单位换算函数（km/mi、温度、海拔、胎压）" \
        "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-unit-functions.sql" \
        "unit-sql" || true
fi
if install_sql "分时电价旁路表（不动 TeslaMate 任何表）" \
        "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-tou.sql" \
        "tou-sql"; then
    run_tou_backfill
fi
install_sql "性能优化索引（positions 表 car_id+date btree）" \
    "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-indexes.sql" \
    "indexes-sql" "warning" || true

# 10b. 三组兼容性 SQL 全部成功才记录 revision（性能索引不算，见 sql_trio_ok 定义处注释）
if sql_trio_ok; then
    _rev_rc=0
    write_sql_compat_revision || _rev_rc=$?
    [[ "$_rev_rc" -eq 2 ]] && FAILED_STEPS+=("sql-object-check")
fi

# 11. 完成 / 部分完成 汇总
trap - ERR  # 后面只是 echo，不需要再触发 on_error
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${#FAILED_STEPS[@]} -eq 0 ]]; then
    if [[ "$LEGACY_VIEW_PENDING" -eq 1 ]]; then
        echo "⚠️  迁移完成，但留了一个尾巴给你"
    else
        echo "🎉 迁移完成"
    fi
    print_legacy_view_warning
    if [[ ${#WARN_STEPS[@]} -gt 0 ]]; then
        # 不再写「不影响核心功能」：「旧版对账视图未清理」这一项恰恰会影响用户的下一步。
        echo "    ⚠ 告警项：${WARN_STEPS[*]}"
    fi
    echo
    echo "现在打开 http://你的IP:3000 — 45 个中文仪表盘已就绪。"
else
    echo "⚠️  迁移部分完成（grafana 已切镜像，但有 ${#FAILED_STEPS[@]} 项 SQL 失败）"
    echo "    失败项：${FAILED_STEPS[*]}"
    print_legacy_view_warning
    if [[ ${#WARN_STEPS[@]} -gt 0 ]]; then
        echo "    另有告警项：${WARN_STEPS[*]}"
    fi
    echo "    照上面的命令补跑，或起容器后重跑本脚本（会自动跳过 image 替换、只重装 SQL）"
fi
echo
echo "📌 下一步（可选）："
echo "   • 配分时电价：仪表盘里点「⚡ 分时电价配置」→「🌆 一键导入城市模板」"
echo "   • 地图改国内瓦片：仪表盘地图右上角下拉框选高德/谷歌"
echo "   • 行程列表地址列空 = nominatim.openstreetmap.org 国内访问超时。"
echo "     修法见 TROUBLESHOOTING.md#nominatim-proxy（加一行 NOMINATIM_PROXY env 即可）"
echo
echo "🔙 想回滚？"
echo "   cp \"$BACKUP_FILE\" \"$COMPOSE_FILE\""
echo "   cd \"$COMPOSE_DIR\" && $DC up -d grafana"
echo "   （注：SQL 函数和分时电价表留在数据库里对官方版无害，无需删除）"
echo "   备份文件含 ENCRYPTION_KEY，确认不需要回滚后建议清理：rm \"$BACKUP_FILE\""
echo
echo "💬 出问题：https://t.me/+BeOASgmvE_IyNzNl（Telegram 群）"
MIGRATION_STAGE="complete"

# 部分完成时返回非零，便于自动化检测
[[ ${#FAILED_STEPS[@]} -eq 0 ]] || exit 2
