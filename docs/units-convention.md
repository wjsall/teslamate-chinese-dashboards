# 单位约定 / Units Convention

> 项目内所有 Grafana 仪表盘单位字段的决策矩阵。新增面板或修改 override 前请先查这里。

## TL;DR

- **汇总型大数值面板**（年度/全部时间总和）→ **字符串单位**（`"km"` / `"kWh"` / `"分钟"` / `"元"`）
- **drill-down 单次详情面板**（一次行程 / 一次充电）→ **Grafana 内置单位**（`lengthkm` / `kwatth` / `velocitykmh`）
- **时长字段已 SQL 拼成中文字符串**（`"1时07分"`）→ `unit: "string"`，stat 面板还要 `reduceOptions.fields = "/.*/"`

## 决策矩阵

| 字段含义 | 数值典型量级 | 推荐 unit | 理由 |
|---------|-------------|----------|------|
| 距离（汇总：年度/月度/累计） | 1000 ~ 100000 km | `"km"` 字符串 | `lengthkm` 把 8076 km 显示为 `8 Mm` |
| 距离（drill-down 单次行程） | 1 ~ 500 km | `lengthkm` 内置 | 数值小不触发 Mm 换算，保留 i18n |
| 时长（未拼接中文） | 1 ~ 10000 min | `"分钟"` 字符串 | 内置 `m` 把 10080 min 显示为 `1 weeks` |
| 时长（已 SQL 拼接 `X时X分`） | 字符串 | `"string"` | stat 面板加 `reduceOptions.fields="/.*/"` 让字符串字段渲染 |
| 时长（drill-down 单次） | 任意秒数 | `clocks` 内置 → 不要用 | Grafana 内置输出 `1h:07m` 英文。统一用 SQL 拼接中文字符串 |
| 能耗 | 50 ~ 500 Wh/km | `"Wh/km"` 字符串 | TeslaMate 上游本身就是字符串，无内置 |
| 电量（汇总） | 100 ~ 100000 kWh | `"kWh"` 字符串 | `kwatth` 把 8842 kWh 显示为 `8.84 MWh` |
| 电量（drill-down 单次充电） | 1 ~ 100 kWh | `kwatth` 内置 | 数值小不触发 MWh 换算 |
| 速度 | 0 ~ 200 km/h | `velocitykmh` 内置 或 `"km/h"` 字符串 | 都不会换算，二选一统一即可 |
| 钱（人民币） | 任意 | `"元"` 字符串 | Grafana 没人民币内置 |
| 单位电费 | 任意 | `"元/度"` 字符串 | 复合单位无内置 |
| 次数 / 计数 | 任意 | `"none"` + displayName 加 `(次)` | `short` 把 2034 显示为 `2 K` |

## 为什么禁用 `lengthkm` / `kwatth` / `short` / `m` 在汇总型面板

Grafana 这些内置单位会按 SI 前缀**自动换算**：
- `lengthkm` ≥ 1000 → Mm（兆米），≥ 0.001 km → m（米）。0.66 km 显示为 `660.00 m`，8076 km 显示为 `8 Mm`
- `kwatth` ≥ 1000 → MWh
- `short` ≥ 1000 → K，≥ 1000000 → M
- `m`（分钟） ≥ 60 → hours，≥ 1440 → days，≥ 10080 → **weeks**（英文！）

**汇总型面板（累计/年度/总计）的数值常常落在换算阈值附近**，触发后用户看到 `8 Mm` / `8.84 MWh` / `1 weeks` 完全没法读。改用字符串单位避免。

## 为什么 drill-down 详情面板用回内置单位

drill-down（CurrentChargeView 当前充电、charge-details 单次充电、drive-details 单次行程）的数值**永远很小**（一次行程 5-50 km、一次充电 5-50 kWh），永远不触发 Mm/MWh 换算。

而上游 TeslaMate 在这些面板就用 `kwatth` / `lengthkm` / `short`。我们 v1.6.7 早期把它们一刀切改成 `"none"` 是错的——违反「上游有同款不改」原则，且失去 i18n（mile 用户拿到的是 km 数值）。v1.6.8 已全部回滚。

## 为什么时长要 SQL 拼中文而不是用 `clocks`

Grafana 内置 `clocks` 单位**强制英文**输出 `1h:07m`，没有中文/i18n 选项。改用 SQL 表达式拼 `"1时07分"` 字符串：

```sql
-- 输入是 minutes 的场景
CASE
  WHEN duration_min < 60 THEN duration_min::int || '分'
  ELSE floor(duration_min/60)::int || '时'
       || lpad((duration_min::int % 60)::text, 2, '0') || '分'
END AS duration_str

-- 输入是 seconds 的场景
CASE
  WHEN secs < 60 THEN secs || '秒'
  WHEN secs < 3600 THEN (secs/60) || '分' || lpad((secs%60)::text, 2, '0') || '秒'
  ELSE (secs/3600) || '时' || lpad(((secs%3600)/60)::text, 2, '0') || '分'
END AS duration_str
```

配套 override 设 `unit: "string"`。**stat 面板**还要把 `options.reduceOptions.fields` 从空字符串改成 `"/.*/"`，否则字符串字段被默认过滤掉显示空。

**列名建议**用 `duration_str` 而不是 `duration_min`——内容已是字符串，名字带 `_min` 误导且让列头点击排序按字母序错乱（`"45分"` 排在 `"1时07分"` 前）。

## 同一概念用同一个 displayName

- 表格里的「时长」列 → `时长`（短）
- stat 面板单值的持续时长 → `持续时间` 或 `时长`（按面板原意，二选一）
- 累加跨多次的 → `总时长`

不要混用 `时长(min)` `时长(分钟)` 这种带英文/单位后缀，单位由 unit 字段或 SQL 字符串本身承载。

## 历史踩坑（避免再犯）

- v1.6.7 把 `charge-details` / `drive-details` 8 处内置单位改成 `none` → drill-down 单次详情数字旁没单位 → v1.6.8 全回滚
- v1.6.8 第一版把 `unit: "none"` 试图改成 `unit: "none:kWh"` （误以为 Grafana 支持 `none:` 前缀）→ 显示字面量 `5.26 none:kWh` → 改用纯字符串单位 `"kWh"`
- v1.6.8 stat 面板单位 `clocks` → `string` 时漏改 `reduceOptions.fields` → 字符串字段被过滤显示空
- v1.6.8 表格列 `duration_min` 改 string 没改名 → 列头排序按字母序错乱（v1.6.8 修订版改成 `duration_str`）
