#!/bin/bash
# TeslaMate 中文 Dashboard 一键诊断脚本
# 用法: bash scripts/diagnose.sh （在 ~/teslamate-chinese 或装好的目录跑）
# 输出: 关键状态报告 + 常见问题指引，不修改任何配置

# 不开 set -e，单项失败不影响其他检查继续跑

PROJECT="${COMPOSE_PROJECT_NAME:-teslamate}"
PASS=0
FAIL=0
WARN=0

ok()    { printf "  ✓ %s\n" "$1"; PASS=$((PASS+1)); }
fail()  { printf "  ✗ %s\n" "$1"; FAIL=$((FAIL+1)); }
warn()  { printf "  ⚠ %s\n" "$1"; WARN=$((WARN+1)); }
info()  { printf "  → %s\n" "$1"; }

echo "================================================="
echo "  TeslaMate 中文 Dashboard 诊断"
echo "================================================="
echo ""

# ---------------- 1. Docker 基础 ----------------
echo "1. Docker 基础"
if command -v docker >/dev/null 2>&1; then
    ok "docker 已安装：$(docker --version | head -1)"
else
    fail "docker 未安装"
    echo ""
    echo "推荐先看 README.md 安装 Docker，再回来跑诊断"
    exit 1
fi

if docker info >/dev/null 2>&1; then
    ok "docker daemon 可访问"
else
    fail "docker daemon 跑不动（权限不够？群晖用户需要 root 或 docker 组）"
    echo ""
    echo "修：sudo usermod -aG docker \$USER && newgrp docker"
    exit 1
fi

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
    ok "Docker Compose v2: $($DC version --short 2>/dev/null)"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
    warn "Docker Compose v1（已过时，建议升级到 v2）"
else
    fail "Docker Compose 未安装"
    exit 1
fi
echo ""

# ---------------- 2. 容器状态 ----------------
echo "2. 容器状态"
EXPECTED=(teslamate database grafana mosquitto)
ALL_RUNNING=1
for svc in "${EXPECTED[@]}"; do
    CID=$(docker ps --format '{{.Names}}' | grep -E "^${PROJECT}-${svc}-[0-9]+$" | head -1)
    if [ -z "$CID" ]; then
        fail "${svc} 容器未找到（期望名 ${PROJECT}-${svc}-1）"
        ALL_RUNNING=0
        continue
    fi

    STATUS=$(docker inspect --format '{{.State.Status}}' "$CID" 2>/dev/null)
    if [ "$STATUS" = "running" ]; then
        UPTIME=$(docker inspect --format '{{.State.StartedAt}}' "$CID" 2>/dev/null | cut -dT -f1)
        ok "${svc} 运行中（自 $UPTIME 起）"
    else
        fail "${svc} 状态异常: $STATUS"
        ALL_RUNNING=0
        info "最近 10 行日志："
        docker logs --tail 10 "$CID" 2>&1 | sed 's/^/    | /'
    fi
done
echo ""

# ---------------- 3. 端口监听 ----------------
echo "3. 端口监听"
check_port_listen() {
    local port=$1
    # 优先 lsof（macOS / Linux 都准），其次 ss（Linux），最后 netstat（仅 GNU 准）
    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$port" -sTCP:LISTEN -P -n >/dev/null 2>&1
    elif command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    else
        return 2
    fi
}

for entry in "TeslaMate:4000" "Grafana:3000"; do
    name="${entry%:*}"
    port="${entry#*:}"
    check_port_listen "$port"
    case $? in
        0) ok "$name 监听 :$port" ;;
        1) fail "$name 端口 :$port 没在监听" ;;
        2) warn "$name 端口检测跳过（系统无 ss/netstat/lsof）" ;;
    esac
done
echo ""

# ---------------- 4. 数据库 ----------------
echo "4. 数据库"
DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "^${PROJECT}-database-[0-9]+$" | head -1)
if [ -z "$DB_CONTAINER" ]; then
    fail "database 容器没起来，跳过数据库检查"
    echo ""
else
    if docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -c "SELECT 1" >/dev/null 2>&1; then
        ok "数据库连接正常"

        CAR_CNT=$(docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc "SELECT count(*) FROM cars" 2>/dev/null)
        if [ -n "$CAR_CNT" ] && [ "$CAR_CNT" -gt 0 ]; then
            ok "数据库已绑定 $CAR_CNT 辆车"
        else
            warn "数据库还没绑定任何车（去 TeslaMate 主页粘贴 token 完成绑定）"
        fi

        DRIVE_CNT=$(docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc "SELECT count(*) FROM drives" 2>/dev/null)
        if [ -n "$DRIVE_CNT" ]; then
            info "已记录 $DRIVE_CNT 段行程，$(docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc "SELECT count(*) FROM charging_processes" 2>/dev/null) 次充电"
        fi

        # 坐标函数（v1.4.2+）
        if docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc "SELECT 1 FROM pg_proc WHERE proname='gcj02_to_wgs84'" 2>/dev/null | grep -q 1; then
            ok "坐标转换函数已装（地图源切换/纠偏可用）"
        else
            warn "坐标函数未装（地图源切换会失败）"
            echo "    修：bash <(curl -fsSL https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/scripts/upgrade.sh)"
        fi

        # TOU 表（v1.5.0+）
        if docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc "SELECT 1 FROM pg_class WHERE relname='tou_rates'" 2>/dev/null | grep -q 1; then
            TOU_CNT=$(docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc "SELECT count(*) FROM tou_rates" 2>/dev/null)
            ok "分时电价表已装（${TOU_CNT} 条规则）"
        else
            warn "分时电价表未装（「⚡ 分时电价配置」仪表盘会空）"
        fi
    else
        fail "数据库无法连接（容器跑着但 psql 不通）"
        info "最近 10 行 database 日志："
        docker logs --tail 10 "$DB_CONTAINER" 2>&1 | sed 's/^/    | /'
    fi
    echo ""
fi

# ---------------- 5. Grafana ----------------
echo "5. Grafana 仪表盘"
GRAFANA_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "^${PROJECT}-grafana-[0-9]+$" | head -1)
if [ -z "$GRAFANA_CONTAINER" ]; then
    fail "grafana 容器没起来，跳过"
else
    # 当前镜像版本 label
    IMAGE=$(docker inspect --format '{{.Config.Image}}' "$GRAFANA_CONTAINER" 2>/dev/null)
    LABEL_VER=$(docker inspect --format '{{ index .Config.Labels "version" }}' "$GRAFANA_CONTAINER" 2>/dev/null)
    if [ -n "$LABEL_VER" ]; then
        ok "Grafana 镜像版本 label: $LABEL_VER ($IMAGE)"
    else
        warn "Grafana 镜像 label 缺失（不是中文 Dashboard 镜像？）"
        info "实际镜像：$IMAGE"
    fi

    # form-panel 插件检测（v1.5.0+ TOU 仪表盘需要）
    if docker exec "$GRAFANA_CONTAINER" ls /var/lib/grafana/plugins/volkovlabs-form-panel >/dev/null 2>&1 \
       || docker exec "$GRAFANA_CONTAINER" ls /usr/share/grafana/plugins-bundled/volkovlabs-form-panel >/dev/null 2>&1; then
        ok "volkovlabs-form-panel 插件已装"
    else
        warn "volkovlabs-form-panel 插件未装（TOU 仪表盘红三角）"
        echo "    修：docker exec --user root $GRAFANA_CONTAINER grafana cli --pluginsDir /var/lib/grafana/plugins plugins install volkovlabs-form-panel 6.3.2"
        echo "        docker exec --user root $GRAFANA_CONTAINER chown -R 472:0 /var/lib/grafana/plugins"
        echo "        docker restart $GRAFANA_CONTAINER"
    fi

    # 最近 5 分钟内的 ERROR 日志
    ERR_CNT=$(docker logs --since 5m "$GRAFANA_CONTAINER" 2>&1 | grep -ic "lvl=eror\|level=error\|permission denied" || true)
    if [ "$ERR_CNT" -gt 0 ]; then
        warn "最近 5 分钟 Grafana 日志有 $ERR_CNT 条错误，最后 5 条："
        docker logs --since 5m "$GRAFANA_CONTAINER" 2>&1 | grep -i "lvl=eror\|level=error\|permission denied" | tail -5 | sed 's/^/    | /'
    else
        ok "Grafana 最近 5 分钟无错误日志"
    fi
fi
echo ""

# ---------------- 6. TeslaMate 后端 ----------------
echo "6. TeslaMate 后端"
TM_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E "^${PROJECT}-teslamate-[0-9]+$" | head -1)
if [ -z "$TM_CONTAINER" ]; then
    fail "teslamate 容器没起来"
else
    # 最近 5 分钟错误
    ERR_CNT=$(docker logs --since 5m "$TM_CONTAINER" 2>&1 | grep -ic "error\|failed" || true)
    if [ "$ERR_CNT" -gt 0 ]; then
        warn "最近 5 分钟 teslamate 日志有 $ERR_CNT 条错误，最后 5 条："
        docker logs --since 5m "$TM_CONTAINER" 2>&1 | grep -i "error\|failed" | tail -5 | sed 's/^/    | /'
    else
        ok "teslamate 最近 5 分钟无错误日志"
    fi

    # 是否在轮询车辆（看到 Fetching 关键字）
    if docker logs --since 10m "$TM_CONTAINER" 2>&1 | grep -q "Fetching"; then
        ok "teslamate 在轮询车辆数据（最近 10 分钟见到 Fetching）"
    elif [ "${CAR_CNT:-0}" -gt 0 ] 2>/dev/null; then
        warn "已绑定车但最近 10 分钟没看到 Fetching 日志（可能 token 过期或车辆休眠）"
    fi
fi
echo ""

# ---------------- 7. 网络连通性 ----------------
echo "7. 网络连通性（Tesla API）"
if curl -fsI -m 5 https://owner-api.vn.cloud.tesla.cn >/dev/null 2>&1; then
    ok "国内 owner-api.vn.cloud.tesla.cn 可达"
elif curl -fsI -m 5 https://owner-api.teslamotors.com >/dev/null 2>&1; then
    ok "国际 owner-api.teslamotors.com 可达"
    warn "国内 owner-api.vn.cloud.tesla.cn 不通（如果你是国内账号需排查 DNS / 网络）"
else
    fail "Tesla API 服务器都不通（容器拿不到车辆数据）"
fi
echo ""

# ---------------- 总结 ----------------
echo "================================================="
echo "  诊断完成: $PASS 通过 / $WARN 告警 / $FAIL 失败"
echo "================================================="

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "❌ 有 $FAIL 项失败需要先修，然后重跑此脚本验证"
    echo "   常见解法见 https://github.com/wjsall/teslamate-chinese-dashboards/blob/main/TROUBLESHOOTING.md"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo ""
    echo "⚠️  $WARN 项告警，多数情况下不影响主功能。详见每条建议。"
    exit 0
else
    echo ""
    echo "✅ 所有检查通过"
fi
