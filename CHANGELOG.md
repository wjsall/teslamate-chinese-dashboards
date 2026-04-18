# 更新日志

## [v1.4.0] - 2026-04-18

### 🔄 同步上游 efficiency 仪表盘改进 (5bf8f82)

- 启用时间选择器（原本被隐藏），默认时间范围 `now-6h` → `now-10y`
- 4 个面板 SQL 加入 `$__timeFilter(start_date)`：行驶能耗 / 充电能耗 / 记录的距离 / 温度对能耗影响
- 「能耗 (总计)」面板替换为上游共享 CTE 写法（drives_start_event / charging_processes_start_event ...），含 is_incomplete 守卫，并新增 organize transformation 隐藏中间列
- 保留本地 slope-adjusted 自定义逻辑和中文别名 `"能耗"`

### 🐛 时区批量修复（影响 10+ 面板）

- 修正 TeslaMate 朴素 UTC 列被错误当本地时区解读的问题
  - 错误模式：`timezone('$__timezone', start_date)` → 中国用户 23:00 充电被显示为 15:00
  - 正确模式：`(col AT TIME ZONE 'UTC' AT TIME ZONE '$__timezone')`
- 影响仪表盘：cost-savings / annual-summary / charging-stats / driving-patterns / charges 等

### 🏆 驾驶评分公式全面重构

- **平稳分**：从功率（>60kW/-30kW）改为加速度（>2 m/s²，严重度加权），更贴近驾驶感受
- **效率分**：加入温度补偿基线（冬冷 ×1.3、夏热 ×1.2），季节差异不再误判
- **回收分**：加入速度动态乘数（×3 ~ ×6），高速刹车少不再被扣分
- **综合分**：按行程场景动态加权（城市 / 混合 / 高速）
- **聚合方式**：所有评分按里程加权平均（取代算术平均）
- **行程明细**：新增「平均速度」「场景」列，蓝/紫/橙配色

### 📊 UI 优化

- 足迹地图统计卡片紧凑化（h=3、隐藏多余标题、字号 32）
- SpeedRates 时长列自适应格式
- 地形变量中英文映射统一
- 清理多处 `lengthkm` / `short` 自动换算导致的 "28 Mm" / "2 K" 显示错误

---

## [v1.3.4] - 2026-03-25

### 🆕 新增驾驶评分仪表盘

- **驾驶评分**（原创）— 四维度综合评分系统初版
  - 效率分（30%）：理想续航消耗比
  - 平稳分（30%）：急加速 / 急刹车时间占比
  - 速度分（20%）：超速采样点占比
  - 回收分（20%）：回收能量 / 消耗能量比值
  - 驾驶风格自动判定 / 综合评分趋势 / 行程评分明细 / 驾驶数据汇总

> ⚠️ 此版本评分公式已在 v1.4.0 重构，最新算法见上方。

---

## [v1.3.3] - 2026-03-22

### 🐛 Bug 修复

- **修复 Grafana 升级 TeslaMate 3.0 后无法启动的问题**（[#3](https://github.com/wjsall/teslamate-chinese-dashboards/issues/3)）
  - 移除 `datasource.yml` 中显式 `uid: TeslaMate` 字段，该字段与 Grafana 12.4.0 Correlations Provisioner 存在兼容性问题，导致启动时报 `Datasource provisioning error: data source not found`
  - 将 `editable` 改为 `true`，与官方保持一致

- **修复动能回收率显示异常（99%）**
  - 坡度调整效率公式修正，引入海拔升降对能量的影响计算

### ✨ 同步官方 TeslaMate 3.0 Dashboard 更新

#### 行程（drives.json）
- 新增 `坡度调整效率` / `按距离效率` 切换变量
- 新增 `reduced_range_info` CTE，统计续航缓冲激活次数
- 修复 `地点筛选（geofence）` 变量初始化异常：改用 SQL CTE 注入 "All/-1" 选项，绕过 Grafana Bug #119793
- 修复时区显示：`timezone: ""` → `"browser"`

#### 充电统计（charging-stats.json）
- 新增 `首选续航模式（preferred_range）` 变量（原版缺失，导致多个面板无法正常显示）
- 新增 `充电时长 >=（min_duration）` 筛选变量
- 新增连续充电检测逻辑（`lead/lag` 窗口函数），避免连续充电被重复计入
- 新增 LFP 磷酸铁锂电池支持（充电效率图 refId=B）
- 升级费用归因算法：采用官方 `drives_start_event` CTE，按行程前最近一次充电归因
- 修复多个面板时间过滤条件（`start_date` → `end_date`）
- 修复 Panel 29 GROUP BY 字段（`"SoC"` → `battery_level`）

#### 统计总览（statistics.json）
- 升级费用归因算法（同 charging-stats.json）
- 修复 `high_precision` 变量过滤逻辑

#### 地点筛选（charges.json）
- 修复 `geofence` 变量初始化异常（同 drives.json）

#### 当前充电状态（overview.json）
- 修复电池加热条件判断：同时支持 `battery_heater_on` 和 `battery_heater` 两个字段

#### 足迹地图（visited.json）
- 修复 SQL 双引号 Bug：`"$length_unit"` → `'$length_unit'`（PostgreSQL 中双引号为列标识符，导致 SQL 报错）
- 修复面板高度（Panels 5/6/7：`h:6` → `h:2`）
- 修复时区显示

#### 充电详情（charge-details.json）
- 修复时区显示

### 📚 文档更新

- **新增行程地址不显示排查说明**：Nominatim 地理编码服务在国内受限，通过 `NOMINATIM_PROXY` 环境变量配置代理（仅支持 HTTP 代理）
- **新增子路径部署说明**：反向代理子路径场景下通过 `URL_PATH` 环境变量配置路径前缀
- 补充小白用户安装指引

---

## [v1.3.2] - 2026-03-19

### 🐛 Bug 修复

- 修复方法四（只替换镜像）升级后 Grafana 无法启动：`Dockerfile` 新增 `DATABASE_PORT` / `DATABASE_SSL_MODE` 默认值环境变量
- 修复 Dashboard 仪表盘跑到根目录：`dashboards.yml` folder 改为 `TeslaMate`
- 修复数据源环境变量未生效问题

### ✨ 新功能

- 新增 Docker Hub 镜像同步，国内用户可通过 `bswlhbhmt816/teslamate-chinese-dashboards` 拉取
- 新增每周定时自动重建镜像，自动修复基础镜像安全漏洞

### 📚 文档更新

- 新增完整快速入门文档（QUICKSTART.md）
- 新增故障排查手册（TROUBLESHOOTING.md）
- 新增 Docker Hub 拉取说明

---

## [v1.3.1] 及更早

早期版本，完成基础中文汉化工作。
