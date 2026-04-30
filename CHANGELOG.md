# 更新日志

## [v1.5.0] - 2026-04-30

### ⚡ 重磅：分时电价系统 + 充电桩性价比榜（中文版独有）

国内电网普遍有峰平谷电价，TeslaMate 默认只能存一个固定单价。家充实际花了多少钱、什么时段最便宜、有没有错开峰段 — 一片黑箱。

**v1.5.0 把 分时电价配置 + 历史回填 + 全仪表盘自动按真实费用显示，全部一键打通。**

#### 🆕「⚡ 分时电价配置」全新仪表盘

- **24 小时电价分布柱图**：按所选充电点 + 当前日期，每小时单价绿/黄/橙/红自动着色
- **配置审计**：自动检查时段空缺 / 重叠 / 月份未配置，0 行 = ✓ 配置完整
- **⚡ 一键填一整季节**：填谷+峰时段 + 3 档单价，平价自动占剩余；高级模式还可加尖 / 深谷
- **🌆 一键导入城市模板**：北京/上海/深圳/广州/浙江/江苏 6 套 2025 参考价
- **✏️ 修改单价 / 🗑️ 删除整段 / 🔄 重算所有历史**
- **💰 最近 10 笔家充对账**：原费用 vs 分时 vs 差额一目了然

#### 🆕「🏆 充电桩性价比榜」全新仪表盘

按真实 ¥/度（家充走分时电价，第三方走原价）排序：

- **排行榜表格**：累计费用 / 累计电量 / **¥/度（分时）** / **¥/度（原价）** / 平均功率 / 次均费用
- **¥/度 Top 10 横排柱图**：颜色分档（绿=家充谷段 / 黄=平 / 橙=峰 / 红=超充）
- **30 天 vs 之前涨/降价对比**（≥5% 红绿提示）
- **充电桩地图**：颜色 = ¥/度，圆点大小 = 充电次数

#### 🔧 数据库基础设施（不动 TeslaMate 任何表）

- `tou_rates` 配置表 + `charging_processes_tou_cost` 旁路表
- `compute_tou_cost(cp_id)` — 按 charges 表逐秒采样加权算分时电价真实费用
- `effective_cost(cp_id, fallback)` — 透明函数：旁路有则用分时电价，否则回退原 cost
- 触发器 `tou_recalc` 充电完成自动算（异常吞掉不阻塞 TeslaMate 主流程）
- 季节判断忽略年份、处理跨年环绕（12-2 月冬季）
- `audit_tou_config()` / `dedup_tou_rates()` / `backfill_all_tou()` 审计/去重/回填工具
- DB 层 UNIQUE 索引防完全重复

#### 📊 9 个仪表盘 60+ 处 SQL 自动适配分时电价

`scripts/wrap-cost-with-tou-view.py` 按 SQL 子查询作用域分析包装 9 个核心仪表盘：

- 充电费用统计、省钱分析、年度报告、多车对比、充电桩排行榜、超充总费用、平均每度电价、累计总费用 等
- 装了分时电价的用户透明显示分时电价真实费用
- **没装分时电价的用户 fallback 原 cost，无任何感知差异**
- 一键回滚：`python3 scripts/wrap-cost-with-tou-view.py --revert`

#### 🚀 升级路径

`scripts/upgrade.sh` 整合 6 步（地图 + 分时电价 + 插件 + Grafana 重启）：

```bash
bash scripts/upgrade.sh
```

新装用户拉镜像自动带 `volkovlabs-form-panel` 插件（Dockerfile `ENV GF_INSTALL_PLUGINS`）。

#### 🛠️ 配套工具

- `scripts/setup-tou.sh` — CLI（install / import / list / test / reset）
- `scripts/tou-wizard.sh` — 5 步交互式向导
- `scripts/build-tou-dashboard.py` / `scripts/build-station-ranking.py` — 仪表盘生成器（避免 JSON 手写）
- `scripts/lib/detect-containers.sh` — 容器检测公共函数（3 脚本共用）

### 🐛 安全 + 重构

- **修 SQL 注入**：所有 `${payload.X}` 数值参数 `NULLIF('${...}', '')::INT/NUMERIC` 强转
- **修 SQL 注入**：shell 脚本 `'$geofence_name'` 改用 psql `:'gname'` 变量代入
- **去重**：`_tou_delete_season()` SQL helper / `RATE_THRESHOLDS` / `RATE_LIST_INITIAL_SQL` / `season_range_elements()` 公共常量
- **删死代码**：`has_unaliased_charging_processes` 函数 + `n=0` 重复赋值
- **数据源单一化**：删 `sql/tou-templates/` 7 个 SQL 文件，城市模板迁移到 `apply_city_template()` PG 函数

### 📚 文档更新

- README.md 顶部加 v1.5.0 升级提示
- QUICKSTART.md 新增「分时电价配置」章节
- 4 路并行代码审查（Security / Reuse / Quality / Efficiency），22 项 finding 全部处理或归档

---

## [v1.4.2] - 2026-04-28

### 🌏 重磅：地图源一键切换 + 自动 GCJ-02 坐标纠偏（中文版独有）

国内 TeslaMate 用户 3 年来的痛点：原版只支持 OpenStreetMap，国内加载慢；想用高德要手动改每个面板的 XYZ URL，git pull 会被覆盖；切高德后还得手写复杂的 SQL 把 WGS-84 坐标转 GCJ-02 才能让车辆轨迹贴合道路 —— 改完一次至少半小时，下次升级又重来。

**v1.4.2 把这一切变成下拉框两步操作。**

#### 6 个内置地图源

9 个含地图的仪表盘顶部统一新增「地图源」下拉框：

| 选项 | 适用 | 坐标系 | 网络要求 |
|------|------|--------|---------|
| **OpenStreetMap** | 默认/全球通用 | WGS-84 | 国内访问慢 |
| **高德地图** | 中国大陆首选（路网详细，加载快） | GCJ-02 | 国内直连 ✓ |
| **高德卫星** | 中国大陆卫星俯瞰 | GCJ-02 | 国内直连 ✓ |
| **谷歌地图** | 海外华人首选（中文路网） | GCJ-02 (国内区域) | 海外直连，国内需翻墙 |
| **谷歌卫星** | 海外卫星视图（高清） | WGS-84 | 海外直连，国内需翻墙 |
| **Carto 浅色** | 极简风格 | WGS-84 | 全球可达 |

#### 自动 GCJ-02 坐标纠偏（数据库函数）

新增 4 个 PostgreSQL 函数，按当前选中的地图源 URL 自动判断是否需要做 GCJ-02 转换：
- `wgs84_to_gcj02_lat()` / `wgs84_to_gcj02_lng()` — eviltransform 标准算法，中国境内误差 < 0.5m
- `lat_for_map()` / `lng_for_map()` — 包装函数，URL 含 `autonavi` 或 `google.com` 路网模式时自动转 GCJ-02

10 个 geomap 面板的 SQL 全部用包装函数透明替代原 latitude / longitude 引用。用户切换地图源 → 数据自动按对应坐标系返回 → 车辆轨迹永远贴合道路。

中国境外坐标自动短路（不转换），海外用户切回 OSM/Google 卫星等 WGS-84 源时无副作用。

#### 安装坐标转换函数

```bash
docker exec -i teslamate-database-1 psql -U teslamate teslamate \
  < sql/install-coord-functions.sql
```

一次性安装。新版镜像后续会内置自动安装。

### 🛠️ 配套基础设施

- 9 个 geomap 面板的 basemap 配置统一为 xyz + `${map_url}` 变量插值（之前 internal/charge-details 和 internal/drive-details 还在用 `osm-standard` preset，本次一并迁移）
- basemap 增加 `minZoom: 3 / maxZoom: 18` — 修复放到最大缩放后空白（高德/谷歌免费瓦片只到 z=18，超出会 404）
- 修正 v1.4.0 起遗留的「QUICKSTART 仪表盘漏写 internal/charge-details 和 drive-details」（之前文档说 7 个仪表盘有地图，实际是 9 个）

### 📚 文档更新

- **QUICKSTART.md** — 进阶配置章节重写：从「手动改 9 个面板 XYZ URL + 写 SQL」简化为「下拉框选 + 装一次 SQL 函数」
- **TROUBLESHOOTING.md** — 「地图不显示」FAQ 加 v1.4.2 下拉框切换；新增「切换高德/Google 路网后标记偏移」FAQ（解释自动纠偏行为）
- **CLAUDE.md** — 完善 push 前评估流程

### 🔧 用户/维护者新增文件

**用户运行:**
- `sql/install-coord-functions.sql` — PostgreSQL 坐标转换函数定义（升级时一次性灌入）

**仓库维护者一次性迁移工具（普通用户不用跑）:**
- `scripts/add-map-source-switcher.py` — 批量给仪表盘加 `map_url` 变量
- `scripts/wrap-coord-with-map-fn.py` — 批量包装 SQL 的 lat/lng 引用

### ⚠️ 已知行为

- 默认值是 OpenStreetMap，git pull 会重置已选项 → 长期想用高德建议浏览器书签传 `?var-map_url=<encoded URL>`
- 高德 / Google 路网瓦片在中国大陆是 GCJ-02，**已自动转换**（无需手动）；OSM / Carto / Google 卫星是 WGS-84，原样
- 6 个非 geomap 的 table 面板（charges/drives/locations/timeline/trip）保留原始 WGS-84 坐标 —— 用于构造 TeslaMate「新建地理围栏」链接，绝不能转 GCJ-02

---

## [v1.4.1] - 2026-04-24

### 🐛 时区 Bug 修复

- **哨兵耗电（sentry-drain）** 第 8 面板「最近停车区间」时间列修正
  - 错误：`TO_CHAR(s.end_date AT TIME ZONE 'Asia/Shanghai', ...)` 把朴素 UTC 列当上海时区解读
  - 正确：`TO_CHAR((s.end_date AT TIME ZONE 'UTC' AT TIME ZONE '$__timezone'), ...)`

### 📊 单位显示优化（15 个面板）

- 统一移除 Grafana 自动换算单位（`lengthkm` / `lengthm` / `kwatth`），改用 `unit: none` + 标题/displayName 手动标注
- 避免 "28 Mm"（应为 28000 km）、"2 K"（应为 2034）等错误渲染
- 影响仪表盘：overview / CurrentDriveView / trip / range-degradation / annual-summary / driving-patterns / regen-braking / ChargingCostsStats / charging-stats / DCChargingCurvesByCarrier / battery-health / drive-stats / drive-details (internal)

### 🔤 电量曲线（charge-level）文案修复

- 修复列别名硬编码 `"30日"` 和 `"2h"`，改为动态变量 `${days_moving_average_percentiles}` 和 `${bucket_width:text}`
  - 用户调整「采样间隔」或「滚动天数」变量后，图例文案现在会同步更新
- 术语调整：`分桶` → `采样`，`日` → `天`（更口语易懂）
  - 示例：`30天滚动 7.5% 分位（按2小时采样）`
- 变量 label：`分桶宽度` → `采样间隔`

### 🔧 其他修正（随本次发版一并提交）

- **充电健康管理（charging-health）**：「充电前/后 SOC 分布」SQL 将 100% SOC 合并到 90% 桶（`LEAST(90, FLOOR(x/10)*10)`），避免 100% 单点数据稀疏
- **省钱分析（cost-savings）**：「预测年度费用」SQL 加入 `AT TIME ZONE 'UTC'`，避免朴素 UTC 列与 `NOW()`（tstz）比较时的时区边界错算
- **多车对比（vehicle-comparison）**：
  - 电池健康度表：移除 `WHERE max_cap.capacity IS NOT NULL` 过滤，显示所有车辆（空数据车辆显示 NULL）
  - 每公里电费表：移除 `WHERE d_stats.total_km > 0` 过滤，显示所有车辆
  - 电池健康度步进阈值：黄色 160 → 200 / 红色 200 → 300（UI 配色调优）

---

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
