# shellcheck shell=bash
# 检测 TeslaMate 相关容器名（PostgreSQL / Grafana），git clone 用户脚本共用
# 用法：source "$(dirname "$0")/lib/detect-containers.sh" && detect_db_container
#
# 注意：simple-deploy.sh 是通过 wget|bash 远程执行的自包含脚本，不能 source 本地文件，
# 所以那边内联了同样的检测逻辑。修这里的检测顺序时记得同步 simple-deploy.sh。

# 兼容 Compose v2 / v1，返回指定 service 的容器 ID。
_detect_compose_service_container() {
    local service="$1" c=""
    if docker compose version >/dev/null 2>&1; then
        c=$(docker compose ps -q "$service" 2>/dev/null | head -1 || true)
    elif command -v docker-compose >/dev/null 2>&1; then
        c=$(docker-compose ps -q "$service" 2>/dev/null | head -1 || true)
    fi
    echo "$c"
}

# 找 PostgreSQL 容器：优先 Compose ps -q（compose 知道自己 project），失败回落 grep
detect_db_container() {
    local c
    c=$(_detect_compose_service_container database)
    [ -z "$c" ] && c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'teslamate.*database|teslamate.*postgres' | head -1 || true)
    [ -z "$c" ] && c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE '^database$|^postgres$' | head -1 || true)
    echo "$c"
}

# 找 Grafana 容器：同样 compose-first
detect_grafana_container() {
    local c
    c=$(_detect_compose_service_container grafana)
    [ -z "$c" ] && c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'teslamate.*grafana|^grafana$' | head -1 || true)
    echo "$c"
}

# ── TeslaMate 容器检测（下面两个函数是三份拷贝的正本）────────────────────────────
# simple-deploy.sh / migrate-from-official.sh 是 curl|bash 远程执行的自包含脚本，
# source 不了本文件，所以那两处内联了逐字相同的副本。三份是否一致由
# scripts/check-container-detect-consistency.sh 逐字节比对，改这里不同步会当场红。
#
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
