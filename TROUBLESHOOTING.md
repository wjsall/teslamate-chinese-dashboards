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

打开 Grafana → 左侧 **Connections → Data sources** → 看名字是否为 `TeslaMate`（区分大小写）。如果不是，点开数据源把 `UID` 改成 `TeslaMate`，所有面板的 SQL 查询都用这个固定 UID 引用。

**常见原因 3：数据库连接超时**
```bash
docker compose logs grafana | grep -i "error\|failed"
```

---

### ❌ TeslaMate「Sign in with Tesla」按钮反复登不上

**症状**：打开 TeslaMate 主页 `http://服务器IP:4000`，点击「Sign in with Tesla」后页面跳转特斯拉登录页，但出现以下任一情况：
- 跳转后空白页 / 一直加载
- 报 `unauthorized_client` 或 `invalid_request`
- 中国账号怎么试都进不去
- 输完两步验证码仍然报错
- 跳回 TeslaMate 后状态依然是「未授权」

**逐项排查：**

#### 1. 国内用户：是否配置了 Tesla 中国区 API？

中国账号必须用 `auth.tesla.cn`（不是 `auth.tesla.com`）。检查 `~/teslamate-chinese-dashboards/docker-compose.yml`：
```bash
grep -E "TESLA_API_HOST|TESLA_WSS_HOST" ~/teslamate-chinese-dashboards/docker-compose.yml
```
应该看到：
```
- TESLA_API_HOST=https://owner-api.vn.cloud.tesla.cn
- TESLA_WSS_HOST=wss://streaming.vn.cloud.tesla.cn
```
如果前面有 `#` 注释掉，去掉 `#` 后 `docker compose up -d` 重启。详细操作见 [QUICKSTART.md](QUICKSTART.md) 第四步「中国大陆用户必看」。

#### 2. 服务器能否访问 Tesla 服务器？

```bash
# 国际账号
curl -I https://auth.tesla.com
# 中国账号
curl -I https://auth.tesla.cn
```
任一报错（超时、连接拒绝、SSL 握手失败）→ 服务器网络不通 → 配代理或换可用网络。

#### 3. 两步验证码是否超时？

验证码默认有效期约 30 秒。**收到短信/App 推送后立即输入**，别拖到下一分钟才输。

#### 4. 浏览器卡 cookie / 缓存

换无痕模式 / 换浏览器 / 清 `auth.tesla.com` 和 `auth.tesla.cn` 的 cookie 后重试。

#### 5. ⭐ 推荐方案：换用「Auth for Tesla」App（最简单）

**国内 Tesla 圈早就把这条作为首选**，不需要改 docker-compose.yml 也不用配中国区 API：

1. 手机 App Store 搜「**Auth for Tesla**」（iOS / Android 都有）
2. App 里登录 Tesla 账号 → 显示 `access_token` 和 `refresh_token` 两段字符串
3. 回 TeslaMate 登录页，展开「**Use existing tokens** / 使用现有 Token」折叠选项，粘贴两段 token

> ⚠️ Auth for Tesla 是社区开源工具，**只在你信任的设备上用**（自己的 iPhone / Android）。绑定后 TeslaMate 用 refresh_token 自动续期。

完整步骤 + 注意事项见 [QUICKSTART.md 第四步「方法 A：用 Auth for Tesla App 拿 Token」](QUICKSTART.md)。

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

按你之前的安装方式选一条：

#### A. 一键脚本用户（之前用 simple-deploy.sh 装的）

直接重跑一键脚本，**它会自动检测现有安装并转升级模式**：

```bash
wget -qO- https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/simple-deploy.sh | bash
```

会做：拉新镜像 → 重启容器 → 装/更新坐标转换函数 → 重启 Grafana。**不会改你的 ENCRYPTION_KEY 或其他配置。**

#### B. git clone 用户

```bash
cd ~/teslamate-chinese-dashboards     # 你的克隆目录
bash scripts/upgrade.sh
```

#### C. 仅更新镜像（旧用法，不含 v1.4.2 坐标函数）

⚠️ **如果你从 v1.4.1 或更早版本升级到 v1.4.2+，单跑这条会让 9 个含地图的仪表盘报错** `function lat_for_map does not exist`。请用上面 A 或 B。

```bash
cd ~/teslamate-chinese-dashboards  # 进入安装目录
docker compose pull
docker compose up -d
```

---

<a id="tou-rollback"></a>

### v1.5.0 分时电价升级排错 / 回滚

#### 仪表盘报 `function effective_cost(...) does not exist`

`install-tou.sql` 没装上。**按你的安装方式重跑升级即可**，详见 [README 方法 B](README.md#upgrade-method-b)（git clone 用户）或 [README 方法 C](README.md#upgrade-method-c)（手动派）。

#### 「⚡ 分时电价配置」仪表盘空白 / 不显示表单

Grafana 缺 `volkovlabs-form-panel` 插件。新镜像启动时自动装（`ENV GF_INSTALL_PLUGINS`），如果你用的旧镜像或自己组的 compose：

```bash
docker exec --user root teslamate-grafana-1 grafana-cli plugins install volkovlabs-form-panel
docker compose restart grafana
```

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
cd ~/teslamate-chinese-dashboards
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
cd ~/teslamate-chinese-dashboards
docker compose down          # 停止并删除容器
docker compose up -d         # 重新创建并启动
```

数据保存在 Docker 命名卷中，`down` 命令不会删除数据。

### 完全重置（清除所有数据）

> ⚠️ **不可恢复！** 执行前请先备份数据库！

```bash
cd ~/teslamate-chinese-dashboards
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
