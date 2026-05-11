#!/usr/bin/env bash
# 从官方源 TeslaMate 迁移到中文 Dashboard 版（teslamate-chinese-dashboards）
# 一键脚本：找 docker-compose.yml → 备份 → 改 grafana image + ENV → 重启 grafana → 装 SQL
#
# 数据零丢失。完全可逆。
# 跑：bash migrate-from-official.sh
#
# 安全提示：脚本通过 https 拉远程 SQL（GitHub raw）。如担心仓库被劫持，
# 把 REPO_REF 设成具体 commit SHA：REPO_REF=abc123... bash migrate-from-official.sh

set -euo pipefail

# ── 配置 ────────────────────────────────────────────────────────────
NEW_IMAGE="bswlhbhmt816/teslamate-chinese-dashboards:latest"
# REPO_REF 默认 main（跟 :latest 镜像同步）。要锁版本传 REPO_REF=v1.6.1 或 commit SHA
REPO_REF="${REPO_REF:-main}"
OFFICIAL_IMAGE_RE='teslamate/grafana(:[a-zA-Z0-9._-]*)?'
COMPOSE_FILE="${COMPOSE_FILE:-}"

# 失败步骤累计（最后汇总）
FAILED_STEPS=()

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

# 探测 PG 版本 — 我们要求 18+（与官方 teslamate-org 默认对齐）
# 12 个仪表盘用 3-arg date_trunc，PG ≤15 直接报错；PG 16/17 能跑但建议升 18
check_pg_version() {
    if [[ -z "${DB_CONTAINER:-}" ]]; then return 0; fi
    local ver
    ver=$(docker exec -i "$DB_CONTAINER" psql -U "${DB_USER:-teslamate}" -d "${DB_NAME:-teslamate}" \
        -tAc "SHOW server_version_num" 2>/dev/null | tr -d '[:space:]' || true)
    [[ -z "$ver" ]] && return 0  # 探测失败不阻塞
    local major=$(( ver / 10000 ))
    PG_MAJOR=$major
    if (( major >= 18 )); then
        echo "✓ PostgreSQL $major（与官方对齐）"
        return 0
    fi
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if (( major <= 15 )); then
        echo "❌ 检测到 PostgreSQL $major — **必须先升级到 18** 才能继续"
        echo "   原因：本项目 12 个仪表盘用 3-arg date_trunc 时区聚合（PG 16+ 才支持）"
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
    echo "   # 3. 停服务 + 删旧 PG 数据卷（不可逆，备份没做完别走这步）"
    echo "   cd \"$(dirname "$COMPOSE_FILE")\""
    echo "   $DC down"
    echo "   docker volume rm \$($DC config --volumes | grep -E 'db|database|postgres' | head -1)"
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
    read -rp "继续迁移而不升级 PG（推荐升级后再来）？ [y/N] " pg_skip </dev/tty
    if [[ "$pg_skip" != "y" && "$pg_skip" != "Y" ]]; then
        echo "已取消，先升级 PG 到 18。"
        exit 0
    fi
    echo "⚠️  跳过升级，继续。仪表盘可正常用，但与官方栈版本不一致。"
}

# 装单个 SQL：失败把真实 stderr 露出来 + 累计到 FAILED_STEPS
install_sql() {
    local label="$1" url="$2" key="$3"
    echo
    echo "→ 装${label}..."
    if [[ -z "${DB_CONTAINER:-}" ]]; then
        echo "⚠️  跳过：database 容器没探测到"
        FAILED_STEPS+=("$key")
        return 1
    fi
    # 留 stderr 让用户看到真实错误（schema 不兼容 / auth 失败 等）
    if curl -fsSL "$url" | docker exec -i "$DB_CONTAINER" psql -U "${DB_USER:-teslamate}" -d "${DB_NAME:-teslamate}" >/dev/null; then
        echo "✓ ${label}装好"
        return 0
    fi
    echo "⚠️  ${label}装失败。重新跑（带 stderr）："
    echo "    curl -fsSL $url | docker exec -i $DB_CONTAINER psql -U ${DB_USER:-teslamate} -d ${DB_NAME:-teslamate}"
    FAILED_STEPS+=("$key")
    return 1
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

# 确保 volkovlabs-form-panel 插件已装到 Grafana volume
#
# 背景：Dockerfile 把 plugin 装在 /var/lib/grafana/plugins，但该路径正是 grafana volume
# 挂载点。从官方迁移用户的旧 volume（来自 teslamate/grafana）覆盖镜像里的 plugin 目录
# → 5 个 form panel 报「panel not found」。本函数检测 + 自愈。
#
# 注意 1：调用必须用 `|| true` 包，否则失败时触发 set -e + on_error trap
# 注意 2：grafana 容器探测逻辑与 scripts/upgrade.sh 同款，volkov 版本号变更需同步更新两处
# 注意 3：`grafana cli plugins install` 走 grafana.com，国内网络偶尔超时；
#         失败时保留 stderr 让用户能看到真实错误（与 install_sql 同款约定）
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

    if docker exec "$grafana_ct" test -d /var/lib/grafana/plugins/volkovlabs-form-panel 2>/dev/null; then
        echo "✓ volkov-form-panel 已就位"
        return 0
    fi

    echo "⚠️  Grafana volume 缺 volkov-form-panel 插件（迁移用户常踩的 volume 覆盖坑）"
    echo "    正在装到 volume（--user root 仅本次 docker exec，命令退出后恢复 grafana user）..."
    # 保留 stderr：网络超时 / signature 错 / 磁盘满都能看到真实原因
    if docker exec --user root "$grafana_ct" \
            grafana cli --pluginsDir /var/lib/grafana/plugins plugins install volkovlabs-form-panel "$VOLKOV_FORM_PANEL_VERSION" >/dev/null; then
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
    echo "    docker create --name volkov-tmp $NEW_IMAGE"
    echo "    docker cp volkov-tmp:/var/lib/grafana/plugins/volkovlabs-form-panel /tmp/volkovlabs-form-panel"
    echo "    docker rm volkov-tmp"
    echo "    docker cp /tmp/volkovlabs-form-panel $grafana_ct:/var/lib/grafana/plugins/"
    echo "    docker exec --user root $grafana_ct chown -R 472:472 /var/lib/grafana/plugins/volkovlabs-form-panel"
    echo "    $DC restart grafana && rm -rf /tmp/volkovlabs-form-panel"
    echo
    echo "  路径 B — 重试 grafana cli（看真实错误）："
    echo "    docker exec --user root $grafana_ct grafana cli --pluginsDir /var/lib/grafana/plugins plugins install volkovlabs-form-panel $VOLKOV_FORM_PANEL_VERSION"
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
        echo "❌ 中途失败（exit $rc）。回滚命令："
        echo "   cp \"$BACKUP_FILE\" \"$COMPOSE_FILE\""
        [[ -n "${COMPOSE_DIR:-}" && -n "${DC:-}" ]] && echo "   cd \"$COMPOSE_DIR\" && $DC up -d grafana"
    else
        echo "❌ 中途失败（exit $rc）。还没改任何东西。"
    fi
    echo "💬 求助：https://t.me/+BeOASgmvE_IyNzNl（Telegram 群）"
    exit $rc
}
on_interrupt() {
    echo
    echo "已中断，没动任何东西。"
    exit 130
}
trap on_error ERR
trap on_interrupt INT

# ── Main ────────────────────────────────────────────────────────────
echo "🇨🇳 TeslaMate 中文 Dashboard 迁移脚本（从官方源 → 我们的源）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# 1. tty 检测（防 curl|bash 误用）
if [[ ! -t 0 ]]; then
    echo "❌ 检测到 stdin 不是终端，可能是 curl|bash 跑的。"
    echo "   请先 wget 下来再 bash 执行（脚本中段需要 y/N 确认）："
    echo "   wget https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/migrate-from-official.sh"
    echo "   bash migrate-from-official.sh"
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
elif grep -m1 -qE "^[[:space:]]+image:[[:space:]]*bswlhbhmt816/teslamate-chinese-dashboards" "$COMPOSE_FILE"; then
    echo "ℹ️  你已经在我们的镜像上了，image 不需要改。"
    echo
    read -rp "要重装/升级 SQL（坐标函数 + 分时电价 + 性能索引）+ 修补 volkov 插件吗？ [y/N] " sql_confirm </dev/tty
    if [[ "$sql_confirm" == "y" || "$sql_confirm" == "Y" ]]; then
        cd "$COMPOSE_DIR"
        # 先修 volkov 插件兜底（若 grafana volume 缺，自动装；同样适用于先前版本没跑这段的迁移用户）
        ensure_volkov_plugin || true
        detect_db_container || true
        install_sql "坐标转换函数（地图轨迹纠偏）" \
            "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-coord-functions.sql" \
            "coord-sql" || true
        install_sql "分时电价旁路表（不动 TeslaMate 任何表）" \
            "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-tou.sql" \
            "tou-sql" || true
        install_sql "性能优化索引（positions 表 car_id+date btree）" \
            "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-indexes.sql" \
            "indexes-sql" || true
    fi
    echo
    if [[ ${#FAILED_STEPS[@]} -eq 0 ]]; then
        echo "✓ 完成"
    else
        echo "⚠️  ${#FAILED_STEPS[@]} 项 SQL 没装成功，看上面输出"
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
echo "⚠️  迁移会用我们的 dashboard 替换官方版本。如果你在 Grafana 里手动改过 panel，"
echo "   先到 Grafana → 仪表盘 → ⋮ → Export 备份 JSON，迁移完再 Import 回去。"
echo

# 6. 预览改动
echo "📋 我会做这 5 件事："
echo "   1) 备份 docker-compose.yml.bak.\$(date +%Y%m%d-%H%M%S)（mode 600，含 ENCRYPTION_KEY）"
echo "   2) 改 grafana image：$CURRENT_IMAGE  →  $NEW_IMAGE"
echo "   3) $DC pull grafana && $DC up -d grafana"
echo "   4) 检查 + 自动装 volkov-form-panel 插件（修「分时电价配置」5 个 form panel 报 panel not found 的 volume 覆盖坑）"
echo "   5) 装 3 个 SQL（坐标函数 + 分时电价 + 性能索引，重复跑不会丢数据）"
echo
echo "⚠️  TeslaMate / Postgres / MQTT 容器完全不动。ENCRYPTION_KEY、Tesla token、"
echo "    所有数据 0 丢失。万一不满意：把 image 改回去重启 grafana 即回滚。"
echo
read -rp "继续？ [y/N] " confirm </dev/tty
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "已取消，没动任何东西。"; exit 0; }

# 7. 备份（mode 600 避免 ENCRYPTION_KEY 全局可读）
BACKUP_FILE="${COMPOSE_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
install -m 600 "$COMPOSE_FILE" "$BACKUP_FILE" 2>/dev/null \
    || { cp "$COMPOSE_FILE" "$BACKUP_FILE"; chmod 600 "$BACKUP_FILE"; }
echo "✓ 已备份到 $BACKUP_FILE（mode 600）"

# 8. sed 改 image — 用 | 当分隔符避免 NEW_IMAGE/路径里的 / 冲突
# （image: 行不含 |；BSD/GNU sed 都接受 | 当分隔符，比 \x01 兼容性好）
sed -i.tmp -E "s|^([[:space:]]+image:[[:space:]]*)${OFFICIAL_IMAGE_RE}|\1${NEW_IMAGE}|" "$COMPOSE_FILE"
rm -f "${COMPOSE_FILE}.tmp"
echo "✓ image 已替换"

# 9. 拉新镜像 + 重启 grafana
cd "$COMPOSE_DIR"
echo
echo "→ 拉新镜像 + 重启 grafana..."
$DC pull grafana
$DC up -d grafana
echo "✓ grafana 已切到中文版镜像"

# 9b. volkov-form-panel 插件兜底（修官方迁移的 volume 覆盖坑）
# 函数内部用 poll loop 等 grafana 就绪，最多 20 秒
ensure_volkov_plugin || true

# 10. 装 SQL（探测 DB 容器名 → install_sql × 3）
detect_db_container || true
install_sql "坐标转换函数（地图轨迹纠偏）" \
    "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-coord-functions.sql" \
    "coord-sql" || true
install_sql "分时电价旁路表（不动 TeslaMate 任何表）" \
    "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-tou.sql" \
    "tou-sql" || true
install_sql "性能优化索引（positions 表 car_id+date btree）" \
    "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REPO_REF}/sql/install-indexes.sql" \
    "indexes-sql" || true

# 11. 完成 / 部分完成 汇总
trap - ERR  # 后面只是 echo，不需要再触发 on_error
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${#FAILED_STEPS[@]} -eq 0 ]]; then
    echo "🎉 迁移完成"
    echo
    echo "现在打开 http://你的IP:3000 — 43 个中文 dashboard 已就绪。"
else
    echo "⚠️  迁移部分完成（grafana 已切镜像，但有 ${#FAILED_STEPS[@]} 项 SQL 失败）"
    echo "    失败项：${FAILED_STEPS[*]}"
    echo "    照上面的命令补跑，或起容器后重跑本脚本（会自动跳过 image 替换、只重装 SQL）"
fi
echo
echo "📌 下一步（可选）："
echo "   • 配分时电价：仪表盘里点「⚡ 分时电价配置」→「🌆 一键导入城市模板」"
echo "   • 地图改国内瓦片：仪表盘地图右上角下拉框选高德/谷歌"
echo
echo "🔙 想回滚？"
echo "   cp \"$BACKUP_FILE\" \"$COMPOSE_FILE\""
echo "   cd \"$COMPOSE_DIR\" && $DC up -d grafana"
echo "   （注：SQL 函数和分时电价表留在数据库里对官方版无害，无需删除）"
echo "   备份文件含 ENCRYPTION_KEY，确认不需要回滚后建议清理：rm \"$BACKUP_FILE\""
echo
echo "💬 出问题：https://t.me/+BeOASgmvE_IyNzNl（Telegram 群）"

# 部分完成时返回非零，便于自动化检测
[[ ${#FAILED_STEPS[@]} -eq 0 ]] || exit 2
