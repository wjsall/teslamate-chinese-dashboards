#!/bin/bash
# TeslaMate 中文版分时电价管理工具
# 把文档里那些零散的 docker exec psql 长命令集中成 CLI
#
# 用法:
#   bash scripts/manage-tou.sh backfill   # 把所有历史充电按当前分时配置重算
#   bash scripts/manage-tou.sh truncate   # 清空 tou_rates + 旁路表（保留函数）
#   bash scripts/manage-tou.sh uninstall  # 完全卸载（CASCADE 删除全部 tou_*）
#   bash scripts/manage-tou.sh status     # 查看安装状态 + 配置数 + 计算数
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/detect-containers.sh
source "$SCRIPT_DIR/lib/detect-containers.sh"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"

DB_CONTAINER=$(detect_db_container)
if [ -z "$DB_CONTAINER" ]; then
    echo -e "${RED}✗ 找不到运行中的 PostgreSQL 容器${NC}"
    exit 1
fi

psql_exec() {
    docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate "$@"
}

cmd_status() {
    psql_exec -c "
SELECT 'tou_rates 配置数' AS what, COUNT(*)::TEXT AS value FROM tou_rates
UNION ALL SELECT 'charging_processes_tou_cost 旁路记录', COUNT(*)::TEXT FROM charging_processes_tou_cost
UNION ALL SELECT 'compute_tou_cost 函数', CASE WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname='compute_tou_cost') THEN '✓ 已装' ELSE '✗ 未装' END
UNION ALL SELECT 'effective_cost 函数', CASE WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname='effective_cost') THEN '✓ 已装' ELSE '✗ 未装' END
UNION ALL SELECT 'tou_recalc 触发器', CASE WHEN EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='tou_recalc') THEN '✓ 已装' ELSE '✗ 未装' END;"
}

cmd_backfill() {
    echo -e "${BLUE}重算所有历史充电的分时电价费用...${NC}"
    psql_exec -c "SELECT * FROM backfill_all_tou()"
    echo -e "${GREEN}  ✓ 完成${NC}"
}

cmd_truncate() {
    echo -e "${YELLOW}⚠ 即将清空 tou_rates + charging_processes_tou_cost 两张表${NC}"
    echo "  函数/触发器/视图都保留，下次想用还能用"
    read -p "  确认？输入 yes 继续: " confirm
    [ "$confirm" = "yes" ] || { echo "  取消"; exit 0; }
    psql_exec -c "TRUNCATE tou_rates RESTART IDENTITY CASCADE; TRUNCATE charging_processes_tou_cost;"
    echo -e "${GREEN}  ✓ 已清空${NC}"
}

cmd_uninstall() {
    echo -e "${YELLOW}⚠ 完全卸载分时电价系统${NC}"
    echo "  - 删除全部 tou_* / _tou_* 函数"
    echo "  - 删除 tou_recalc 触发器 + charging_processes_v 视图"
    echo "  - 删除 tou_rates + charging_processes_tou_cost 表（CASCADE）"
    echo "  - 你自己建在 tou_rates 上的视图也会被 CASCADE 删掉"
    read -p "  确认？输入 yes 继续: " confirm
    [ "$confirm" = "yes" ] || { echo "  取消"; exit 0; }
    psql_exec -c "SELECT uninstall_tou(); DROP FUNCTION uninstall_tou();"
    echo -e "${GREEN}  ✓ 已卸载${NC}"
    echo ""
    echo "  仪表盘 SQL 改回原 cost (git clone 用户):"
    echo "    python3 scripts/wrap-cost-with-tou-view.py --revert"
}

case "${1:-}" in
    status)    cmd_status ;;
    backfill)  cmd_backfill ;;
    truncate)  cmd_truncate ;;
    uninstall) cmd_uninstall ;;
    *)
        cat <<EOF
TeslaMate 中文版分时电价管理工具

用法:
  bash $0 status      查看安装状态 + 配置数 + 旁路记录数
  bash $0 backfill    把所有历史充电按当前分时配置重算
  bash $0 truncate    清空 tou_rates + 旁路表（保留函数）
  bash $0 uninstall   完全卸载（CASCADE 删除全部 tou_*）

例子:
  bash $0 status               # 看现状
  bash $0 backfill             # 改了 TOU 配置后重算历史
  bash $0 uninstall            # 想完全恢复 v1.4.x 状态
EOF
        ;;
esac
