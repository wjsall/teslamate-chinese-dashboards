# 新手向导 — 从零开始使用 TeslaMate 中文 Dashboard

> 没用过 Docker？没关系。本文用最简单的方式带你完成安装。

---

## 第一步：搞清楚它是什么

### TeslaMate 是什么？
TeslaMate 是一个**开源**的特斯拉数据记录工具。它会自动收集你的车辆数据（每次行程、充电、电池状态等），保存在你自己的服务器上。数据完全属于你，不经过任何第三方。

### 本项目是什么？
TeslaMate 官方的 Grafana 图表是英文的。本项目提供了 **40 个简体中文汉化版图表**（含 9 个原创分析仪表盘），把所有界面翻译成中文，开箱即用。

### 整体架构（你不需要完全理解，但有个概念更好）

```
你的特斯拉
    ↓（通过 Tesla 官方 API）
TeslaMate（数据采集）─→ PostgreSQL（数据库存储）
    ↓（MQTT消息）
Mosquitto（消息中间件）
    ↓（数据读取）
Grafana（图表展示）← 你用浏览器打开这个看数据
```

运行这些服务需要一台**常开的机器**（家用 NAS、云服务器、甚至树莓派都行）。

---

## 第二步：检查前置条件

在开始之前，确认以下几项：

### ✅ 必要条件

| 条件 | 如何确认 |
|------|---------|
| **一台常开的机器** | NAS / 云服务器 / 家用电脑 |
| **已安装 Docker** | 终端运行 `docker --version`，有输出即可 |
| **已安装 Docker Compose** | 终端运行 `docker compose version`，有输出即可 |
| **2GB 以上内存** | 服务器基本都满足 |
| **10GB 以上磁盘空间** | 用于数据库和镜像 |
| **网络能访问 Tesla 服务器** | 国内需确认（或配置代理） |

### 安装 Docker（如果还没安装）

**Ubuntu / Debian：**
```bash
curl -fsSL https://get.docker.com | bash
sudo usermod -aG docker $USER
# 重新登录后生效
```

**macOS：**
下载安装 [Docker Desktop](https://www.docker.com/products/docker-desktop/)

**Windows：**
通过 WSL2 安装 Docker Desktop（需要 Windows 10 版本 2004+）

---

## 第三步：一键安装（最简单的方式）

### 方法 A：一键脚本（强烈推荐新手）

在你的服务器上运行以下命令：

```bash
wget https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/simple-deploy.sh
bash simple-deploy.sh
```

脚本会自动：
- 创建 `~/teslamate-chinese/` 工作目录
- 生成 docker-compose.yml 配置文件
- 生成随机加密密钥
- 启动所有服务

> **🇨🇳 中国大陆用户注意：**
> 脚本默认使用 Docker Hub 镜像（`bswlhbhmt816/teslamate-chinese-dashboards`），相比 ghcr.io 在国内访问更稳定。
> 如果拉取镜像仍然很慢或失败，请先配置 Docker 镜像代理：
> ```bash
> # 编辑 Docker 配置（需要 root 权限）
> sudo tee /etc/docker/daemon.json <<EOF
> {"registry-mirrors": ["https://dockerproxy.cn"]}
> EOF
> sudo systemctl daemon-reload && sudo systemctl restart docker
> # 然后重新运行脚本
> ```

### 方法 B：手动 Docker Compose（推荐已熟悉 Docker 的用户）

**1. 创建工作目录**
```bash
mkdir ~/teslamate && cd ~/teslamate
```

**2. 创建 docker-compose.yml**

> 🔴 **重要：关于 ENCRYPTION_KEY**
>
> `ENCRYPTION_KEY` 是用来加密你的 Tesla 账号 Token 的**系统级密钥**。
> - **必须设置为一个随机字符串**（不能用默认值或简单的密码）
> - **设置后绝对不能修改**，否则 Tesla Token 将无法解密，TeslaMate 会崩溃且无法恢复
> - **请把它保存到安全的地方**（记事本、密码管理器均可）
>
> 生成随机密钥的命令：
> ```bash
> openssl rand -hex 32
> ```

> 🔴 **重要：关于数据库密码**
>
> `DATABASE_PASS`（teslamate 服务）和 `POSTGRES_PASSWORD`（database 服务）**必须填写完全相同的密码**，否则 TeslaMate 将无法连接数据库。

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
      - ENCRYPTION_KEY=用 openssl rand -hex 32 生成的随机字符串  # 🔴 必填，设置后不能修改！
      - DATABASE_USER=teslamate
      - DATABASE_PASS=你的数据库密码  # 🔴 替换为安全密码，与下方 POSTGRES_PASSWORD 必须相同
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - MQTT_HOST=mosquitto

  database:
    image: postgres:18-trixie
    restart: always
    volumes:
      - teslamate-db:/var/lib/postgresql
    environment:
      - POSTGRES_USER=teslamate
      - POSTGRES_PASSWORD=你的数据库密码  # 🔴 必须与上方 DATABASE_PASS 完全相同
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
      - DATABASE_PASS=你的数据库密码
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
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

**3. 生成随机加密密钥**
```bash
openssl rand -hex 32
# 把输出的字符串替换到 ENCRYPTION_KEY=
```

**4. 启动**
```bash
docker compose up -d
```

---

## 第四步：首次登录 TeslaMate

安装完成后，按照以下步骤完成车辆绑定：

### 1. 打开 TeslaMate
在浏览器中访问：`http://服务器IP:4000`

> 本机安装用 `http://localhost:4000`

### 2. 授权 Tesla 账号

TeslaMate 使用 **Tesla 官方 OAuth** 授权，**不需要把密码输入到 TeslaMate**，全程在特斯拉官网完成。

具体步骤：
1. 点击 TeslaMate 页面上的 **「Sign in with Tesla」** 按钮
2. 页面会跳转到 `auth.tesla.com`（特斯拉官方登录页）
3. 输入你的**特斯拉账号和密码**
4. 如果开启了两步验证，还需要输入验证码
5. 授权完成后，页面自动跳回 TeslaMate

> **🇨🇳 中国大陆用户注意：**
> 登录页面会跳转到 Tesla 国际区（`auth.tesla.com`），中国账号可能需要使用 `auth.tesla.cn`。
> 如果跳转后一直加载失败，请确认 `docker-compose.yml` 中已添加以下两行并重启：
> ```yaml
> - TESLA_API_HOST=https://owner-api.vn.cloud.tesla.cn
> - TESLA_WSS_HOST=wss://streaming.vn.cloud.tesla.cn
> ```

> **授权失败常见原因：**
> - 账号密码错误 → 确认在特斯拉 App 能正常登录
> - 两步验证超时 → 尽快输入验证码，不要等待太久
> - 网络不通 → 检查服务器能否访问 Tesla 服务器

### 3. 完成绑定
授权成功后，TeslaMate 会自动开始同步车辆数据。

> ⏱️ **首次同步预计 5-30 分钟**（取决于历史行程数量），之后每次行程结束自动更新。
>
> 同步进行中时，可以通过以下命令确认：
> ```bash
> docker compose logs -f teslamate
> # 看到 "Fetching vehicle data" 或 "Importing drive" 说明正在同步
> ```

---

## 第五步：登录 Grafana 查看图表

### 打开 Grafana
浏览器访问：`http://服务器IP:3000`

### 默认登录信息
- 用户名：`admin`
- 密码：`admin`

> ⚠️ **强烈建议**：首次登录后立即修改密码！
> 点击右上角头像 → Profile → Change Password

### 界面说明

登录后你会看到左侧导航栏，点击 **Dashboards** 查看所有 40 个中文图表。

**推荐第一次看这几个：**
1. **概览** — 车辆当前整体状态
2. **最近车辆状态** — 实时电量、续航、位置
3. **充电记录** — 历史充电记录

---

## 第六步：安装后必做的 5 件事

**1. 修改 Grafana 默认密码**
```
Grafana → 右上角头像 → Profile → Change Password
```

**2. 收藏常用 Dashboard**
打开 Dashboard → 点击右上角 ☆ → 下次直接在"收藏"中找到

**3. 设置时区**
如果时间显示不对：Grafana 右上角时钟图标 → 选择 `Asia/Shanghai`

**4. 确认数据同步正常**
```bash
# 查看 TeslaMate 日志
docker compose logs -f teslamate
# 看到 "Fetching vehicle data" 说明正在同步
```

**5. 设置自动重启（防止断电后不能自启）**
docker-compose.yml 中已配置 `restart: always`，Docker 重启后服务会自动恢复。确认 Docker 服务本身开机自启：
```bash
sudo systemctl enable docker
```

---

## 常见新手问题 (FAQ)

**Q: 数据会上传到哪里？会被特斯拉或其他人看到吗？**
A: 所有数据都保存在你自己的机器上，不会上传到任何第三方服务器（除了从 Tesla 官方 API 获取数据这一步）。

**Q: 需要一直开着电脑吗？**
A: 是的，需要一台常开的机器。推荐使用 NAS（如群晖/威联通）、云服务器，或者树莓派等低功耗设备。如果机器关机，TeslaMate 就停止收集数据了，但已有数据不会丢失。

**Q: 能用手机看吗？**
A: 可以。只要你的手机和服务器在同一局域网，或者服务器有公网 IP，手机浏览器访问 `http://IP:3000` 即可。Grafana 界面对手机做了适配。

**Q: 会影响车辆续航或让车睡不着觉吗？**
A: TeslaMate 的设计会尊重车辆休眠。当车辆处于休眠状态时，TeslaMate 不会主动唤醒它。有时会有少量唤醒（用于数据获取），但对续航影响极小。

**Q: 我的车辆 Token 安全吗？**
A: Token 使用你自己设置的 `ENCRYPTION_KEY` 加密后存储在本地数据库中，不会外泄。**请务必设置一个强随机密钥，并妥善保存。**

**Q: 图表里没有数据是正常的吗？**
A: 刚安装后数据需要几分钟到几小时才会出现，取决于 Tesla API 的响应速度。如果超过 1 小时还没有数据，查看 `docker compose logs teslamate` 排查问题。

**Q: 如果 TeslaMate 容器重启会丢数据吗？**
A: 不会。所有数据都存在 PostgreSQL 数据库中，容器重启不影响数据。

**Q: 安装在国内服务器上会有问题吗？**
A: **国内用户需要额外配置 Tesla 中国区 API 地址**，否则无法获取车辆数据。在 `docker-compose.yml` 的 `teslamate` 服务中添加：
```yaml
environment:
  - TZ=Asia/Shanghai
  - TESLA_API_HOST=https://owner-api.vn.cloud.tesla.cn
  - TESLA_WSS_HOST=wss://streaming.vn.cloud.tesla.cn
```
此外，ghcr.io 镜像拉取可能需要代理，详见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。

**Q: 怎么更新到新版本？**
A: 一条命令搞定：
```bash
cd ~/teslamate-chinese  # 或你的安装目录
docker compose pull grafana
docker compose up -d grafana
```

**Q: 如何备份数据？**
A: 备份 PostgreSQL 数据库：
```bash
docker compose exec database pg_dump -U teslamate teslamate > backup_$(date +%Y%m%d).sql
```

**Q: 能同时监控多辆车吗？**
A: 可以。用同一个特斯拉账号下的多辆车，TeslaMate 会自动识别并分别记录。图表顶部有车辆选择下拉框。

**Q: Grafana 界面怎么还是英文？**
A: 确认 Grafana 服务的环境变量中有 `GF_USERS_DEFAULT_LANGUAGE=zh-Hans`，然后重启 Grafana：
```bash
docker compose restart grafana
```

---

## 进阶配置：切换高德地图（国内用户可选）

> 默认使用 OpenStreetMap，国内加载可能较慢。如果你在中国大陆，可以手动切换为高德地图，加载更快、路名更准确。

### 为什么需要坐标纠偏？

高德地图使用 **GCJ-02（火星坐标系）**，而 GPS 和 TeslaMate 记录的是 **WGS-84（地球坐标系）**。两者在中国境内有 100-700 米偏差。不纠偏的话，车辆轨迹点会偏离道路。

### 需要改动的内容

共需修改 **7 个仪表盘** 的两处配置：
1. **底图 URL** → 改为高德瓦片地址
2. **SQL 查询** → 加入坐标转换公式

涉及的 7 个仪表盘：`充电统计（汇总）`、`访问过的地点`、`最近车辆状态`、`当前驾驶状态`、`行程统计（时间段）`、`驾驶记录追踪`、`当前充电状态`

---

### 第一步：修改底图 URL

在 Grafana 中打开每个含地图的面板，点击右上角 **Edit（编辑）**：

1. 找到地图面板
2. 右侧面板选项中找到 **底图图层 → 图层类型 → XYZ Tile layer**
3. 将 URL template 替换为：

```
http://wprd0{1-4}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&style=7&x={x}&y={y}&z={z}
```

4. Attribution 填写：`© 高德地图`
5. 保存面板

> 💡 无需高德 API Key，该地址为高德公共瓦片 CDN，直接可用。

---

### 第二步：SQL 加入坐标纠偏

在同一面板的 **Query（查询）** 中，将原始的 `latitude` / `longitude` 列替换为纠偏后的表达式。

**纠偏后纬度（替换原 `latitude`）：**

```sql
latitude + (
  (-100.0 + 2.0*(longitude-105.0) + 3.0*(latitude-35.0)
   + 0.2*(latitude-35.0)*(latitude-35.0)
   + 0.1*(longitude-105.0)*(latitude-35.0)
   + 0.2*sqrt(abs(longitude-105.0))
   + (20.0*sin(6.0*(longitude-105.0)*PI()) + 20.0*sin(2.0*(longitude-105.0)*PI())) * 2.0/3.0
   + (20.0*sin((latitude-35.0)*PI()) + 40.0*sin((latitude-35.0)/3.0*PI())) * 2.0/3.0
   + (160.0*sin((latitude-35.0)/12.0*PI()) + 320.0*sin((latitude-35.0)*PI()/30.0)) * 2.0/3.0
  ) * 180.0
) / (
  (6378137.0 * (1 - 0.00669342162296594323))
  / (
      (1 - 0.00669342162296594323*sin(latitude/180.0*PI())*sin(latitude/180.0*PI()))
      * sqrt(1 - 0.00669342162296594323*sin(latitude/180.0*PI())*sin(latitude/180.0*PI()))
    )
  * PI()
)
```

**纠偏后经度（替换原 `longitude`）：**

```sql
longitude + (
  (300.0 + (longitude-105.0) + 2.0*(latitude-35.0)
   + 0.1*(longitude-105.0)*(longitude-105.0)
   + 0.1*(longitude-105.0)*(latitude-35.0)
   + 0.1*sqrt(abs(longitude-105.0))
   + (20.0*sin(6.0*(longitude-105.0)*PI()) + 20.0*sin(2.0*(longitude-105.0)*PI())) * 2.0/3.0
   + (20.0*sin((longitude-105.0)*PI()) + 40.0*sin((longitude-105.0)/3.0*PI())) * 2.0/3.0
   + (150.0*sin((longitude-105.0)/12.0*PI()) + 300.0*sin((longitude-105.0)*PI()/30.0)) * 2.0/3.0
  ) * 180.0
) / (
  6378137.0
  / sqrt(1 - 0.00669342162296594323*sin(latitude/180.0*PI())*sin(latitude/180.0*PI()))
  * cos(latitude/180.0*PI())
  * PI()
)
```

> 📌 算法来源：[eviltransform](https://github.com/googollee/eviltransform)（WGS-84 → GCJ-02 标准实现），精度误差 < 0.5 米。

---

### 注意事项

- 上述修改仅在 **Grafana 界面手动编辑**，不影响底层数据库中的原始坐标
- 如果你在中国大陆以外使用，**不需要做此改动**，OSM 原版即可
- 修改后如需恢复 OSM，把底图 URL 改回 `https://tile.openstreetmap.org/{z}/{x}/{y}.png`，SQL 改回原始 `latitude` / `longitude` 即可

---

## 下一步

安装完成后，建议阅读：

| 文档 | 内容 |
|------|------|
| [SCENE_GUIDE.md](SCENE_GUIDE.md) | 什么场景看什么 Dashboard |
| [DASHBOARD_MAP.md](DASHBOARD_MAP.md) | 40 个 Dashboard 导航地图 |
| [METRICS_GUIDE.md](METRICS_GUIDE.md) | 各项数据指标解释 |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | 遇到问题怎么解决 |

---

**遇到问题？** 提交 [GitHub Issue](https://github.com/wjsall/teslamate-chinese-dashboards/issues)
