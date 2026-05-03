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
    read -rp "要重装/升级 SQL（坐标函数 + 分时电价 + 性能索引）吗？ [y/N] " sql_confirm </dev/tty
    if [[ "$sql_confirm" == "y" || "$sql_confirm" == "Y" ]]; then
        cd "$COMPOSE_DIR"
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

# 5. 改过 dashboard 提醒
echo
echo "⚠️  迁移会用我们的 dashboard 替换官方版本。如果你在 Grafana 里手动改过 panel，"
echo "   先到 Grafana → 仪表盘 → ⋮ → Export 备份 JSON，迁移完再 Import 回去。"
echo

# 6. 预览改动
echo "📋 我会做这 4 件事："
echo "   1) 备份 docker-compose.yml.bak.\$(date +%Y%m%d-%H%M%S)（mode 600，含 ENCRYPTION_KEY）"
echo "   2) 改 grafana image：$CURRENT_IMAGE  →  $NEW_IMAGE"
echo "   3) $DC pull grafana && $DC up -d grafana"
echo "   4) 装 2 个 SQL（坐标函数 + 分时电价旁路表，重复跑不会丢数据）"
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
