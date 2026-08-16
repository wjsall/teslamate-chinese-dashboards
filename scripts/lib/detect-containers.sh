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
# 在一个范围内按「容器名」再按「镜像」找 TeslaMate。$1 = running（只看运行中）/ all（含已停止）。
# 刻意不用数组传 docker ps 参数：NAS 和 macOS 上还有 Bash 3.2。
_teslamate_scan() {
    local scope="$1" c="" rows=""
    if [ "$scope" = "all" ]; then
        rows=$(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null || true)
    else
        rows=$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null || true)
    fi
    c=$(printf '%s\n' "$rows" | cut -f1 \
        | grep -iE '(^|[-_])teslamate([-_][0-9]+)?$' \
        | grep -viE 'database|postgres|grafana|mosquitto' | head -1 || true)
    if [ -z "$c" ]; then
        c=$(printf '%s\n' "$rows" \
            | grep -iE '(^|[[:space:]])teslamate/teslamate(:|[[:space:]]|$)' \
            | cut -f1 | head -1 || true)
    fi
    echo "$c"
}

teslamate_container_name() {
    local c=""
    c=$(${DC:-docker compose} ps -q teslamate 2>/dev/null | head -1 || true)
    # 先在运行中的容器里找，找不到才把已停止的算进来。
    # 只扫 -a 会踩这个坑：docker ps -a 按创建时间倒序，宿主机上只要躺着一个更晚创建、
    # 已经停掉的 TeslaMate（改过名的旧栈、试过一次的部署、跑过一遍的测试），head -1 就会
    # 选中那个死的 → 存活判据读出 exited → 判定「它的迁移不可能完成」→ 跳过单位换算函数
    # 并以「✗ 升级失败」收场，而用户真正在跑的 TeslaMate 一切正常。
    # 回落仍保留 -a：一个都没运行时，「反复重启/已退出」那条告警本来就要能看见死容器。
    [ -z "$c" ] && c=$(_teslamate_scan running)
    [ -z "$c" ] && c=$(_teslamate_scan all)
    echo "$c"
}
