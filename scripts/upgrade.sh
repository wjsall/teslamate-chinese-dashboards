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
# 等 TeslaMate 自己的 Ecto 迁移跑完，再装我们的 SQL。
# 理由同 simple-deploy.sh：install-tou.sql 依赖 charging_processes（TeslaMate 迁移建的），
# 而 install-unit-functions.sql 抢先建 convert_* 会让上游那条不带 OR REPLACE 的迁移撞
# duplicate_function、TeslaMate 起不来。判据：等 charging_processes 出现，再等
# schema_migrations 行数连续 8 次采样（24 秒）不变——窗口取短了会在一条耗时长的迁移
# 中途误判成已完成。
# TeslaMate 容器当前状态（running / restarting / exited / unknown）。
# 崩溃重启中的 TeslaMate，schema_migrations 行数同样恒定不变，只看行数会把「迁移撞崩、
# 永久停在半途」判成「迁移已完成」，然后继续装 SQL 把问题坐实。
# 找 TeslaMate 主容器。三级探测，一级比一级不依赖命名约定：
#   ① compose 自己报（用户改过 project 名也准）
#   ② 名字正则（兼容没跑在 compose 里的情况）
#   ③ 按镜像找（用户给容器起了完全不相干的名字时的兜底）
# 探不到会让下面的存活判据退化成「不判」，所以这里要尽量探得到——实测过：容器叫
# teslamate-app 时只有 ③ 能找到，而少了它，一个正在崩溃重启的 TeslaMate 会被当成健康。
teslamate_container_name() {
    local c=""
    c=$(${DC:-docker compose} ps -q teslamate 2>/dev/null | head -1 || true)
    if [ -z "$c" ]; then
        c=$(docker ps -a --format '{{.Names}}' 2>/dev/null \
            | grep -iE '(^|[-_])teslamate([-_][0-9]+)?$' \
            | grep -viE 'database|postgres|grafana|mosquitto' | head -1 || true)
    fi
    if [ -z "$c" ]; then
        c=$(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
            | grep -iE '(^|[[:space:]])teslamate/teslamate(:|[[:space:]]|$)' \
            | cut -f1 | head -1 || true)
    fi
    echo "$c"
}

teslamate_container_status() {
    local c
    c=$(teslamate_container_name)
    if [ -z "$c" ]; then
        echo unknown
        return
    fi
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

wait_teslamate_migrated() {
    local db="$1" u="$2" d="$3"
    local i cur last="" stable=0 code tm_st tm_port bad=0
    for i in $(seq 1 60); do
        if docker exec "$db" psql -U "$u" -d "$d" -tAc \
            "SELECT 1 FROM pg_class WHERE relname='charging_processes'" 2>/dev/null | grep -qx 1; then
            break
        fi
        tm_st=$(teslamate_container_status)
        if [ "$tm_st" = "restarting" ] || [ "$tm_st" = "exited" ]; then
            bad=$((bad + 1))
            if [ "$bad" -ge 3 ]; then
                echo "  ✗ TeslaMate 容器状态为 ${tm_st}（反复重启/已退出），它的迁移不可能完成。"
                echo "    先看 docker logs 排掉 TeslaMate 自身的启动问题，再重跑本脚本。"
                return 1
            fi
        else
            bad=0
        fi
        sleep 3
    done
    # 第一段跑完还没 break，说明表始终没出现——这时再进第二段也只会白等一个 180 秒的
    # 超时（实测总耗时 400 秒+）。直接返回"确认不了"，让调用方走跳过分支。
    if ! docker exec "$db" psql -U "$u" -d "$d" -tAc \
        "SELECT 1 FROM pg_class WHERE relname='charging_processes'" 2>/dev/null | grep -qx 1; then
        echo "  ✗ 等了 3 分钟，TeslaMate 仍未建好自己的数据表，无法确认迁移状态。"
        return 1
    fi

    for i in $(seq 1 60); do
        # 主判据：TeslaMate 的 HTTP 端口能应答。它的 entrypoint 是先跑完整套迁移
        # 再 exec 启动服务，所以端口一应答就等于迁移结束——比数迁移行数准得多。
        tm_port=$(teslamate_published_port)
        if [ -n "$tm_port" ] && command -v curl >/dev/null 2>&1; then
            code=$(curl -sS --noproxy '*' -m 3 -o /dev/null -w '%{http_code}' \
                "http://127.0.0.1:${tm_port}/" 2>/dev/null)
            if [ -n "$code" ] && [ "$code" != "000" ]; then
                return 0
            fi
        fi
        tm_st=$(teslamate_container_status)
        if [ "$tm_st" = "restarting" ] || [ "$tm_st" = "exited" ]; then
            bad=$((bad + 1))
            if [ "$bad" -ge 3 ]; then
                echo "  ✗ TeslaMate 容器状态为 ${tm_st}（反复重启/已退出），它的迁移不可能完成。"
                echo "    先看 docker logs 排掉 TeslaMate 自身的启动问题，再重跑本脚本。"
                return 1
            fi
            stable=0
            last=""
            sleep 3
            continue
        fi
        bad=0
        cur=$(docker exec "$db" psql -U "$u" -d "$d" -tAc \
            "SELECT count(*) FROM schema_migrations" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$cur" ] && [ "$cur" = "$last" ]; then
            stable=$((stable + 1))
            if [ "$stable" -ge 8 ]; then
                return 0
            fi
        else
            stable=0
        fi
        last="$cur"
        sleep 3
    done
    return 1
}

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
# 三组兼容性 SQL 的对象是否真的在库里——记 revision 之前的最后一道校验。
# psql 的退出码不够：默认不是 ON_ERROR_STOP 时语句失败也 exit 0（2026-07 冒烟①实测到
# 「✓ 已装」+ revision=1 但 tou_rates 根本没建的假绿）。安装调用都加了 ON_ERROR_STOP=1，
# 这里再直接问库一遍作为第二道闸。谓词与 scripts/diagnose.sh 第 4 节语义一致（同样的三组对象、
# 同样的哨兵），但不是逐字相同：curl-piped 单文件脚本不能 source 公共库，各自内联了一份。
# 改任一处务必同步全部四处（simple-deploy.sh / migrate-from-official.sh / upgrade.sh / diagnose.sh）。
sql_trio_objects_present() {
    [ -n "${DB_CONTAINER:-}" ] || return 1
    docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc \
        "SELECT count(DISTINCT proname) FROM pg_proc WHERE proname IN ('lat_for_map','lng_for_map','wgs84_to_gcj02_lat','wgs84_to_gcj02_lng','is_outside_china')" \
        2>/dev/null | grep -qx 5 || return 1
    # 只数 proname 是查不出东西的：convert_km/convert_celsius/convert_m/convert_tire_pressure
    # 这四个名字上游 TeslaMate 自己的迁移就会建（这正是"抢先建会撞车"的前提），所以任何迁移
    # 完成的库上那个计数都恒等于 4——这一腿等于没查。改查我们这版独有的特征：只有我们的
    # convert_tire_pressure 支持 kPa/kpa 单位。它又是 install-unit-functions.sql 的最后一个
    # 函数，装到它就说明整份文件都装完了，正好当哨兵。
    docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc \
        "SELECT count(*) FROM pg_proc WHERE proname = 'convert_tire_pressure' AND prosrc LIKE '%kPa%'" \
        2>/dev/null | grep -qE '^[1-9][0-9]*$' || return 1
    docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -tAc \
        "SELECT 1 FROM pg_class WHERE relname='tou_rates'" \
        2>/dev/null | grep -qx 1 || return 1
    return 0
}

write_sql_compat_revision() {
    if ! sql_trio_objects_present; then
        echo -e "${YELLOW}  ⚠ 三组兼容性 SQL 的对象没在库里查到，不记录 revision（跑 scripts/diagnose.sh 看缺哪一组）${NC}"
        return 2
    fi
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

# 装 SQL 之前先确认 TeslaMate 的迁移不在跑：文档里的标准升级姿势是
# `docker compose pull && docker compose up -d` 之后紧接着跑本脚本，新版本 TeslaMate
# 起来时可能正在跑新迁移，这时装我们的 SQL 会撞车（见 wait_teslamate_migrated 注释）。
# 已经跑了一阵的实例上这一步几秒就确认完。
echo -e "${BLUE}      等 TeslaMate 完成自身数据库迁移...${NC}"
TM_MIGRATED=1
if ! wait_teslamate_migrated "$DB_CONTAINER" teslamate teslamate; then
    TM_MIGRATED=0
    echo -e "${YELLOW}  ⚠ 没能确认 TeslaMate 迁移已完成。为避免和它的迁移撞车，这次跳过单位换算函数${NC}"
    echo -e "${YELLOW}    （撞车会让 TeslaMate 自己起不来，且重跑本脚本也修不好）。等它正常启动后重跑即可补上。${NC}"
fi

# ============================================================
# 3. 安装坐标转换函数（地图源切换 + GCJ-02 转换）
# ============================================================
echo -e "${BLUE}[3/8] 安装坐标转换函数（地图）...${NC}"
if ! docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 \
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
# TM_MIGRATED=0 时必须真的跳过（不是只打印一句）：这组函数与上游 TeslaMate 迁移建的是
# 同名函数，抢先建会让上游那条不带 OR REPLACE 的迁移撞 duplicate_function，TeslaMate 从此
# 反复重启、重跑本脚本也修不好。少装这组只影响单位显示，轻得多。
if [ "${TM_MIGRATED:-1}" -eq 0 ]; then
    echo -e "${YELLOW}  ⏭ 跳过单位换算函数（上面没能确认 TeslaMate 迁移已完成）${NC}"
    FAILED_STEPS+=("单位换算函数")
elif ! docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 \
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
    if docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 \
            < sql/install-tou.sql > /dev/null 2> /tmp/tou-install.log; then
        echo -e "${GREEN}  ✓ 分时电价表/函数/触发器/视图已就绪${NC}"
        echo "    用 'bash scripts/tou-wizard.sh' 配置峰谷电价（可选，没装也不影响主仪表盘）"
        # v1.7.5: compute_tou_cost 公式从 charge_energy_added 改为
        # GREATEST(added, used)。旁路表已有 cost_tou 是旧公式算的，重跑回算修正。
        # 单笔几毫秒，对个人用户（百~千笔）秒级完成，无副作用（旁路表仅函数写入）。
        #
        # 回算的四个计数里，gapped / cleared / failed 必须报出来，不能只打 processed/updated/skipped：
        #   cleared 意味着「你库里存着一批按旧算法算出的费用，刚被清掉了」——升级后那些充电
        #           的金额会跟升级前不一样，用户不该在毫无提示的情况下发现数字变了；
        #   gapped  意味着「这些充电的时段你没配全」，是需要用户回去补配置的信号；
        #   failed  正常恒为 0，非 0 说明有笔充电算崩了，沉默等于把问题埋掉。
        # 只在非 0 时才多打那几行，正常路径保持安静。
        echo "    回算历史分时电价费用（充电记录多的话要几十秒，请稍候）..."
        if docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate \
                -At -c "SELECT format('  ✓ 已扫描 %s 笔充电，按分时电价算出 %s 笔，跳过 %s 笔（没有适用的分时电价规则）', processed, updated, skipped)
                        || CASE WHEN cleared > 0 THEN format(E'\n      · 其中 %s 笔原先存着按旧算法算出的费用，已清除；这些充电现在按 TeslaMate 记录的金额或默认电价显示，跟升级前会不一样', cleared) ELSE '' END
                        || CASE WHEN gapped  > 0 THEN format(E'\n      · %s 笔充电有时段没被你配的分时电价规则覆盖，算不出可信金额；想让它们按分时电价计费，去「⚡ 分时电价配置」仪表盘的「配置审计」看缺哪几个小时', gapped) ELSE '' END
                        || CASE WHEN failed  > 0 THEN format(E'\n      ⚠ %s 笔充电回算时出错，已跳过；这些充电的费用维持原样，可稍后手动跑 SELECT * FROM backfill_all_tou(); 重试', failed) ELSE '' END
                        FROM backfill_all_tou();" \
                2> /tmp/tou-backfill.log; then
            :
        else
            echo -e "${YELLOW}    ⚠ 回算失败（不影响升级，可稍后手动跑 SELECT backfill_all_tou();）${NC}"
            sed 's/^/      /' /tmp/tou-backfill.log | head -10
            WARN_STEPS+=("TOU 历史费用回算")
        fi
        # 升级时如果判断不出你原来设的默认电价是多少，安装 SQL 会把要跟你说的话留在库里。
        # psql 的 NOTICE 走 stderr、上面已经丢进 /tmp/tou-install.log 了，用户看不见，
        # 所以这里主动查出来讲一遍。
        TOU_DEFAULT_NOTE=$(docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -At \
            -c "SELECT legacy_default_note FROM tou_settings WHERE legacy_default_note IS NOT NULL" \
            2>/dev/null) || TOU_DEFAULT_NOTE=""
        if [ -n "$TOU_DEFAULT_NOTE" ]; then
            echo -e "${YELLOW}    ${TOU_DEFAULT_NOTE}${NC}"
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
    _rev_rc=0
    write_sql_compat_revision || _rev_rc=$?
    [ "$_rev_rc" -eq 2 ] && FAILED_STEPS+=("SQL 对象校验")
fi

# ============================================================
# 6. 安装性能优化索引（v1.6.1+）
# ============================================================
echo -e "${BLUE}[6/8] 安装性能优化索引...${NC}"
if [ ! -f "sql/install-indexes.sql" ]; then
    echo -e "${YELLOW}  ⚠ 找不到 sql/install-indexes.sql，跳过（不影响功能，仅性能略差）${NC}"
    WARN_STEPS+=("性能索引")
else
    if docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 \
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
