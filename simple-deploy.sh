#!/bin/bash
# TeslaMate 中文 Dashboard 一键安装脚本
# 5分钟完成 TeslaMate + 中文 Grafana Dashboard 部署

set -e
set -o pipefail

# 强制 docker compose project name = teslamate，
# 让容器名稳定为 teslamate-database-1 / teslamate-grafana-1 等，
# 与 README/QUICKSTART/TROUBLESHOOTING 文档里所有 docker exec 命令一致
export COMPOSE_PROJECT_NAME=teslamate

# SQL 文件拉取的 git ref（默认 main，跟着 :latest 镜像滚动 + 拿 bug 修复最快）。
# 安全敏感用户想锁固定版本：SQL_REF=v1.6.4 bash simple-deploy.sh
# 详见 README「SQL 远程拉取的信任模型」
SQL_REF="${SQL_REF:-main}"
SQL_BASE="https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${SQL_REF}/sql"
# 仓库根 raw 基址（拉 scripts/backup.sh 等非 SQL 文件用）
REPO_BASE="https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${SQL_REF}"

# 端口配置（支持环境变量覆盖，端口冲突时用：TM_PORT=14000 GF_PORT=13000 bash simple-deploy.sh）
TM_PORT="${TM_PORT:-4000}"
GF_PORT="${GF_PORT:-3000}"

echo "=============================================="
echo "  TeslaMate 中文版 — Tesla 车主数据看板"
echo "=============================================="
echo ""
echo "📊 装完你能看到："
echo "  - 每次行程地图回放（高德/谷歌切换，国内不偏移）"
echo "  - 充电记录 + 分时电价省钱分析"
echo "  - 电池健康 / 续航衰减 / 回本分析"
echo "  - 46 个中文仪表盘（年度报告、多车对比、驾驶评分等）"
echo ""
echo "⏱️  耗时 5-10 分钟  💾 数据全在你机器上，不上传第三方"
echo ""
echo "📌 装完用 Auth for Tesla App 拿 access_token + refresh_token，"
echo "   到 TeslaMate 主页粘贴绑车（详见 QUICKSTART.md 第四步）。"
echo ""

# 检测平台用于 Docker 缺失时的 OS 适配安装方式
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos"; return ;;
        Linux) ;;
        *) echo "other"; return ;;
    esac
    if [ -f /etc/synoinfo.conf ]; then echo "synology"; return; fi
    if [ -f /etc/os-release ]; then
        local id
        id=$(. /etc/os-release; echo "$ID")
        case "$id" in
            ubuntu|debian|raspbian|centos|rhel|fedora|rocky|almalinux|linuxmint|pop)
                echo "linux-supported"; return ;;
        esac
    fi
    echo "linux-unknown"
}

PLATFORM=$(detect_platform)

# 检测是否在云主机上（AWS/GCP/Azure/阿里云/腾讯云/华为云等）
# 用于发版后提醒用户加固，不改默认行为
detect_cloud() {
    local vendor="" product=""
    [ -r /sys/class/dmi/id/sys_vendor ] && vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
    [ -r /sys/class/dmi/id/product_name ] && product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    case "${vendor}${product}" in
        *Google*|*Amazon*|*EC2*|*Microsoft*|*Alibaba*|*Tencent*|*HUAWEI*|*Huawei*|*Oracle*|*Vultr*|*DigitalOcean*|*Linode*|*Hetzner*)
            echo "cloud"; return ;;
    esac
    # metadata 端点（link-local，云厂商通用）— 1 秒内连得通基本是云
    # 不用 -f：AWS IMDSv2 默认对裸 GET 返 401，但 401 也证明端点存在；--noproxy 防止 SSRF 路径被 $http_proxy 接管
    if curl -sS --max-time 1 --noproxy '*' -o /dev/null http://169.254.169.254 2>/dev/null; then
        echo "cloud"; return
    fi
    echo "physical"
}

IS_CLOUD=$(detect_cloud)

# Linux 上一键装 Docker（用 docker.com 官方脚本，覆盖主流发行版）
install_docker_linux() {
    echo "🚀 正在安装 Docker（用 docker.com 官方一键脚本，1-2 分钟）..."
    local sudo_cmd=""
    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "❌ 当前不是 root 也没 sudo，请用 root 重跑此脚本"
            return 1
        fi
        sudo_cmd="sudo "
    fi
    if ! curl -fsSL https://get.docker.com | ${sudo_cmd}sh; then
        echo "❌ Docker 安装失败"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        ${sudo_cmd}systemctl enable --now docker >/dev/null 2>&1 || true
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "⚠️ Docker 已装但 daemon 没起（可能需要重启系统后再跑此脚本）"
        return 1
    fi
    echo "✅ Docker 已就绪"
    echo ""
}

# ============================================================
# 备份：把 backup.sh 拉到 $INSTALL_DIR，并（可选）设置每日定时备份。
# fresh-install 和 upgrade 两条路径都会调用。
# 设计约束：一键用户不 clone 仓库 → 本地没有 scripts/backup.sh，必须 curl 下来；
#          群晖 DSM 不认普通 crontab（程序化设置不持久）→ 改打印 DSM 任务计划步骤。
# ============================================================
setup_backup() {
    echo ""
    echo "💾 定期备份数据库（行车历史丢了不可逆，强烈建议）"

    # 1. 必修：拉/刷新备份脚本到本地（单文件即可跑，内置容器探测兜底）
    if ! curl -fsSL "$REPO_BASE/scripts/backup.sh" -o "$INSTALL_DIR/backup.sh" 2>/dev/null; then
        echo "  ⚠ 备份脚本下载失败。手动拉：curl -fsSL $REPO_BASE/scripts/backup.sh -o $INSTALL_DIR/backup.sh"
        return 0
    fi
    chmod +x "$INSTALL_DIR/backup.sh"
    echo "  ✓ 备份脚本已就位：$INSTALL_DIR/backup.sh"

    local BK_DIR CRON_LINE want
    BK_DIR="$INSTALL_DIR/backups"
    CRON_LINE="0 3 * * * BACKUP_DIR=$BK_DIR KEEP=7 bash $INSTALL_DIR/backup.sh >> $BK_DIR/cron.log 2>&1"

    # 已设过定时（通用 Linux）→ 不再追问，避免每次升级都问
    if [ "$PLATFORM" != "synology" ] && command -v crontab >/dev/null 2>&1 \
        && crontab -l 2>/dev/null | grep -Fq "$INSTALL_DIR/backup.sh"; then
        echo "  ✓ 已有每日定时备份任务（crontab -l 可查），脚本已更新到最新"
        return 0
    fi

    # 2. 交互：是否设置每日自动备份
    if [ "${AUTO_BACKUP:-}" = "1" ]; then
        want=Y
    elif [ -t 0 ]; then
        read -r -p "  设置每日 03:00 自动备份？[Y/n] " want || want=""
        want=${want:-Y}
    else
        # 非交互（curl|bash）：不擅自设定时，给指引
        echo "  ℹ 非交互模式跳过定时设置。启用：AUTO_BACKUP=1 重跑本脚本，或见 TROUBLESHOOTING.md#db-backup"
        return 0
    fi

    if [[ ! "$want" =~ ^[Yy] ]]; then
        echo "  已跳过自动备份。以后想设见 TROUBLESHOOTING.md#db-backup"
        return 0
    fi

    mkdir -p "$BK_DIR"

    if [ "$PLATFORM" = "synology" ]; then
        # 群晖：程序化写 crontab 不持久，改打印 DSM 任务计划步骤
        echo "  📋 群晖请用 DSM 任务计划（DSM 不认普通 crontab）："
        echo "     控制面板 ▸ 任务计划 ▸ 新增 ▸ 计划的任务 ▸ 用户定义的脚本"
        echo "     用户 root，每天 03:00，运行命令（整行复制）："
        echo "       BACKUP_DIR=$BK_DIR KEEP=7 bash $INSTALL_DIR/backup.sh"
    elif ! command -v crontab >/dev/null 2>&1; then
        echo "  ⚠ 系统没有 crontab，无法自动设置。手动定时见 TROUBLESHOOTING.md#db-backup"
        echo "    备份命令：BACKUP_DIR=$BK_DIR KEEP=7 bash $INSTALL_DIR/backup.sh"
    else
        ( crontab -l 2>/dev/null; echo "$CRON_LINE" ) | crontab -
        echo "  ✓ 已设每日 03:00 自动备份 → $BK_DIR（保留 7 份）"
        echo "    查看：crontab -l    日志：$BK_DIR/cron.log"
    fi
    echo "  ℹ 备份会连 docker-compose.yml（含密钥）一起存 → 这份备份能独立恢复；"
    echo "    请保证备份目录私密、别公开分享（不想含密钥：备份命令加 INCLUDE_CONFIG=0）"
}

# 检查 Docker 和 Docker Compose
if ! command -v docker &> /dev/null; then
    echo "ℹ️ Docker 未安装"
    case "$PLATFORM" in
        linux-supported)
            if [ "${AUTO_INSTALL_DOCKER:-}" = "1" ]; then
                install_docker_linux || exit 1
            elif [ -t 0 ]; then
                echo ""
                read -r -p "是否自动安装 Docker？[Y/n] " ans
                ans=${ans:-Y}
                if [[ "$ans" =~ ^[Yy] ]]; then
                    install_docker_linux || exit 1
                else
                    echo "已取消。手动安装后重跑此脚本："
                    echo "  curl -fsSL https://get.docker.com | sh"
                    exit 1
                fi
            else
                echo ""
                echo "非交互模式无法弹确认提示。两选一："
                echo "  1) 重跑时加环境变量授权自动装：AUTO_INSTALL_DOCKER=1 bash simple-deploy.sh"
                echo "  2) 先手动装 Docker：curl -fsSL https://get.docker.com | sh"
                exit 1
            fi
            ;;
        synology)
            echo ""
            echo "❌ 群晖 DSM 必须从套件中心装："
            echo "   - DSM 7.2+：「Container Manager」"
            echo "   - DSM 7.0/7.1：「Docker」"
            echo "命令行装会破坏 DSM 系统稳定性，不要硬装"
            exit 1
            ;;
        macos)
            echo ""
            echo "❌ macOS 请安装 Docker Desktop："
            echo "   https://www.docker.com/products/docker-desktop/"
            exit 1
            ;;
        *)
            echo ""
            echo "❌ 未识别的平台（$(uname -s)），请手动安装 Docker 后重跑此脚本"
            echo "   常规 Linux：curl -fsSL https://get.docker.com | sh"
            exit 1
            ;;
    esac
fi

# 检查 docker daemon 实际可访问（不只是命令存在）—— 群晖 SSH 用户没 docker 组权限会卡这里
if ! docker info >/dev/null 2>&1; then
    echo "❌ docker 命令存在但跑不动（没有 daemon 访问权限）"
    echo ""
    echo "可能原因 + 修法："
    echo "  - 群晖 SSH 用户：先在 DSM 控制面板开启 root SSH，sudo -i 切 root 后重跑此脚本"
    echo "    或改用 Container Manager「项目」模式 GUI 部署（不用命令行）"
    echo "  - Linux 用户：sudo usermod -aG docker \$USER && newgrp docker"
    echo "  - 任何系统：用 sudo bash $(basename "$0")"
    echo ""
    exit 1
fi

# 检查 Docker Compose 是 v1 还是 v2，并把命令名存到 $DC（后续所有命令通过 $DC 调用）
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
    echo "⚠️ 检测到 docker-compose v1（已过时），建议升级到 v2（docker compose）"
    echo "   v2 安装：sudo apt install docker-compose-plugin（或参考 docker.com 官方文档）"
    echo "   本脚本仍兼容 v1，但部分命令可能稍慢"
    echo ""
else
    echo "❌ Docker Compose 未安装（v1 / v2 都没找到）"
    echo ""
    echo "请先安装 Docker Compose v2（推荐）："
    echo "  sudo apt install docker-compose-plugin"
    exit 1
fi

# 创建工作目录
INSTALL_DIR="${HOME}/teslamate-chinese"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "📁 工作目录: $INSTALL_DIR"
echo ""

# ============================================================
# 已存在检测：如果 docker-compose.yml 已经存在，转升级模式
# 避免覆盖用户的 ENCRYPTION_KEY、Tesla CN API 配置等
# ============================================================
if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    echo "🔄 检测到已有安装，进入升级模式（不会改你的配置）..."
    echo ""
    echo "  → 拉取最新镜像"
    $DC pull
    echo ""
    echo "  → 重启服务（应用新镜像）"
    $DC up -d
    echo ""
    echo "  → 等数据库就绪"
    DB_CONTAINER=$($DC ps -q database 2>/dev/null | head -1)
    [ -z "$DB_CONTAINER" ] && DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE 'teslamate.*database' | head -1)
    DB_READY=0
    for i in $(seq 1 30); do
        if docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -c "SELECT 1" >/dev/null 2>&1; then
            DB_READY=1
            break
        fi
        sleep 2
    done
    echo ""
    if [ "$DB_READY" -eq 1 ]; then
        echo "  → 安装/更新坐标转换函数"
        if curl -fsSL "$SQL_BASE/install-coord-functions.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate >/dev/null 2>&1; then
            echo "  ✓ 坐标函数已更新（地图源切换/纠偏）"
        else
            echo "  ⚠ 坐标函数更新失败"
        fi

        echo "  → 安装/更新分时电价表 + 函数（v1.5.0+）"
        if curl -fsSL "$SQL_BASE/install-tou.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate >/dev/null 2>&1; then
            echo "  ✓ 分时电价已就绪（首次装好后到「⚡ 分时电价配置」仪表盘填规则）"
        else
            echo "  ⚠ 分时电价更新失败，TOU 仪表盘可能不可用"
        fi

        echo "  → 安装/更新性能优化索引（v1.6.1+）"
        if curl -fsSL "$SQL_BASE/install-indexes.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate >/dev/null 2>&1; then
            echo "  ✓ 索引已就绪（电池健康/天气-能耗等查询提速）"
        else
            echo "  ⚠ 索引安装失败（不影响功能，仅性能略差）"
        fi
        echo ""
        echo "  → 重启 Grafana（让新仪表盘生效）"
        GRAFANA_CONTAINER=$($DC ps -q grafana 2>/dev/null | head -1)
        [ -z "$GRAFANA_CONTAINER" ] && GRAFANA_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE 'teslamate.*grafana' | head -1)
        [ -n "$GRAFANA_CONTAINER" ] && docker restart "$GRAFANA_CONTAINER" >/dev/null
    else
        echo ""
        echo "  ❌ 数据库 60 秒内未就绪，SQL 函数没装上"
        echo "     等服务起来后**重跑此脚本**（自动进入升级模式重试）："
        echo "     curl -fsSL https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/simple-deploy.sh | bash"
        exit 1
    fi
    echo ""
    echo "============================================="
    echo "✅ 升级完成"
    echo "============================================="
    echo ""
    echo "下一步: 浏览器 Ctrl+Shift+R 强刷，看「地图源」下拉框是否就绪"
    echo ""
    echo "📚 完整发版说明: https://github.com/wjsall/teslamate-chinese-dashboards/releases/latest"
    setup_backup
    exit 0
fi

# ============================================================
# 全新安装流程
# ============================================================

# 端口预检：4000 (TeslaMate) / 3000 (Grafana) 必须空闲，否则容器起来直接 conflict
# 群晖 DSM 高发：DSM 自带服务、其他 docker 容器（Portainer/Bitwarden）也可能占
# macOS 高发：3000 被 Vite/Next.js/Rails 默认占
# 检测优先 lsof（macOS / Linux 都准），其次 ss（Linux 现代发行版），最后 netstat（兼容老系统）
check_port_free() {
    local port=$1
    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$port" -sTCP:LISTEN -P -n >/dev/null 2>&1
    elif command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    elif command -v netstat >/dev/null 2>&1; then
        # GNU netstat -tln 才输出 LISTEN，BSD/macOS netstat 行为不同（已优先走 lsof 规避）
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    else
        return 2  # 无工具检测，跳过
    fi
}

PORT_CONFLICT=0
for port in "$TM_PORT" "$GF_PORT"; do
    # || rc=$? 让 check_port_free 的非零返回不触发 set -e（端口空闲返回 1 是正常情况）
    rc=0
    check_port_free "$port" || rc=$?
    case $rc in
        0)
            echo "❌ 端口 ${port} 已被占用（TeslaMate / Grafana 启动会失败）"
            PORT_CONFLICT=1
            if command -v lsof >/dev/null 2>&1; then
                echo "   占用进程：$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n 2>/dev/null | tail -1)"
            elif command -v ss >/dev/null 2>&1; then
                echo "   占用进程：$(ss -tlnp 2>/dev/null | grep -E ":${port}\b" | head -1)"
            fi
            ;;
        2)
            echo "⚠️ 系统没装 lsof/ss/netstat 任一工具，跳过端口 ${port} 预检"
            ;;
    esac
done

if [ "$PORT_CONFLICT" -eq 1 ]; then
    echo ""
    echo "⚠️  解决方案（推荐 A，B 进阶）："
    echo "   A. 关掉占用 ${TM_PORT}/${GF_PORT} 的服务后重跑此脚本（最简单）"
    echo "      - 群晖 DSM 用户：Portainer / Bitwarden 默认占 3000"
    echo "      - macOS：Vite / Next.js / Rails 默认 3000"
    echo "   B. 用环境变量改端口重跑：TM_PORT=14000 GF_PORT=13000 bash simple-deploy.sh"
    echo "      （脚本会自动把 docker-compose.yml 的端口映射改成你指定的值）"
    exit 1
fi
echo ""

# 生成 docker-compose.yml
echo "📝 生成配置文件..."

cat > docker-compose.yml << 'EOF'
services:
  teslamate:
    image: teslamate/teslamate:latest
    restart: always
    cap_drop:
      - all
    ports:
      - 4000:4000
    volumes:
      - ./import:/opt/app/import
    environment:
      - ENCRYPTION_KEY=INSERT_RANDOM_KEY_HERE
      - DATABASE_USER=teslamate
      - DATABASE_PASS=password
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - MQTT_HOST=mosquitto
      # 通常不需要手动设置：TeslaMate 3.0 会从 access_token 自动识别中国区 / 国际，
      # 国内 token 自动用 owner-api.vn.cloud.tesla.cn / streaming.vn.cloud.tesla.cn。
      # 仅在走自建 Fleet API 网关或代理时取消注释（参考 TROUBLESHOOTING.md「公网部署专项」）：
      # - TESLA_API_HOST=https://owner-api.vn.cloud.tesla.cn
      # - TESLA_WSS_HOST=wss://streaming.vn.cloud.tesla.cn
      # 国内用户强烈建议取消下一行注释 + 填代理地址：nominatim.openstreetmap.org 国内常超时
      # 会让行程列表起始/结束地址列大量为空。详见 TROUBLESHOOTING.md#nominatim-proxy
      # - NOMINATIM_PROXY=http://你的代理IP:7890
      - TZ=Asia/Shanghai

  database:
    image: postgres:18-trixie
    restart: always
    volumes:
      - teslamate-db:/var/lib/postgresql
    environment:
      - POSTGRES_USER=teslamate
      - POSTGRES_PASSWORD=password
      - POSTGRES_DB=teslamate

  grafana:
    image: bswlhbhmt816/teslamate-chinese-dashboards:latest
    restart: always
    ports:
      - 3000:3000
    volumes:
      - teslamate-grafana-data:/var/lib/grafana
    environment:
      - DATABASE_USER=teslamate
      - DATABASE_PASS=password
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - GF_SECURITY_ADMIN_PASSWORD=INSERT_GRAFANA_PASSWORD_HERE
      - GF_USERS_DEFAULT_LANGUAGE=zh-Hans

  mosquitto:
    image: eclipse-mosquitto:2
    restart: always
    command: mosquitto -c /mosquitto-no-auth.conf
    volumes:
      - mosquitto-conf:/mosquitto/config
      - mosquitto-data:/mosquitto/data

volumes:
  teslamate-db:
  teslamate-grafana-data:
  mosquitto-conf:
  mosquitto-data:
EOF

# 生成随机加密密钥 + 随机 DB 密码 + 随机 Grafana admin 密码（兼容 Linux 和 macOS）
ENCRYPTION_KEY=$(openssl rand -hex 32)
DB_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
GRAFANA_PASS=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-18)
# sed in-place 包装：GNU 用 `-i`，BSD/macOS 用 `-i ""`。
# 占位符列表只写一次，未来加新密码字段不会漏写一边（v1.6.9 第一版 BSD 分支漏 GRAFANA_PASS 教训）
if sed --version 2>/dev/null | grep -q GNU; then
  sed_inplace() { sed -i "$@"; }
else
  sed_inplace() { sed -i "" "$@"; }
fi

sed_inplace "s/INSERT_RANDOM_KEY_HERE/$ENCRYPTION_KEY/"        docker-compose.yml
sed_inplace "s/DATABASE_PASS=password/DATABASE_PASS=$DB_PASS/g" docker-compose.yml
sed_inplace "s/POSTGRES_PASSWORD=password/POSTGRES_PASSWORD=$DB_PASS/" docker-compose.yml
sed_inplace "s/INSERT_GRAFANA_PASSWORD_HERE/$GRAFANA_PASS/"    docker-compose.yml
# 端口映射（默认 4000/3000，TM_PORT/GF_PORT 环境变量可覆盖）
sed_inplace "s|- 4000:4000|- ${TM_PORT}:4000|" docker-compose.yml
sed_inplace "s|- 3000:3000|- ${GF_PORT}:3000|" docker-compose.yml

# 限制 docker-compose.yml 文件权限（含 ENCRYPTION_KEY + DB 密码 + 后续 Tesla token）
chmod 600 docker-compose.yml

echo ""
echo "✅ 配置文件已生成（含随机密钥 + 随机 DB 密码 + 文件权限 600）"
echo ""

# 启动服务
echo "🚀 启动服务（首次启动需要下载镜像，请耐心等待 2-5 分钟）..."
echo "   如果长时间卡在拉取镜像，请参考文末说明配置 Docker 镜像代理。"
$DC up -d

# 检查服务状态
echo ""
echo "📊 服务状态:"
$DC ps

# ============================================================
# 安装 SQL：坐标函数 + 分时电价表 + 性能索引
# ============================================================
echo ""
echo "📍 安装 SQL（坐标函数 / 分时电价 / 性能索引）..."

# 等数据库就绪（最多 60 秒）
DB_CONTAINER=$($DC ps -q database 2>/dev/null | head -1)
if [ -z "$DB_CONTAINER" ]; then
    DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE 'teslamate.*database' | head -1)
fi

DB_READY=0
for i in $(seq 1 30); do
    if docker exec "$DB_CONTAINER" psql -U teslamate -d teslamate -c "SELECT 1" >/dev/null 2>&1; then
        DB_READY=1
        break
    fi
    sleep 2
done

if [ "$DB_READY" -eq 1 ]; then
    SQL_OK=1

    if curl -fsSL "$SQL_BASE/install-coord-functions.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate >/dev/null 2>&1; then
        echo "  ✓ 坐标转换函数已装（地图源切换+GCJ-02 自动纠偏）"
    else
        echo "  ⚠ 坐标函数安装失败"
        SQL_OK=0
    fi

    if curl -fsSL "$SQL_BASE/install-tou.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate >/dev/null 2>&1; then
        echo "  ✓ 分时电价表+函数已装（v1.5.0+，首次装好后到「⚡ 分时电价配置」仪表盘填规则）"
    else
        echo "  ⚠ 分时电价安装失败，TOU 仪表盘可能不可用"
        SQL_OK=0
    fi

    if curl -fsSL "$SQL_BASE/install-indexes.sql" | docker exec -i "$DB_CONTAINER" psql -U teslamate -d teslamate >/dev/null 2>&1; then
        echo "  ✓ 性能索引已装（v1.6.1+，电池健康/天气-能耗等查询提速）"
    else
        echo "  ⚠ 索引安装失败（不影响功能，仅性能略差）"
        SQL_OK=0
    fi

    if [ "$SQL_OK" -eq 0 ]; then
        echo ""
        echo "    部分 SQL 安装失败，可手动重跑（按需选）："
        echo "    for f in install-coord-functions install-tou install-indexes; do"
        echo "      curl -fsSL $SQL_BASE/\$f.sql | docker exec -i $DB_CONTAINER psql -U teslamate -d teslamate"
        echo "    done"
    fi
else
    echo "  ⚠ 数据库 60 秒内未就绪，跳过 SQL 安装"
    echo "    服务起来后重跑此脚本（自动进入升级模式）即可装上 SQL"
fi

echo ""
echo "=============================================="
echo "✅ 安装完成！"
echo "=============================================="
echo ""

# 云主机检测：在凭据展示前先打安全警告（最容易被看见）
if [ "$IS_CLOUD" = "cloud" ]; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  检测到本机是云服务器（公网 IP 暴露）                  ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "   TeslaMate (4000) / Grafana (3000) 端口默认绑 0.0.0.0，"
    echo "   任何扫描你公网 IP 的人都能直接看到登录页。"
    echo ""
    echo "   立刻做的两件事："
    echo "   1) 云厂商安全组只放白名单 IP 访问 4000/3000，不要全公网开放"
    echo "   2) 加反向代理 + HTTPS（Caddy / Traefik）+ basic-auth，"
    echo "      参考 TROUBLESHOOTING.md「公网部署专项」章节"
    echo ""
fi

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  🚨🚨🚨 必须立刻抄录！下面凭据仅显示这一次！  🚨🚨🚨       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  ENCRYPTION_KEY = $ENCRYPTION_KEY"
echo "  DATABASE_PASS  = $DB_PASS"
echo "  GRAFANA_PASS   = $GRAFANA_PASS"
echo ""
echo "  📁 docker-compose.yml 备份位置：$INSTALL_DIR/docker-compose.yml"
echo "     （已设 mode 600，仅当前用户可读）"
echo "     ↑ 上面三项也都写在这个文件里，没抄到可随时从这里找回（只要这个目录还在）"
echo ""
echo "  ❌ ENCRYPTION_KEY 丢失 → 所有 Tesla Token 永远解密不出 → 必须重新授权"
echo "  ❌ DATABASE_PASS 丢失 → 数据库迁移/恢复全部失败"
echo "  ❌ GRAFANA_PASS 丢失 → Grafana 后台进不去，需 docker exec 重置"
echo ""
echo "  👉 立刻抄到密码管理器（1Password / Keychain / Bitwarden）"
echo ""
echo "════════════════════════════════════════════════════════════"
echo ""
echo "📱 访问地址："
echo "  - TeslaMate:  http://localhost:${TM_PORT}"
echo "  - Grafana:    http://localhost:${GF_PORT}"
echo ""
echo "🔐 Grafana 登录信息："
echo "  - 用户名: admin"
echo "  - 密码: $GRAFANA_PASS  （已自动生成强随机，不再是默认 admin）"
echo ""
echo "📝 下一步："
echo "  1. 拿 Token：推荐 https://github.com/adriankumpf/tesla_auth/releases （桌面版，TeslaMate 主作者维护）"
echo "     - macOS / Linux / Windows 都有原生二进制；下载后双击运行，登录 Tesla 账号即可看到 access_token + refresh_token"
echo "     - 国内 iOS 用户也可用「Auth for Tesla」App（需要美区/港区 Apple ID）"
echo "  2. 访问 TeslaMate http://localhost:${TM_PORT}，把两段 token 粘贴到登录页"
echo "  3. 车辆会自动开始同步数据"
echo "  4. 几分钟后访问 Grafana 查看中文 Dashboard"
echo "  5. 打开任一含地图仪表盘（足迹地图/驾驶记录追踪等），顶部「地图源」"
echo "     下拉框试试切换到「高德地图」/「谷歌卫星」"
echo ""
setup_backup
echo ""
echo "📚 相关文档（在线）："
echo "  https://github.com/wjsall/teslamate-chinese-dashboards"
echo ""
echo "🆘 遇到问题？"
echo "  查看日志: $DC logs -f"
echo "  重启服务: $DC restart"
echo ""
echo "🍓 树莓派用户提示："
echo "  必须使用 64 位系统（64-bit Raspberry Pi OS），32 位系统不支持。"
echo "  树莓派 4 / 5 均可正常运行，树莓派 3 建议升级到 64 位系统后使用。"
echo ""
echo "⚠️  中国大陆用户提示："
echo "  1. 如果镜像拉取失败，在 /etc/docker/daemon.json 中添加镜像代理："
echo "     { \"registry-mirrors\": [\"https://docker.1ms.run\", \"https://docker.m.daocloud.io\"] }"
echo "     然后执行: sudo systemctl daemon-reload && sudo systemctl restart docker"
echo "  2. TeslaMate 3.0 起仅支持「粘贴 Token」登录，先在手机装 Auth for Tesla App"
echo "     生成 token，再到 http://你的IP:4000 粘贴 Access Token / Refresh Token"
echo "     国内账号不需要改环境变量（TeslaMate 会从 token 自动识别）"
echo "  3. 行程列表地址列经常空 = nominatim.openstreetmap.org 国内访问超时。"
echo "     修法见 TROUBLESHOOTING.md#nominatim-proxy（加一行 NOMINATIM_PROXY env 即可）"
echo "  4. 配置文件路径: $INSTALL_DIR/docker-compose.yml"
echo ""
