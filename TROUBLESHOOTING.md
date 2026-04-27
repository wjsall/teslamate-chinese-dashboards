# 故障排查手册

> 遇到问题不要慌，按症状找原因，一步一步来。

---

## 🔍 诊断三板斧

遇到任何问题，先执行这三个命令：

```bash
# 1. 查看所有容器状态
docker compose ps

# 2. 查看所有服务日志（最近50行）
docker compose logs --tail=50

# 3. 查看特定服务日志（实时）
docker compose logs -f teslamate   # TeslaMate 日志
docker compose logs -f grafana     # Grafana 日志
docker compose logs -f database    # 数据库日志
docker compose logs -f mosquitto   # MQTT 日志
```

**健康状态应该是这样的：**
```
NAME         STATUS          PORTS
teslamate    Up 2 hours      0.0.0.0:4000->4000/tcp
database     Up 2 hours
grafana      Up 2 hours      0.0.0.0:3000->3000/tcp
mosquitto    Up 2 hours
```

如果某个服务显示 `Restarting` 或 `Exited`，说明有问题。

---

## 📦 安装问题

### ❌ Docker 安装失败

**症状**：`bash simple-deploy.sh` 报错说 Docker 未找到

**解决：**
```bash
# Ubuntu / Debian
curl -fsSL https://get.docker.com | bash
sudo usermod -aG docker $USER
newgrp docker   # 立即生效（或重新登录）

# 验证
docker run hello-world
```

---

### ❌ 端口被占用

**症状**：
```
Error starting: Bind for 0.0.0.0:4000 failed: port is already allocated
Error starting: Bind for 0.0.0.0:3000 failed: port is already allocated
```

**查找占用进程：**
```bash
# 查看谁在用 4000 端口
sudo lsof -i :4000
sudo lsof -i :3000
```

**解决方案 A：停止占用端口的程序**
```bash
sudo kill -9 <PID>
```

**解决方案 B：修改 TeslaMate/Grafana 端口**
编辑 `docker-compose.yml`，把端口改掉，例如改成 `4001:4000`：
```yaml
ports:
  - 4001:4000   # 左边是宿主机端口，右边是容器端口
```
然后访问 `http://localhost:4001`

---

### ❌ 镜像拉取失败（国内网络）

**症状**：
```
Error response from daemon: Get "https://ghcr.io/...": dial tcp: i/o timeout
```

**解决方案 A：切换到 Docker Hub 镜像（最简单，推荐）**

将 `docker-compose.yml` 中 grafana 的 `image` 替换为 Docker Hub 地址：
```yaml
image: bswlhbhmt816/teslamate-chinese-dashboards:latest
```
Docker Hub 在中国大陆访问比 ghcr.io 稳定得多，无需额外配置。

**解决方案 B：配置 Docker 镜像加速**
```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": [
    "https://dockerproxy.cn",
    "https://docker.1ms.run",
    "https://hub-mirror.c.163.com"
  ]
}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

**解决方案 C：使用代理**
```bash
# 临时设置代理
export HTTP_PROXY=http://你的代理IP:端口
export HTTPS_PROXY=http://你的代理IP:端口
docker compose pull
```

**解决方案 D：在能访问的机器上拉取并导出**
```bash
# 有网络的机器上
docker pull ghcr.io/wjsall/teslamate-chinese-dashboards:latest
docker save ghcr.io/wjsall/teslamate-chinese-dashboards:latest | gzip > grafana-chinese.tar.gz
# 传到目标机器
scp grafana-chinese.tar.gz user@server:~/
# 目标机器上加载
docker load < grafana-chinese.tar.gz
```

---

### ❌ 权限不足

**症状**：
```
Permission denied while trying to connect to the Docker daemon socket
```

**解决：**
```bash
sudo usermod -aG docker $USER
newgrp docker
# 或者重新登录
```

---

## 📊 Dashboard 问题

### ❌ Dashboard 显示空白 / 无数据

**Step 1：确认 TeslaMate 有数据**
```bash
docker compose exec database psql -U teslamate -c "SELECT COUNT(*) FROM drives;"
docker compose exec database psql -U teslamate -c "SELECT COUNT(*) FROM charges;"
```
如果返回 `0`，说明还没有数据（车辆刚授权，等待同步）。

**Step 2：检查数据源连接**
- 打开 Grafana → 左侧菜单 → Connections → Data Sources
- 点击 `TeslaMate` 数据源
- 点击 `Save & Test`
- 应显示绿色 `Database Connection OK`

**Step 3：检查时间范围**
Grafana 右上角的时间范围选择，默认是 `Last 6 hours`。如果车辆数据是昨天的，需要调宽时间范围。

**Step 4：重启 Grafana**
```bash
docker compose restart grafana
```

---

### ❌ Dashboard 显示英文而非中文

**症状**：打开 Grafana 界面全是英文，或者 Dashboard 面板标题是英文

**解决 1：确认语言环境变量**
查看 `docker-compose.yml` 中 grafana 服务是否有：
```yaml
environment:
  - GF_USERS_DEFAULT_LANGUAGE=zh-Hans
```

**解决 2：确认使用的是中文镜像**
```bash
docker compose ps grafana
# 应该显示 ghcr.io/wjsall/teslamate-chinese-dashboards:latest
```

**解决 3：清除浏览器缓存**
```
Ctrl+Shift+R（Windows/Linux）
Cmd+Shift+R（macOS）
```

**解决 4：重启 Grafana**
```bash
docker compose restart grafana
```

---

### ❌ 某些面板显示 "No data"

**常见原因 1：数据库里确实没有这段时间的数据**
- 调整时间范围（右上角时钟图标）

**常见原因 2：数据源 UID 不匹配**
```bash
# 检查数据源 UID
docker compose exec grafana grafana-cli admin data-migration
```

**常见原因 3：数据库连接超时**
```bash
docker compose logs grafana | grep -i "error\|failed"
```

---

### ❌ 容器启动后无限重启

**症状**：`docker compose ps` 显示 `Restarting`

**排查步骤：**
```bash
# 查看最近的错误日志
docker compose logs --tail=20 grafana
docker compose logs --tail=20 teslamate
```

**常见原因：数据库未就绪**
等待约 30 秒后重试：
```bash
docker compose restart teslamate grafana
```

**常见原因：ENCRYPTION_KEY 变更**
如果修改过 `ENCRYPTION_KEY`，Token 无法解密，TeslaMate 会崩溃。**ENCRYPTION_KEY 一旦设置不能更改**（除非重新授权 Tesla 账号）。

**常见原因：端口冲突**
见上方「端口被占用」章节。

---

### ❌ 「自定义新车电池容量」「自定义新车最大续航里程」每次刷新重置为 0

**症状**：在「电池健康」仪表盘里输入了自定义值，关闭浏览器或刷新后又变回 `0`。

**原因**：这是 Grafana **textbox 类型变量**的设计行为，输入值只保存在当前 URL 中，不会持久化到数据库或本地存储。

**解决方法 1（推荐）：URL 书签**

1. 在仪表盘里输入你的实际值（例如 `82` 度、`600` km）
2. 等 1-2 秒，浏览器地址栏 URL 末尾会出现：
   ```
   ?var-custom_kwh_new=82&var-custom_max_range=600
   ```
3. 把这个完整 URL 加到浏览器书签
4. 以后从书签打开，数值自动预填

**解决方法 2：修改 JSON 默认值（仅自用场景）**

编辑 `grafana/dashboards/zh-cn/battery-health.json`，找到 `custom_kwh_new` 和 `custom_max_range` 两个变量，把以下三处 `"0"` 改成你的值：

```json
{
  "name": "custom_kwh_new",
  "current": {"text": "82", "value": "82"},
  "query": "82",
  "options": [{"selected": true, "text": "82", "value": "82"}]
}
```

保存后重启 Grafana 容器或等 10 秒自动 reload。

**为什么不做成默认就保存？** 不同车型/电池容量/购车里程都不同，没有对所有用户都正确的默认值，所以保留可调输入框。

---

## 🚗 数据问题

### ❌ 车辆数据不更新

**Step 1：检查 TeslaMate 日志**
```bash
docker compose logs -f teslamate
```
正常日志应包含类似 `Fetching vehicle data` 的内容。

**Step 2：确认 Tesla API 授权有效**
访问 `http://localhost:4000`，看是否显示正确的车辆信息。如果显示未登录，重新授权。

**Step 3：检查网络连通性**
```bash
# 测试能否访问 Tesla 服务器
docker compose exec teslamate curl -s https://fleet-api.prd.na.vn.cloud.tesla.com
```

**Step 4：检查 MQTT 连接**
```bash
docker compose logs mosquitto
# 应该看到 TeslaMate 的连接记录
```

---

### ❌ 行程数据缺失

**可能原因：**
- 行程中 GPS 信号丢失
- 车辆在行程中进入休眠（短途多次停车）
- TeslaMate 服务在行程中重启

**查看不完整数据：**
打开 Grafana → **「不完整的数据」** Dashboard，可以看到哪些行程/充电缺少了数据。

**手动导入历史数据（如有 TeslaFi / Tesla API 备份）：**
将数据放入 `./import/` 目录，TeslaMate 会自动处理。

---

### ❌ 地图不显示

**症状**：行程追踪页面地图空白

**常见原因 1：网络无法访问 OpenStreetMap**
OpenStreetMap 地图服务在国内可能受限，需要代理。

**常见原因 2：浏览器控制台有 CORS 错误**
```
按 F12 → Console 标签 → 查看是否有地图相关错误
```

**解决：需要自建可访问的 OSM 瓦片代理**
由于国内无法直连 `tile.openstreetmap.org`，通常有两种办法：
1. 在可访问海外的服务器上架设 OSM 瓦片代理，然后在每个含地图的面板里把瓦片 URL 改为你的代理地址（Panel → Edit → Map layers → Base layer → URL template）
2. 使用国内可直连的瓦片源替换底图（Grafana Geomap 仅支持 XYZ 瓦片协议，自行评估许可与合规）

> 说明：Grafana 本身不提供地图瓦片代理 env var，需要在面板配置里改 URL template，或通过 provisioning 定制默认底图。

---

### ❌ 行程地址不显示（显示为空或仅有坐标）

**症状**：行程列表中出发地、目的地显示为空，或仪表盘中地点名称无法正确显示

**原因：Nominatim 地址解析服务在国内无法访问**

TeslaMate 使用 [Nominatim](https://nominatim.openstreetmap.org)（OpenStreetMap 地理编码服务）将 GPS 坐标转换为可读地址。该服务在中国大陆网络环境下通常无法直连，导致地址字段始终为空。

> 注意：这与「地图不显示」是两个独立问题。地图显示的是瓦片图层，地址显示依赖 Nominatim API 查询，二者需要分别解决。

**解决：配置 Nominatim 代理**

TeslaMate 现已原生支持通过 `NOMINATIM_PROXY` 环境变量为地址解析配置代理，编辑 `docker-compose.yml`，在 `teslamate` 服务的 environment 中添加：

```yaml
services:
  teslamate:
    environment:
      # ... 其他配置 ...
      - NOMINATIM_PROXY=http://代理IP:端口
```

配置后重启 TeslaMate：
```bash
docker compose restart teslamate
```

> **注意：仅支持 HTTP 代理**，不支持 HTTPS 代理。填写格式为 `http://代理IP:端口`（即使你的代理支持 HTTPS，此处也必须写 `http://`）。填写能访问公网的代理地址（如本地 Clash/V2Ray 的局域网监听地址）。配置后历史行程的地址也会在下次处理时自动补全。

---

## 🌐 网络问题

### ❌ 国内无法访问 ghcr.io 镜像

见上方「镜像拉取失败（国内网络）」章节。

---

### ❌ 防火墙阻止访问

如果你的服务器有防火墙（如阿里云/腾讯云安全组），需要开放端口：

```bash
# Ubuntu UFW
sudo ufw allow 4000/tcp   # TeslaMate
sudo ufw allow 3000/tcp   # Grafana

# CentOS firewalld
sudo firewall-cmd --permanent --add-port=4000/tcp
sudo firewall-cmd --permanent --add-port=3000/tcp
sudo firewall-cmd --reload
```

云服务器还需要在控制台的「安全组/防火墙」页面添加入站规则。

---

### ❌ 从外网访问（公网 IP）

直接暴露 TeslaMate 到公网有安全风险，**推荐方案**：

1. **Tailscale / ZeroTier**（最简单）：组建虚拟局域网，像访问本地一样访问
2. **Cloudflare Tunnel**：免费，无需公网 IP，有 HTTPS
3. **反向代理**（Nginx/Caddy）：配置 HTTPS + 基础认证

不推荐直接将 TeslaMate 端口暴露到公网。

---

### ❌ 反向代理后访问路径报错（子路径部署）

**症状**：通过反向代理将 TeslaMate 部署在子路径下（如 `/teslamate/`），访问时出现资源加载失败或页面空白。

**解决：配置 URL_PATH 环境变量**

在 `docker-compose.yml` 的 `teslamate` 服务中添加：

```yaml
services:
  teslamate:
    environment:
      # ... 其他配置 ...
      - URL_PATH=/teslamate
```

同时需要在反向代理（Nginx/Caddy）中正确配置路径转发，例如 Nginx：

```nginx
location /teslamate/ {
    proxy_pass http://localhost:4000/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

> **注意**：`URL_PATH` 值不要加末尾斜杠（写 `/teslamate` 而非 `/teslamate/`）。

---

## 🔄 升级问题

### 如何升级到新版本

```bash
cd ~/teslamate-chinese  # 进入安装目录
docker compose pull     # 拉取最新镜像
docker compose up -d    # 重启使用新镜像
```

单独升级 Grafana（中文 Dashboard 更新）：
```bash
docker compose pull grafana
docker compose up -d grafana
```

---

### ❌ 升级后数据丢失 / Dashboard 错乱

**不要慌，数据通常在数据库里没问题。**

```bash
# 确认数据库数据完整
docker compose exec database psql -U teslamate -c "SELECT COUNT(*) FROM drives;"
```

Dashboard 错乱通常是 Grafana 缓存问题：
```bash
docker compose restart grafana
# 然后清除浏览器缓存：Ctrl+Shift+R
```

---

### 数据库备份与恢复

**备份：**
```bash
cd ~/teslamate-chinese
docker compose exec database pg_dump -U teslamate teslamate > backup_$(date +%Y%m%d_%H%M).sql
```

**恢复：**
```bash
# 停止 TeslaMate（避免写入冲突）
docker compose stop teslamate

# 恢复数据
docker compose exec -T database psql -U teslamate teslamate < backup_20260315_1200.sql

# 重启
docker compose start teslamate
```

---

## 🔧 完整重置

### 重置（保留数据）

```bash
cd ~/teslamate-chinese
docker compose down          # 停止并删除容器
docker compose up -d         # 重新创建并启动
```

数据保存在 Docker 命名卷中，`down` 命令不会删除数据。

### 完全重置（清除所有数据）

> ⚠️ **不可恢复！** 执行前请先备份数据库！

```bash
cd ~/teslamate-chinese
docker compose down -v       # 停止并删除容器和卷（数据会丢失！）
docker compose up -d         # 重新开始
```

---

## 📋 常见错误日志对照

| 错误信息 | 含义 | 解决方法 |
|----------|------|----------|
| `could not connect to server: Connection refused` | 数据库未就绪 | 等待 30 秒，重启 TeslaMate |
| `FATAL: password authentication failed` | 数据库密码错误 | 检查 DATABASE_PASS 和 POSTGRES_PASSWORD 是否一致 |
| `crypto: AES.decrypt: Data is not valid` | 加密密钥不匹配 | 不能更改 ENCRYPTION_KEY，需重新授权 |
| `connection refused (os error 111)` | MQTT 连接失败 | 检查 mosquitto 容器状态 |
| `invalid character '<' looking for beginning of value` | API 返回 HTML 错误页 | Tesla API 暂时不可用，等待重试 |
| `Exit 1` / `Exit 137` | 内存不足 | 增加服务器内存或关闭其他程序 |
| `no space left on device` | 磁盘满了 | 清理磁盘空间 |

---

## 💬 还是解决不了？

1. **查看完整日志**：`docker compose logs > debug.log` 然后贴到 Issue 中
2. **提交 Issue**：https://github.com/wjsall/teslamate-chinese-dashboards/issues
3. **提供信息**：
   - 操作系统版本
   - Docker 版本（`docker --version`）
   - 错误日志截图或文字
   - 你做了什么操作之后出现的问题
