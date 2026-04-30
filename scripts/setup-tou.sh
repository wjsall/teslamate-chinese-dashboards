#!/bin/bash
# TeslaMate 中文版分时电价配置工具
#
# 用法:
#   bash scripts/setup-tou.sh install                       # 装函数+表（如未装）
#   bash scripts/setup-tou.sh import <city> <geofence_name> # 导入城市模板
#   bash scripts/setup-tou.sh list                          # 列出当前 分时电价配置
#   bash scripts/setup-tou.sh test [<charge_id>]            # 试算单笔（不传 ID 用最近一笔家充）
#   bash scripts/setup-tou.sh reset                         # 清空所有 分时电价配置
#
# 例子:
#   bash scripts/setup-tou.sh install
#   bash scripts/setup-tou.sh import beijing 仁安玺苑
#   bash scripts/setup-tou.sh test
set -e
set -o pipefail

# ============================================================
# 颜色
# ============================================================
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"

# ============================================================
# 路径
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$SCRIPT_DIR/../sql"

# 城市模板列表从 PG 函数 list_city_templates() 动态查（单一数据源在 install-tou.sql）
# 数据库未装时 fallback 到硬编码列表（与 install-tou.sql 的 apply_city_template CASE 分支同步）
CITIES_FALLBACK=(beijing shanghai shenzhen guangzhou zhejiang jiangsu)
get_cities() {
    local list
    list=$(docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -t -A \
           -c "SELECT city_id FROM list_city_templates()" 2>/dev/null)
    if [ -n "$list" ]; then
        echo "$list" | tr '\n' ' '
    else
        echo "${CITIES_FALLBACK[@]}"
    fi
}

# shellcheck source=lib/detect-containers.sh
source "$SCRIPT_DIR/lib/detect-containers.sh"

# ============================================================
# 检测 PostgreSQL 容器（包装：找不到时退出）
# ============================================================
ensure_db_container() {
    DB_CONTAINER=$(detect_db_container)
    if [ -z "$DB_CONTAINER" ]; then
        echo -e "${RED}✗ 找不到运行中的 PostgreSQL 容器${NC}"
        echo "  请先启动 TeslaMate: docker compose up -d"
        exit 1
    fi
}

psql_exec() {
    docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate "$@"
}

psql_query_value() {
    docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -t -A -c "$1"
}

# ============================================================
# 子命令: install
# ============================================================
cmd_install() {
    ensure_db_container
    if [ ! -f "$SQL_DIR/install-tou.sql" ]; then
        echo -e "${RED}✗ 找不到 $SQL_DIR/install-tou.sql${NC}"
        echo "  请确保在 teslamate-chinese-dashboards 仓库根目录运行"
        exit 1
    fi
    echo -e "${BLUE}[1/1] 安装 分时电价函数 + 表...${NC}"
    psql_exec < "$SQL_DIR/install-tou.sql" | tail -5
    echo -e "${GREEN}  ✓ 分时电价系统已安装${NC}"
    echo ""
    echo "下一步: bash $0 import <city> <geofence_name>"
    echo "或交互式: bash scripts/tou-wizard.sh"
}

# ============================================================
# 子命令: import <city> <geofence_name>
# ============================================================
cmd_import() {
    local city="$1"
    local geofence_name="$2"

    if [ -z "$city" ] || [ -z "$geofence_name" ]; then
        echo -e "${RED}✗ 用法: bash $0 import <city> <geofence_name>${NC}"
        echo ""
        echo "可用城市:"
        ensure_db_container 2>/dev/null || true
        for c in $(get_cities); do echo "  - $c"; done
        exit 1
    fi

    ensure_db_container

    # 查 geofence_id + 调 apply_city_template（用 psql 变量代入避免 SQL 注入）
    local geofence_id
    geofence_id=$(docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -t -A \
        -v gname="$geofence_name" \
        -c "SELECT id FROM geofences WHERE name = :'gname'" | tr -d '[:space:]')

    if [ -z "$geofence_id" ]; then
        echo -e "${RED}✗ 找不到地理围栏: $geofence_name${NC}"
        echo ""
        echo "你的地理围栏列表："
        psql_exec -c "SELECT id, name FROM geofences ORDER BY name"
        exit 1
    fi

    echo -e "${BLUE}导入 $city 模板到「$geofence_name」(geofence_id=$geofence_id)...${NC}"
    docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -t -A \
        -v cname="$city" \
        -c "SELECT apply_city_template(:'cname', $geofence_id)"
    echo -e "${GREEN}  ✓ 已导入${NC}"
    echo ""
    echo "用 'bash $0 test' 试算最近一笔家充"
}

# ============================================================
# 子命令: list
# ============================================================
cmd_list() {
    ensure_db_container
    psql_exec -c '
SELECT
  r.id,
  COALESCE(g.name, $$(全局)$$) AS geofence,
  r.hour_start || $$-$$ || r.hour_end AS hours,
  r.rate AS rate_yuan,
  r.label,
  CASE WHEN r.apply_to_dc THEN $$DC$$ ELSE $$AC$$ END AS scope,
  CASE WHEN r.valid_from IS NULL THEN $$全年$$
       ELSE r.valid_from::TEXT || $$ ~ $$ || COALESCE(r.valid_to::TEXT, $$无$$) END AS season
FROM tou_rates r
LEFT JOIN geofences g ON g.id = r.geofence_id
ORDER BY r.geofence_id NULLS FIRST, r.id'
}

# ============================================================
# 子命令: test [charge_id]
# ============================================================
cmd_test() {
    ensure_db_container
    local charge_id="$1"

    if [ -z "$charge_id" ]; then
        # 找最近一笔有 cost 的家充作 default
        charge_id=$(psql_query_value "
SELECT cp.id FROM charging_processes cp
WHERE cp.geofence_id IN (SELECT DISTINCT geofence_id FROM tou_rates WHERE geofence_id IS NOT NULL)
  AND cp.cost > 0
ORDER BY cp.start_date DESC LIMIT 1" | tr -d '[:space:]')

        if [ -z "$charge_id" ]; then
            echo -e "${YELLOW}没找到匹配的充电记录。手动指定 ID: bash $0 test <id>${NC}"
            exit 1
        fi
        echo -e "${BLUE}用最近一笔家充对账（id=$charge_id）...${NC}"
    fi

    psql_exec -c "
SELECT
  cp.id,
  (cp.start_date AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Shanghai')::timestamp(0) AS local_start,
  ROUND(cp.charge_energy_added::numeric, 2) AS kwh,
  cp.cost AS old_cost,
  compute_tou_cost(cp.id) AS tou_cost,
  ROUND((compute_tou_cost(cp.id) - cp.cost)::numeric, 2) AS diff,
  COALESCE(g.name, '(无围栏)') AS geofence
FROM charging_processes cp
LEFT JOIN geofences g ON g.id = cp.geofence_id
WHERE cp.id = $charge_id"
}

# ============================================================
# 子命令: reset
# ============================================================
cmd_reset() {
    ensure_db_container
    echo -e "${YELLOW}⚠ 即将清空所有 分时电价配置（tou_rates + charging_processes_tou_cost）${NC}"
    read -p "  确认？输入 yes 继续: " confirm
    if [ "$confirm" != "yes" ]; then
        echo "  取消"
        exit 0
    fi
    psql_exec -c "TRUNCATE tou_rates RESTART IDENTITY CASCADE; TRUNCATE charging_processes_tou_cost;"
    echo -e "${GREEN}  ✓ 已清空${NC}"
}

# ============================================================
# Main
# ============================================================
case "${1:-}" in
    install)  cmd_install ;;
    import)   cmd_import "$2" "$3" ;;
    list)     cmd_list ;;
    test)     cmd_test "$2" ;;
    reset)    cmd_reset ;;
    *)
        cat <<EOF
TeslaMate 中文版分时电价配置工具

用法:
  bash $0 install                        装函数+表（首次跑必须）
  bash $0 import <city> <geofence_name>  导入城市模板
  bash $0 list                           列出当前 分时电价配置
  bash $0 test [<charge_id>]             试算单笔（不传 ID 用最近一笔家充）
  bash $0 reset                          清空所有 分时电价配置

可用城市模板:
$(printf '  - %s\n' "${CITIES_FALLBACK[@]}")

例子:
  bash $0 install
  bash $0 import beijing 仁安玺苑
  bash $0 list
  bash $0 test

更友好: bash scripts/tou-wizard.sh （交互式向导）
EOF
        ;;
esac
