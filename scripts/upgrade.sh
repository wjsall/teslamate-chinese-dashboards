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
#   4. 安装/更新单位换算函数（convert_km / convert_celsius / convert_m / convert_tire_pressure）
#   5. 安装/更新分时电价系统（tou_rates 表 + 函数 + 触发器 + 视图）
#   6. 安装/更新性能优化索引（v1.6.1+，positions 表 car_id+date btree）
#   7. 检查 Grafana 必装插件（volkovlabs-form-panel）
#   8. 重启 Grafana 容器，触发仪表盘重载
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
FAILED_STEPS=()
WARN_STEPS=()

# 三组兼容性 SQL（坐标函数/单位换算函数/分时电价）是否全部装成功——用于判断能不能记录
# SQL 兼容性 revision（issue #23/#29 事故预防机制）。不算性能索引，与 simple-deploy.sh /
# migrate-from-official.sh 口径一致。用 case + 空格分隔字符串匹配而不是数组遍历：
# 老 bash（如 Synology 的 3.2）在 set -e 下遍历「已声明但零元素」的数组可能报错，
# 字符串匹配没有这个坑（CLAUDE.md「Bash 3.2 兼容」条款同类教训）。
sql_trio_ok() {
    case " ${FAILED_STEPS[*]:-} " in
        *" 坐标函数 "*|*" 单位换算函数 "*|*" 分时电价 "*) return 1 ;;
    esac
    return 0
}

# SQL 兼容性 revision 记录：写入 teslamate_cn_extension_meta 表，scripts/diagnose.sh 用它
# 比对镜像要求的 revision（config/versions.env，随镜像一起装进 /opt/teslamate-cn/versions.env）
# 和数据库里实际装到的 revision。CREATE TABLE IF NOT EXISTS 是自愈的关键：老用户的数据库
# 压根没有这张表，本函数第一次跑起来时会自动建表 + 写入当前 revision，不需要任何手动迁移步骤。
write_sql_compat_revision() {
    if [ -z "$SQL_COMPAT_REVISION" ]; then
        echo -e "${YELLOW}  ⚠ 本地检出没有 config/versions.env，跳过记录 SQL 兼容性 revision${NC}"
        return 1
    fi
    local project_version
    project_version=$(git describe --tags --always 2>/dev/null || echo "unknown")
    project_version="${project_version//\'/}"
    if docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQLEOF
CREATE TABLE IF NOT EXISTS teslamate_cn_extension_meta (
    id              INTEGER PRIMARY KEY DEFAULT 1,
    sql_revision    INTEGER NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    project_version TEXT,
    CONSTRAINT teslamate_cn_extension_meta_singleton CHECK (id = 1)
);
INSERT INTO teslamate_cn_extension_meta (id, sql_revision, updated_at, project_version)
VALUES (1, ${SQL_COMPAT_REVISION}, now(), '${project_version}')
ON CONFLICT (id) DO UPDATE SET
    sql_revision    = EXCLUDED.sql_revision,
    updated_at      = EXCLUDED.updated_at,
    project_version = EXCLUDED.project_version;
SQLEOF
    then
        echo -e "${GREEN}  ✓ SQL 兼容性 revision 已记录（${SQL_COMPAT_REVISION}）${NC}"
        return 0
    else
        echo -e "${YELLOW}  ⚠ SQL 兼容性 revision 记录失败（不影响刚装好的 SQL 功能本身，diagnose 之后可能误报过期）${NC}"
        return 1
    fi
}

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
echo -e "${BLUE}[1/8] 拉取最新代码...${NC}"
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

# SQL 兼容性 revision 的单一事实源：config/versions.env。本脚本跑在本地仓库检出里
# （工作目录检查已确认），git pull 之后直接 source 就能拿到跟刚拉的 SQL 一致的 revision，
# 不用像 curl-piped 的 simple-deploy.sh / migrate-from-official.sh 那样现场再拉一次。
# 兼容老检出还没有这个文件的情况（不存在时 SQL_COMPAT_REVISION 留空，后面写入步骤会跳过）。
SQL_COMPAT_REVISION=""
if [ -f "config/versions.env" ]; then
    # shellcheck source=config/versions.env
    source "config/versions.env"
fi

# ============================================================
# 2. 检测 PostgreSQL 容器名
# ============================================================
echo -e "${BLUE}[2/8] 检测 PostgreSQL 容器...${NC}"
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
echo -e "${BLUE}[3/8] 安装坐标转换函数（地图）...${NC}"
if ! docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate \
        < sql/install-coord-functions.sql > /dev/null; then
    echo -e "${RED}✗ 坐标函数安装失败${NC}"
    echo "  常见原因 + 解决: 见 TROUBLESHOOTING.md「装 PostgreSQL 坐标转换函数报错」章节"
    FAILED_STEPS+=("坐标函数")
else
    echo -e "${GREEN}  ✓ 地图坐标函数已就绪${NC}"
fi

# ============================================================
# 4. 安装单位换算函数
# ============================================================
echo -e "${BLUE}[4/8] 安装单位换算函数...${NC}"
if ! docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate \
        < sql/install-unit-functions.sql > /dev/null; then
    echo -e "${RED}✗ 单位换算函数安装失败${NC}"
    echo "  请确认 sql/install-unit-functions.sql 存在且可被当前数据库用户执行。"
    FAILED_STEPS+=("单位换算函数")
else
    echo -e "${GREEN}  ✓ 单位换算函数已就绪${NC}"
fi

# ============================================================
# 5. 安装分时电价系统
# ============================================================
echo -e "${BLUE}[5/8] 安装分时电价系统...${NC}"
if [ ! -f "sql/install-tou.sql" ]; then
    echo -e "${RED}  ✗ 找不到 sql/install-tou.sql，分时电价未安装${NC}"
    FAILED_STEPS+=("分时电价")
else
    # 把 stderr 落盘，便于排错；NOTICE 信息走 stdout 丢弃
    if docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate \
            < sql/install-tou.sql > /dev/null 2> /tmp/tou-install.log; then
        echo -e "${GREEN}  ✓ 分时电价表/函数/触发器/视图已就绪${NC}"
        echo "    用 'bash scripts/tou-wizard.sh' 配置峰谷电价（可选，没装也不影响主仪表盘）"
        # v1.7.5: compute_tou_cost 公式从 charge_energy_added 改为
        # GREATEST(added, used)。旁路表已有 cost_tou 是旧公式算的，重跑回算修正。
        # 单笔几毫秒，对个人用户（百~千笔）秒级完成，无副作用（旁路表仅函数写入）。
        echo "    回算历史 TOU 费用（v1.7.5 算法修正）..."
        if docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate \
                -At -c "SELECT format('  ✓ 已扫描 %s 笔充电，回算 %s 笔，跳过 %s 笔（未配 TOU 的）', processed, updated, skipped) FROM backfill_all_tou();" \
                2> /tmp/tou-backfill.log; then
            :
        else
            echo -e "${YELLOW}    ⚠ 回算失败（不影响升级，可稍后手动跑 SELECT backfill_all_tou();）${NC}"
            sed 's/^/      /' /tmp/tou-backfill.log | head -10
            WARN_STEPS+=("TOU 历史费用回算")
        fi
    else
        echo -e "${RED}  ✗ 分时电价安装失败！错误日志：${NC}"
        sed 's/^/    /' /tmp/tou-install.log | head -20
        echo ""
        echo -e "${YELLOW}  地图功能仍可用，但「⚡ 分时电价配置」仪表盘不可用。${NC}"
        echo -e "${YELLOW}  排错见 TROUBLESHOOTING.md「v1.5.0 分时电价升级排错」章节${NC}"
        FAILED_STEPS+=("分时电价")
    fi
fi

# 三组兼容性 SQL 全部成功才记录 revision（性能索引不算，见 sql_trio_ok 定义处注释）
if sql_trio_ok; then
    write_sql_compat_revision || true
fi

# ============================================================
# 6. 安装性能优化索引（v1.6.1+）
# ============================================================
echo -e "${BLUE}[6/8] 安装性能优化索引...${NC}"
if [ ! -f "sql/install-indexes.sql" ]; then
    echo -e "${YELLOW}  ⚠ 找不到 sql/install-indexes.sql，跳过（不影响功能，仅性能略差）${NC}"
    WARN_STEPS+=("性能索引")
else
    if docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate \
            < sql/install-indexes.sql > /dev/null 2>&1; then
        echo -e "${GREEN}  ✓ 性能索引已就绪（电池健康/天气-能耗等查询提速）${NC}"
    else
        echo -e "${YELLOW}  ⚠ 索引安装失败（不影响功能，仅查询略慢）${NC}"
        WARN_STEPS+=("性能索引")
    fi
fi

# ============================================================
# 7. 检查 Grafana 必装插件
# ============================================================
echo -e "${BLUE}[7/8] 检查 Grafana 插件...${NC}"
# Pinned 版本与 Dockerfile / migrate-from-official.sh 同步
VOLKOV_FORM_PANEL_VERSION="6.3.2"

# PROJECT_IMAGE 默认值必须和"本地代码版本"对应，不能再硬编码 :latest —— :latest 现在
# 只在打正式 tag 时更新（不再随 main 每次 push 变化，见 CLAUDE.md「构建产物版本注入」
# 条款 / issue #33），若本地 git pull 已经领先最新正式版（在 main 滚动分支上），
# :latest 会比本地检出旧，插件本地复制兜底命令会从一个落后的镜像里拷插件。
# 本脚本运行在 git clone 检出里，"版本"就是当前 checkout 状态，不需要像 curl-piped 的
# simple-deploy.sh / migrate-from-official.sh 那样引入 TARGET_REF 去解析远程 ref——
# 直接问本地 git 就知道：刚 pull 完，如果 HEAD 正好在某个 vX.Y.Z tag 上，就精确对应
# 那个数字 tag；否则说明本地在 main 分支上领先于最新正式版，默认到 :main
# （CI 每次 push main 都会构建这个 tag，与只在打 tag 时更新的 :latest 相互独立，
# 见 .github/workflows/ghcr-build.yml）。
# 注意：这只是给"插件从镜像本地复制"兜底命令（见下方 docker pull $PROJECT_IMAGE）挑一个
# 大概率正确的默认镜像，不会拿它去自动 pull/替换任何服务——运行镜像版本始终由用户自己
# docker-compose.yml 的 image: 行决定，本脚本不碰它。
_LOCAL_TAG=""
if command -v git >/dev/null 2>&1; then
    _LOCAL_TAG=$(git describe --tags --exact-match 2>/dev/null || true)
fi
if [ -n "$_LOCAL_TAG" ]; then
    _DEFAULT_PROJECT_IMG_TAG="${_LOCAL_TAG#v}"
else
    _DEFAULT_PROJECT_IMG_TAG="main"
fi
PROJECT_IMAGE="${PROJECT_IMAGE:-bswlhbhmt816/teslamate-chinese-dashboards:${_DEFAULT_PROJECT_IMG_TAG}}"
GRAFANA_CONTAINER=$(detect_grafana_container)
if [ -n "$GRAFANA_CONTAINER" ]; then
    # 容器实际配置的插件目录：新版镜像（issue #20/#21 修复后）用 GF_PATHS_PLUGINS=
    # /opt/grafana-plugins（volume 外，不会被 volume 覆盖）；老镜像没设这个 env，grafana
    # 自身默认值就是 /var/lib/grafana/plugins——现场读容器自己的 env，新老镜像都能测准、装对地方。
    PLUGIN_DIR=$(docker exec "$GRAFANA_CONTAINER" sh -c 'echo "${GF_PATHS_PLUGINS:-/var/lib/grafana/plugins}"' 2>/dev/null) || true
    PLUGIN_DIR="${PLUGIN_DIR:-/var/lib/grafana/plugins}"
    if docker exec "$GRAFANA_CONTAINER" test -d "${PLUGIN_DIR}/volkovlabs-form-panel" 2>/dev/null \
       || docker exec "$GRAFANA_CONTAINER" test -d /var/lib/grafana/plugins/volkovlabs-form-panel 2>/dev/null; then
        echo -e "${GREEN}  ✓ volkovlabs-form-panel 已装${NC}"
    else
        echo -e "${YELLOW}  ⚠ 分时电价配置仪表盘需要 volkovlabs-form-panel 插件（插件目录：${PLUGIN_DIR}）${NC}"
        echo -e "${YELLOW}    根因：老版本镜像把插件装进了 grafana volume 内部，旧卷会覆盖它${NC}"
        install_plugin="n"
        if [ -t 0 ]; then
            if ! read -r -p "  是否现在安装？[Y/n]: " -n 1 install_plugin; then
                install_plugin="n"
                echo ""
                echo -e "${YELLOW}    ⚠ 输入已结束（EOF），跳过自动安装插件${NC}"
            else
                echo ""
            fi
        else
            echo -e "${YELLOW}    ⚠ 非交互模式，跳过自动安装插件；请按下方手动命令安装${NC}"
        fi
        if [[ ! $install_plugin =~ ^[Nn]$ ]]; then
            # 保留 stderr（与 install_sql 同款约定：让用户看到真实错误，如 grafana.com 国内超时）
            if docker exec --user root "$GRAFANA_CONTAINER" \
                    grafana cli --pluginsDir "$PLUGIN_DIR" plugins install volkovlabs-form-panel "$VOLKOV_FORM_PANEL_VERSION" >/dev/null; then
                echo -e "${GREEN}  ✓ 插件已装（重启后生效）${NC}"
            else
                echo -e "${RED}  ✗ grafana cli 装失败（grafana.com 国内常超时）${NC}"
                WARN_STEPS+=("Grafana 插件")
                echo
                echo "  两条修复路径任选其一："
                echo
                echo "  路径 A — 从镜像本地复制（推荐，无外网依赖）："
                echo "    docker pull $PROJECT_IMAGE"
                echo "    docker create --name volkov-tmp $PROJECT_IMAGE"
                echo "    docker cp volkov-tmp:/opt/grafana-plugins/volkovlabs-form-panel /tmp/volkovlabs-form-panel"
                echo "    docker rm volkov-tmp"
                echo "    docker cp /tmp/volkovlabs-form-panel $GRAFANA_CONTAINER:${PLUGIN_DIR}/"
                echo "    docker exec --user root $GRAFANA_CONTAINER chown -R 472:472 ${PLUGIN_DIR}/volkovlabs-form-panel"
                echo "    docker restart $GRAFANA_CONTAINER && rm -rf /tmp/volkovlabs-form-panel"
                echo
                echo "  路径 B — 重试 grafana cli 看真实错误："
                echo "    docker exec --user root $GRAFANA_CONTAINER grafana cli --pluginsDir ${PLUGIN_DIR} plugins install volkovlabs-form-panel $VOLKOV_FORM_PANEL_VERSION"
                echo "    docker restart $GRAFANA_CONTAINER"
            fi
        else
            echo "    跳过。「⚡ 分时电价配置」仪表盘会显示空白，但不影响其他面板。"
            WARN_STEPS+=("Grafana 插件")
        fi
    fi
fi

# ============================================================
# 8. 重启 Grafana
# ============================================================
echo -e "${BLUE}[8/8] 重启 Grafana...${NC}"
# GRAFANA_CONTAINER 已在步骤 6 检测过，直接复用
if [ -n "$GRAFANA_CONTAINER" ]; then
    if docker restart "$GRAFANA_CONTAINER" > /dev/null; then
        echo -e "${GREEN}  ✓ 已重启 ${GRAFANA_CONTAINER}${NC}"
    else
        echo -e "${YELLOW}  ⚠ Grafana 重启失败，请稍后手动执行 docker restart ${GRAFANA_CONTAINER}${NC}"
        WARN_STEPS+=("Grafana 重启")
    fi
else
    echo -e "${YELLOW}  ⚠ 没找到运行中的 Grafana 容器，跳过重启${NC}"
    echo "    Grafana 默认 10 秒内会自动检测到仪表盘 JSON 变化。"
fi

# ============================================================
# 完成
# ============================================================
echo ""
if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  ✗ 升级失败：关键 SQL 未全部就绪${NC}"
    echo "    失败项：${FAILED_STEPS[*]}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    UPGRADE_EXIT=2
elif [ "${#WARN_STEPS[@]}" -gt 0 ]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  ⚠ 升级部分完成：核心功能可用，但有非关键步骤失败${NC}"
    echo "    告警项：${WARN_STEPS[*]}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    UPGRADE_EXIT=0
else
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ✓ 升级完成！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    UPGRADE_EXIT=0
fi
echo ""
echo "下一步:"
echo "  1. 浏览器 Ctrl+Shift+R（Windows）/ Cmd+Shift+R（Mac）强刷"
echo "  2. 地图功能：打开任一含地图的仪表盘 → 顶部「地图源」试试 OSM / 高德 / 谷歌 / 卫星"
echo "  3. 分时电价（可选）："
echo "     bash scripts/tou-wizard.sh        # 交互式向导（推荐）"
echo "     或打开「⚡ 分时电价配置」仪表盘 → 「🌆 一键导入城市模板」"
echo "  4. 配完想让历史充电也按分时电价算："
echo "     docker exec ${DB_CONTAINER} psql -U teslamate -d teslamate -c 'SELECT backfill_all_tou()'"
echo "  5. 行程列表地址列空 = nominatim.openstreetmap.org 国内访问超时。"
echo "     修法见 TROUBLESHOOTING.md#nominatim-proxy（加一行 NOMINATIM_PROXY env 即可）"
echo ""
echo "如有问题: TROUBLESHOOTING.md"
exit "$UPGRADE_EXIT"
