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
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://docker.cnb.cool"
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

### ❌ 自定义 / 上传 Dashboard JSON 后 Grafana 看不到（群晖 NAS 用户高发）

**症状**：把改过的 dashboard JSON 通过 File Station / scp 推到 `/volume1/docker/teslamate/dashboards/zh-cn/`，重启 grafana 也不生效，仪表盘还是旧版。

**根因**：DSM File Station / scp 上传的文件 owner 是你本地用户（`wjsall:admin` 之类），但 Grafana 容器跑的是 uid `472`，**读不了你的文件**（DSM 隐藏 ACL 让 grafana 看上去 permission denied 但 provisioning 静默跳过）。

**修法**：上传后必须 chown 到容器 uid：

```bash
# zh-cn 仪表盘（挂到容器内 /dashboards/）
ssh wjsall@192.168.31.135 \
  "docker exec --user root teslamate-grafana-1 chown 472:472 /dashboards/<filename>.json"

# internal 仪表盘（挂到容器内 /dashboards_internal/）
ssh wjsall@192.168.31.135 \
  "docker exec --user root teslamate-grafana-1 chown 472:472 /dashboards_internal/<filename>.json"
```

> ⚠️ 容器内 `chown grafana:grafana` 报 `unknown user`，必须用 uid `472:472`（数字形式）。

**判断是否中招**：

```bash
docker logs teslamate-grafana-1 | grep -i "permission denied"
```

看到对应文件名就是这个坑。

**永久修法（一劳永逸）**：在 NAS 任务计划里建一个每分钟跑一次的脚本：

```bash
docker exec --user root teslamate-grafana-1 chown -R 472:472 /dashboards /dashboards_internal
```

这样以后任何 scp / File Station 上传都自动修。

---

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

打开 Grafana → 左侧 **Connections → Data sources** → 看名字是否为 `TeslaMate`（区分大小写）。如果不是，点开数据源把 `UID` 改成 `TeslaMate`，所有面板的 SQL 查询都用这个固定 UID 引用。

**常见原因 3：数据库连接超时**
```bash
docker compose logs grafana | grep -i "error\|failed"
```

---

### ❌ TeslaMate 登录失败（Token 粘贴提交后报错）

> ℹ️ **TeslaMate 3.0 已移除浏览器 OAuth 登录**——登录页只有 Access Token + Refresh Token 两个粘贴框，没有「Sign in with Tesla」大按钮。本节专门讲粘贴 token 后失败的排查。

**症状**：登录页粘贴 token 点提交后出现以下任一情况：
- 报 `Tokens are invalid`
- 报 `Your Tesla account is locked`
- 一直转圈无响应
- 提交后跳回登录页没有进展

**逐项排查：**

#### 1. Token 是否过期 / 复制完整？

`access_token` 通常 ≥ 2000 字符，`refresh_token` 约 100 字符。粘贴时容易因换行/空格导致截断：
- 重新打开 Auth for Tesla App，重新生成一对（点 App 内「重新登录」或「刷新」）
- 复制时**长按整段 → 全选 → 复制**，避免只复制可见部分
- 粘贴到 TeslaMate 后用浏览器开发者工具看输入框 value 长度，是否被空格污染

#### 2. 账号被锁

如果 App 里反复登录失败，特斯拉会锁账号几小时。看到 `Your Tesla account is locked due to too many failed sign in attempts`：
- **国内大陆账号**：去 [Tesla 中国官网](https://www.tesla.cn/teslaaccount/forgot-password) 重置密码（用 `tesla.com` 那边登不进去，国内账号在 tesla.cn 体系下）
- **国际账号**：去 [Tesla 官网](https://www.tesla.com/teslaaccount/forgot-password) 重置密码
- 等几小时后再用 tesla_auth / Auth for Tesla 重新生成 token

#### 3. 服务器到 Tesla 服务器网络不通

```bash
# 中国账号
curl -fsI https://auth.tesla.cn
curl -fsI https://owner-api.vn.cloud.tesla.cn

# 国际账号
curl -fsI https://auth.tesla.com
curl -fsI https://owner-api.teslamotors.com
```
任一报错（超时、连接拒绝、SSL 握手失败）→ 服务器网络不通 → 配代理或换可用网络。

#### 4. TeslaMate 容器看具体报错

```bash
docker compose logs --tail 100 teslamate | grep -iE "error|failed|tokens"
```
看到 `:token_refresh` → token 已被 Tesla 服务端废弃，Auth for Tesla App 重新生成
看到 SSL/TLS 错误 → 服务器系统时间偏差太多（`date` 看一下，必要时 `chronyd` / `systemctl restart systemd-timesyncd`）

#### 5. 用工具拿 token 的具体步骤

TeslaMate 3.0 没有别的登录方式，token 必须从外部工具来。**推荐 tesla_auth 桌面版**（TeslaMate 主作者维护、跨平台、不需要 Apple ID 切区）：

1. 下载：[github.com/adriankumpf/tesla_auth/releases](https://github.com/adriankumpf/tesla_auth/releases) 选对应平台二进制
2. 解压后双击运行 → 弹出窗口登录 Tesla 账号
3. 显示 `access_token` 和 `refresh_token` 两段字符串，复制下来
4. 回 TeslaMate 登录页（**直接显示两个输入框，不是折叠的**）粘贴两段 token，点 `Sign in`

**国内 iOS 用户备选：**
- App Store 搜「Auth for Tesla」**需要美区 / 港区 Apple ID**，国内大陆账号看不到这个 App
- 不想切区的，去家人/朋友的美区 iPhone 装一下，或者直接用 macOS / Windows 桌面版 tesla_auth

绑定后 TeslaMate 用 refresh_token 自动续期，长期不需要重新拿。

完整步骤 + 截图见 [QUICKSTART.md 第四步「授权 Tesla 账号」](QUICKSTART.md#step-4)。

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

**常见原因：mosquitto 拉不下来 → TeslaMate 卡 MQTT 连接（群晖 ARM 用户高发）**

群晖 ARM 系列（DS218j / DS118 等）拉 `eclipse-mosquitto:2` 经常超时失败，TeslaMate 启动后报 `MQTT connection refused` 反复重启。

**MQTT 是可选功能**（只用于 / 实时推送外部 home assistant 等场景），不用 MQTT 也不影响数据收集 / 仪表盘。**禁掉即可解决**：

```yaml
# docker-compose.yml 的 teslamate service 改：
services:
  teslamate:
    environment:
      - DISABLE_MQTT=true       # ← 加这一行
      # - MQTT_HOST=mosquitto   # ← 注释掉这一行（如果有）
```

然后整个 mosquitto service 也可以删（节省内存）：

```yaml
# 删掉 docker-compose.yml 末尾的 mosquitto: 整段
# 也删 volumes 段的 mosquitto-conf / mosquitto-data
```

`docker compose up -d` 重启后 TeslaMate 不再尝试连 MQTT，启动正常。

---

### ❌ 「自定义新车电池容量」「自定义新车最大续航里程」每次刷新重置为 0

Grafana textbox 变量只活在 URL 里，刷新就丢。两个方法选一个：

**方法 1（推荐）：URL 书签** —— 在仪表盘填好值后，浏览器地址栏会出现 `?var-custom_kwh_new=82&var-custom_max_range=600`，把整个 URL 存书签，以后直接从书签打开。

**方法 2（仅自用）：改 JSON 默认值** —— 编辑 `grafana/dashboards/zh-cn/battery-health.json`，把 `custom_kwh_new` / `custom_max_range` 两个变量的 `current` / `query` / `options` 里 `"0"` 全改成你的实际值（如 `"82"`）。保存后等 10 秒 Grafana 自动 reload。

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
# 在宿主机直接测（teslamate 容器没装 curl）
# 国内账号
curl -fsI https://auth.tesla.cn
curl -fsI https://owner-api.vn.cloud.tesla.cn

# 国际账号
curl -fsI https://auth.tesla.com
curl -fsI https://owner-api.teslamotors.com
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
OpenStreetMap 地图服务在国内可能受限。

**常见原因 2：浏览器控制台有 CORS 错误**
```
按 F12 → Console 标签 → 查看是否有地图相关错误
```

**解决方法 1（v1.4.2+ 推荐）：使用顶部「地图源」下拉框切换到高德地图**

打开任一含地图的仪表盘，顶部下拉框「地图源」选「高德地图」即可（瓦片直连国内 CDN，无需代理）。详见 [QUICKSTART.md](QUICKSTART.md) 「地图源切换 + 自动 GCJ-02 坐标纠偏」章节。

**解决方法 2：自建瓦片代理**
1. 在可访问海外的服务器上架设 OSM 瓦片代理
2. 编辑面板 → Map layers → Base layer → URL template 填入代理地址

### ❌ 切换高德/谷歌路网后车辆标记偏离道路 100~700 米

**原因：坐标系差异 + 未装 PostgreSQL 坐标转换函数**

高德 / 谷歌中国区域路网瓦片用 **GCJ-02（火星坐标系）**，TeslaMate 记录的是 **WGS-84（GPS 原始）**。两者在中国境内偏差 100~700 米。

**解决：装一次 v1.4.2+ 的坐标转换函数（一行命令）：**

```bash
docker exec -i teslamate-database-1 psql -U teslamate teslamate \
  < sql/install-coord-functions.sql
```

执行后会显示「坐标转换函数安装成功 (天安门测试通过): (39.91522, 116.40407)」自检通过提示。装完刷新仪表盘（Ctrl+Shift+R），轨迹会自动贴合道路。

> 不在意精度的话，切回 OSM / Carto / 谷歌卫星即可（都是 WGS-84，无偏差）。

### ❌ Dashboard 顶部「地图源」下拉框看不到

**症状**：升级到 v1.4.2 后，仪表盘顶部下拉框区域空白或只看到旧变量

**排查步骤：**
1. **强刷浏览器**：Ctrl+Shift+R（Windows）/ Cmd+Shift+R（Mac），清掉 Grafana 前端缓存
2. **重启 Grafana 容器**：`docker compose restart grafana`，触发仪表盘 provisioning 重载
3. **确认你打开的是含地图的仪表盘**：只有 9 个仪表盘有此下拉框（CurrentChargeView / CurrentDriveView / CurrentState / TrackingDrives / charging-stats / trip / visited / charge-details / drive-details）
4. **确认仓库是 v1.4.2+**：`head -3 CHANGELOG.md` 应显示 `## [v1.4.2]` 或更新版本

### ❌ 装 PostgreSQL 坐标转换函数报错

**症状**：执行 `docker exec -i teslamate-database-1 psql ...` 时报错

**常见原因 + 解决：**

| 报错关键字 | 原因 | 解决 |
|----------|------|------|
| `No such container: teslamate-database-1` | 容器名不对 | 先 `docker ps` 找你的 PostgreSQL 容器名（一般是 `teslamate-database-1` / `teslamate_database_1` 或 `postgres`），用真实名替换 |
| `database "teslamate" does not exist` | 数据库名不对 | TeslaMate 默认 DB 名就叫 teslamate；如自定义过，把命令里的 `teslamate teslamate` 第二个换成你的实际 DB 名 |
| `permission denied` | 用户权限不足 | TeslaMate 默认 superuser 是 `teslamate`；如改过，把 `-U teslamate` 替换 |
| `function pi() does not exist` | PostgreSQL 版本太低 | 函数依赖 PostgreSQL 9.0+ 内置 pi()；TeslaMate 官方镜像满足，正常不会触发 |

**确认装好的快速测试：**
```bash
docker exec teslamate-database-1 psql -U teslamate -d teslamate \
  -c "SELECT lat_for_map('autonavi.com', 39.913818, 116.397828);"
# 应输出 39.9152217625129（不是原值 39.913818）
```

输出原值说明函数没装上或 URL 不匹配；输出转换后的值说明工作正常。

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

⚠️ **直接把 TeslaMate `:4000` 暴露到公网 = 任何人能看到你的车辆位置/历史行程**。Grafana `:3000` 默认 admin/admin 也是一秒被攻破。**强烈建议先看 [QUICKSTART.md - 云服务器场景：安全防护必读](QUICKSTART.md#cloud-security)** 完整 5 级防护清单。

简版快速选项（详细操作见上述 QUICKSTART 章节）：
1. **Tailscale / ZeroTier**（推荐新手）：虚拟内网，云服务器关掉公网端口，本地像局域网访问
2. **Cloudflare Tunnel**：免费 + 自动 HTTPS，需要域名
3. **反向代理（Nginx/Caddy）+ Basic Auth + HTTPS**：最灵活，需运维经验

无论选哪种，都要：
- ✅ Grafana 默认密码改掉（admin/admin → 强密码）
- ✅ 云服务器安全组里 4000/3000 不要 `0.0.0.0/0` 全开放
- ✅ docker-compose.yml 端口绑定改 `127.0.0.1:` 前缀（如果配反向代理）

---

### 🟢 群晖 DSM 7.x 反向代理 + Let's Encrypt（推荐 NAS 用户）

**目标：** 用域名 `teslamate.your-domain.com` HTTPS 访问，不暴露 `:4000` `:3000` 端口。

**前置条件：**
- DSM 7.0+
- 一个能解析到你 NAS 公网 IP（或 DDNS）的域名
- 路由器已把 80 / 443 端口转发到 NAS

**步骤 1：申请 Let's Encrypt 证书**

1. **控制面板 → 安全性 → 证书 → 新增 → 添加新证书 → 从 Let's Encrypt 取得证书**
2. **域名** 填 `teslamate.your-domain.com`，**电邮** 填你能收信的邮箱
3. 点确定，DSM 自动用 80 端口完成 ACME 验证
4. 提示「证书已添加」即成功（**域名不解析 / 80 端口不通会失败**，先 `curl -I http://teslamate.your-domain.com` 验证）

**步骤 2：配反向代理**

1. **控制面板 → 登录门户 → 高级 → 反向代理服务器 → 新增**
2. **来源**：协议 `HTTPS` / 主机名 `teslamate.your-domain.com` / 端口 `443`
3. **目的地**：协议 `HTTP` / 主机名 `localhost` / 端口 `4000`（TeslaMate 主页）
4. 切到「自定义标头」标签页 → **新增 → 创建** → 选 **WebSocket**（TeslaMate 实时更新依赖 WS，不加这条会卡）
5. 保存。如果还要给 Grafana 配反代，新建一条规则：来源 `grafana.your-domain.com:443` → 目的地 `localhost:3000`

**步骤 3：绑定证书到域名**

控制面板 → 安全性 → 证书 → 选刚申请的证书 → **设置 → 把 `teslamate.your-domain.com` 服务的证书改为这张**。

**步骤 4：关掉端口直连**

打开浏览器测试 `https://teslamate.your-domain.com` 能进 → 改 `~/teslamate-chinese/docker-compose.yml`，给 teslamate 端口加 `127.0.0.1:` 前缀（仅本机访问，反代用），重启容器：
```yaml
    ports:
      - 127.0.0.1:4000:4000
```

**证书自动续期：** Let's Encrypt 90 天到期，DSM 默认每天 03:00 检查 → 30 天内到期自动续期，**不用手动管**。

> ⚠️ 证书续期失败常见原因：80 端口路由器忘了转发，或被 ISP 封。检查路径：控制面板 → 通知 → 看 ACME renewal 的失败日志。

---

### 🟢 群晖 Container Manager 「项目」部署（DSM 7.2+ 推荐）

**适用场景：** DSM 7.2+ 移除了 Docker 套件、用 Container Manager 替代。命令行不熟、想纯 GUI 部署的群晖小白。

**步骤 1：装 Container Manager**

控制面板 → 套件中心 → 搜「Container Manager」→ 安装。

**步骤 2：准备 docker-compose.yml**

DSM File Station 进入 `/volume1/docker/`，新建子文件夹 `teslamate`。**右键 → 新建文件 → 命名 `docker-compose.yml`**，内容粘贴下方完整模板（**记得替换两个红色占位符**）：

```yaml
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
      - ENCRYPTION_KEY=【请改成 openssl rand -hex 32 生成的 64 位字符串】
      - DATABASE_USER=teslamate
      - DATABASE_PASS=【请改成 openssl rand -base64 24 生成的密码】
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - MQTT_HOST=mosquitto
      - TZ=Asia/Shanghai

  database:
    image: postgres:18-trixie
    restart: always
    volumes:
      - teslamate-db:/var/lib/postgresql
    environment:
      - POSTGRES_USER=teslamate
      - POSTGRES_PASSWORD=【与上面 DATABASE_PASS 同一个密码】
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
      - DATABASE_PASS=【与上面 DATABASE_PASS 同一个密码】
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - GF_SECURITY_ADMIN_PASSWORD=admin
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
```

> **生成两个密钥的方法**（任选一种）：
> - **DSM 套件中心装「Text Editor / 终端机」**：开终端，跑 `openssl rand -hex 32`（这是 ENCRYPTION_KEY）+ `openssl rand -base64 24 | tr -d '/+=' | cut -c1-24`（这是 DATABASE_PASS），把输出粘到 yml 里
> - **任何 Mac / Linux 桌面**：终端跑同样命令，复制粘贴
> - **没终端**：用 [random-string-generator.com](https://www.random-string-generator.com/) 生成 64 位 hex（不推荐，第三方网站存在泄露风险，本地终端跑更稳）

⚠️ **`ENCRYPTION_KEY` 用于加密 Tesla token，丢了下次装就解密不出来**。生成完立刻抄到 1Password / Bitwarden / Keychain。

**步骤 3：在 Container Manager 里建项目**

1. Container Manager → **项目 → 新增**
2. **项目名称**：`teslamate-chinese`（随意，别和已有项目重名）
3. **路径**：选刚刚放 docker-compose.yml 的文件夹（如 `/docker/teslamate`）
4. **来源**：选「使用现有的 docker-compose.yml」
5. 点「下一步」→ Container Manager 自动解析 compose，列出 4 个服务（teslamate / database / grafana / mosquitto）
6. **下一步 → 完成 → 启动项目**

**步骤 4：等容器拉取启动**

进度条到 100% 后，浏览器访问 `http://NAS-IP:4000` 进 TeslaMate。

**升级时：** Container Manager → 项目 → 选 `teslamate-chinese` → **操作 → 重新构建** 即可重新拉镜像（实际等价于 `docker compose pull && docker compose up -d`）。

> ⚠️ Container Manager 项目模式有个坑：第一次启动失败后，**项目状态会卡在 STOPPED**，但部分容器其实启动了一半。**清理方法**：项目页面 → 操作 → 停止 → 清理 → 重新构建。

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

## 🌍 公网部署专项（云服务器用户）

### ⚠️ 流量爆表防护

云服务器（阿里云轻量 / 腾讯云轻量 / AWS Lightsail）通常按**月流量包**计费，公网暴露 Grafana 后高德/谷歌瓦片可能让流量飙升。

**典型场景**：

- 阿里云轻量 `1Mbps / 100GB` 套餐
- 你 + 家人手机经常打开「足迹地图」/ 「驾驶记录追踪」，每次加载几百张地图瓦片
- **1 周打满 100GB**（高德瓦片每张 ~30KB，3000 张 ≈ 100MB，1 周访问 1000 次就 100GB）

**3 种解决方案**：

| 方案 | 说明 | 推荐度 |
|---|---|---|
| ✅ **Tailscale / 自建 WireGuard** | 不开公网，只在自己设备间通信，**0 流量消耗** | ⭐⭐⭐⭐⭐ |
| ⚠️ Cloudflare 反代 | 中间挡一层 CDN 缓存瓦片 | ⭐⭐⭐ 减少但不消除 |
| ⚠️ Grafana 切换 OSM 默认 | OSM 瓦片小（~10KB），但**国内访问慢** | ⭐⭐ 小流量但卡 |

**强烈建议**：除非确实需要公网访问，**用 Tailscale** —— 5 分钟设置，免费，所有家人手机一并接入，流量为 0。

详见 [QUICKSTART → cloud-security 章节](QUICKSTART.md#cloud-security) 的 Tailscale 段。

### ⚠️ 服务挂了你怎么知道？— 失败告警可选配置

TeslaMate / Grafana 容器 OOM / 数据库挂 / Tesla token 过期 等情况下，**默认无任何通知**，你只能下次打开 Grafana 才发现「数据停在三周前」。

**配 uptime-kuma 5 分钟搞定**：

```yaml
# 在你 docker-compose.yml 末尾加这个 service：
  uptime-kuma:
    image: louislam/uptime-kuma:1
    restart: always
    ports:
      - 3001:3001
    volumes:
      - uptime-kuma-data:/app/data

# 也别忘了 volumes 段加：
volumes:
  uptime-kuma-data:
```

`docker compose up -d` 后访问 `http://你机器:3001`：

- 添加监控：`http://localhost:4000` (TeslaMate)、`http://localhost:3000` (Grafana)
- 频率：每 60 秒 ping 一次
- 通知：Telegram / 微信 (PushDeer / Bark) / 邮件 / Discord 任选

挂了 1 分钟内手机收到告警。

> ⚠️ uptime-kuma 是**第三方开源项目**，本项目不强制集成，仅作可选推荐。

---

## 🔄 升级问题

### 如何升级到新版本

按你之前的安装方式选一条：

#### A. 一键脚本用户（之前用 simple-deploy.sh 装的）

直接重跑一键脚本，**它会自动检测现有安装并转升级模式**：

```bash
curl -fsSL https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/simple-deploy.sh | bash
```

会做：拉新镜像 → 重启容器 → 装/更新坐标转换函数 → 重启 Grafana。**不会改你的 ENCRYPTION_KEY 或其他配置。**

#### B. git clone 用户

```bash
cd ~/teslamate-chinese     # 你的克隆目录
bash scripts/upgrade.sh
```

#### C. 仅更新镜像（旧用法，不含 v1.4.2 坐标函数）

⚠️ **如果你从 v1.4.1 或更早版本升级到 v1.4.2+，单跑这条会让 9 个含地图的仪表盘报错** `function lat_for_map does not exist`。请用上面 A 或 B。

```bash
cd ~/teslamate-chinese  # 进入安装目录
docker compose pull
docker compose up -d
```

---

<a id="tou-rollback"></a>

### v1.5.0 分时电价升级排错 / 回滚

#### 仪表盘报 `function effective_cost(...) does not exist`

`install-tou.sql` 没装上。**按你的安装方式重跑升级即可**，详见 [README 方法 B](README.md#upgrade-method-b)（git clone 用户）或 [README 方法 C](README.md#upgrade-method-c)（手动派）。

#### 「⚡ 分时电价配置」仪表盘空白 / 不显示表单

Grafana 缺 `volkovlabs-form-panel` 插件。**v1.6.3+ 镜像 build-time 已装**，但**升级用户需要额外做一步 runtime 装**（Docker 数据卷会盖住镜像里新装的插件）。详见 [issue #13](https://github.com/wjsall/teslamate-chinese-dashboards/issues/13)。

##### 修法（**所有受影响用户都跑这条**）

```bash
docker exec --user root teslamate-grafana-1 grafana cli plugins install volkovlabs-form-panel 6.3.2 \
 && docker compose restart grafana \
 && sleep 10 \
 && docker exec teslamate-grafana-1 grafana cli plugins ls | grep volkovlabs-form-panel
```

**期望输出**：

```
volkovlabs-form-panel @ 6.3.2
```

装一次后**永久生效**（Grafana 数据卷持久化）。

##### 为什么升级镜像本身不够（Docker 数据卷坑）

TeslaMate 标准 compose 有 `teslamate-grafana-data:/var/lib/grafana` 命名卷。Docker 命名卷的行为：

> **首次创建容器时**从镜像挂载点**拷贝初始内容**，**之后只用卷自己的内容**。

后果：
- 已经跑过 grafana 的用户 → 卷里是旧镜像的 plugins/，**新镜像里的 form-panel 进不去卷**
- 全新用户首次 `docker compose up` → 卷是空的，从 v1.6.3+ 镜像拷贝（**含 form-panel**）✅

`--force-recreate` 只销毁容器实例，**不动卷**。所以已有 grafana 卷的用户必须 runtime 装一次。

##### 谁不受影响

| 用户类型 | 是否需要 runtime 装 |
|---|---|
| 全新装（首次 `docker compose up`，卷为空）| ❌ 不需要，v1.6.3+ 镜像自动带 |
| 用 `scripts/upgrade.sh` 升级 | ❌ 不需要，脚本自动检测 + 触发 runtime 装 |
| **手动 `docker compose pull + up -d`（任何旧版本升 v1.6.3）** | ✅ 需要，跑上面的命令 |
| 自己组 compose 没用我们镜像 | ✅ 需要，跑上面的命令 |

#### 主仪表盘费用数字突然变了

如果你**配了分时电价**，所有费用面板会自动按 分时电价真实价显示，跟之前 TeslaMate 默认估算的数字会有 1-5% 差异（TeslaMate 默认按充电点配的固定单价 × 度数算，分时电价是按时段逐秒加权）。这是预期行为。

**想恢复原数字**：

```bash
# 选项 1：清空 分时电价配置（保留函数和旁路表，下次想用还能用）
docker exec teslamate-database-1 psql -U teslamate -d teslamate \
  -c "TRUNCATE tou_rates RESTART IDENTITY CASCADE; TRUNCATE charging_processes_tou_cost"

# 选项 2：把仪表盘 SQL 改回原 cost（git clone 用户）
python3 scripts/wrap-cost-with-tou-view.py --revert
```

#### 完全卸载分时电价（恢复到 v1.4.x 状态）

**TeslaMate 任何表都没动**，可以彻底拆除。一行调 `uninstall_tou()` PG 函数：

```bash
docker exec teslamate-database-1 psql -U teslamate -d teslamate \
  -c "SELECT uninstall_tou(); DROP FUNCTION uninstall_tou();"

# 仪表盘 SQL 也改回去（git clone 用户）
python3 scripts/wrap-cost-with-tou-view.py --revert
```

`uninstall_tou()` 用 `pg_proc` 自动找全部 tou_* / _tou_* 函数 + 触发器 + 视图 + 旁路表，不会跟 install-tou.sql 函数列表漂移。

> ⚠ 调用会 **CASCADE 删除所有依赖 `tou_rates` / `charging_processes_tou_cost` 的对象（包括你自己建的视图）**。卸载前先跑 `\d+ tou_rates` 看 referenced by 列表确认没要保的。

#### 分时电价计算不对劲（充电费用看上去不合理）

打开「⚡ 分时电价配置」仪表盘，看「⚠ 配置审计」面板：
- **时段空缺**：某些小时没配置 → 那段时间充电会按 NULL → 仪表盘 fallback 原 cost
- **时段重叠**：同一小时被多条记录覆盖 → 系统按 ID 最小的那条算，其他失效
- **月份空缺**：整个月没落入任何季节 → 那个月充电按 NULL → fallback 原 cost

修法：用「⚡ 一键填一整季节」重新覆盖，或「✏️ 修改单价」/「🗑️ 删除整段」精修。
改完点底部「**🔄 重算所有历史充电**」按钮重算历史。

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

## 🚚 迁移与备份

### 整机迁移（旧 NAS → 新 NAS / 重装 DSM / 换云服务器）

⚠️ **必须备份的 3 件**（缺一不可，少一个都恢复不了）：

| 项 | 不备份的后果 |
|---|---|
| 1. **`docker-compose.yml`**（含 `ENCRYPTION_KEY` + 数据库密码）| Tesla token 永远解密不出来，必须重新授权 |
| 2. **PostgreSQL 数据库 dump**（`drives` / `charges` / `positions` / `cars` 全部历史）| 行车记录全丢 |
| 3. **Grafana 数据卷**（自定义书签 / 用户 / 配置）| 你改过的 dashboard 设置丢，43 个仪表盘会自动重新 provisioning |

**备份步骤（旧机器上跑）**：

```bash
cd ~/teslamate-chinese

# 1. 备份 docker-compose.yml + .env
tar czf teslamate-config.tar.gz docker-compose.yml .env 2>/dev/null

# 2. 备份数据库（pg_dump）
docker compose exec -T database \
  pg_dump -U teslamate -d teslamate -Fc -f /tmp/teslamate.dump
docker cp $(docker compose ps -q database):/tmp/teslamate.dump ./teslamate.dump

# 3. 备份 Grafana 数据卷
docker run --rm \
  -v teslamate_teslamate-grafana-data:/data \
  -v $(pwd):/backup alpine \
  tar czf /backup/grafana-data.tar.gz -C /data .

# 4. 把 3 个备份文件下载到本机 / 网盘 / 移动硬盘
ls -lh teslamate-config.tar.gz teslamate.dump grafana-data.tar.gz
```

**恢复步骤（新机器上）**：

> ⚠️ **关键 vs 旧版**：旧版「先起 database → pg_restore -c」流程会踩两个坑：(1) `private` schema 不被 `-c` 清理 → 旧 token 加密对象残留 → Tesla token 解密失败被迫重新授权；(2) 单起 database 容器时 `cube` / `earthdistance` extension 没装 → pg_restore 报 `type "cube" does not exist`。下面流程跟 [TeslaMate 官方 backup_restore](https://docs.teslamate.org/docs/maintenance/backup_restore) 对齐，避坑。

```bash
# 1. 装回 TeslaMate
mkdir -p ~/teslamate-chinese
cd ~/teslamate-chinese

# 2. 恢复 docker-compose.yml + .env（含 ENCRYPTION_KEY，必须保持一致）
tar xzf teslamate-config.tar.gz

# 3. 完整启动一次（让 teslamate 容器自动建好 schema 和 extensions）
docker compose up -d
sleep 30   # 等 teslamate 完成首次 schema/extension 初始化

# 4. 停 teslamate 防止恢复时写冲突（database 保持运行）
docker compose stop teslamate

# 5. 清空 schema + 重建 extensions（跟官方 backup_restore 对齐）
docker compose exec -T database psql -U teslamate teslamate <<'EOF'
DROP SCHEMA public CASCADE;
DROP SCHEMA private CASCADE;
CREATE SCHEMA public;
CREATE EXTENSION cube WITH SCHEMA public;
CREATE EXTENSION earthdistance WITH SCHEMA public;
EOF

# 6. 恢复数据库（用 -Fc 格式 dump → pg_restore，不带 -c 因为已手动 DROP）
docker cp teslamate.dump $(docker compose ps -q database):/tmp/teslamate.dump
docker compose exec -T database \
  pg_restore -U teslamate -d teslamate /tmp/teslamate.dump

# 7. 恢复 Grafana 数据卷
docker run --rm \
  -v teslamate_teslamate-grafana-data:/data \
  -v $(pwd):/backup alpine \
  tar xzf /backup/grafana-data.tar.gz -C /data

# 8. 启动 teslamate
docker compose start teslamate
```

> **如果你已经按旧版流程恢复过 + token 解密失败被迫重授权过**：那是这个 bug 的症状。现在用新流程不会再遇到。如果还有 4S 店保养记录或其他业务数据是从 backup 来的，旧版流程不会丢，仅 token 那一项受影响。

### 单纯备份数据库（定期跑）

如果只想 hypper backup 时拉一份数据库快照（不迁移），加到 NAS 任务计划：

```bash
docker exec teslamate-database-1 \
  pg_dump -U teslamate -d teslamate -Fc -f /tmp/teslamate.dump && \
docker cp teslamate-database-1:/tmp/teslamate.dump \
  /volume1/backup/teslamate-$(date +%Y%m%d).dump
```

每周保留 4 份：

```bash
find /volume1/backup/teslamate-*.dump -mtime +28 -delete
```

---

### 🟡 进阶：把数据从 Docker 命名卷迁到 NAS 共享文件夹（bind mount）

**适用场景：** 群晖 / 威联通用户想把 Postgres 数据库 / Grafana 数据放到能直接通过 NAS 文件浏览器看见的路径，方便用 Hyper Backup / Snapshot Replication 备份。

> ⚠️ **这是有损操作（涉及停服 + 文件搬运），新装直接用 bind mount 比迁移简单**。已经在跑的用户，**先做完整数据库 dump 再开始**（见上节「单纯备份数据库」）。

**步骤：**

1. **停服 + 整库 dump 留底（保险）**
   ```bash
   cd ~/teslamate-chinese
   docker exec teslamate-database-1 pg_dump -U teslamate teslamate > /volume1/backup/teslamate-pre-bindmount.dump
   docker compose down
   ```

2. **从命名卷拷数据到目标路径**

   先找到命名卷的实际宿主路径：
   ```bash
   docker volume inspect teslamate_teslamate-db | grep Mountpoint
   # 输出类似 /var/lib/docker/volumes/teslamate_teslamate-db/_data
   ```

   建好目标目录并拷过去（保留属主 / 权限，**这一步必须 sudo**）：
   ```bash
   sudo mkdir -p /volume1/docker/teslamate/data/{db,grafana,mosquitto-conf,mosquitto-data}
   sudo cp -a /var/lib/docker/volumes/teslamate_teslamate-db/_data/. /volume1/docker/teslamate/data/db/
   sudo cp -a /var/lib/docker/volumes/teslamate_teslamate-grafana-data/_data/. /volume1/docker/teslamate/data/grafana/
   sudo cp -a /var/lib/docker/volumes/teslamate_mosquitto-conf/_data/. /volume1/docker/teslamate/data/mosquitto-conf/
   sudo cp -a /var/lib/docker/volumes/teslamate_mosquitto-data/_data/. /volume1/docker/teslamate/data/mosquitto-data/
   ```

3. **改 docker-compose.yml**

   把 `database` / `grafana` / `mosquitto` 三个服务的 `volumes:` 段改成 bind mount：
   ```yaml
   database:
     volumes:
       - /volume1/docker/teslamate/data/db:/var/lib/postgresql

   grafana:
     volumes:
       - /volume1/docker/teslamate/data/grafana:/var/lib/grafana

   mosquitto:
     volumes:
       - /volume1/docker/teslamate/data/mosquitto-conf:/mosquitto/config
       - /volume1/docker/teslamate/data/mosquitto-data:/mosquitto/data
   ```

   把文件最底部 `volumes:` 段（声明 4 个命名卷的部分）整段删除（已经不用了）。

4. **修权限**（关键，permission 错容器起来报错）：
   ```bash
   # 999 = postgres 官方镜像内置的 postgres 用户 uid（固定值，不能改）
   sudo chown -R 999:999 /volume1/docker/teslamate/data/db
   # 472 = Grafana 官方镜像内置的 grafana 用户 uid（固定值，不能改）
   sudo chown -R 472:472 /volume1/docker/teslamate/data/grafana
   # 1883 = eclipse-mosquitto 镜像内置的 mosquitto 用户 uid（固定值，不能改）
   sudo chown -R 1883:1883 /volume1/docker/teslamate/data/mosquitto-conf /volume1/docker/teslamate/data/mosquitto-data
   ```

   > 这三个 uid 来自各官方镜像 Dockerfile 里硬编码的 `USER` 指令，不是任意数。`docker exec teslamate-database-1 id` 验证 = `uid=999(postgres)`。

5. **启动 + 验证**：
   ```bash
   docker compose up -d
   docker compose logs -f database | grep -i "ready\|error"
   ```

   看到 `database system is ready to accept connections` 即成功。打开 TeslaMate 主页验证数据完整。

6. **确认无问题后删旧命名卷**（可选，省宿主磁盘空间）：
   ```bash
   docker volume rm teslamate_teslamate-db teslamate_teslamate-grafana-data \
                    teslamate_mosquitto-conf teslamate_mosquitto-data
   ```

> ⚠️ **任一步骤出错**：恢复方案 = `docker compose down` → 把 docker-compose.yml volumes 段改回命名卷 → `docker compose up -d` → `docker exec -i teslamate-database-1 psql -U teslamate -d teslamate < /volume1/backup/teslamate-pre-bindmount.dump`。所以第 1 步的 dump 必须先做。

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
