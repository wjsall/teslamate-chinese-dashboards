# TeslaMate 中文 Grafana Dashboard

**TeslaMate Chinese Grafana Dashboards** — Simplified Chinese localization for TeslaMate, ready to use out of the box.

简体中文汉化版 TeslaMate Grafana Dashboard - 开箱即用 | 43 个仪表盘 99% 汉化 | 支持 Docker 一键部署

---

<a id="upgrade-v16"></a>

> ## ⚡ 升级到 v1.6.x — 分时电价 + 性能索引（中文版独有）
>
> **v1.5.0 起的中文版独有功能**：
> - 🆕 「⚡ 分时电价配置」仪表盘 — 在线配置峰平谷电价 + 配置审计 + 24 小时电价分布
> - 🆕 「🏆 充电桩性价比榜」仪表盘 — 按 ¥/度 排序所有充电点
> - 🌡️ 「天气-能耗关联」仪表盘（v1.6.0）— 国内 #1 痛点「冬天到底掉多少电」量化版
> - 🚀 positions 表性能索引（v1.6.1）— 电池健康/行程列表/能耗聚合等查询从 200ms 降到 < 5ms
> - 🔧 9 个仪表盘 60+ 处 SQL 自动适配分时电价
> - **没装分时电价的用户无任何感知差异**（所有面板回退到原 `cp.cost`）
>
> 按你当时怎么装的，选一种：
>
> | 你之前怎么装的？ | 用哪个 |
> |---|---|
> | **没装过**（全新用户） | 跳到下方 [快速开始](#-快速开始) |
> | **官方源**（grafana 是 `teslamate/grafana`） | [方法 D](#upgrade-method-d) |
> | 跟 jheredianet 教程装的（手动 import dashboard JSON） | [方法 D](#upgrade-method-d) — 但**先 export 你改过的 dashboard JSON 备份**，迁移会用我们这一套替换 |
> | 用了我们的 `simple-deploy.sh` | [方法 A](#upgrade-method-a) |
> | `git clone` 了我们仓库 | [方法 B](#upgrade-method-b) |
> | 自己写 docker-compose 套了我们镜像 | [方法 C](#upgrade-method-c) |
>
> <a id="upgrade-method-a"></a>
>
> ### 方法 A — 一键脚本用户（之前用 `simple-deploy.sh` 装的）
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/simple-deploy.sh | bash
> ```
>
> 脚本自动检测现有安装 → 切升级模式（拉新镜像 + 装新 SQL 函数 + 重启 Grafana）。**不会重置 ENCRYPTION_KEY 或配置**。
>
> <a id="upgrade-method-b"></a>
>
> ### 方法 B — git clone 用户（之前 `git clone` 仓库装的）
>
> ```bash
> cd teslamate-chinese-dashboards
> bash scripts/upgrade.sh
> ```
>
> 自动 7 步：git pull → 检测 PG → 装地图函数 → 装分时电价 → 装性能索引（v1.6.1+）→ 检查 Grafana 插件 → 重启 Grafana。**重复跑不会丢数据**。
>
> <a id="upgrade-method-c"></a>
>
> ### 方法 C — 手动派（自己写 docker compose 套了我们镜像的）
>
> ```bash
> # 1. 拉新镜像（带 volkovlabs-form-panel 插件 + 43 个仪表盘 — 该插件给「⚡ 分时电价配置」面板提供按钮交互）
> docker compose pull && docker compose up -d
>
> # 2. 装 SQL 三件套（坐标函数 + 分时电价 + 性能索引，远程 curl 不用 git clone）
>
> # 默认用 main（跟 :latest 镜像同步）。担心仓库被劫持的话把 main 替换成具体 tag（如 v1.6.2）锁版本：
> REF=main   # 或 v1.6.2
>
> # 自动找 database 容器名（你的项目目录不叫 teslamate 时容器名会不同，直接 ps 拿）
> DB=$(docker compose ps -q database)
> [ -z "$DB" ] && { echo "❌ database 容器没起来，先跑 docker compose up -d 再来"; exit 1; }
>
> for f in install-coord-functions install-tou install-indexes; do
>   curl -fsSL "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REF}/sql/${f}.sql" \
>     | docker exec -i "$DB" psql -U teslamate -d teslamate
> done
>
> # 3. 重启 Grafana
> docker compose restart grafana
> ```
>
> Watchtower 自动升镜像的用户每次升级后**只需要重跑这一段**就能拿到最新 SQL 改动（函数 / 索引 / TOU）。脚本是 `IF NOT EXISTS / CREATE OR REPLACE`，重跑零风险。详见 [SQL 远程拉取的安全注意](#sql-trust-model)。
>
> <a id="upgrade-method-d"></a>
>
> ### 方法 D — 从官方源迁移（你以前是 `teslamate/grafana`）
>
> ```bash
> curl -fsSLO https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/migrate-from-official.sh
> bash migrate-from-official.sh
> ```
>
> 脚本预检 docker daemon + compose CLI（v1/v2 都识别）→ 找 `docker-compose.yml`（含 v2 新 `compose.yml`）→ 备份（mode 600，含 ENCRYPTION_KEY）→ 改 grafana 镜像 → 拉新镜像 → 探测 database 容器名 → 装 SQL。**TeslaMate / Postgres / MQTT 完全不动，ENCRYPTION_KEY 和数据 0 丢失**。脚本结尾会打印一行 `cp + $DC up -d` 的回滚命令，复制粘贴即可回去。
>
> ⚠️ 在 Grafana 里手动改过 dashboard 的，先到「仪表盘 → ⋮ → Export」备份 JSON，迁移完再 Import 回来 —— 我们的镜像会用我们这一套覆盖。
>
> ### 配分时电价（可选，约 3 分钟）
>
> ```bash
> bash scripts/tou-wizard.sh                 # 5 步交互式向导（git clone 用户）
> ```
>
> 或直接打开「**⚡ 分时电价配置**」仪表盘 →「**🌆 一键导入城市模板**」选你城市，配完点「**🔄 重算所有历史充电**」按钮把历史按分时电价重算。
>
> ### 升级前必读：先备份
>
> 任何升级（含 v1.6.x → v1.6.x、PG 大版本升级）前都强烈建议先做完整数据库备份：
> ```bash
> docker compose exec -T database pg_dump -U teslamate teslamate > backup_$(date +%Y%m%d).sql
> ```
> 详见 [TeslaMate 官方 backup_restore](https://docs.teslamate.org/docs/maintenance/backup_restore) + [我们的 TROUBLESHOOTING「整机迁移」](TROUBLESHOOTING.md)。
>
> ### 升级出问题？完全可逆
>
> TeslaMate 任何表都没动，分时电价数据全在我们新建的旁路表。详见 [TROUBLESHOOTING.md「v1.5.0 分时电价升级排错 / 回滚」](TROUBLESHOOTING.md#tou-rollback) | [Telegram 交流群](https://t.me/+BeOASgmvE_IyNzNl)
>
> ### v1.6.6+ 升级提示
>
> v1.6.6 修复了备份恢复跟 TeslaMate 官方流程不对齐的真 bug（缺 `DROP SCHEMA private` + `CREATE EXTENSION cube`）。**如果你做过整机迁移且遇到 token 解密失败被迫重新授权过**——那就是这个 bug，新版恢复流程不会再触发。详见 [v1.6.6 发版说明](https://github.com/wjsall/teslamate-chinese-dashboards/releases/tag/v1.6.6)。
>

---

> 🚗 基于 [TeslaMate](https://github.com/teslamate-org/teslamate) 项目的 Grafana Dashboard 汉化版本
>
> 📖 原版文档: https://docs.teslamate.org
>
> 🙏 早期汉化工作参考自 GitHub 用户 [@dhuar](https://github.com/dhuar) 的私有镜像 `ccr.ccs.tencentyun.com/dhuar/grafana:latest`，在此致谢

![GitHub Stars](https://img.shields.io/github/stars/wjsall/teslamate-chinese-dashboards?style=social)
![GitHub Forks](https://img.shields.io/github/forks/wjsall/teslamate-chinese-dashboards?style=social)
![GitHub Issues](https://img.shields.io/github/issues/wjsall/teslamate-chinese-dashboards)
![Build Status](https://github.com/wjsall/teslamate-chinese-dashboards/actions/workflows/ghcr-build.yml/badge.svg)
[![Telegram](https://img.shields.io/badge/Telegram-交流群-blue?logo=telegram)](https://t.me/+BeOASgmvE_IyNzNl)

## 📸 效果预览

### 🌡️ v1.6.0 新增：天气-能耗关联

国内特斯拉车主 #1 痛点「冬天到底掉多少电」量化版 — 温度桶能耗曲线柱色冷蓝→热红，一眼看出「16°C 最省 / 38°C 最费」的 U 型规律 + 月度双轴 + 季节对比。

![天气-能耗关联](screenshots/weather-efficiency.png)

### ⚡ v1.5.0 重磅功能：分时电价系统 + 充电桩性价比榜

**「⚡ 分时电价配置」** — 24 小时电价柱图自动配色（绿=谷 / 黄=平 / 橙=峰）+ 配置审计 + 5 步交互式向导
![分时电价配置](screenshots/tou-config.png)

**「🏆 充电桩性价比榜」** — 按 ¥/度 排序所有充电点（家充走分时电价、第三方走原价）+ 30 天涨/降价对比 + 充电桩地图
![充电桩性价比榜](screenshots/station-ranking.png)

### 🌏 v1.4.2 重磅功能：地图源一键切换 + 自动 GCJ-02 坐标纠偏

仪表盘顶部下拉框秒切 6 种瓦片源（OSM / 高德 / 高德卫星 / 谷歌 / 谷歌卫星 / Carto）。选高德或谷歌路网时 PostgreSQL 函数自动做 WGS-84 → GCJ-02 转换，车辆轨迹精准贴合道路。

![地图源切换](screenshots/map-source-switcher.png)

### 🆕 原创分析仪表盘

**年度驾驶报告** — 年度里程 / 充电 / 能耗 / 常去地点 TOP10
![年度驾驶报告](screenshots/annual-summary.png)

**省钱分析** — 与燃油车对比节省金额、充电时段分布、预算进度
![省钱分析](screenshots/cost-savings.png)

**充电健康管理** — 充电习惯评分、SOC 分布、充电次数趋势
![充电健康管理](screenshots/charging-health.png)

**停车掉电分析** — 掉电趋势、区间分布、最耗电停车 TOP20
![停车掉电分析](screenshots/sentry-drain.png)

**出行规律分析** — 时段分布、工作日 vs 周末、温度与能耗关系
![出行规律分析](screenshots/driving-patterns.png)

**动能回收分析** — 各固件版本回收率对比、每日/每周回收能量、温度影响
![动能回收分析](screenshots/regen-braking.png)

**多车对比** — 名下所有车辆里程/能耗/费用/电池健康横向对比，自动适配车辆数量
![多车对比](screenshots/vehicle-comparison.png)

**续航退化分析** — 满电续航趋势、线性回归退化率、月度统计、数据质量监控
![续航退化分析](screenshots/battery-degradation.png)

**驾驶评分** — 效率/平稳/速度/回收四维度评分、驾驶风格判定、行程明细与数据汇总
![驾驶评分](screenshots/driving-score.png)

---

### 核心仪表盘

| 概览 | 电池健康度 |
|------|-----------|
| ![概览](screenshots/overview.png) | ![电池健康度](screenshots/battery-health.png) |

| 里程统计 | 充电记录 |
|---------|---------|
| ![里程统计](screenshots/mileage-stats.png) | ![充电记录](screenshots/charges.png) |

| 电池容量曲线 | 行程追踪地图 |
|------------|------------|
| ![电池容量曲线](screenshots/charge-level.png) | ![行程追踪](screenshots/tracking.png) |

| 时间线 | 电池容量曲线（全量） |
|--------|-----------------|
| ![时间线](screenshots/timeline.png) | ![电池容量曲线2](screenshots/charge-level-2.png) |

---

## 🎯 特点

- ✅ **开箱即用** - 无需 Docker Hub 账号，直接挂载使用
- ✅ **一键安装** - 提供多种安装方式，5分钟完成部署
- ✅ **持续更新** - 通过 git pull 即可获取最新汉化
- ✅ **深度汉化** - 43 个 Dashboard，含12 个全新原创分析图表
- 🌏 **地图源一键切换（独有）** - 9 个含地图仪表盘顶部加 OSM / 高德 / 高德卫星 / 谷歌 / 谷歌卫星 / Carto 下拉框，秒切，自动 GCJ-02 坐标纠偏（v1.4.2+）
  - 国内用户告别手动改 SQL，海外华人用户也能用谷歌中文路网
- ✅ **完整适配 TeslaMate 3.0** - 同步官方全部新特性，已验证兼容 Grafana 12.4.0

## 📊 汉化成果

| 指标 | 数值 |
| --- | --- |
| Dashboard 数量 | 43个 ✅ |
| 内部详情页 | 3个（行程/充电详情）|
| 文件总大小 | ~1.2MB |
| 汉化完成度 | 99%+ |
| 质量等级 | A+ |
| 最后更新 | 2026-05-06 |

**43 个 Dashboard 深度汉化，持续优化中，开箱即用！** 🎉

## 📚 使用文档

我们为你准备了三份详细的使用指南：

| 文档 | 说明 | 适合人群 |
|------|------|----------|
| **[新手向导](QUICKSTART.md)** | 从零开始安装，含 FAQ | 完全新手 |
| **[功能地图](DASHBOARD_MAP.md)** | 43 个 Dashboard 分类导航 | 新用户 |
| **[场景速查手册](SCENE_GUIDE.md)** | 什么时候看什么 Dashboard | 所有用户 |
| **[数据指标手册](METRICS_GUIDE.md)** | 指标解释、正常范围、异常处理 | 进阶用户 |
| **[故障排查手册](TROUBLESHOOTING.md)** | 遇到问题按症状查解决方案 | 遇到问题时 |

**新手建议**：先看「新手向导」→「功能地图」→「场景速查手册」→「数据指标手册」

## 📁 包含的 Dashboard

**43 个仪表盘** ：核心 4 / 充电 14 / 驾驶 12 / 车辆状态 6 / 其他 7。完整功能列表 + 字段映射 → [DASHBOARD_MAP.md](DASHBOARD_MAP.md)

## 🚀 快速开始

按你的场景三选一：

| 你的情况 | 用方法 |
|---|---|
| **从零开始装**（没装过 TeslaMate） | 方法一 |
| **已经在用原版英文 TeslaMate**（想换中文） | 方法二 |
| **想自己写 docker-compose.yml + 挂仪表盘** | 方法三 |

### 方法一：一键脚本（推荐 ⭐）

适合**全新部署**的用户。脚本自动装 TeslaMate + PostgreSQL + Grafana 中文版 + Mosquitto，随机生成 ENCRYPTION_KEY 和数据库密码。

```bash
curl -fsSLO https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/simple-deploy.sh
bash simple-deploy.sh
```

跑完后看终端输出：

- TeslaMate: `http://服务器IP:4000`（粘贴 Auth for Tesla App 生成的 token 完成绑定）
- Grafana:   `http://服务器IP:3000`（admin / **脚本自动生成的强随机密码**，从终端输出抄走）
- ENCRYPTION_KEY + DATABASE_PASS + GRAFANA_PASS（三条**立刻抄到密码管理器**，丢了未来迁移/进 Grafana 全失败）

### 方法二：替换已有原版 TeslaMate 的 Grafana 镜像

适合**已经在用原版英文 TeslaMate** 想换中文版的用户。改两处 + 清旧卷：

```yaml
# 原 docker-compose.yml 的 grafana service 改两处：
  grafana:
    image: bswlhbhmt816/teslamate-chinese-dashboards:latest   # ← 改镜像（原 teslamate/grafana:latest）
    environment:
      - DATABASE_USER=teslamate
      - DATABASE_PASS=password
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - GF_USERS_DEFAULT_LANGUAGE=zh-Hans                      # ← 加这一行
    # ports / volumes / restart 保持原样
```

> ⚠️ **必须清除旧 Grafana 数据卷**（不影响行车记录数据，那存在独立的 `teslamate-db` 卷）：

```bash
docker compose stop grafana
docker volume rm teslamate_teslamate-grafana-data
docker compose pull grafana
docker compose up -d grafana
```

### 方法三：手动挂载 Dashboard 文件（进阶）

适合需要**完全控制 docker-compose.yml** 的用户（自定义部署 / 老版 Grafana 升级路径）。

> ⚠️ **版本要求**：部分仪表板用 `schemaVersion 41`，需要 **Grafana 12+**（TeslaMate Grafana 镜像 3.0.0+）。

```yaml
services:
  grafana:
    image: teslamate/grafana:latest
    volumes:
      - ./teslamate-chinese-dashboards/grafana/dashboards/zh-cn:/dashboards:ro
      - ./teslamate-chinese-dashboards/grafana/dashboards/internal:/dashboards_internal:ro
    environment:
      - GF_USERS_DEFAULT_LANGUAGE=zh-Hans
```

```bash
git clone https://github.com/wjsall/teslamate-chinese-dashboards.git
docker compose restart grafana
```

> ⚠️ `internal/` 必须挂载到 `/dashboards_internal/`（带下划线），否则行程详情/充电详情仍显示英文。

### 🇨🇳 中国大陆用户：镜像拉取失败

`ghcr.io` 在大陆经常超时。本项目镜像**双源同步**：

- ✅ Docker Hub：`bswlhbhmt816/teslamate-chinese-dashboards:latest`（国内更稳）
- ⚠️ ghcr.io：`ghcr.io/wjsall/teslamate-chinese-dashboards:latest`（备用）

**默认就用 Docker Hub**（方法一脚本已默认选 Docker Hub，方法二/三里手动指定）。

如果 Docker Hub 也慢，配镜像代理：

```bash
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://docker.cnb.cool"
  ]
}
EOF
sudo systemctl restart docker
```

## 🔄 更新方法

### 使用镜像方式
镜像会自动更新，只需重新拉取：
```bash
docker compose pull grafana
docker compose up -d grafana
```

> ⚠️ **如果更新后 Dashboard 仍显示旧版本**，说明 Grafana 数据卷有缓存残留，执行以下命令重置（车辆数据不受影响）：
> ```bash
> docker compose stop grafana
> docker volume rm teslamate_teslamate-grafana-data
> docker compose up -d grafana
> ```

### 使用挂载方式
```bash
cd teslamate-chinese-dashboards
git pull
docker compose restart grafana
```

## 🔧 故障排除

完整故障排查手册 → [TROUBLESHOOTING.md](TROUBLESHOOTING.md)（覆盖部署 / Dashboard 显示 / 数据 / Tesla 授权 / 升级 / 中国大陆专项 等所有常见问题）

## 📦 镜像信息

| 镜像地址 | 说明 |
|----------|------|
| `ghcr.io/wjsall/teslamate-chinese-dashboards:latest` | 最新稳定版（GitHub Container Registry） |
| `bswlhbhmt816/teslamate-chinese-dashboards:latest` | Docker Hub 镜像（中国大陆推荐） |
| `ghcr.io/wjsall/teslamate-chinese-dashboards:sha-xxxxx` | 特定版本 |

镜像构建状态：[![Build and Push to GitHub Container Registry](https://github.com/wjsall/teslamate-chinese-dashboards/actions/workflows/ghcr-build.yml/badge.svg)](https://github.com/wjsall/teslamate-chinese-dashboards/actions/workflows/ghcr-build.yml)

<a id="cn-region"></a>

## 🇨🇳 中国大陆用户专项配置

**TeslaMate 3.0 起，国内账号通常什么都不用改**。登录方式是粘贴 Access Token / Refresh Token（推荐用 [tesla_auth 桌面版](https://github.com/adriankumpf/tesla_auth/releases) 拿，TeslaMate 主作者维护，跨平台），TeslaMate 会从 token 自动识别中国区，所有 API/streaming 请求自动走 `*.cloud.tesla.cn`。详见 [QUICKSTART.md 第四步](QUICKSTART.md#step-4)。

仅在以下情况需要手动设置环境变量：

```yaml
services:
  teslamate:
    environment:
      - TZ=Asia/Shanghai
      # 走自建 Fleet API 网关 / 反向代理时才需要：
      # - TESLA_API_HOST=https://your-proxy.example.com
      # - TESLA_WSS_HOST=wss://your-proxy.example.com
```

完整环境变量参考：[TeslaMate 官方文档](https://docs.teslamate.org/docs/configuration/environment_variables)

<a id="sql-trust-model"></a>

## 🔒 SQL 远程拉取的信任模型

升级路径中的所有「SQL 三件套」（`install-coord-functions` / `install-tou` / `install-indexes`）都是从 GitHub 拉到本地用 `psql` 执行。这是**典型的 `curl | bash` 信任模型**：

- ✅ **传输安全**：HTTPS + GitHub 证书，中间人无法篡改
- ⚠️ **来源信任**：你信任 `wjsall/teslamate-chinese-dashboards` 仓库的内容
- ⚠️ **维护者风险**：若维护者 GitHub 账号被盗，攻击者可推恶意 SQL → 所有用 `main` ref 的用户下次升级会拉到恶意脚本 → psql 执行 → **数据库层任意代码执行**

### 想强化安全的用户：锁固定版本

把所有命令里的 `main` 替换成具体 tag（如 `v1.6.2`）：

```bash
# 原（默认，跟 :latest 镜像同步）
curl -fsSL "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/sql/install-tou.sql" | ...

# 锁版本（推荐有安全洁癖的用户）
curl -fsSL "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/v1.6.2/sql/install-tou.sql" | ...
```

或者跑 `simple-deploy.sh` / `migrate-from-official.sh` 时传环境变量：

```bash
SQL_REF=v1.6.2 bash simple-deploy.sh
REPO_REF=v1.6.2 bash migrate-from-official.sh
```

锁版本后**升级到新功能需要手动改 ref 数字**（不会自动升）。这是**安全 vs 便利的 trade-off**，按你需求选。

### 为什么默认是 `main` 而不是固定版本

- 大部分用户希望"重跑脚本就能拿到最新 bug 修复 / 函数升级"，固定 ref 反而让 Watchtower 自动升镜像后 SQL 不同步
- 维护者账号被盗概率低（GitHub 2FA），破坏面广（所有用户）—— **这条主要靠 GitHub 账号防御 + 你愿意时锁版本**
- 仓库公开，每条 SQL commit 都可审计，社区和我（维护者）第一时间能看到异常 push

### Cloudflare 镜像（避免直连 GitHub raw）

国内访问 `raw.githubusercontent.com` 偶尔不稳，可以替换成镜像。**注意信任边界**：

- **`ghproxy.com` 等第三方镜像** ⚠️ — 镜像运营方能改返回内容（实际是新加一个 MITM 信任点），仅在你信任该镜像方时使用
- **自建 Cloudflare Worker 转发 raw 内容** ✅ — 你完全控制 Worker 源码 → 等价直连

## 🛠️ 系统要求

- Docker 20.10+
- Docker Compose 2.0+
- 内存: 2GB+
- 磁盘: 10GB+

支持系统：
- ✅ Linux (Ubuntu/CentOS/Debian等)
- ✅ macOS (Intel/Apple Silicon)
- ✅ Windows (WSL2)
- ✅ 树莓派 (ARM64)

## 📚 相关链接

### 原版项目
- **GitHub**: https://github.com/teslamate-org/teslamate
- **官方文档**: https://docs.teslamate.org
- **原版 Grafana Dashboards**: https://github.com/teslamate-org/teslamate/tree/master/grafana/dashboards

### 帮助文档
- **安装指南**: https://docs.teslamate.org/docs/installation/docker
- **常见问题**: https://docs.teslamate.org/docs/faq
- **升级指南**: https://docs.teslamate.org/docs/upgrading
- **环境变量**: https://docs.teslamate.org/docs/configuration/environment_variables

### 本汉化项目
- **GitHub**: https://github.com/wjsall/teslamate-chinese-dashboards
- **问题反馈**: https://github.com/wjsall/teslamate-chinese-dashboards/issues
- **中文文档**: https://github.com/wjsall/teslamate-chinese-dashboards

## 👏 贡献者

感谢以下贡献者的辛勤付出:

### 主要贡献者
- [@wjsall](https://github.com/wjsall) - 项目发起人、主要汉化
- 社区贡献者 - 翻译校对、建议反馈

### 如何成为贡献者?

我们欢迎任何形式的贡献:
- 🌐 翻译改进
- 🐛 问题反馈
- 📝 文档完善
- 💡 功能建议
- ⭐ 给项目点 Star

[查看贡献指南](CONTRIBUTING.md)

## 🤝 贡献指南

欢迎提交 Issue 和 PR 改进汉化质量！

### 如何贡献

1. **Fork 本项目**
2. **修改 Dashboard JSON 文件**
   - 文件位置: `grafana/dashboards/zh-cn/`
3. **提交 PR**
   - 说明修改内容和原因
   - 确保 JSON 格式正确

### 翻译规范

- 使用简体中文
- 保持专业术语准确性
- 参考特斯拉官方中文术语

## 📄 License

MIT License - 与 TeslaMate 项目相同

## 🙏 致谢

- **原始汉化**: wjsall
- **整理优化**: Claude AI
- **验证测试**: 自动化脚本
- **原始项目**: [TeslaMate](https://github.com/teslamate-org/teslamate)
- **英文 Dashboard 参考**: [@jheredianet](https://github.com/jheredianet) — [Teslamate-CustomGrafanaDashboards](https://github.com/jheredianet/Teslamate-CustomGrafanaDashboards)，部分面板实现逻辑参考自其原版设计

## 💬 问题反馈

- GitHub Issues: https://github.com/wjsall/teslamate-chinese-dashboards/issues

---

**如果本项目对你有帮助，请给个 ⭐ Star！**

---

## 💰 支持项目

业余时间 1 个人维护。最有用的支持是 ⭐ Star、[报 Bug / 提建议](https://github.com/wjsall/teslamate-chinese-dashboards/issues)、加 [Telegram 群](https://t.me/+BeOASgmvE_IyNzNl) 帮其他车主装好。

| 微信打赏 | 支付宝打赏 |
|---------|-----------|
| ![微信打赏码](https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/images/wechat-donate.jpg) | ![支付宝打赏码](https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/images/alipay-donate.jpg) |

谢谢你 ❤️
