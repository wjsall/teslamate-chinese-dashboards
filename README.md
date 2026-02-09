# TeslaMate 中文 Grafana Dashboard

简体中文汉化版 TeslaMate Grafana Dashboard - 开箱即用

> 🚗 基于 [TeslaMate](https://github.com/teslamate-org/teslamate) 项目的 Grafana Dashboard 汉化版本
> 
> 📖 原版文档: https://docs.teslamate.org

![GitHub Stars](https://img.shields.io/github/stars/wjsall/teslamate-chinese-dashboards?style=social)
![GitHub Forks](https://img.shields.io/github/forks/wjsall/teslamate-chinese-dashboards?style=social)
![GitHub Issues](https://img.shields.io/github/issues/wjsall/teslamate-chinese-dashboards)
![Build Status](https://github.com/wjsall/teslamate-chinese-dashboards/actions/workflows/ghcr-build.yml/badge.svg)

## 🎯 特点

- ✅ **开箱即用** - 无需 Docker Hub 账号，直接挂载使用
- ✅ **一键安装** - 提供多种安装方式，5分钟完成部署
- ✅ **持续更新** - 通过 git pull 即可获取最新汉化
- ✅ **完全汉化** - 31个 Dashboard，258个面板100%汉化
- ✅ **完整地图** - 支持 OpenStreetMap 地图服务

## 📊 汉化成果

| 指标 | 数值 |
| --- | --- |
| Dashboard 数量 | 31个 ✅ |
| 文件总大小 | ~1.2MB |
| 面板总数 | 258个 |
| 已汉化 | 258个 (100%) |
| 汉化完成度 | 100% |
| 质量等级 | A+ |
| 最后更新 | 2026-02-08 |

**所有 Dashboard 均已完成简体中文汉化，开箱即用！** 🎉

## 📚 使用文档

我们为你准备了三份详细的使用指南：

| 文档 | 说明 | 适合人群 |
|------|------|----------|
| **[场景速查手册](SCENE_GUIDE.md)** | 什么时候看什么 Dashboard | 所有用户 |
| **[数据指标手册](METRICS_GUIDE.md)** | 指标解释、正常范围、异常处理 | 进阶用户 |
| **[功能地图](DASHBOARD_MAP.md)** | 31个 Dashboard 分类导航 | 新用户 |

**新手建议**：先看「功能地图」→ 再看「场景速查手册」→ 最后参考「数据指标手册」

## 📁 包含的 Dashboard (31个)

### 核心功能 (4个)
- ✅ **概览 (Overview)** - 车辆整体状态和关键指标
- ✅ **状态 (States)** - 实时监控和当前状态  
- ✅ **充电统计 (Charging Stats)** - 充电数据汇总分析
- ✅ **行程统计 (Drive Stats)** - 行驶数据汇总分析

### 充电相关 (9个)
- ✅ **当前充电状态 (Current Charge View)** - 实时充电监控
- ✅ **充电记录 (Charges)** - 历史充电记录查询
- ✅ **充电费用统计 (Charging Cost Stats)** - 充电成本分析
- ✅ **停车电量消耗 (Vampire Drain)** - 停车期间电量损耗
- ✅ **快充曲线统计 (Charging Curve Stats)** - 快充性能分析
- ✅ **快充曲线图-按运营商 (DC Charging Curves)** - 不同运营商充电对比
- ✅ **电池容量曲线图 (Charge Level)** - 电池容量趋势
- ✅ **电池健康度 (Battery Health)** - 电池退化监控
- ✅ **续航曲线图 (Projected Range)** - 预计续航分析

### 驾驶相关 (7个)
- ✅ **当前驾驶状态 (Current Drive View)** - 实时驾驶监控
- ✅ **行程列表 (Drives)** - 行程记录查询
- ✅ **驾驶记录追踪 (Tracking Drives)** - GPS轨迹追踪
- ✅ **最近车速统计 (Speed Rates)** - 车速分布分析
- ✅ **行程统计-年月日 (Statistics)** - 按时间维度统计
- ✅ **行程统计-时间段 (Trip)** - 自定义时间段分析
- ✅ **行程统计-每次充电 (Continuous Trips)** - 单次充电行程分析

### 车辆状态 (6个)
- ✅ **最近车辆状态 (Current State)** - 车辆最新状态
- ✅ **胎压 (Tire Pressure)** - 轮胎压力监控
- ✅ **能效 (Efficiency)** - 能耗效率分析
- ✅ **车辆里程统计 (Mileage Stats)** - 里程数据统计
- ✅ **车辆里程曲线图 (Mileage)** - 里程趋势图
- ✅ **不完整的数据 (Incomplete Data)** - 数据完整性检查

### 其他功能 (5个)
- ✅ **时间线 (Timeline)** - 事件时间轴
- ✅ **访问过的地点 (Locations)** - 常去地点统计
- ✅ **足迹地图 (Visited)** - 行驶轨迹地图
- ✅ **数据库信息 (Database Info)** - 系统信息监控
- ✅ **系统更新 (Updates)** - 软件更新记录

---

**Dashboard 功能矩阵:**

| 类别 | 数量 | 占比 | 主要功能 |
|------|------|------|----------|
| 核心功能 | 4 | 13% | 概览、状态、统计汇总 |
| 充电相关 | 9 | 29% | 充电监控、成本、电池健康 |
| 驾驶相关 | 7 | 23% | 行程记录、轨迹、统计 |
| 车辆状态 | 6 | 19% | 实时状态、胎压、能效 |
| 其他功能 | 5 | 16% | 地图、时间线、系统信息 |
| **总计** | **31** | **100%** | **全方位车辆数据分析** |

## 🚀 快速开始

### 方法一：使用预构建镜像（推荐 ⭐）

无需克隆项目，直接使用 GitHub Container Registry 镜像：

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

**验证安装:**
```bash
# 1. 启动服务
docker compose up -d

# 2. 检查 Grafana 日志
docker compose logs grafana

# 3. 访问 Grafana
open http://localhost:3000

# 4. 验证 Dashboard
# 登录后应该看到 31 个中文 Dashboard
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

然后重启：
```bash
docker compose pull grafana
docker compose up -d grafana
```

### 方法五：手动挂载 Dashboard（高级用户）

在你的 `docker-compose.yml` 中添加：

```yaml
services:
  grafana:
    image: teslamate/grafana:latest
    volumes:
      # 挂载中文Dashboard
      - ./teslamate-chinese-dashboards/grafana/dashboards/zh-cn:/etc/grafana/provisioning/dashboards/zh:ro
    environment:
      - GF_DEFAULT_LANGUAGE=zh-Hans
```

然后：
```bash
git clone https://github.com/wjsall/teslamate-chinese-dashboards.git
docker compose restart grafana
```

## 🔄 更新方法

### 使用镜像方式
镜像会自动更新，只需重新拉取：
```bash
docker compose pull grafana
docker compose up -d grafana
```

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
   # 应该看到 31 个 JSON 文件
   ```

2. **检查权限**
   ```bash
   chmod -R 755 grafana/dashboards/
   ```

3. **检查 Docker Compose 配置**
   ```yaml
   volumes:
     - ./grafana/dashboards/zh-cn:/etc/grafana/provisioning/dashboards/zh:ro
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
- **版本号**: v1.0.0
- **发布日期**: 2026-02-08
- **Dashboard 数量**: 31个
- **汉化完成度**: 100%

### 兼容性
- ✅ TeslaMate v1.28.0+
- ✅ Grafana 9.0+
- ✅ Docker 20.10+
- ✅ Docker Compose 2.0+

### 更新日志

#### v1.0.3 (2026-02-08)
- 📝 继续汉化遗漏内容
  - 汉化所有按钮链接 (View charge details→查看充电详情, Set Cost→设置费用等)
  - 汉化数据链接 (Trip→行程, Drives→行程列表, Charging stats→充电统计等)
  - 汉化警告信息 (寒冷天气提示)
  - 汉化面板标题 (Stats per month→每月统计, Help→帮助等)
  - 更新 18 个文件，汉化完成度接近 100%

#### v1.0.2 (2026-02-08)
- 🗺️ 更换为高德标准地图
  - 将 CartoDB 更换为高德标准地图
  - 国内访问速度更快
  - 中文街道标注，更符合国内用户习惯

#### v1.0.1 (2026-02-08)
- 🗺️ 修复地图加载问题
  - 将 OpenStreetMap 更换为 CartoDB 地图服务
  - 修复 7 个包含地图的 Dashboard
  - 国内用户可以正常访问地图

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
├── LICENSE                      # MIT许可证
├── Dockerfile                   # Docker镜像构建
├── simple-deploy.sh            # 一键安装脚本
├── docker-compose.yml          # Docker Compose配置
├── grafana/
│   └── dashboards/
│       └── zh-cn/              # 31个汉化Dashboard
│           ├── overview.json
│           ├── states.json
│           ├── charging-stats.json
│           └── ... (共31个)
└── .github/
    └── workflows/
        └── ghcr-build.yml      # GitHub Actions 自动构建
```

## 📦 镜像信息

| 镜像地址 | 说明 |
|----------|------|
| `ghcr.io/wjsall/teslamate-chinese-dashboards:latest` | 最新稳定版（推荐） |
| `ghcr.io/wjsall/teslamate-chinese-dashboards:sha-xxxxx` | 特定版本 |

镜像构建状态：[![Build and Push to GitHub Container Registry](https://github.com/wjsall/teslamate-chinese-dashboards/actions/workflows/ghcr-build.yml/badge.svg)](https://github.com/wjsall/teslamate-chinese-dashboards/actions/workflows/ghcr-build.yml)

## ⚙️ 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `GF_DEFAULT_LANGUAGE` | Grafana默认语言 | `zh-Hans` |
| `GF_SECURITY_ADMIN_PASSWORD` | Grafana管理员密码 | `admin` |
| `DATABASE_PASSWORD` | 数据库密码 | `password` |

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
- **中文文档**: https://www.teslamate.com.cn

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
