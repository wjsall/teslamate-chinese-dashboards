# TeslaMate 中文仪表板维护指南

---

## 一、项目结构

```
grafana/dashboards/
├── zh-cn/ # 主要中文仪表板（用户可见）
└── internal/ # 内部仪表板（行程/充电详情页）
 └── drive-details.json
Dockerfile # 构建 Docker 镜像
```

**Dockerfile 关键路径：**
```dockerfile
COPY grafana/dashboards/zh-cn/*.json /dashboards/
COPY grafana/dashboards/internal/*.json /dashboards_internal/
```
> ⚠️ internal 目录必须复制到 `/dashboards_internal/`（带下划线），写成 `/dashboards/internal/` 会导致该页面永远显示英文。

---

## 二、翻译规则

### ✅ 可以翻译的地方

| 位置 | 说明 |
|------|------|
| `panel.title` | 面板标题 |
| `fieldConfig.overrides[].properties[].displayName` | 字段显示名 |
| `fieldConfig.defaults.displayName` | 默认显示名 |
| SQL 中纯展示用的列别名（无 transformation 引用） | 图表图例/提示 |

### ❌ 绝对不能翻译的地方

| 位置 | 原因 |
|------|------|
| `transformations[organize].indexByName` 的**键名** | 必须与 SQL 实际列名完全一致，否则列顺序乱掉 |
| `transformations[filterFieldsByName].include.names` 的值 | 必须与 SQL 列名一致，否则面板无数据 |
| `transformations[calculateField]` 引用的字段名 | 计算来源字段名 |
| `transformations[configFromData]` 的 `refId` | 必须匹配 target.refId |
| `options.xField` / `options.colorByField` | 引用真实字段名，翻译后图表报错 |
| `series[].x` / `series[].y` / `series[].pointColor.field` | XY 散点图轴配置 |
| `target.refId`（A/B/C 或自定义） | transformation 通过 refId 识别数据源 |

> **核心原则**：SQL 列名和所有引用它的地方必须保持一致。要改就全部一起改，不能只改一处。

---

## 三、常见错误类型及修复

### 错误 1：SQL 列别名与 transformation 脱节
**症状**：面板显示"No data"或列顺序错乱

**原因**：翻译了 SQL 的 `AS "列名"` 但忘记同步更新 transformation 里的引用。

**检查要点**：
- `organize.indexByName` 的键 = SQL 列名 ✓
- `filterFieldsByName.include.names` 的值 = SQL 列名 ✓
- `xField` / `colorByField` = SQL 列名 ✓

**实际案例**：
- `timeline.json`：SQL 列名改成中文（开始/结束/操作/时长），但 `organize.indexByName` 仍用英文（Start/End/Action/Duration），导致列顺序错乱
- `MileageStats.json`：SQL 列名是 `"周期"`，但 `filterFieldsByName` 里写的是 `"Period"`，导致面板无数据

---

### 错误 2：rawSql 内引号是转义格式，字符串替换会漏改
**症状**：XY 图轴配置更新了，但图表仍然显示"Err"

**原因**：JSON 里 rawSql 中的引号存储为 `\"`（转义），用简单的文本替换只能改到 JSON 属性级别的引号，SQL 内部的转义引号改不到。

**实际案例**：把 `"Power [kW]"` 改为 `"功率 [kW]"` 时，XY 轴配置改了，但 rawSql 里的 SQL 语句没改，导致图表找不到字段报错。

**正确修改方式（用 Python）**：
```python
import json
with open('file.json') as f:
 d = json.load(f)
# 直接操作 target['rawSql'] 字符串
for panel in d['panels']:
 for t in panel.get('targets', []):
 t['rawSql'] = t['rawSql'].replace('"旧名称"', '"新名称"')
with open('file.json', 'w') as f:
 json.dump(d, f, ensure_ascii=False, indent=2)
```

---

### 错误 3：datasource type 填错
**症状**：模板变量报错，筛选下拉框无数据

| 位置 | 错误值 | 正确值 |
|------|--------|--------|
| `templating.list[].datasource.type` | `"postgres"` | `"grafana-postgresql-datasource"` |
| `__requires[].id` | `"postgres"` | `"grafana-postgresql-datasource"` |

**批量检查命令**：
```bash
grep -rl '"type": "postgres"' grafana/dashboards/
grep -rl '"id": "postgres"' grafana/dashboards/
```

---

### 错误 4：datasource UID 硬编码了个人实例的 UID
**症状**：地图或特定面板无数据，报"datasource not found"

**原因**：从个人 Grafana 导出的 JSON 含私人 UID（如 `PC98BA2F4D77E1A42`），其他用户 Grafana 里不存在。

**正确值**：所有 datasource uid 必须是字符串 `"TeslaMate"`

**检查命令**：
```bash
grep -rn '"uid"' grafana/dashboards/ | grep -v '"TeslaMate"\|__inputs\|__requires'
```

---

### 错误 5：图表图例/悬浮提示出现英文
**症状**：鼠标悬浮在图表上出现英文字段名

**原因**：SQL 列别名是英文，且没有对应的 `displayName` override。

**修复方式**：在对应 panel 的 `fieldConfig.overrides` 里添加：
```json
{
 "matcher": { "id": "byName", "options": "english_field" },
 "properties": [{ "id": "displayName", "value": "中文名称" }]
}
```

> ⚠️ 对于 barchart 的 `xField` 引用的字段，不能改 SQL 列名，只能用 displayName override 改显示名，SQL 列名保持英文。

**实际案例**：
- `battery_heater` → 电池加热器
- `is_climate_on` → 空调开关
- `fan_status` → 风扇状态
- `SOC` → 电量
- `SoC Diff` → 电量差
- `Power [kW]` → 功率 [kW]
- `B - Avg Power [kW]` → B - 平均功率 [kW]

---

### 错误 6：Grafana 12 模板变量相关
**症状**：Query 类型模板变量出现错误提示

**修复 1**：每个 `type: "query"` 的变量需要加：
```json
"regexApplyTo": "value"
```

**修复 2**：`$aux` 变量的 SQL 中 `json_build_object(...)` 后面必须加 `#>> '{}'`：
```sql
-- 错误（返回 JSON 类型）
json_build_object('key', value) AS alias
-- 正确（返回文本类型）
json_build_object('key', value) #>> '{}' AS alias
```

---

## 四、术语对照表

| 英文 | 中文 |
|------|------|
| Overview | 概览 |
| Charging | 充电 |
| Driving | 驾驶/行驶 |
| Consumption | 能耗 |
| Range | 续航里程 |
| Odometer | 里程表 |
| Temperature | 温度 |
| Statistics | 统计 |
| SOC / SoC | 电量 |
| SoC Diff | 电量差 |
| battery_heater | 电池加热器 |
| is_climate_on | 空调开关 |
| fan_status | 风扇状态 |
| Power [kW] | 功率 [kW] |
| Avg Power | 平均功率 |
| Duration | 时长/持续时间 |
| Distance | 距离 |
| Efficiency | 效率 |

---

## 五、收到 PR 时的验收清单

```
□ SQL 列名改了吗？→ 检查 transformation 引用是否同步更新
□ 有 "type": "postgres"？→ 改为 "grafana-postgresql-datasource"
□ datasource uid 都是 "TeslaMate"？→ 不能有私人 UID
□ refId 有没有被翻译？→ 不能翻译
□ xField/colorByField/series 轴配置与 SQL 列名是否一致？
□ rawSql 里的列别名和 organize/filterFieldsByName 是否一致？
□ internal/ 里的文件是否也同步修改了？
□ JSON 格式是否合法？
```

**快速 JSON 格式验证**：
```bash
for file in grafana/dashboards/zh-cn/*.json grafana/dashboards/internal/*.json; do
 python3 -m json.tool "$file" > /dev/null || echo "❌ JSON 格式错误: $file"
done
```

---

## 六、快速排查命令

```bash
# 检查 datasource type 错误
grep -rl '"type": "postgres"' grafana/dashboards/

# 检查硬编码私人 UID
grep -rn '"uid"' grafana/dashboards/ | grep -v '"TeslaMate"\|__inputs\|__requires'

# 检查英文 displayName（可能漏译）
grep -rn '"displayName": "[A-Z]' grafana/dashboards/zh-cn/

# 检查 SQL 中仍有英文的可见别名
grep -rn 'AS "[A-Z][a-zA-Z ]' grafana/dashboards/zh-cn/
```

---

## 七、部署流程

```bash
# 修改文件后推送到 GitHub main 分支
git add . && git commit -m "fix: 描述" && git push origin main

# GitHub Actions 自动构建新镜像（约 3-5 分钟）

# 用户更新镜像
docker compose pull && docker compose up -d
```
