# shellcheck shell=bash
# 检测 TeslaMate 相关容器名（PostgreSQL / Grafana），git clone 用户脚本共用
# 用法：source "$(dirname "$0")/lib/detect-containers.sh" && detect_db_container
#
# 注意：simple-deploy.sh 是通过 wget|bash 远程执行的自包含脚本，不能 source 本地文件，
# 所以那边内联了同样的检测逻辑。修这里的检测顺序时记得同步 simple-deploy.sh。

# 找 PostgreSQL 容器：优先 docker compose ps -q（compose 知道自己 project），失败回落 grep
detect_db_container() {
    local c
    c=$(docker compose ps -q database 2>/dev/null | head -1)
    [ -z "$c" ] && c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'teslamate.*database|teslamate.*postgres' | head -1)
    [ -z "$c" ] && c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE '^database$|^postgres$' | head -1)
    echo "$c"
}

# 找 Grafana 容器：同样 compose-first
detect_grafana_container() {
    local c
    c=$(docker compose ps -q grafana 2>/dev/null | head -1)
    [ -z "$c" ] && c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'teslamate.*grafana|^grafana$' | head -1)
    echo "$c"
}
