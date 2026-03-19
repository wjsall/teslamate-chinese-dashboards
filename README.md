# TeslaMate 中文 Grafana Dashboard

**TeslaMate Chinese Grafana Dashboards** — Simplified Chinese localization for TeslaMate, ready to use out of the box.

简体中文汉化版 TeslaMate Grafana Dashboard - 开箱即用 | 38个仪表板 100% 汉化 | 支持 Docker 一键部署

> 🚗 基于 [TeslaMate](https://github.com/teslamate-org/teslamate) 项目的 Grafana Dashboard 汉化版本
>
> 📖 原版文档: https://docs.teslamate.org
>
> 🙏 早期汉化工作参考自 GitHub 用户 [@dhuar](https://github.com/dhuar) 的私有镜像 `ccr.ccs.tencentyun.com/dhuar/grafana:latest`，在此致谢

![GitHub Stars](https://img.shields.io/github/stars/wjsall/teslamate-chinese-dashboards?style=social)
![GitHub Forks](https://img.shields.io/github/forks/wjsall/teslamate-chinese-dashboards?style=social)
![GitHub Issues](https://img.shields.io/github/issues/wjsall/teslamate-chinese-dashboards)
![Build Status](https://github.com/wjsall/teslamate-chinese-dashboards/actions/workflows/ghcr-build.yml/badge.svg)

## 📸 效果预览

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
- ✅ **完全汉化** - 38个 Dashboard，含7个全新原创分析图表
- ✅ **完整地图** - 支持 OpenStreetMap 地图服务

## 📊 汉化成果

| 指标 | 数值 |
| --- | --- |
| Dashboard 数量 | 38个 ✅ |
| 内部详情页 | 3个（行程/充电详情）|
| 文件总大小 | ~1.2MB |
| 面板总数 | 295个 |
| 已汉化 | 258个 (100%) |
| 汉化完成度 | 100% |
| 质量等级 | A+ |
| 最后更新 | 2026-03-19 |

**所有 Dashboard 均已完成简体中文汉化，开箱即用！** 🎉

## 📚 使用文档

我们为你准备了三份详细的使用指南：

| 文档 | 说明 | 适合人群 |
|------|------|----------|
| **[新手向导](QUICKSTART.md)** | 从零开始安装，含 FAQ | 完全新手 |
| **[功能地图](DASHBOARD_MAP.md)** | 38个 Dashboard 分类导航 | 新用户 |
| **[场景速查手册](SCENE_GUIDE.md)** | 什么时候看什么 Dashboard | 所有用户 |
| **[数据指标手册](METRICS_GUIDE.md)** | 指标解释、正常范围、异常处理 | 进阶用户 |
| **[故障排查手册](TROUBLESHOOTING.md)** | 遇到问题按症状查解决方案 | 遇到问题时 |

**新手建议**：先看「新手向导」→「功能地图」→「场景速查手册」→「数据指标手册」

## 📁 包含的 Dashboard (38个)

### 核心功能 (4个)
- ✅ **概览 (Overview)** - 车辆整体状态和关键指标
- ✅ **状态 (States)** - 实时监控和当前状态
- ✅ **充电统计 (Charging Stats)** - 充电数据汇总分析
- ✅ **行程统计 (Drive Stats)** - 行驶数据汇总分析

### 充电相关 (11个)
- ✅ **当前充电状态 (Current Charge View)** - 实时充电监控
- ✅ **充电记录 (Charges)** - 历史充电记录查询
- ✅ **充电费用统计 (Charging Cost Stats)** - 充电成本分析
- ✅ **停车电量消耗 (Vampire Drain)** - 停车期间电量损耗
- ✅ **快充曲线统计 (Charging Curve Stats)** - 快充性能分析
- ✅ **快充曲线图-按运营商 (DC Charging Curves)** - 不同运营商充电对比
- ✅ **电池容量曲线图 (Charge Level)** - 电池容量趋势
- ✅ **电池健康度 (Battery Health)** - 电池退化监控
- ✅ **续航曲线图 (Projected Range)** - 预计续航分析
- 🆕 **充电健康管理** - 充电习惯评分、快充占比、SOC分布分析
- 🆕 **哨兵模式耗电分析** - 哨兵开启时长、耗电估算、地点分布

### 驾驶相关 (10个)
- ✅ **当前驾驶状态 (Current Drive View)** - 实时驾驶监控
- ✅ **行程列表 (Drives)** - 行程记录查询
- ✅ **驾驶记录追踪 (Tracking Drives)** - GPS轨迹追踪
- ✅ **最近车速统计 (Speed Rates)** - 车速分布分析
- ✅ **行程统计-年月日 (Statistics)** - 按时间维度统计
- ✅ **行程统计-时间段 (Trip)** - 自定义时间段分析
- ✅ **行程统计-每次充电 (Continuous Trips)** - 单次充电行程分析
- 🆕 **出行规律分析** - 时段分布、工作日vs周末、温度与能耗关系
- 🆕 **年度驾驶报告** - 年度里程/费用/亮点，常去地点TOP10
- 🆕 **动能回收分析** - 各固件版本回收率/功率对比、每日趋势、速度区间分析

### 车辆状态 (6个)
- ✅ **最近车辆状态 (Current State)** - 车辆最新状态
- ✅ **胎压 (Tire Pressure)** - 轮胎压力监控
- ✅ **能效 (Efficiency)** - 能耗效率分析
- ✅ **车辆里程统计 (Mileage Stats)** - 里程数据统计
- ✅ **车辆里程曲线图 (Mileage)** - 里程趋势图
- ✅ **不完整的数据 (Incomplete Data)** - 数据完整性检查

### 其他功能 (7个)
- ✅ **时间线 (Timeline)** - 事件时间轴
- ✅ **访问过的地点 (Locations)** - 常去地点统计
- ✅ **足迹地图 (Visited)** - 行驶轨迹地图
- ✅ **数据库信息 (Database Info)** - 系统信息监控
- ✅ **系统更新 (Updates)** - 软件更新记录
- 🆕 **省钱分析** - 与燃油车对比节省费用，可自定义油价/油耗/预算
- 🆕 **多车对比** - 名下所有车辆里程/能耗/费用横向对比，自动适配车辆数量

---

**Dashboard 功能矩阵:**

| 类别 | 数量 | 占比 | 主要功能 |
|------|------|------|----------|
| 核心功能 | 4 | 11% | 概览、状态、统计汇总 |
| 充电相关 | 11 | 29% | 充电监控、成本、电池健康、哨兵耗电 |
| 驾驶相关 | 10 | 26% | 行程记录、轨迹、规律分析、年度报告、动能回收 |
| 车辆状态 | 6 | 16% | 实时状态、胎压、能效 |
| 其他功能 | 7 | 18% | 地图、时间线、省钱分析、多车对比 |
| **总计** | **38** | **100%** | **全方位车辆数据分析** |

## 🚀 快速开始

### 方法一：使用预构建镜像（推荐 ⭐）

无需克隆项目，直接使用预构建镜像：

```yaml
services:
  grafana:
    image: ghcr.io/wjsall/teslamate-chinese-dashboards:latest
    environment:
      - GF_DEFAULT_LANGUAGE=zh-Hans
      - GF_SECURITY_ADMIN_PASSWORD=admin
      # ... 其他配置
```

镜像地址：`ghcr.io/wjsall/teslamate-chinese-dashboards:latest`

特点：
- ✅ 完全免费，无需注册
- ✅ 自动同步最新汉化
- ✅ 开箱即用

#### 🇨🇳 中国大陆用户：镜像拉取失败解决方案

`ghcr.io`（GitHub Container Registry）在中国大陆访问不稳定，常见报错为 `connection refused`、`timeout` 或 `401`。有以下几种解决方案：

**方案 A：配置 Docker 镜像代理（推荐）**

在 `/etc/docker/daemon.json` 中添加代理地址（选择一个可用的）：

```json
{
  "registry-mirrors": [
    "https://dockerproxy.cn",
    "https://docker.1ms.run",
    "https://hub-mirror.c.163.com"
  ]
}
```

然后重启 Docker：

```bash
sudo systemctl daemon-reload && sudo systemctl restart docker
```

**方案 B：本地构建镜像（无需网络代理）**

```bash
# 1. 克隆项目
git clone https://github.com/wjsall/teslamate-chinese-dashboards.git
cd teslamate-chinese-dashboards

# 2. 在本地构建镜像（FROM teslamate/grafana:latest 可通过镜像代理加速）
docker build -t teslamate-grafana-zh .

# 3. 修改 docker-compose.yml 的 grafana.image 为 teslamate-grafana-zh
# 4. 启动
docker compose up -d
```

**方案 C：使用 Docker Hub 镜像（即将支持）**

我们计划同步推送到 Docker Hub 以提升中国可用性，敬请期待。

**验证安装:**
```bash
# 1. 启动服务
docker compose up -d

# 2. 检查 Grafana 日志
docker compose logs grafana

# 3. 访问 Grafana
open http://localhost:3000

# 4. 验证 Dashboard
# 登录后应该看到 38 个中文 Dashboard
```

### 方法二：一键安装脚本

```bash
# 在服务器上执行
wget https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/simple-deploy.sh
bash simple-deploy.sh
```

访问：
- TeslaMate: http://服务器IP:4000
- Grafana: http://服务器IP:3000

### 方法三：Docker Compose Plugin（新版Docker）

```bash
# 1. 克隆项目
git clone https://github.com/wjsall/teslamate-chinese-dashboards.git
cd teslamate-chinese-dashboards

# 2. 启动
docker compose up -d

# 3. 访问 Grafana
open http://localhost:3000
```

### 方法四：基于原版 TeslaMate 修改（推荐已有用户）

如果你已经在使用原版 TeslaMate，只需修改 Grafana 镜像即可：

**原版 docker-compose.yml：**
```yaml
services:
  teslamate:
    image: teslamate/teslamate:latest
    restart: always
    environment:
      - ENCRYPTION_KEY=secretkey #replace with a secure key to encrypt your Tesla API tokens
      - DATABASE_USER=teslamate
      - DATABASE_PASS=password #insert your secure database password!
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - MQTT_HOST=mosquitto
    ports:
      - 4000:4000
    volumes:
      - ./import:/opt/app/import
    cap_drop:
      - all

  database:
    image: postgres:18-trixie
    restart: always
    environment:
      - POSTGRES_USER=teslamate
      - POSTGRES_PASSWORD=password #insert your secure database password!
      - POSTGRES_DB=teslamate
    volumes:
      - teslamate-db:/var/lib/postgresql

  grafana:
    image: teslamate/grafana:latest  # ← 修改这一行
    restart: always
    environment:
      - DATABASE_USER=teslamate
      - DATABASE_PASS=password #insert your secure database password!
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
    ports:
      - 3000:3000
    volumes:
      - teslamate-grafana-data:/var/lib/grafana

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

**修改方案：**

将 `grafana` 部分的 `image: teslamate/grafana:latest` 替换为：

```yaml
  grafana:
    image: ghcr.io/wjsall/teslamate-chinese-dashboards:latest  # ← 汉化版镜像
    restart: always
    environment:
      - DATABASE_USER=teslamate
      - DATABASE_PASS=password
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - GF_DEFAULT_LANGUAGE=zh-Hans  # ← 添加中文语言设置
    ports:
      - 3000:3000
    volumes:
      - teslamate-grafana-data:/var/lib/grafana
```

然后按以下步骤切换：

> ⚠️ **重要：切换前必须清除旧数据卷**
>
> 原版 Grafana 首次启动时已将英文 Dashboard 写入数据卷，直接换镜像**不会自动覆盖**，界面仍会显示英文。
> 必须先删除旧数据卷，让汉化版镜像重新初始化。
>
> **车辆行驶数据不受影响**（存储在独立的 `teslamate-db` 数据卷中）。

```bash
# 1. 停止 Grafana 容器
docker compose stop grafana

# 2. 删除旧 Grafana 数据卷（清除英文 Dashboard 缓存）
docker volume rm teslamate_teslamate-grafana-data

# 3. 拉取汉化版镜像并启动
docker compose pull grafana
docker compose up -d grafana
```

### 方法五：手动挂载 Dashboard（高级用户）

> ⚠️ **版本要求**：部分仪表板使用 `schemaVersion 41`，需要 **Grafana 12+**（即 TeslaMate Grafana 镜像 3.0.0+）。旧版 Grafana 可能出现面板渲染异常。

在你的 `docker-compose.yml` 中添加：

```yaml
services:
  grafana:
    image: teslamate/grafana:latest
    volumes:
      # 挂载中文Dashboard（主要仪表板）
      - ./teslamate-chinese-dashboards/grafana/dashboards/zh-cn:/dashboards:ro
      # 挂载内部详情页（行程详情/充电详情）⚠️ 路径必须是 /dashboards_internal/
      - ./teslamate-chinese-dashboards/grafana/dashboards/internal:/dashboards_internal:ro
    environment:
      - GF_DEFAULT_LANGUAGE=zh-Hans
```

然后：
```bash
git clone https://github.com/wjsall/teslamate-chinese-dashboards.git
docker compose restart grafana
```

> ⚠️ **注意**：`internal/` 必须挂载到 `/dashboards_internal/`（带下划线），否则行程详情、充电详情页仍显示英文。

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

### Dashboard 没有显示中文?

1. **检查语言设置**
   ```yaml
   environment:
     - GF_DEFAULT_LANGUAGE=zh-Hans
   ```

2. **清除浏览器缓存**
   - 按 `Ctrl+Shift+R` (Windows/Linux)
   - 按 `Cmd+Shift+R` (macOS)

3. **重启 Grafana 容器**
   ```bash
   docker compose restart grafana
   ```

### Dashboard 显示为空?

1. **检查数据源连接**
   - Grafana → Configuration → Data Sources
   - 确认 TeslaMate 数据源正常

2. **检查 TeslaMate 服务**
   ```bash
   docker compose ps
   docker compose logs teslamate
   ```

3. **检查数据库**
   ```bash
   docker compose exec database psql -U teslamate -c "SELECT COUNT(*) FROM drives;"
   ```

### 文件挂载失败?

1. **检查路径**
   ```bash
   ls -la grafana/dashboards/zh-cn/
   # 应该看到 38 个 JSON 文件
   ```

2. **检查权限**
   ```bash
   chmod -R 755 grafana/dashboards/
   ```

3. **检查 Docker Compose 配置**
   ```yaml
   volumes:
     - ./grafana/dashboards/zh-cn:/dashboards:ro
     - ./grafana/dashboards/internal:/dashboards_internal:ro
   ```

### 地图无法加载或显示空白?

如果地图无法显示：

1. **检查网络连接**
   - 确保服务器能访问 OpenStreetMap
   - 国内用户可能需要配置代理或 VPN

2. **检查 Grafana 版本**
   - Geomap 面板需要 Grafana 9.0+
   - 建议使用 Grafana 10.0+ 获得最佳体验

3. **检查浏览器控制台**
   - 按 `F12` 打开开发者工具
   - 查看 Console 是否有地图加载错误

4. **手动切换地图图层**
   - 在 Dashboard 中点击地图右上角的图层按钮
   - 尝试切换其他地图图层

### 更多问题?

- 📖 查看 [Wiki](https://github.com/wjsall/teslamate-chinese-dashboards/wiki)
- 🐛 提交 [Issue](https://github.com/wjsall/teslamate-chinese-dashboards/issues)
- 💬 加入讨论 [Discussions](https://github.com/wjsall/teslamate-chinese-dashboards/discussions)

## 📦 版本信息

### 当前版本
- **版本号**: v1.3.2
- **发布日期**: 2026-03-19
- **Dashboard 数量**: 38个（含7个原创分析仪表盘 + 3个内部详情页）
- **汉化完成度**: 100%

### 兼容性
- ✅ TeslaMate v1.28.0+
- ✅ Grafana 12.x（基于 teslamate/grafana:latest）
- ⚠️ 不兼容 Grafana 9.x/10.x（使用了 12.x 专有特性）
- ✅ Docker 20.10+
- ✅ Docker Compose 2.0+

### 更新日志

#### v1.3.2 (2026-03-19)
- 🔧 修复 dashboards.yml 路径错误（`/etc/grafana/.../zh-cn` → `/dashboards`，`/internal` → `/dashboards_internal`）
- 🔧 Dockerfile 新增显式覆盖 Grafana provisioning 配置（避免基础镜像版本变化引起路径失效）
- 🔧 修复 datasource.yml 硬编码端口/SSL 模式 → 改用 `${DATABASE_PORT}` / `${DATABASE_SSL_MODE}` 环境变量
- 🔧 修复 statistics.json `high_precision` 变量 SQL 注入错误（`column "no" does not exist`）
- 🔧 修复 ContinuousTrips.json 长途行程开始/结束时间列名不匹配（英文显示问题）
- 🔧 修复 ChargingCurveStats.json / DCChargingCurvesByCarrier.json `GROUP BY` 别名引用错误
- 🔧 修复 drives.json 行程列表时间点击无法跳转到行程详情（#2）
- 📝 新增中国大陆用户镜像拉取失败解决方案（Docker 镜像代理 / 本地构建）

#### v1.3.0 (2026-03-17)
- 🆕 新增7个原创分析仪表盘
  - **年度驾驶报告** — 年度里程/充电/能耗汇总，常去地点 & 充电站 TOP10
  - **省钱分析** — 燃油对比节省金额、充电时段费用分布、年度预算进度
  - **充电健康管理** — 充电习惯评分、充至100%/低电量占比、SOC 分布统计
  - **停车掉电分析** — 掉电趋势、区间分布、最耗电停车 TOP20
  - **出行规律分析** — 24小时出行时段、工作日 vs 周末、温度与能耗散点图
  - **动能回收分析** — 各固件版本回收率/最大功率对比、每日/周趋势、速度区间 & 温度影响、行程 TOP20
- 🔧 全面修复单位显示问题
  - 消除所有自动缩放单位（lengthkm/short/kwatth/velocitykmh/kilo/m）
  - 统一使用 `none` 单位 + displayName 标注中文单位
  - 修复所有 stat 面板缺失 title 导致无标题栏问题
- 🔧 修复5个仪表盘 SQL 及数据问题
  - 停车掉电：重写全部 SQL，使用 LEAD() 窗口函数 + JOIN positions 表获取 SOC
  - 省钱分析：修复预算仪表盘 max 变量不生效，改为 SQL 计算百分比
  - 省钱分析：修复充电时段饼图只显示1个扇区，改为宽表格式
  - 充电健康管理：修复空白面板、duplicate fieldConfig JSON key
  - 所有面板补全 `rawQuery: true` + `editorMode: code`

#### v1.2.0 (2026-03-15)
- 🔧 全面修复汉化质量问题
  - 修复时间线、电池健康、行程统计等多个仪表板列顺序错乱
  - 修复充电曲线图悬浮提示英文（Power [kW]、SOC [%] 等）
  - 修复行程详情页英文图例（battery_heater、is_climate_on、fan_status）
  - 修复 11 个文件 datasource type 错误（postgres → grafana-postgresql-datasource）
  - 修复 drive-details 内部页部署路径（/dashboards_internal/）
  - 统一日期/时长格式为中文（2025年10月、2天12小时）
  - 修复速度直方图、超级充电站排名、行程列表等无数据问题

#### v1.0.0 (2026-02-08)
- 🎉 初始版本发布
- ✅ 完成 31 个 Dashboard 汉化
- ✅ 支持 Docker 镜像部署
- ✅ 支持文件挂载部署
- ✅ 添加一键安装脚本
- 📝 完善文档和说明

### 镜像标签

| 标签 | 说明 | 用途 |
|------|------|------|
| `latest` | 最新稳定版 | 生产环境推荐 |
| `v1.0.0` | 指定版本 | 版本锁定 |
| `sha-xxxxx` | 特定提交 | 开发测试 |

**镜像地址**: `ghcr.io/wjsall/teslamate-chinese-dashboards`

## 📁 项目结构

```
teslamate-chinese-dashboards/
├── README.md                    # 项目说明
├── QUICKSTART.md               # 新手向导（从零开始）
├── TROUBLESHOOTING.md          # 故障排查手册
├── SCENE_GUIDE.md              # 场景速查手册
├── METRICS_GUIDE.md            # 数据指标手册
├── DASHBOARD_MAP.md            # Dashboard 功能地图
├── CONTRIBUTING.md             # 贡献指南
├── LICENSE                      # MIT许可证
├── Dockerfile                   # Docker镜像构建
├── simple-deploy.sh            # 一键安装脚本
├── grafana/
│   └── dashboards/
│       ├── zh-cn/              # 38个主要汉化Dashboard → 挂载到 /dashboards/
│       │   ├── overview.json
│       │   ├── states.json
│       │   ├── charging-stats.json
│       │   └── ... (共38个)
│       └── internal/           # 3个内部详情页 → 挂载到 /dashboards_internal/
│           ├── home.json
│           ├── drive-details.json
│           └── charge-details.json
└── .github/
    └── workflows/
        ├── ghcr-build.yml      # GitHub Actions 自动构建
        └── update-base-image.yml  # 基础镜像自动更新
```

## 📦 镜像信息

| 镜像地址 | 说明 |
|----------|------|
| `ghcr.io/wjsall/teslamate-chinese-dashboards:latest` | 最新稳定版（推荐） |
| `ghcr.io/wjsall/teslamate-chinese-dashboards:sha-xxxxx` | 特定版本 |

镜像构建状态：[![Build and Push to GitHub Container Registry](https://github.com/wjsall/teslamate-chinese-dashboards/actions/workflows/ghcr-build.yml/badge.svg)](https://github.com/wjsall/teslamate-chinese-dashboards/actions/workflows/ghcr-build.yml)

## ⚙️ 环境变量

### Grafana 变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `GF_DEFAULT_LANGUAGE` | Grafana 界面语言 | `zh-Hans` |
| `GF_SECURITY_ADMIN_PASSWORD` | Grafana 管理员密码 | `admin` |
| `DATABASE_USER` | 数据库用户名 | `teslamate` |
| `DATABASE_PASS` | 数据库密码 | `password` |
| `DATABASE_NAME` | 数据库名称 | `teslamate` |
| `DATABASE_HOST` | 数据库主机名 | `database` |

### TeslaMate 重要变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `ENCRYPTION_KEY` | Tesla Token 加密密钥（**必须设置且不能更改**） | 无 |
| `TZ` | 时区设置（中国用户建议设置） | 系统默认 |
| `TESLA_API_HOST` | Tesla API 地址（**中国大陆专用**） | 见下方 |
| `TESLA_WSS_HOST` | Tesla 流式数据地址（**中国大陆专用**） | 见下方 |

### 🇨🇳 中国大陆用户专项配置

中国大陆用户需要添加以下环境变量到 `teslamate` 服务，否则无法连接 Tesla 服务器：

```yaml
services:
  teslamate:
    environment:
      - TZ=Asia/Shanghai
      - TESLA_API_HOST=https://owner-api.vn.cloud.tesla.cn
      - TESLA_WSS_HOST=wss://streaming.vn.cloud.tesla.cn
```

> 📖 参考：[TeslaMate 官方文档 - 环境变量](https://docs.teslamate.org/docs/configuration/environment_variables)

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

## 💬 问题反馈

- GitHub Issues: https://github.com/wjsall/teslamate-chinese-dashboards/issues

---

**如果本项目对你有帮助，请给个 ⭐ Star！**

---

## 💰 支持项目

如果你觉得这个项目对你有帮助，欢迎打赏支持，让汉化工作持续更新！

| 微信打赏 | 支付宝打赏 |
|---------|-----------|
| ![微信打赏码](https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/images/wechat-donate.jpg) | ![支付宝打赏码](https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/images/alipay-donate.jpg) |

**您的支持是我持续更新的动力！** ❤️
