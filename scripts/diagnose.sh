#!/bin/bash
# TeslaMate 中文 Dashboard 一键诊断脚本
# 用法: bash scripts/diagnose.sh （在 ~/teslamate-chinese 或装好的目录跑）
# 输出: 关键状态报告 + 常见问题指引，不修改任何配置

# 不开 set -e，单项失败不影响其他检查继续跑

PROJECT="${COMPOSE_PROJECT_NAME:-teslamate}"
TM_PORT="${TM_PORT:-4000}"
GF_PORT="${GF_PORT:-3000}"
PASS=0
FAIL=0
WARN=0

# --verify：机器可读校验模式（CI 用）。不带这个参数时，输出/退出码与旧版完全一致。
VERIFY=0
for _arg in "$@"; do
    case "$_arg" in
        --verify) VERIFY=1 ;;
    esac
done

# --verify 输出的 REASONS 封闭词表（新增 reason 前先确认没有合适的已有项；新增须同步登记在此处，
# 别散落到各检查点。带「预留」的几项当前脚本还没做对应检查，先占位，方便 CI 提前枚举）：
#   plugin_missing            插件缺失
#   plugin_version_mismatch   插件版本不符（预留，脚本暂未做版本号比对）
#   sql_object_missing        核心 SQL 对象缺失（坐标/单位换算函数、TOU 表等）
#   sql_revision_mismatch     SQL 兼容性 revision 不匹配（镜像要求的版本 ≠ 数据库里实际记录的版本；
#                             issue #23/#29 事故预防机制，见 config/versions.env）
#   index_missing             性能索引缺失（预留，脚本暂未做索引检查）
#   datasource_unreachable    数据源连不上（Tesla API）
#   container_down            容器没起来 / 端口未监听
#   db_unreachable            数据库连不上（容器在跑但 psql 不通）
#   dashboard_missing         仪表盘文件缺失（预留，脚本暂未做文件检查）
#   docker_unavailable        docker / docker compose 工具链本身不可用（本脚本新增，不在原始词表内）
VERIFY_REASONS=()

ok()    { printf "  ✓ %s\n" "$1"; PASS=$((PASS+1)); }
fail()  { printf "  ✗ %s\n" "$1"; FAIL=$((FAIL+1)); }
warn()  { printf "  ⚠ %s\n" "$1"; WARN=$((WARN+1)); }
info()  { printf "  → %s\n" "$1"; }

# fail_r/warn_r：在 fail()/warn() 之上多记一条 REASONS（仅用于真正影响健康判定的检查项；
# 纯提示性的 warn()——如 Compose v1 过时、还没绑车、日志噪音——保持用原始 warn()，不进 REASONS，
# 避免全新安装等正常场景被误判成 DEGRADED）。
fail_r() { fail "$1"; VERIFY_REASONS+=("$2"); }
warn_r() { warn "$1"; VERIFY_REASONS+=("$2"); }

# print_verify_result：打印 RESULT=/REASONS= 两行（REASONS 去重，保持插入顺序）
print_verify_result() {
    printf "RESULT=%s\n" "$1"
    if [ ${#VERIFY_REASONS[@]} -gt 0 ]; then
        local joined="" seen="," r
        for r in "${VERIFY_REASONS[@]}"; do
            case "$seen" in
                *",${r},"*) continue ;;
            esac
            seen="${seen}${r},"
            if [ -z "$joined" ]; then joined="$r"; else joined="${joined},${r}"; fi
        done
        printf "REASONS=%s\n" "$joined"
    fi
}

# finish：统一出口。不带 --verify 时行为与旧版一致（直接 exit "$1"）；
# 带 --verify 时改按三态（HEALTHY=0/DEGRADED=2/FAILED=1）重新判定并追加两行机器可读输出。
finish() {
    if [ "$VERIFY" = "1" ]; then
        if [ "$FAIL" -gt 0 ]; then
            print_verify_result "FAILED"
            exit 1
        elif [ ${#VERIFY_REASONS[@]} -gt 0 ]; then
            print_verify_result "DEGRADED"
            exit 2
        else
            print_verify_result "HEALTHY"
            exit 0
        fi
    fi
    exit "$1"
}

echo "================================================="
echo "  TeslaMate 中文仪表盘诊断"
echo "================================================="
echo ""

# ---------------- 1. Docker 基础 ----------------
echo "1. Docker 基础"
if command -v docker >/dev/null 2>&1; then
    ok "docker 已安装：$(docker --version | head -1)"
else
    fail_r "docker 未安装" docker_unavailable
    echo ""
    echo "推荐先看 README.md 安装 Docker，再回来跑诊断"
    finish 1
fi

if docker info >/dev/null 2>&1; then
    ok "docker daemon 可访问"
else
    fail_r "docker daemon 跑不动（权限不够？群晖用户需要 root 或 docker 组）" docker_unavailable
    echo ""
    echo "修：sudo usermod -aG docker \$USER && newgrp docker"
    finish 1
fi

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
    ok "Docker Compose v2: $($DC version --short 2>/dev/null)"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
    warn "Docker Compose v1（已过时，建议升级到 v2）"
else
    fail_r "Docker Compose 未安装" docker_unavailable
    finish 1
fi
echo ""

# Compose 优先探测 service，失败再兼容 v2 连字符 / v1 下划线容器名。
detect_service_container() {
    local svc="$1" c=""
    c=$($DC ps -q "$svc" 2>/dev/null | head -1 || true)
    if [ -z "$c" ]; then
        c=$(docker ps --format '{{.Names}}' 2>/dev/null \
            | grep -E "^${PROJECT}[-_]${svc}[-_][0-9]+$|^${svc}$" | head -1 || true)
    fi
    echo "$c"
}

# ---------------- 2. 容器状态 ----------------
echo "2. 容器状态"
EXPECTED=(teslamate database grafana mosquitto)
ALL_RUNNING=1
for svc in "${EXPECTED[@]}"; do
    CID=$(detect_service_container "$svc")
    if [ -z "$CID" ]; then
        fail_r "${svc} 容器未找到（Compose service: ${svc}；兼容 ${PROJECT}-${svc}-1 / ${PROJECT}_${svc}_1）" container_down
        ALL_RUNNING=0
        continue
    fi

    STATUS=$(docker inspect --format '{{.State.Status}}' "$CID" 2>/dev/null)
    if [ "$STATUS" = "running" ]; then
        UPTIME=$(docker inspect --format '{{.State.StartedAt}}' "$CID" 2>/dev/null | cut -dT -f1)
        ok "${svc} 运行中（自 $UPTIME 起）"
    else
        fail_r "${svc} 状态异常: $STATUS" container_down
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
    # 真正要回答的问题是「这个端口能不能连上」，所以先直接连一次——这是唯一
    # 不受 Docker 网络实现影响的判据。Docker 28 默认可以不起 docker-proxy 用户态
    # 进程（nftables 直接转发），这时端口工作正常，但 lsof/ss 看不到任何 LISTEN
    # socket；只看监听表会把一套健康的部署判成 container_down（CI 实测：curl
    # /api/health 成功，同一时刻 lsof 报没监听）。
    if command -v curl >/dev/null 2>&1; then
        # 任何 HTTP 响应（含 401/404）都说明端口是通的；连不上时 curl 返回空
        local code
        # --noproxy 必须：curl 不会自动为 127.0.0.1 绕过 http_proxy/all_proxy。国内用户
        # 为了拉 GitHub 常在 shell 里 export 代理，那时这个探测会打到代理上、拿回代理自己的
        # 404，把「服务其实没起来」判成「端口正常」——比原来的 lsof 盲区更糟。
        code=$(curl -sS --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null)
        [ -n "$code" ] && [ "$code" != "000" ] && return 0
    fi
    # 连不上再看监听表，用来区分「端口没开」和「开了但这次请求失败」
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

for entry in "TeslaMate:${TM_PORT}" "Grafana:${GF_PORT}"; do
    name="${entry%:*}"
    port="${entry#*:}"
    check_port_listen "$port"
    case $? in
        0) ok "$name 监听 :$port" ;;
        1) fail_r "$name 端口 :$port 没在监听" container_down ;;
        2) warn "$name 端口检测跳过（系统无 ss/netstat/lsof）" ;;
    esac
done
echo ""

# grafana 容器提前探测（第 5 节也会用到）：SQL revision 比对需要从 grafana 容器读镜像里
# 内置的 required revision（config/versions.env，见下方 4.1），比对必须在数据库检查这一节
# 内完成，所以探测要提到这里。
GRAFANA_CONTAINER=$(detect_service_container grafana)

# ---------------- 4. 数据库 ----------------
echo "4. 数据库"
DB_CONTAINER=$(detect_service_container database)
if [ -z "$DB_CONTAINER" ]; then
    fail_r "database 容器没起来，跳过数据库检查" container_down
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

        # 坐标函数（v1.4.2+，共 5 个：is_outside_china 境内外判断 + wgs84_to_gcj02_lat/lng 算法 + lat_for_map/lng_for_map 包装）
        COORD_MISSING=0
        if docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc \
            "SELECT count(DISTINCT proname) FROM pg_proc WHERE proname IN ('lat_for_map','lng_for_map','wgs84_to_gcj02_lat','wgs84_to_gcj02_lng','is_outside_china')" \
            2>/dev/null | grep -qx 5; then
            ok "坐标转换函数已装（地图源切换/纠偏可用）"
        else
            COORD_MISSING=1
            warn_r "坐标函数未装（地图源切换会失败）" sql_object_missing
            echo "    修：已探测到数据库容器 ${DB_CONTAINER}；请按权威循环安装 SQL 四件套："
            echo "    https://github.com/wjsall/teslamate-chinese-dashboards/blob/main/TROUBLESHOOTING.md#repair-sql-install"
        fi

        # 单位换算函数（v1.8.0+）
        # 不能只数函数名：convert_km/convert_celsius/convert_m/convert_tire_pressure 这四个名字
        # 上游 TeslaMate 自己的迁移就会建，任何迁移完成的库上都齐，按名字数永远是「已装」——
        # 这条检查等于没做。改查我们这版独有的特征：只有我们的 convert_tire_pressure 支持
        # kPa/kpa。它是 install-unit-functions.sql 里最后一个函数，装到它 = 整份装完。
        UNIT_MISSING=0
        if docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc \
            "SELECT count(*) FROM pg_proc WHERE proname = 'convert_tire_pressure' AND prosrc LIKE '%kPa%'" \
            2>/dev/null | grep -qE '^[1-9][0-9]*$'; then
            ok "单位换算函数已装（里程/温度/海拔/胎压可用）"
        else
            UNIT_MISSING=1
            warn_r "单位换算函数未完整安装（convert_km/convert_celsius/convert_m/convert_tire_pressure）" sql_object_missing
            echo "    修：已探测到数据库容器 ${DB_CONTAINER}；请按权威循环安装 SQL 四件套："
            echo "    https://github.com/wjsall/teslamate-chinese-dashboards/blob/main/TROUBLESHOOTING.md#repair-sql-install"
        fi

        # TOU 表（v1.5.0+）
        TOU_MISSING=0
        if docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc "SELECT 1 FROM pg_class WHERE relname='tou_rates'" 2>/dev/null | grep -qx 1; then
            TOU_CNT=$(docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc "SELECT count(*) FROM tou_rates" 2>/dev/null)
            ok "分时电价表已装（${TOU_CNT} 条规则）"
        else
            TOU_MISSING=1
            warn_r "分时电价表未装（「⚡ 分时电价配置」仪表盘会空）" sql_object_missing
        fi

        # ---- 4.1 SQL 兼容性 revision 比对（issue #23/#29 事故预防机制）----
        #
        # 上面三项是「对象存在性」检测（缺了肯定报），这里额外比对一个整数 revision，
        # 能多抓一种上面测不出的情况：三个对象都「存在」，但已经是旧版本（签名没变、内部
        # 逻辑变了）——纯存在性 SELECT 测不出这种「装了但装的是旧的」。
        #
        # required revision 来自镜像本身（config/versions.env 随镜像 COPY 进
        # /opt/teslamate-cn/versions.env）；installed revision 来自数据库里的
        # teslamate_cn_extension_meta 表（三条安装路径在三组 SQL 全部成功后才写入）。
        # 方法 C（手动 docker compose pull）/ Watchtower 用户只换镜像不跑安装脚本，
        # 最容易撞上这个不匹配——这正是这套机制要专门检测的场景。
        REQUIRED_REV=""
        if [ -n "$GRAFANA_CONTAINER" ]; then
            REQUIRED_REV=$(docker exec "$GRAFANA_CONTAINER" sh -c 'cat /opt/teslamate-cn/versions.env 2>/dev/null' 2>/dev/null \
                | grep -m1 '^SQL_COMPAT_REVISION=' | cut -d= -f2 | tr -d '[:space:]\r')
        fi
        INSTALLED_REV=$(docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc \
            "SELECT sql_revision FROM teslamate_cn_extension_meta WHERE id=1" 2>/dev/null | tr -d '[:space:]\r')

        if [ -z "$REQUIRED_REV" ]; then
            warn "无法从 Grafana 容器读到镜像要求的 SQL 兼容性 revision（镜像太旧，或 grafana 容器未探测到），跳过比对"
        else
            AFFECTED=()
            [ "$COORD_MISSING" -eq 1 ] && AFFECTED+=("地图相关仪表盘（地图源切换、轨迹展示等，报 lat_for_map/lng_for_map does not exist，issue #29 实证）")
            [ "$UNIT_MISSING" -eq 1 ] && AFFECTED+=("里程/温度/海拔/胎压等单位显示（多个仪表盘，报 convert_km 等 does not exist）")
            [ "$TOU_MISSING" -eq 1 ] && AFFECTED+=("「⚡ 分时电价配置」仪表盘（报 relation tou_rates / function set_default_charging_rate does not exist，issue #23 实证）")

            if [ -z "$INSTALLED_REV" ]; then
                warn_r "数据库未记录已装的 SQL revision（镜像要求 ${REQUIRED_REV}）——通常是换了镜像但没跑过 SQL 安装脚本" sql_revision_mismatch
                if [ ${#AFFECTED[@]} -gt 0 ]; then
                    for a in "${AFFECTED[@]}"; do echo "    受影响：$a"; done
                else
                    echo "    上面坐标/单位/分时电价三项对象检测目前都通过，暂无已知受影响功能，但强烈建议按下面命令补装一遍以写入 revision 记录"
                fi
                echo "    修：已探测到数据库容器 ${DB_CONTAINER}；请按权威循环安装 SQL 四件套："
                echo "    https://github.com/wjsall/teslamate-chinese-dashboards/blob/main/TROUBLESHOOTING.md#repair-sql-install"
            elif [ "$INSTALLED_REV" != "$REQUIRED_REV" ]; then
                warn_r "SQL revision 不匹配：镜像要求 ${REQUIRED_REV}，数据库已装 ${INSTALLED_REV}" sql_revision_mismatch
                if [ ${#AFFECTED[@]} -gt 0 ]; then
                    for a in "${AFFECTED[@]}"; do echo "    受影响：$a"; done
                else
                    echo "    上面坐标/单位/分时电价三项对象检测目前都通过，但 revision 落后——可能是某个对象的内部逻辑已更新但签名未变（存在性检测测不出），建议仍重装一遍"
                fi
                echo "    修：已探测到数据库容器 ${DB_CONTAINER}；请按权威循环安装 SQL 四件套："
                echo "    https://github.com/wjsall/teslamate-chinese-dashboards/blob/main/TROUBLESHOOTING.md#repair-sql-install"
            else
                ok "SQL 兼容性 revision 匹配（${INSTALLED_REV}）"
            fi
        fi
    else
        fail_r "数据库无法连接（容器跑着但 psql 不通）" db_unreachable
        info "最近 10 行 database 日志："
        docker logs --tail 10 "$DB_CONTAINER" 2>&1 | sed 's/^/    | /'
    fi
    echo ""
fi

# ---------------- 5. Grafana ----------------
echo "5. Grafana 仪表盘"
# GRAFANA_CONTAINER 已在第 4 节之前探测过（SQL revision 比对需要），这里直接复用
if [ -z "$GRAFANA_CONTAINER" ]; then
    fail_r "grafana 容器没起来，跳过" container_down
else
    # 当前镜像版本 label
    IMAGE=$(docker inspect --format '{{.Config.Image}}' "$GRAFANA_CONTAINER" 2>/dev/null)
    LABEL_VER=$(docker inspect --format '{{ index .Config.Labels "version" }}' "$GRAFANA_CONTAINER" 2>/dev/null)
    if [ -n "$LABEL_VER" ]; then
        ok "Grafana 镜像版本 label: $LABEL_VER ($IMAGE)"
    else
        warn "Grafana 镜像 label 缺失（不是中文仪表盘镜像？）"
        info "实际镜像：$IMAGE"
    fi

    # form-panel 插件检测（v1.5.0+ TOU 仪表盘需要）
    # 新版镜像（issue #20/#21 修复后）插件装在 /opt/grafana-plugins（volume 外，
    # GF_PATHS_PLUGINS 覆盖）；老镜像还在 /var/lib/grafana/plugins（volume 内，会被旧卷
    # 覆盖）；plugins-bundled 是官方基础镜像另一种可能的内置插件位置——三个路径都认，兼容新老镜像
    if docker exec "$GRAFANA_CONTAINER" ls /opt/grafana-plugins/volkovlabs-form-panel >/dev/null 2>&1 \
       || docker exec "$GRAFANA_CONTAINER" ls /var/lib/grafana/plugins/volkovlabs-form-panel >/dev/null 2>&1 \
       || docker exec "$GRAFANA_CONTAINER" ls /usr/share/grafana/plugins-bundled/volkovlabs-form-panel >/dev/null 2>&1; then
        ok "volkovlabs-form-panel 插件已装"
    else
        warn_r "volkovlabs-form-panel 插件未装（TOU 仪表盘红三角）" plugin_missing
        echo "    修：docker exec --user root $GRAFANA_CONTAINER sh -c 'grafana cli --pluginsDir /var/lib/grafana/plugins plugins install volkovlabs-form-panel 6.3.2 && chown -R 472:472 /var/lib/grafana/plugins/volkovlabs-form-panel'"
        echo "        docker restart $GRAFANA_CONTAINER"
    fi

    # 最近 5 分钟内的 ERROR 日志（严格匹配 logfmt: lvl=eror / level=error，不抓 error_count=0 / error: false 这类）
    ERR_PATTERN='lvl=eror\b|level=error\b|permission denied'
    ERR_CNT=$(docker logs --since 5m "$GRAFANA_CONTAINER" 2>&1 | grep -cE "$ERR_PATTERN" || true)
    if [ "$ERR_CNT" -gt 0 ]; then
        warn "最近 5 分钟 Grafana 日志有 $ERR_CNT 条错误，最后 5 条："
        docker logs --since 5m "$GRAFANA_CONTAINER" 2>&1 | grep -E "$ERR_PATTERN" | tail -5 | sed 's/^/    | /'
    else
        ok "Grafana 最近 5 分钟无错误日志"
    fi
fi
echo ""

# ---------------- 6. TeslaMate 后端 ----------------
echo "6. TeslaMate 后端"
TM_CONTAINER=$(detect_service_container teslamate)
if [ -z "$TM_CONTAINER" ]; then
    fail_r "teslamate 容器没起来" container_down
else
    # 最近 5 分钟错误（严格匹配 Elixir 日志: [error] [warning] / fatal / [crit]，过滤 "0 errors" 这类正常输出）
    TM_ERR_PATTERN='\[error\]|\[crit\]|\bfatal\b|MatchError|Sign in failed'
    ERR_CNT=$(docker logs --since 5m "$TM_CONTAINER" 2>&1 | grep -cE "$TM_ERR_PATTERN" || true)
    if [ "$ERR_CNT" -gt 0 ]; then
        warn "最近 5 分钟 teslamate 日志有 $ERR_CNT 条错误，最后 5 条："
        docker logs --since 5m "$TM_CONTAINER" 2>&1 | grep -E "$TM_ERR_PATTERN" | tail -5 | sed 's/^/    | /'
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
# 注意：Tesla API 网关（envoy）对 HEAD / 统一回 404（与地域、账号无关），
# 不能用 curl -f 判断 HTTP 状态码是否为 2xx。只要拿到了任何 HTTP 响应
# （状态码非 000），就说明网络可达；000 才代表 DNS/TCP/TLS 层连不上。
tesla_api_reachable() {
    local code
    code=$(curl -sI -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null)
    [ -n "$code" ] && [ "$code" != "000" ]
}
if tesla_api_reachable https://owner-api.vn.cloud.tesla.cn; then
    ok "国内 owner-api.vn.cloud.tesla.cn 可达"
elif tesla_api_reachable https://owner-api.teslamotors.com; then
    ok "国际 owner-api.teslamotors.com 可达"
    # 国内网关不通算不算问题，取决于这套部署用的是哪个地域的账号：
    #   - 配了 TESLA_API_HOST=...tesla.cn（国内账号）→ 它就是这套部署唯一的数据来源，
    #     不通就是真故障，记进 REASONS。
    #   - 没配 → **判不出地域**，不能当成"国际账号，没事"。本项目推荐姿势就是不配这几个
    #     变量（TeslaMate 3.0 会从 token 自动识别中国区），所以绝大多数国内车主在这里都是
    #     "没配"；这条要是写成"不影响使用"，等于对主力用户群把真故障说成没事。
    #     但也不能一律记进 REASONS——国际账号用户本来就连不上国内网关，那会让一套完全
    #     健康的部署被判 DEGRADED。折中：不降级，但话说准，把两种可能都摆给用户。
    TM_CONTAINER=$(detect_service_container teslamate)
    TESLA_CN_CONFIGURED=0
    if [ -n "$TM_CONTAINER" ] && docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' \
        "$TM_CONTAINER" 2>/dev/null | grep -qiE '^TESLA_(API|AUTH|WSS)_HOST=.*tesla\.cn'; then
        TESLA_CN_CONFIGURED=1
    fi
    if [ "$TESLA_CN_CONFIGURED" = "1" ]; then
        fail_r "国内 owner-api.vn.cloud.tesla.cn 不通，而这套部署配的正是国内账号网关（拿不到车辆数据）" datasource_unreachable
        echo "    修：排查 DNS / 网络能否解析并访问 owner-api.vn.cloud.tesla.cn"
    else
        warn "国内 owner-api.vn.cloud.tesla.cn 不通（国际 owner-api.teslamotors.com 可达）"
        echo "    用国际账号：正常现象，忽略即可。"
        echo "    用国内账号：这多半就是「车辆数据不同步 / 一直没数据」的原因，需要排查本机到"
        echo "      owner-api.vn.cloud.tesla.cn 的 DNS 与网络（这条不计入总体结论，因为脚本"
        echo "      无法确定你用的是哪种账号）。"
    fi
else
    fail_r "Tesla API 服务器都不通（容器拿不到车辆数据）" datasource_unreachable
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
    finish 1
elif [ "$WARN" -gt 0 ]; then
    echo ""
    echo "⚠️  $WARN 项告警，多数情况下不影响主功能。详见每条建议。"
    finish 0
else
    echo ""
    echo "✅ 所有检查通过"
    finish 0
fi
