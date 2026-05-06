# 新手向导 — 从零开始使用 TeslaMate 中文 Dashboard

> 没用过 Docker？没关系。本文用最简单的方式带你完成安装。

---

## 第一步：搞清楚它是什么

### TeslaMate 是什么？
TeslaMate 是一个**开源**的特斯拉数据记录工具。它会自动收集你的车辆数据（每次行程、充电、电池状态等），保存在你自己的服务器上。数据完全属于你，不经过任何第三方。

### 本项目是什么？
TeslaMate 官方的 Grafana 图表是英文的。本项目提供了 **43 个简体中文汉化版图表**（含 12 个原创分析仪表盘），把所有界面翻译成中文，开箱即用。

### 🌟 中文版独有亮点

- 🌏 **地图源一键切换 + 自动 GCJ-02 坐标纠偏（v1.4.2+ 独家）** —— 仪表盘顶部下拉框秒切 OSM / 高德 / 高德卫星 / 谷歌 / 谷歌卫星 / Carto，国内用户车辆轨迹精准贴合道路（不再偏移 100~700m）。**这是 TeslaMate 原版没有的，全中文社区独有。**
- 🆕 **12 个原创分析仪表盘** —— 年度驾驶报告、省钱分析、充电健康管理、停车掉电分析、出行规律、动能回收、驾驶评分、续航退化、多车对比
- 🇨🇳 **国内网络优化** —— 默认使用 Docker Hub 镜像（国内加载更稳），可一键切换高德地图（直连国内 CDN），可配置 Tesla 中国区 API 地址

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

## 第二步：准备机器和工具

### 你需要怎样一台机器？

TeslaMate 需要 **一台一直开机的机器**（关机就停止记录数据，但已存的数据不会丢）。三种常见选择，挑一个适合你的：

| 场景 | 适合谁 | 上手难度 |
|------|--------|----------|
| **A. 家里的 NAS**（群晖/威联通等） | 已有 NAS 的家庭用户 | ⭐⭐⭐ |
| **B. 云服务器**（阿里云/腾讯云/AWS Lightsail 等，1GB 起 / 推荐 2GB） | 想用公网 IP 远程访问的用户 | ⭐⭐ ⚠️ [必读安全章节](#cloud-security) |
| **C. 你自己的电脑**（Mac / Windows / Linux） | 只想试试看，**电脑要一直开着** | ⭐ |

> 📌 **拿不准？直接选 C** —— 在自己电脑上跑个把月再决定要不要换 NAS / 云服务器。本文剩下的步骤都通用。

### ✅ 配置最低要求

| 条件 | 说明 |
|------|------|
| **最低 1GB 内存（推荐 2GB）** | TeslaMate 官方最低要求 1GB，2GB 流畅；树莓派 3 / 入门 VPS 也能装 |
| **10GB 以上磁盘空间** | 用于数据库和镜像 |
| **网络能访问 Tesla 服务器** | 国内访问 `*.cloud.tesla.cn`，国际访问 `*.teslamotors.com` |

### 第一关：打开「终端」/ 命令行

后面的所有命令都要在「终端」里运行。不同系统打开方式不一样：

**macOS：**
- 按 <kbd>⌘</kbd> + <kbd>空格</kbd> 打开聚焦搜索 → 输入 `终端` → 回车
- 或在「应用程序 → 实用工具」里找「终端」

**Windows：**
- 按 <kbd>Win</kbd> 键 → 输入 `PowerShell` → 回车
- 或安装 [Git for Windows](https://git-scm.com/download/win)，用里面的「Git Bash」（更接近 Linux 体验，推荐）

**Linux：**
- 按 <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>T</kbd>，或菜单里找「Terminal」

> 终端打开后，是个黑色或白色窗口，光标在闪。后面的命令都是**复制粘贴 → 回车** 就行。

### 第二关：连到你的「服务器」（如果是 NAS / 云服务器）

如果你选了 **场景 A（NAS）** 或 **场景 B（云服务器）**，需要 SSH 远程连进去再操作。**场景 C（自己电脑）跳过这一步。**

```bash
# 在你的本机终端里跑（替换成你的服务器 IP 和用户名）
ssh 用户名@服务器IP

# 例：阿里云 Ubuntu 服务器
ssh root@1.2.3.4

# 例：群晖 NAS
ssh admin@192.168.1.100
```

第一次 SSH 会问 `Are you sure you want to continue connecting?` 输入 `yes` 回车；然后输入服务器密码（输入时不会显示，正常）。

> 🆘 不知道服务器 IP？阿里云/腾讯云在控制台「实例详情」找；群晖在「控制面板 → 网络」看 LAN IP。

### 第三关：装 Docker（如果还没装）

在终端（本机或 SSH 连接里）跑：

**Ubuntu / Debian / 大部分云服务器：**
```bash
curl -fsSL https://get.docker.com | bash
sudo usermod -aG docker $USER
# 退出重新 SSH 登录后生效（场景 A/B），或重启电脑（场景 C）
```

**macOS（场景 C）：**
下载安装 [Docker Desktop](https://www.docker.com/products/docker-desktop/)，装完打开应用，等顶部菜单栏 Docker 图标变绿。

**Windows（场景 C）：**
通过 WSL2 安装 [Docker Desktop](https://www.docker.com/products/docker-desktop/)（需要 Windows 10 版本 2004+）。装完启动 WSL2 + Docker Desktop。

**群晖 NAS（场景 A）：**
在套件中心搜索「Container Manager」（DSM 7.2+）或「Docker」（旧版），安装即可。

### 第四关：验证 Docker 装好了

终端里跑：
```bash
docker --version
docker compose version
```

两条都有输出（例如 `Docker version 28.5.1` / `Docker Compose version v2.40.1`）就表示装好了。

> ❌ 报 `command not found`？
> - 装完没重新登录终端 → 关掉终端窗口，再开一个
> - 装完没启动 Docker Desktop（macOS/Windows）→ 启动它
> - Linux 上 `docker compose version` 报错而 `docker --version` OK → 你装的是老版 docker-compose-plugin，跑 `docker-compose version`（中间有横线）也行

---

## 第三步：一键安装

> 🎯 **小白直接看「方法 A」就行，方法 B 看不懂跳过没事**。
> 方法 A 是脚本帮你做完所有配置；方法 B 给已经熟 Docker、想改 ports/volumes/路径的人用。

### ⭐ 方法 A：一键脚本（强烈推荐）

在终端里运行以下两条命令（复制粘贴 → 回车 → 等 5 分钟）：

```bash
curl -fsSLO https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/simple-deploy.sh
bash simple-deploy.sh
```

脚本会自动：
- 创建 `~/teslamate-chinese/` 工作目录
- 生成 `docker-compose.yml` 配置文件
- **生成随机的 ENCRYPTION_KEY**（用来加密 Tesla Token 的密钥）
- 启动所有服务（TeslaMate / PostgreSQL / Grafana / MQTT，共 4 个容器）
- **自动安装地图坐标转换函数**（v1.4.2 新功能，不再需要手动操作）

### ⚠️ 装完立即做：备份你的 ENCRYPTION_KEY

脚本自动生成的密钥写在 `~/teslamate-chinese/docker-compose.yml` 里。**这个密钥用来加密你的特斯拉 Token，一旦丢了或被改，TeslaMate 就解不开 Token 永远卡死，必须重新授权。**

立刻执行（找出来 → 备份）：

```bash
grep ENCRYPTION_KEY ~/teslamate-chinese/docker-compose.yml
```

输出大概长这样：
```
- ENCRYPTION_KEY=a3f5b8c9d2e1f4...（一串 64 位十六进制字符）
```

**把这一整串复制到密码管理器或安全的笔记里。** 万一以后哪天 docker-compose.yml 被不小心动了，还能照着原样恢复。

> **🇨🇳 中国大陆用户镜像加速（如果脚本卡在 "Pulling image..."）：**
> 脚本默认用 Docker Hub 镜像（`bswlhbhmt816/teslamate-chinese-dashboards`），国内多数能直连。如果还是慢/失败：
> ```bash
> # 配置 Docker 镜像代理（需要 root 权限）
> sudo tee /etc/docker/daemon.json <<EOF
> {"registry-mirrors": ["https://docker.1ms.run", "https://docker.m.daocloud.io"]}
> EOF
> sudo systemctl daemon-reload && sudo systemctl restart docker
> # 然后回到 ~/teslamate-chinese/，重新跑：docker compose pull && docker compose up -d
> ```

---

### 方法 B：手动 Docker Compose（已熟 Docker 的可以来看）

> ⚠️ 不建议小白用此方法 —— 方法 A 已经完整够用，方法 B 是给想改 ports / volumes / 自定义路径的人。

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
    image: bswlhbhmt816/teslamate-chinese-dashboards:latest    # 默认 Docker Hub（国内访问稳定）
    # image: ghcr.io/wjsall/teslamate-chinese-dashboards:latest  # 备选 GHCR
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

<a id="step-4"></a>

## 第四步：首次登录 TeslaMate

安装完成后，按照以下步骤完成车辆绑定：

### 1. 打开 TeslaMate
在浏览器中访问：`http://服务器IP:4000`

#### 「服务器 IP」是什么？怎么查？

| 你装在哪里 | 浏览器输入 | 怎么查 IP |
|-----------|-----------|-----------|
| **本机**（场景 C：自己电脑） | `http://localhost:4000` | 不用查，写 `localhost` 就行 |
| **同一局域网的 NAS / 树莓派**（场景 A） | `http://192.168.x.x:4000` | NAS 控制面板「网络」看 LAN IP；或在 NAS 终端跑 `hostname -I` |
| **云服务器**（场景 B） | `http://公网IP:4000` | 阿里云/腾讯云控制台「实例详情」找「公网 IP」；或在服务器上跑 `curl ifconfig.me` |

> ⚠️ **云服务器还得在控制台开放 4000 和 3000 端口安全组**，否则浏览器连不上。阿里云：实例 → 安全组 → 配置规则 → 入方向 → 添加 4000 和 3000。
>
> 🔴 **但开放公网前请先看 [云服务器安全防护章节](#cloud-security)** —— TeslaMate 主页 `:4000` 默认无认证，直接公网开放任何人都能看你的车辆位置和历史行程。

### 2. 授权 Tesla 账号

> ⚠️ **TeslaMate 3.0 已移除浏览器内 OAuth 登录**（不再有 `Sign in with Tesla` 大按钮）。**唯一登录方式 = 用 Auth for Tesla App 拿 Token 后粘贴**。

**为什么这样：**
- 你手机上的 Tesla App 已经是登录状态 → 用同一个手机打开 Auth for Tesla → 一次完成授权
- TeslaMate 会从 token 自动识别中国区 / 国际，**不用改 docker-compose.yml、不用配 TESLA_API_HOST、不用重启服务**
- TeslaMate 拿到 Token 后自动续期（用 refresh_token 换新的 access_token），不需要你每天换

**步骤：**

**1. 下载工具拿 Token（推荐 ⭐：tesla_auth 桌面版，TeslaMate 主作者维护）**

去 [github.com/adriankumpf/tesla_auth/releases](https://github.com/adriankumpf/tesla_auth/releases) 选**最新 release**，下载对应平台的包：
- **macOS（Apple Silicon M1/M2/M3）**：找文件名带 `aarch64-apple-darwin` 的
- **macOS（Intel）**：找 `x86_64-apple-darwin`
- **Windows**：找 `x86_64-pc-windows-msvc`
- **Linux**：找 `x86_64-unknown-linux-gnu`（ARM 版找 `aarch64-unknown-linux-gnu`）

> ⚠️ 后缀名（`.tar.xz` / `.zip` / `.tar.gz`）作者偶尔会调，**以 release 页面当下提供的为准**

解压后双击运行，弹出 GUI 让你登录 Tesla 账号 → 两段 token 直接显示在窗口里复制即可。**作者是 TeslaMate 主作者 Adrian Kumpf，开源、可信、跨平台、不依赖 App Store**。

**国内备选：**
- iOS：「Auth for Tesla」App（[App Store 链接](https://apps.apple.com/us/app/auth-for-tesla/id1552058613)），**需要美区 / 港区 Apple ID 才能下载**——国内大陆 Apple ID 看不到这个 App
- Android：国内 Google Play 多数装不了，建议借家人 iPhone 装上面那个 App，或者用 macOS / Windows 桌面跑 tesla_auth

**2. 工具里登录你的 Tesla 账号**

输入特斯拉账号密码，完成两步验证。工具会显示两段字符串：
- `access_token` —— 一长串，约 2000 字符
- `refresh_token` —— 一长串，约 100 字符

**两段都复制保存到密码管理器或备忘录**（refresh_token 是长期凭证，丢了得重新走一遍）。

**3. 在 TeslaMate 登录页粘贴 Token**

浏览器打开 `http://服务器IP:4000`，登录页直接显示两个输入框：
- `Access Token` ← 粘贴 access_token
- `Refresh Token` ← 粘贴 refresh_token

点 `Sign in`，**绑定完成**。

> ⚠️ tesla_auth 和 Auth for Tesla 都是开源工具，在你的电脑/手机本地完成 Tesla 登录，**不会把密码上传到任何服务器**。但仍然要**在你信任的设备上用**（自己的 Mac / iPhone，不要在公司公用机器上跑）。

> **登录失败排查：**
> - `Tokens are invalid` → token 过期，回 Auth for Tesla App 重新生成一对
> - `account_locked` → 失败次数过多被锁，去特斯拉 App 重置密码后再来
> - 长时间转圈无响应 → 检查服务器能否访问 `owner-api.vn.cloud.tesla.cn`（国内）/ `owner-api.teslamotors.com`（国际）

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

登录后你会看到左侧导航栏，点击 **Dashboards** 查看所有 43 个中文图表。

**推荐第一次看这几个：**
1. **概览** — 车辆当前整体状态
2. **最近车辆状态** — 实时电量、续航、位置
3. **充电记录** — 历史充电记录

---

## 第六步：✅ 装完了？跑这个清单确认

如果以下 6 项都打勾，说明装得没问题：

```bash
cd ~/teslamate-chinese     # 方法 A 用户；方法 B 改成你的目录
docker compose ps
```

- [ ] **4 个容器都在跑** —— 输出里能看到 `teslamate`、`database`、`grafana`、`mosquitto`，状态都是 `Up` 或 `running (healthy)`
- [ ] **TeslaMate 网页能开** —— 浏览器打开 `http://服务器IP:4000`，看到登录页
- [ ] **Grafana 网页能开** —— 浏览器打开 `http://服务器IP:3000`，看到登录页
- [ ] **TeslaMate 已绑定车辆** —— 登录 TeslaMate 后能看到你的车，状态是 `online` / `asleep` / `driving` 等（不是 `unauthenticated`）
- [ ] **Grafana 有 43 个仪表盘** —— 登录 Grafana 后左侧 `Dashboards` 菜单，能看到「TeslaMate」文件夹下 43 个图
- [ ] **数据开始同步** —— 跑 `docker compose logs -f teslamate` 能看到类似 `Fetching vehicle data` 的日志（按 <kbd>Ctrl</kbd>+<kbd>C</kbd> 退出查看）

> 任何一项不通过 → 看 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)，或直接到本节末尾的「卸载/重置」部分清空重装。

---

## 第七步：安装后必做的 5 件事

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

## 装完了？下一步看哪些仪表盘？

车辆数据要积累几天才有意思（行程 / 充电至少各 5 次）。这期间先认识下仪表盘：

<a id="first-5"></a>

### 🎯 第一周必看 5 个

1. **「概览」** — 车辆健康度全景看板，电池 / 续航 / 累计里程一眼到位
2. **「驾驶记录追踪」** — 每次行程的 GPS 路线 + 速度曲线（**国内用户记得切「高德地图」**：仪表盘顶部「地图源」下拉框）
3. **「充电记录」** — 历次充电时间 / 度数 / 费用，**国内用户先去「⚡ 分时电价配置」配峰平谷**，所有费用瞬间变真实
4. **「电池健康度」** — 看你电池退化曲线（开几个月才有意思）
5. **「省钱分析」** — 跟你之前燃油车的对比，"开电车一年省了多少钱"

### 📚 进阶玩法（积累 1 个月数据后）

- **「年度驾驶报告」** — 总里程 / 充电费 / 常去地点 TOP10
- **「驾驶评分」** — 油门 / 刹车 / 转弯激进度评分
- **「天气-能耗关联」** — 量化温度对续航的影响（国内冬天痛点）
- **「充电桩性价比榜」** — 你常去的充电桩按 ¥/度 排序

### 完整 43 个仪表盘说明

详见 [DASHBOARD_MAP.md](DASHBOARD_MAP.md) 和 [SCENE_GUIDE.md](SCENE_GUIDE.md)（场景速查：「这个数据看哪个仪表盘」）。

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
A: TeslaMate 3.0 起，国内账号**不需要改任何环境变量**——粘贴中国区 token 后会自动用 `*.cloud.tesla.cn`。仅镜像拉取可能慢，需要配镜像加速器，详见 README [中国大陆专项配置](README.md#cn-region)。

**Q: 怎么更新到新版本？**
A: 详见 [README → ⚡ 升级到 v1.6.x](README.md#upgrade-v16) 的方法 A/B/C/D（按你之前怎么装的选）。

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

## 🌏 地图源切换 + 自动 GCJ-02 坐标纠偏（v1.4.2+）

> **国内 TeslaMate 用户痛点 3 年终结。**
>
> 原版只支持 OpenStreetMap，国内加载慢得像挤牙膏；想换高德要手动改 9 个面板的 XYZ URL，git pull 又被覆盖；切完高德车辆轨迹还偏离道路 100~700 米，因为高德是 GCJ-02 坐标系而 TeslaMate 存 WGS-84 —— 想纠偏就得手写一坨复杂三角函数 SQL。
>
> 本项目 v1.4.2 把这一切变成两步操作。**海外用户也别走开 —— 谷歌中文路网在中国大陆区域同样是 GCJ-02，本方案一并自动处理。**

### 一步：装一次 PostgreSQL SQL 三件套（坐标函数 + 分时电价 + 性能索引）

**新装用户（v1.4.2+ 一键脚本装的）跳过本节** —— 一键脚本已自动装好。

**老版本升级 / 手动验证**：升级路径已统一在 README 顶部，按方法 A/B/C/D 任选一条跑：

→ 详见 **[README → ⚡ 升级到 v1.6.x](README.md#upgrade-v16)**

装成功标志：执行返回 `坐标转换函数安装成功 (天安门测试通过): (39.91522, 116.40407)` 自检通过提示。一次性安装，后续所有仪表盘自动生效。

容器名不一定叫 `teslamate-database-1`，先 `docker ps --format '{{.Names}}' | grep -i database` 确认。

装失败排查见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md) 「装 PostgreSQL 坐标转换函数报错」章节。

### 二步：在仪表盘上切换地图源

含地图的 9 个仪表盘顶部都有「**地图源**」下拉框：

| 选项 | 推荐场景 | 坐标系 | 网络要求 |
|------|---------|--------|---------|
| **OpenStreetMap** | 默认/全球通用 | WGS-84 | 国内访问慢（无 CDN） |
| **高德地图** | 中国大陆首选 | GCJ-02（自动纠偏） | 国内直连 |
| **高德卫星** | 中国大陆卫星俯瞰 | GCJ-02（自动纠偏） | 国内直连 |
| **谷歌地图** | 海外华人首选（中文路网） | GCJ-02 中国区域（自动纠偏） | 海外直连/国内需翻墙 |
| **谷歌卫星** | 海外卫星视图（高清） | WGS-84 | 海外直连/国内需翻墙 |
| **Carto 浅色** | 极简风格、深色主题底图 | WGS-84 | 全球可达 |

切换地图源后，PostgreSQL 函数会根据新 URL 自动判断是否要做 GCJ-02 转换：选高德/谷歌路网 → 转；选 OSM/Carto/谷歌卫星 → 不转。**车辆轨迹永远贴合道路。**

### 9 个含地图的仪表盘

| 仪表盘 | 路径 |
|--------|------|
| 当前充电状态 | `/d/CurrentChargeView` |
| 当前驾驶状态 | `/d/CurrentDriveView` |
| 最近车辆状态 | `/d/CurrentState` |
| 驾驶记录追踪 | `/d/TrackingDrives` |
| 充电统计（汇总） | `/d/charging-stats` |
| 行程统计（时间段） | `/d/trip` |
| 访问过的地点 | `/d/visited` |
| 充电详情（内部跳转） | `/d/charge-details` |
| 行程详情（内部跳转） | `/d/drive-details` |

### 长期固化某个地图源（避免 git pull 重置）

默认值是 OpenStreetMap。每次 git pull 后下拉框会回到默认值。要长期用某个特定源，把 URL 参数加进浏览器书签：

```
http://你的Grafana/d/CurrentDriveView?var-map_url=https%3A%2F%2Fwprd01.is.autonavi.com%2Fappmaptile%3Flang%3Dzh_cn%26size%3D1%26scale%3D1%26style%3D7%26x%3D%7Bx%7D%26y%3D%7By%7D%26z%3D%7Bz%7D
```

`var-map_url=` 后面接 URL 编码后的瓦片地址。书签每次打开自动套用。

### 工作原理（给好奇的同学）

#### GCJ-02 是啥

中国出于地理信息安全考虑，规定境内地图厂商必须用 **GCJ-02（火星坐标系）**，相对国际标准 WGS-84 在中国境内非线性偏移 100~700 米。所以高德/百度/腾讯/谷歌（中国区域）瓦片都是 GCJ-02；OSM/Carto/谷歌卫星是 WGS-84。

#### 怎么自动判断

`sql/install-coord-functions.sql` 装了 4 个函数：

```sql
wgs84_to_gcj02_lat(lat, lng) -- 算法实现
wgs84_to_gcj02_lng(lat, lng)
lat_for_map(map_url, lat, lng)  -- 包装：URL 含 autonavi 或 google.com 路网 → 转，否则原样返回
lng_for_map(map_url, lat, lng)
```

9 个 geomap 面板 SQL 把原本的 `latitude, longitude` 替换成 `lat_for_map('${map_url}', latitude, longitude) AS latitude` 这种调用。Grafana 把当前选中的 URL 注入 SQL，函数按 URL 决定要不要转。

中国境外坐标自动短路（不转换），海外用户切回 OSM 等 WGS-84 源时无副作用。NULL 输入返回 NULL，数据完整性安全。

#### 算法精度

基于 [eviltransform](https://github.com/googollee/eviltransform) 标准实现，中国境内误差 < 0.5 米。北京天安门 WGS-84 (39.913818, 116.397828) → GCJ-02 (39.91522, 116.40407)，自检通过即可放心使用。

---

## ⚡ 分时电价配置（v1.5.0+）

国内电网普遍有峰平谷电价。TeslaMate 默认只能存一个固定单价，没法反映真实的家充成本。v1.5.0 加了完整的 分时电价系统：在线配置时段单价、自动算每笔充电的真实费用、所有费用面板透明替换。

**没装分时电价的用户**：所有功能回退到原 `cp.cost`，**无任何感知差异**。装分时电价 是可选的，看你需不需要。

### 适合谁？

- ✅ 家里安了私人充电桩，电价是按峰平谷计费的
- ✅ 想知道「我家充实际花了多少钱」「凌晨充比白天便宜多少」
- ✅ 多车家庭，想看每辆车在家充了多少
- ❌ 只用第三方充电桩（特来电/星星/小桔），它们 App 直接显示费用，分时电价用处不大

### 3 步配好

> **先决条件**：你的 TeslaMate 已经升到 v1.5.0+（v1.6.1 当前最新）。还在 v1.4.x 的用户先按 [README → ⚡ 升级到 v1.6.x](README.md#upgrade-v16) 升级；新装用户跳过下面 step 1 直接看 step 2。

#### 1. 升级（仅 v1.4.x 老用户）

```bash
bash scripts/upgrade.sh
```

upgrade.sh 自动 7 步（git pull → 检测 PG → 装地图函数 → 装分时电价 → 装性能索引 → 检查 Grafana 插件 → 重启 Grafana）。

#### 2. 配分时电价（5 步交互式向导）

```bash
bash scripts/tou-wizard.sh
```

按提示选：
1. 你城市（北京/上海/深圳/广州/浙江/江苏 共 6 个内置模板，2025 年参考价）
2. 应用到哪个地理围栏（在 TeslaMate 里你设的「家」围栏）
3. 是否按账单微调单价（按你电费账单实际数字改）
4. 快充是否单独算（一般跳过，超充按运营商 App 真实付款最准）
5. 试算最近一笔家充对账

或者打开 Grafana 的「**⚡ 分时电价配置**」仪表盘 →「**🌆 一键导入城市模板**」一键套用。

#### 3. 把历史充电按分时电价重算

配分时电价 **之前**已经发生的充电不会自动重算，跑一下 backfill：

```bash
docker exec teslamate-database-1 psql -U teslamate -d teslamate -c "SELECT backfill_all_tou()"
```

或在「⚡ 分时电价配置」仪表盘最下方点「**🔄 重算所有历史充电**」按钮。

### 配完了去哪里看？

- **「⚡ 分时电价配置」仪表盘** —「💰 最近 10 笔家充对账」直接看 分时 vs 原价差额
- **「🏆 充电桩性价比榜」仪表盘**（v1.5.0 新增）— 按 ¥/度 排序所有充电点，家充按分时 算
- **充电费用统计 / 省钱分析 / 年度报告** — 9 个仪表盘 60+ 处 SQL 自动按分时显示

### 不想要了怎么办？

完全可逆，**TeslaMate 任何表都没动**：

```bash
# 选项 A：清空 分时电价配置（保留函数 + 旁路表）
docker exec teslamate-database-1 psql -U teslamate -d teslamate \
  -c "TRUNCATE tou_rates RESTART IDENTITY CASCADE; TRUNCATE charging_processes_tou_cost"

# 选项 B：仪表盘 SQL 改回原 cost
python3 scripts/wrap-cost-with-tou-view.py --revert
```

### 详细文档

- [`sql/install-tou.sql`](sql/install-tou.sql) — 表/函数/触发器/视图全部 schema
- [`sql/install-indexes.sql`](sql/install-indexes.sql) — 性能索引（v1.6.1+）
- [`scripts/setup-tou.sh`](scripts/setup-tou.sh) — CLI 命令清单
- 「⚡ 分时电价配置」仪表盘内置审计面板 — 时段空缺/重叠/月份缺失自动检测

---

<a id="cloud-security"></a>

## ☁️ 云服务器场景：安全防护必读（场景 B 用户）

> **如果你装在自己电脑（场景 C）或家里 NAS（场景 A）上，可以跳过这一节** —— 默认局域网/本机不会被陌生人访问。
>
> **如果你装在公网可访问的云服务器（阿里云/腾讯云/AWS/Lightsail 等），请耐心读完。**

### ⚠️ 你必须先知道的事实

**TeslaMate 主界面（`:4000`）默认完全没有用户认证。** 任何人只要知道你的服务器公网 IP，浏览器输入 `http://你的IP:4000` 就能看到：
- 你车的当前位置（实时 GPS）
- 你车的所有历史行程（精确到米的轨迹）
- 你的家庭/公司地址（自动从地理围栏推断）
- 你的特斯拉账号 Token（虽然加密，但暴露在被入侵风险里）

**Grafana（`:3000`）默认账号是 `admin / admin`。** 不改的话陌生人扫到 IP 就能登入看完整数据。

**这就是为什么不能直接把端口暴露到公网。** 下面 5 级防护清单按优先级做。

### 🔴 必做 1：改 Grafana 默认密码

第一次登录 Grafana 后，**立即**改密码：

```
Grafana → 右上角头像 → Profile → Change Password
```

新密码至少 12 位，含大小写 + 数字。**这条不做的话其他防护都白搭。**

### 🔴 必做 2：选一种方式禁止公网直连，二选一

**TeslaMate `:4000` 没有任何认证，绝不能直接公网开放**。三种方式选一种：

#### 方案 A（最简单 ⭐）：Tailscale 虚拟内网

把云服务器和你的电脑/手机加进同一个 Tailscale 内网，访问就像在局域网。完全不需要把端口暴露到公网。

```bash
# 在云服务器上装 Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# 它会给你一个授权 URL，浏览器打开授权
# 完成后查 Tailscale IP（100.x.x.x）
tailscale ip -4
```

然后**关闭云服务器的安全组里 4000/3000 端口的公网入站规则**（只保留 SSH 的 22 端口），用 Tailscale IP 访问：`http://100.x.x.x:4000`。

> 同类替代：[ZeroTier](https://www.zerotier.com/)、[Netbird](https://netbird.io/)、[WireGuard](https://www.wireguard.com/) 自建。Tailscale 免费档够用（最多 100 台设备 / 3 用户）。

#### 方案 B：Cloudflare Tunnel（免费，自带 HTTPS）

不需要公网 IP，cloudflared 客户端打通隧道。Cloudflare 提供 HTTPS + DDoS 防护。

```bash
# 在云服务器上装 cloudflared
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared.deb

# 然后到 https://one.dash.cloudflare.com → Networks → Tunnels 创建隧道
# 跟着提示走，把 4000/3000 映射到自定义域名
```

完整教程：[Cloudflare Tunnel 官方文档](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/create-remote-tunnel/)。

> ⚠️ 国内服务器到 Cloudflare 的延迟可能不稳定。

#### 方案 C：Nginx / Caddy 反向代理 + HTTP Basic Auth + HTTPS

最灵活但最折腾。简化推荐用 [Caddy](https://caddyserver.com/) + Let's Encrypt 自动证书。

**步骤：**
1. 注册一个域名（阿里云/Namecheap 等）
2. 把域名 A 记录指向你云服务器公网 IP
3. 改 docker-compose.yml 把端口绑定从 `4000:4000` 改成 `127.0.0.1:4000:4000`（仅监听本地，不暴露公网）
4. 在云服务器装 Caddy，配置反向代理 + Basic Auth：

```caddyfile
# /etc/caddy/Caddyfile
teslamate.你的域名.com {
    basicauth {
        admin $2a$14$... # caddy hash-password 生成
    }
    reverse_proxy 127.0.0.1:4000
}
grafana.你的域名.com {
    basicauth {
        admin $2a$14$...
    }
    reverse_proxy 127.0.0.1:3000
}
```

启动 Caddy 即可。Caddy 会自动申请 Let's Encrypt 证书。Basic Auth 让陌生人扫到也进不来。

### 🟠 强烈推荐 1：安全组 IP 白名单

即使用了上面的方案，**云服务器安全组里也只开放你必要的入站规则**：
- 22（SSH）：限制到你常用的 IP（家庭固定 IP / 移动 4G 段 / 公司）
- 80/443（如果用方案 C）：开放 0.0.0.0/0
- **4000/3000：禁止 0.0.0.0/0**（除非你确定方案 A/B 已生效）

阿里云：实例 → 安全组 → 配置规则 → 入方向 → 设置「授权对象」为你的 IP 而非 `0.0.0.0/0`。

### 🟠 强烈推荐 2：SSH 加固

```bash
# 1. 禁用 root 密码登录，只允许 ssh key
sudo nano /etc/ssh/sshd_config
#   PermitRootLogin prohibit-password
#   PasswordAuthentication no
sudo systemctl restart sshd

# 2. 装 fail2ban 防止 SSH 暴力破解
sudo apt install fail2ban
sudo systemctl enable --now fail2ban
```

### 🟡 可选：限制 Docker 端口绑定到 localhost

即使不用反向代理，也可以让 docker-compose.yml 端口只绑定本机，避免容器直接监听公网：

```yaml
ports:
  - 127.0.0.1:4000:4000   # 改这里：加 127.0.0.1: 前缀
  - 127.0.0.1:3000:3000
```

这样必须先 SSH 进服务器，再 `curl localhost:3000` 才能访问。需要远程访问改用 SSH 隧道：
```bash
# 本地终端跑（替换 user@server）
ssh -L 3000:localhost:3000 -L 4000:localhost:4000 user@server
# 然后本地浏览器开 http://localhost:3000
```

### 部署模式安全等级对照

| 模式 | 难度 | 安全等级 | 推荐度 |
|------|------|---------|--------|
| 直接 4000/3000 暴露公网 | ⭐ | 🔴 危险 | ❌ 绝对不要 |
| 暴露公网 + 改 Grafana 密码 | ⭐ | 🔴 仍危险（TeslaMate 无认证） | ❌ 不要 |
| 安全组 IP 白名单（仅自己 IP） | ⭐⭐ | 🟡 中等 | ⚠️ 临时可用 |
| Tailscale / ZeroTier 虚拟内网 | ⭐⭐ | 🟢 高 | ✅ 推荐新手 |
| Cloudflare Tunnel | ⭐⭐⭐ | 🟢 高 | ✅ 推荐有域名的 |
| 反向代理 + Basic Auth + HTTPS | ⭐⭐⭐⭐ | 🟢 高 | ✅ 推荐有运维经验的 |

### 装完检查清单

- [ ] Grafana 密码已抄到密码管理器（v1.6.9 起脚本自动生成强随机；旧版 admin/admin 用户必须立刻改）
- [ ] 云服务器安全组 4000/3000 端口**未对 `0.0.0.0/0` 开放**
- [ ] 选了 Tailscale / Cloudflare Tunnel / 反代 三种方式之一并已配置
- [ ] SSH 用 key 登录而非密码（建议）
- [ ] 浏览器从外网（关掉 Tailscale / 不挂代理）尝试访问 `http://你的服务器公网IP:3000`，应该**连不上或加载失败**（说明已经隔离）

任何一项不通过，回头补齐再用。**云服务器的安全是一次性配置，配好后忘了它；不配的话哪天醒来发现行程被人扒走，悔之晚矣。**

---

## 想推倒重来？卸载 / 重置

### 仅停止服务（保留数据）

```bash
cd ~/teslamate-chinese
docker compose down
```

下次想再开：`docker compose up -d`，数据完整保留。

### 完全卸载（删除所有数据，无法恢复！⚠️）

> **🔴 警告：这会删掉所有行程历史、充电记录、电池数据，且不可逆。先想清楚要不要备份再做。**

**第 1 步：备份（可选但强烈推荐）**

```bash
cd ~/teslamate-chinese
docker compose exec database pg_dump -U teslamate teslamate > backup_$(date +%Y%m%d).sql
# 备份文件保存在当前目录，万一以后想还原就有
```

**第 2 步：停服务并删容器+数据卷**

```bash
cd ~/teslamate-chinese
docker compose down -v        # -v 表示一并删除数据卷（最关键的一步）
```

**第 3 步：删工作目录**

```bash
rm -rf ~/teslamate-chinese
```

**第 4 步：可选 —— 删镜像（释放磁盘）**

```bash
docker rmi bswlhbhmt816/teslamate-chinese-dashboards
docker rmi teslamate/teslamate
docker rmi postgres:18-trixie
docker rmi eclipse-mosquitto:2
```

**清空之后，可以从「第三步：一键安装」重头来过。** 你的 `ENCRYPTION_KEY` 可以重新生成（不影响新装），但如果有备份的 `backup_xxx.sql` 想还原就需要用同一个旧 KEY。

---

## 下一步

安装完成后，建议阅读：

| 文档 | 内容 |
|------|------|
| [SCENE_GUIDE.md](SCENE_GUIDE.md) | 什么场景看什么 Dashboard |
| [DASHBOARD_MAP.md](DASHBOARD_MAP.md) | 43 个 Dashboard 导航地图 |
| [METRICS_GUIDE.md](METRICS_GUIDE.md) | 各项数据指标解释 |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | 遇到问题怎么解决 |

---

**遇到问题？** 提交 [GitHub Issue](https://github.com/wjsall/teslamate-chinese-dashboards/issues)
