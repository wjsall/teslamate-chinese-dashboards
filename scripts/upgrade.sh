#!/bin/bash
# TeslaMate 中文仪表盘 — 一键升级脚本
#
# 用法（在仓库根目录运行）:
#   bash scripts/upgrade.sh
#
# 自动完成（幂等，多次跑无副作用）:
#   1. git pull 拉取最新代码
#   2. 自动检测运行中的 PostgreSQL 容器名
#   3. 安装/更新坐标转换函数（lat_for_map / lng_for_map / wgs84_to_gcj02_*）
#   4. 安装/更新分时电价系统（tou_rates 表 + 7 个函数 + 触发器 + 视图）
#   5. 安装/更新性能优化索引（v1.6.1+，positions 表 car_id+date btree）
#   6. 检查 Grafana 必装插件（volkovlabs-form-panel）
#   7. 重启 Grafana 容器，触发仪表盘重载
#
# 适用场景:
#   - 从任一旧版本升级到最新（v1.4.x → v1.5.x）
#   - 全新安装后第一次启用扩展功能
#   - 任何时候想确保函数 / 插件是最新的
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/detect-containers.sh
source "$SCRIPT_DIR/lib/detect-containers.sh"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"

# ============================================================
# 0. 检查工作目录
# ============================================================
if [ ! -f "sql/install-coord-functions.sql" ]; then
    echo -e "${RED}✗ 错误：找不到 sql/install-coord-functions.sql${NC}"
    echo "  请确认你在 teslamate-chinese-dashboards 仓库根目录运行此脚本。"
    exit 1
fi

# ============================================================
# 1. git pull
# ============================================================
echo -e "${BLUE}[1/7] 拉取最新代码...${NC}"
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    echo -e "${RED}✗ 本地有未提交的修改，无法 git pull${NC}"
    echo ""
    echo "  请先处理本地改动（任选一）:"
    echo "    git stash                # 暂存到栈，pull 完后 git stash pop"
    echo "    git commit -am 'wip'     # 提交"
    echo "    git restore .            # 放弃所有未提交改动（危险）"
    echo ""
    echo "  处理后重新运行: bash scripts/upgrade.sh"
    exit 1
fi
git pull --rebase

# ============================================================
# 2. 检测 PostgreSQL 容器名
# ============================================================
echo -e "${BLUE}[2/7] 检测 PostgreSQL 容器...${NC}"
DB_CONTAINER=$(detect_db_container)

if [ -z "$DB_CONTAINER" ]; then
    echo -e "${RED}✗ 找不到运行中的 PostgreSQL 容器${NC}"
    echo ""
    echo "  请先启动 TeslaMate："
    echo "    docker compose up -d"
    echo ""
    echo "  或手动指定容器名后再跑函数安装："
    echo "    docker exec -i <你的容器名> psql -U teslamate teslamate \\"
    echo "      < sql/install-coord-functions.sql"
    exit 1
fi
echo -e "${GREEN}  ✓ 找到容器: ${DB_CONTAINER}${NC}"

# ============================================================
# 3. 安装坐标转换函数（地图源切换 + GCJ-02 转换）
# ============================================================
echo -e "${BLUE}[3/7] 安装坐标转换函数（地图）...${NC}"
if ! docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate \
        < sql/install-coord-functions.sql > /dev/null; then
    echo -e "${RED}✗ 坐标函数安装失败${NC}"
    echo "  常见原因 + 解决: 见 TROUBLESHOOTING.md「装 PostgreSQL 坐标转换函数报错」章节"
    exit 1
fi
echo -e "${GREEN}  ✓ 地图坐标函数已就绪${NC}"

# ============================================================
# 4. 安装分时电价系统
# ============================================================
echo -e "${BLUE}[4/7] 安装分时电价系统...${NC}"
TOU_INSTALLED=0
if [ ! -f "sql/install-tou.sql" ]; then
    echo -e "${YELLOW}  ⚠ 找不到 sql/install-tou.sql，跳过分时电价安装（地图功能仍可用）${NC}"
else
    # 把 stderr 落盘，便于排错；NOTICE 信息走 stdout 丢弃
    if docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate \
            < sql/install-tou.sql > /dev/null 2> /tmp/tou-install.log; then
        echo -e "${GREEN}  ✓ 分时电价表/函数/触发器/视图已就绪${NC}"
        echo "    用 'bash scripts/tou-wizard.sh' 配置峰谷电价（可选，没装也不影响主仪表盘）"
        TOU_INSTALLED=1
    else
        echo -e "${RED}  ✗ 分时电价安装失败！错误日志：${NC}"
        sed 's/^/    /' /tmp/tou-install.log | head -20
        echo ""
        echo -e "${YELLOW}  地图功能仍可用，但「⚡ 分时电价配置」仪表盘不可用。${NC}"
        echo -e "${YELLOW}  排错见 TROUBLESHOOTING.md「v1.5.0 分时电价升级排错」章节${NC}"
        # 不 exit 1：让用户继续看到地图功能升级是 OK 的
    fi
fi

# ============================================================
# 5. 安装性能优化索引（v1.6.1+）
# ============================================================
echo -e "${BLUE}[5/7] 安装性能优化索引...${NC}"
if [ ! -f "sql/install-indexes.sql" ]; then
    echo -e "${YELLOW}  ⚠ 找不到 sql/install-indexes.sql，跳过（不影响功能，仅性能略差）${NC}"
else
    if docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate \
            < sql/install-indexes.sql > /dev/null 2>&1; then
        echo -e "${GREEN}  ✓ 性能索引已就绪（电池健康/天气-能耗等查询提速）${NC}"
    else
        echo -e "${YELLOW}  ⚠ 索引安装失败（不影响功能，仅查询略慢）${NC}"
    fi
fi

# ============================================================
# 6. 检查 Grafana 必装插件
# ============================================================
echo -e "${BLUE}[6/7] 检查 Grafana 插件...${NC}"
GRAFANA_CONTAINER=$(detect_grafana_container)
if [ -n "$GRAFANA_CONTAINER" ]; then
    if docker exec "$GRAFANA_CONTAINER" ls /var/lib/grafana/plugins/volkovlabs-form-panel >/dev/null 2>&1; then
        echo -e "${GREEN}  ✓ volkovlabs-form-panel 已装${NC}"
    else
        echo -e "${YELLOW}  ⚠ 分时电价配置仪表盘需要 volkovlabs-form-panel 插件${NC}"
        read -p "  是否现在安装？[Y/n]: " -n 1 -r install_plugin
        echo ""
        if [[ ! $install_plugin =~ ^[Nn]$ ]]; then
            docker exec --user root "$GRAFANA_CONTAINER" \
                grafana-cli plugins install volkovlabs-form-panel >/dev/null 2>&1 \
                && echo -e "${GREEN}  ✓ 插件已装（重启后生效）${NC}" \
                || echo -e "${RED}  ✗ 插件安装失败，可手动跑: docker exec ${GRAFANA_CONTAINER} grafana-cli plugins install volkovlabs-form-panel${NC}"
        else
            echo "    跳过。「⚡ 分时电价配置」仪表盘会显示空白，但不影响其他面板。"
        fi
    fi
fi

# ============================================================
# 7. 重启 Grafana
# ============================================================
echo -e "${BLUE}[7/7] 重启 Grafana...${NC}"
# GRAFANA_CONTAINER 已在步骤 6 检测过，直接复用
if [ -n "$GRAFANA_CONTAINER" ]; then
    docker restart "$GRAFANA_CONTAINER" > /dev/null
    echo -e "${GREEN}  ✓ 已重启 ${GRAFANA_CONTAINER}${NC}"
else
    echo -e "${YELLOW}  ⚠ 没找到运行中的 Grafana 容器，跳过重启${NC}"
    echo "    Grafana 默认 10 秒内会自动检测到仪表盘 JSON 变化。"
fi

# ============================================================
# 完成
# ============================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ 升级完成！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "下一步:"
echo "  1. 浏览器 Ctrl+Shift+R（Windows）/ Cmd+Shift+R（Mac）强刷"
echo "  2. 地图功能：打开任一含地图的仪表盘 → 顶部「地图源」试试 OSM / 高德 / 谷歌 / 卫星"
echo "  3. 分时电价（可选）："
echo "     bash scripts/tou-wizard.sh        # 交互式向导（推荐）"
echo "     或打开「⚡ 分时电价配置」仪表盘 → 「🌆 一键导入城市模板」"
echo "  4. 配完想让历史充电也按分时电价算："
echo "     docker exec ${DB_CONTAINER} psql -U teslamate -d teslamate -c 'SELECT backfill_all_tou()'"
echo ""
echo "如有问题: TROUBLESHOOTING.md"
