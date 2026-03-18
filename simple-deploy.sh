#!/bin/bash
# TeslaMate 中文 Dashboard 一键安装脚本
# 5分钟完成 TeslaMate + 中文 Grafana Dashboard 部署

set -e

echo "=============================================="
echo "  TeslaMate 中文 Dashboard 一键安装脚本"
echo "=============================================="
echo ""
echo "📦 安装内容："
echo "  - TeslaMate 后端"
echo "  - PostgreSQL 数据库"
echo "  - Grafana + 中文 Dashboard（37个）"
echo "  - MQTT 消息服务"
echo ""
echo "⏱️  预计耗时：5-10 分钟"
echo ""
echo "📌 说明：TeslaMate 使用 Tesla Fleet API（OAuth）授权，"
echo "         安装完成后在 TeslaMate 界面中完成车辆绑定。"
echo ""

# 检查 Docker 和 Docker Compose
if ! command -v docker &> /dev/null; then
    echo "❌ Docker 未安装"
    echo ""
    echo "请先安装 Docker："
    echo "  Ubuntu: curl -fsSL https://get.docker.com | bash"
    echo "  CentOS: sudo yum install docker"
    echo ""
    exit 1
fi

if ! command -v docker compose &> /dev/null && ! command -v docker-compose &> /dev/null; then
    echo "❌ Docker Compose 未安装"
    echo ""
    echo "请先安装 Docker Compose"
    exit 1
fi

# 创建工作目录
INSTALL_DIR="${HOME}/teslamate-chinese"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "📁 工作目录: $INSTALL_DIR"
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
      # 中国大陆用户：请取消下方两行注释
      # - TESLA_API_HOST=https://owner-api.vn.cloud.tesla.cn
      # - TESLA_WSS_HOST=wss://streaming.vn.cloud.tesla.cn
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
    image: ghcr.io/wjsall/teslamate-chinese-dashboards:latest
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
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_DEFAULT_LANGUAGE=zh-Hans

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

# 生成随机加密密钥（兼容 Linux 和 macOS）
ENCRYPTION_KEY=$(openssl rand -hex 32)
if sed --version 2>/dev/null | grep -q GNU; then
  sed -i "s/INSERT_RANDOM_KEY_HERE/$ENCRYPTION_KEY/" docker-compose.yml
else
  sed -i "" "s/INSERT_RANDOM_KEY_HERE/$ENCRYPTION_KEY/" docker-compose.yml
fi

echo ""
echo "✅ 配置文件已生成"
echo ""

# 启动服务
echo "🚀 启动服务（首次启动需要下载镜像，请耐心等待）..."
docker compose up -d

echo ""
echo "⏳ 等待服务启动..."
sleep 30

# 检查服务状态
echo ""
echo "📊 服务状态:"
docker compose ps

echo ""
echo "=============================================="
echo "✅ 安装完成！"
echo "=============================================="
echo ""
echo "📱 访问地址："
echo "  - TeslaMate:  http://localhost:4000"
echo "  - Grafana:     http://localhost:3000"
echo ""
echo "🔐 Grafana 登录信息："
echo "  - 用户名: admin"
echo "  - 密码: admin（建议登录后修改）"
echo ""
echo "📝 下一步："
echo "  1. 访问 TeslaMate: http://localhost:4000"
echo "  2. 按照页面引导完成 Tesla 账号授权（OAuth）"
echo "  3. 车辆会自动开始同步数据"
echo "  4. 几分钟后访问 Grafana 查看中文 Dashboard"
echo ""
echo "📚 相关文档："
echo "  - 新手向导:     QUICKSTART.md"
echo "  - 场景速查手册: SCENE_GUIDE.md"
echo "  - 数据指标手册: METRICS_GUIDE.md"
echo "  - 功能地图:     DASHBOARD_MAP.md"
echo "  - 故障排查:     TROUBLESHOOTING.md"
echo ""
echo "🆘 遇到问题？"
echo "  查看日志: docker compose logs -f"
echo "  重启服务: docker compose restart"
echo "  故障排查: cat TROUBLESHOOTING.md"
echo ""
