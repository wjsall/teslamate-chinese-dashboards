#!/bin/bash
# TeslaMate 中文版分时电价交互式配置向导
#
# 5 步从零到能用：
#   1. 选择城市 / 自定义分时电价
#   2. 选择给哪个地理围栏配分时电价
#   3. 可选覆盖默认电价（按你账单填）
#   4. 是否对快充也启用
#   5. 试算最近一笔充电对账
#
# 用法: bash scripts/tou-wizard.sh
set -e
set -o pipefail

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$SCRIPT_DIR/setup-tou.sh"

# shellcheck source=lib/detect-containers.sh
source "$SCRIPT_DIR/lib/detect-containers.sh"

# ============================================================
# 检测容器
# ============================================================
DB_CONTAINER=$(detect_db_container)
if [ -z "$DB_CONTAINER" ]; then
    echo -e "${RED}✗ 找不到运行中的 PostgreSQL 容器${NC}"
    echo "  请先启动 TeslaMate: docker compose up -d"
    exit 1
fi

# ============================================================
# 横幅
# ============================================================
clear
cat <<'EOF'
═══════════════════════════════════════════════
  ⚡ TeslaMate 中文版分时电价配置向导
═══════════════════════════════════════════════
EOF
echo ""

# ============================================================
# Step 0: 检查函数是否已装
# ============================================================
has_func=$(docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -t -A -c \
  "SELECT 1 FROM pg_proc WHERE proname = 'compute_tou_cost' LIMIT 1" 2>/dev/null | tr -d '[:space:]')

if [ "$has_func" != "1" ]; then
    echo -e "${YELLOW}⚠ 分时电价函数未装，先装一下...${NC}"
    bash "$SETUP" install
    echo ""
fi

# ============================================================
# Step 1: 选城市
# ============================================================
echo -e "${BOLD}[1/4] 你在哪个城市/区域？${NC}"
echo ""

# 城市列表与 install-tou.sql 的 apply_city_template() 函数 CASE 分支对应
# 用 _ 占位 0 号槽，让用户输入的 1-based 序号直接当下标用（避免 ${cities[@]} 紧凑化下标的坑）
declare -a cities=(_ beijing shanghai shenzhen guangzhou zhejiang jiangsu)
declare -a displays=(_ "北京" "上海" "深圳" "广州" "浙江（杭州）" "江苏（南京，含夏冬尖峰）")
for i in $(seq 1 $((${#cities[@]} - 1))); do
    printf "  ${CYAN}%d)${NC} %s\n" "$i" "${displays[$i]}"
done
echo "  ${CYAN}c)${NC} 自定义（手动填时段+单价）"
echo ""
read -p "> 选择 [1-$((${#cities[@]} - 1)) 或 c]: " city_choice

if [ "$city_choice" = "c" ] || [ "$city_choice" = "C" ]; then
    CUSTOM=1
elif [[ "$city_choice" =~ ^[0-9]+$ ]] && [ -n "${cities[$city_choice]}" ]; then
    CITY="${cities[$city_choice]}"
    CUSTOM=0
else
    echo -e "${RED}✗ 无效选项${NC}"
    exit 1
fi

# ============================================================
# Step 2: 选地理围栏
# ============================================================
echo ""
echo -e "${BOLD}[2/4] 给哪个充电点配分时电价？${NC}"
echo ""
echo "你的地理围栏列表："
docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -c "
SELECT id, name FROM geofences ORDER BY name" 2>&1 | grep -vE '^[(\s].*rows\)' | sed 's/^/  /'
echo ""
read -p "> 输入地理围栏的「名字」（如 仁安玺苑 / 公司）: " geofence_name

geofence_id=$(docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -t -A \
  -v gname="$geofence_name" \
  -c "SELECT id FROM geofences WHERE name = :'gname'" 2>/dev/null | tr -d '[:space:]')
if [ -z "$geofence_id" ]; then
    echo -e "${RED}✗ 找不到地理围栏「$geofence_name」${NC}"
    exit 1
fi
echo -e "${GREEN}  ✓ geofence_id = $geofence_id${NC}"

# ============================================================
# Step 3: 导入模板（或自定义）
# ============================================================
echo ""
# 校验函数：整数（含范围）+ 数字（含小数）
require_int_in_range() {
    local val="$1" min="$2" max="$3" label="$4"
    [[ "$val" =~ ^[0-9]+$ ]] || { echo -e "${RED}✗ $label 必须是整数${NC}"; exit 1; }
    [ "$val" -ge "$min" ] && [ "$val" -le "$max" ] || { echo -e "${RED}✗ $label 必须在 $min-$max 之间${NC}"; exit 1; }
}
require_decimal_positive() {
    local val="$1" label="$2"
    [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo -e "${RED}✗ $label 必须是正数（如 0.50）${NC}"; exit 1; }
}

if [ "$CUSTOM" = "1" ]; then
    echo -e "${BOLD}[3/4] 自定义峰谷时段...${NC}"
    echo ""
    echo "默认 2 段（峰/谷）。先填峰段："
    read -p "  峰段开始小时 [0-23, 默认 8]: " peak_start
    peak_start=${peak_start:-8}
    require_int_in_range "$peak_start" 0 23 "峰段开始小时"
    read -p "  峰段结束小时 [1-24, 默认 22]: " peak_end
    peak_end=${peak_end:-22}
    require_int_in_range "$peak_end" 1 24 "峰段结束小时"
    read -p "  峰段单价 [元/度, 默认 0.50]: " peak_rate
    peak_rate=${peak_rate:-0.50}
    require_decimal_positive "$peak_rate" "峰段单价"
    read -p "  谷段单价 [元/度, 默认 0.30]: " valley_rate
    valley_rate=${valley_rate:-0.30}
    require_decimal_positive "$valley_rate" "谷段单价"
    valley_start=$peak_end
    valley_end=$peak_start

    # 经过 require_* 校验，4 个变量都已是干净数字，可安全拼入 SQL
    docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate <<EOF
DELETE FROM tou_rates WHERE geofence_id = $geofence_id;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, timezone) VALUES
  ($geofence_id, $peak_start, $peak_end, $peak_rate, '峰', 'Asia/Shanghai'),
  ($geofence_id, $valley_start, $valley_end, $valley_rate, '谷', 'Asia/Shanghai');
EOF
    echo -e "${GREEN}  ✓ 自定义配置已写入${NC}"
else
    echo -e "${BOLD}[3/4] 导入 $CITY 模板${NC}"
    bash "$SETUP" import "$CITY" "$geofence_name" >/dev/null
    echo -e "${GREEN}  ✓ 模板已导入${NC}"
    echo ""
    echo -e "${YELLOW}⚠ 模板里的单价是 2025 年参考值，你账单可能不一样。${NC}"
    echo "  想按账单微调单价 → 打开 Grafana「⚡ 分时电价配置」仪表盘 → 「✏️ 修改单价」面板"
    echo "  （以前向导里有 freeform SQL 入口，已移除以避免误操作把全库电价清零）"
fi

# ============================================================
# Step 4: 是否对快充启用
# ============================================================
echo ""
echo -e "${BOLD}[4/4] 是否对 DC 快充也启用分时电价？${NC}"
echo "  快充包括：Tesla 超充、特来电、星星充电、国家电网快充等"
echo "  启用后需要再为快充地点单独配置时段 + 单价"
read -p "  [y/N]: " enable_dc
if [ "$enable_dc" = "y" ] || [ "$enable_dc" = "Y" ]; then
    echo ""
    echo "  跳过此向导 —— 快充配置请手动跑："
    echo "  ${CYAN}bash $SETUP import dc-fast-charge <快充点的 geofence 名>${NC}"
    echo "  然后 UPDATE 单价为你 App 看到的实际值"
fi

# ============================================================
# Step 5: 试算最近一笔充电
# ============================================================
echo ""
echo "═══════════════════════════════════════════════"
echo -e "${GREEN}  ✓ 分时电价配置完成${NC}"
echo "═══════════════════════════════════════════════"
echo ""
echo -e "${BOLD}最近一笔充电对账：${NC}"
bash "$SETUP" test || true
echo ""
echo "下一步:"
echo "  ${CYAN}bash $SETUP list${NC}                    查看所有 分时电价配置"
echo "  ${CYAN}bash $SETUP test <id>${NC}               试算指定充电"
echo "  ${CYAN}docker exec teslamate-database-1 psql -U teslamate -d teslamate \\
    -c \"UPDATE tou_rates SET rate=X WHERE id=Y;\"${NC}  微调单价"
echo ""
