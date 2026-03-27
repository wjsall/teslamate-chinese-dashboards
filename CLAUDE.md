# TeslaMate 中文仪表盘 — Claude 工作规则

本文件在每次对话时自动加载，所有规则强制执行。

---

## 零、自我纠错规则（最高优先级）

**每当发生以下任意一种情况，必须在当次对话结束前主动提议更新 CLAUDE.md 或 Memory，不等用户提醒：**

- 发现自己的判断或结论是错的（如误报 bug、误判路径、误用变量名）
- 某个操作需要回滚或撤销
- 某个方案因范围失控、复杂度过高被放弃
- 用户纠正了我的做法

**触发动作：**
1. 当场承认错误，说明错在哪
2. 主动说："这条经验值得记录，我来更新 CLAUDE.md / Memory"
3. 立即执行更新，不等对话结束时被提问才做

**为什么：** 被动等用户提醒才总结，意味着用户要多做一步，且容易遗漏。错误发生的当下是记录成本最低、细节最清晰的时机。

---

## 一、调查与核实原则（最重要）

### 先查官方，再动手
参考优先级：**官方 TeslaMate（adriankumpf）> jheredianet 原版 > 自行推导**

1. 官方有对应面板 → `gh api repos/adriankumpf/teslamate/contents/grafana/dashboards/xxx.json` 拉取原始 SQL，以官方为基准做中文适配
2. 官方无 → 查 jheredianet：`gh api repos/jheredianet/Teslamate-CustomGrafanaDashboards/contents/dashboards/xxx.json`
3. 两者均无 → 原创，commit 中注明

**版本号、路径、配置项有疑问时，也必须先查官方文档再下结论，不能凭印象直接说"这里有错"。**
曾发生：误判 `postgres:18-trixie` 和 `/var/lib/postgresql` 数据卷路径为错误，实际均符合官方标准。

### 上游有同样实现，不改
发现疑似 bug → 先对比 jheredianet 原版 → 原版一样 → 标注为"已知行为，同上游"，不修改。
曾发生：CurrentChargeView `$__timeFilter` 导致默认时间范围无数据，上游同款，不算 bug。

### 先核实，再上报
找到疑似问题 → 找第二个权威来源验证 → 确认后才上报。
**不能用"两个文档互相印证"作为验证**（可能同时错）。
曾发生：`GF_DEFAULT_LANGUAGE` 全项目集体写错，应为 `GF_USERS_DEFAULT_LANGUAGE`。

### 需求实现前先估完整范围
涉及超过 3 个文件，或需要数据库变更 → 先列完整方案报给用户确认，再动手。
曾发生：高德地图需求实际涉及 env var + 7 个 JSON + PostgreSQL 函数 + 6 个仪表盘 SQL，最终因复杂度高全部回滚。

---

## 二、文档审查规则

修改文档中的数字或名称时，必须做「三层检查」：

**层 1 — 全局搜索**
```bash
grep -rn "旧数字或旧名称" . --include="*.md" --include="*.sh" --include="Dockerfile"
```

**层 2 — 局部数字验证**
- 段落标题写「N个」→ 实际数一数列表条目是否等于 N
- 总计 = 各分类之和（用 python3 验证加法）
- 百分比列跟着重算

**层 3 — 跨文件一致性**
- 同一概念在所有文件的说法必须一致（如 README 和 TROUBLESHOOTING 的镜像源列表）

**补充：**
- 镜像源（registry-mirrors）会随时间失效，审查时顺手核实
- `registry.docker-cn.com` 已于 2023 年 5 月关闭，勿再使用

---

## 三、SQL / Grafana 技术规则

### 改之前先找参考对象
修 xychart/bargauge/barchart 等面板前，先 `grep -rl "type.*xychart"` 找同目录中已可工作的同类型面板，直接对比 options/fieldConfig。

### 读完整 SQL，不靠片段
核实 SQL alias / override matcher 匹配问题时，必须读完整 rawSql，重点看**最外层 SELECT 的 AS 别名**。
CTE（WITH ... AS）的内部列名是中间变量，不是最终输出列名。
曾发生：搜到 CTE 内部 `update_duration_secs`，误判 override `update_duration` 不匹配，实际外层正确，改了反而破坏。

### Override 修复必须全文搜索
修 displayName / override 显示问题时，先用脚本找出 dashboard JSON 中**所有**含该字段的面板，确认每一处都修到。
注意重复 override（同一字段出现两次，最后一个生效）。

### SQL 列名与 override matcher 必须一一核对
修显示名时，同时检查 SQL SELECT 的列别名是否与 matcher options 一致。
常见错误：matcher 写了中文名（如 `"充电添加能量"`），但 SQL 列名是英文（`charge_energy_added`）。

### PostgreSQL 时长 SQL 类型规则
`mod()` 不支持 `double precision`。秒数计算必须用：
```sql
EXTRACT(EPOCH FROM (end_date - start_date))::bigint AS secs
-- 然后用 % 运算符，不用 mod()
secs % 86400
```
不要用 `DATE_PART()` 计算秒数，改用 `EXTRACT(EPOCH FROM ...)::bigint`。

### 单位：禁止自动换算
禁止使用 `lengthkm`、`short`、`kwatth` 等会自动换算的单位，一律改用 `"unit": "none"`，在 displayName 或标题中手动标注单位（如 `(km)`、`(kWh)`、`(次)`）。
曾发生：`lengthkm` 把 28000 km 显示为 "28 Mm"，`short` 把 2034 显示为 "2 K"。

### 柱状图不加趋势线
`drawStyle: "bars"` 的面板一律不加 regression transformation 趋势线。
只在折线图（`drawStyle: "line"`）或散点图（`drawStyle: "points"`）上加。

---

## 四、工作流规则

### 中文 override matcher 是汉化遗漏高发区
发现某面板有 override matcher 未匹配列名时，立即全局扫描：
```bash
grep -rn '"options": "充电\|"options": "行程\|"options": "能量\|"options": "里程\|"options": "时长\|"options": "电量' grafana/dashboards/zh-cn/
```
发现问题用脚本批量修，不要逐文件手改。

### 修链接前先确认目标存在
修 dataLink URL 前先确认目标 dashboard uid 存在：
```bash
grep -rl "uid" grafana/dashboards/internal/
```

### 改配置前先看历史
```bash
git log --oneline -- <文件路径>
```
遇到"还是 Err"时，先确认用户是否已更新 docker 镜像，再找新原因。

### 面板报错先用浏览器看
面板显示 Err → 优先用浏览器 `Panel inspect → Query` 看完整错误信息，SQL 报错优先于配置格式报错。

### 类似问题批量修，不逐个改
单位问题、barchart min:0 等类似问题用 Python 脚本批量扫描修改，修完后用 grep 验证归零。

### Grafana 变量值插入 SQL
自定义变量值如果是字符串（非数字），用 `${var:sqlstring}` 格式强制加引号，防止 PostgreSQL 当列名报错。

---

## 五、GitHub Issues 处理规范

看到新 Issue → **先回复要求日志，不改代码**：
1. 要求用户提供：`docker compose logs grafana` 完整错误日志 + 镜像地址 + 安装方式
2. 同时列出最常见原因（数据卷冲突、配置错误等）
3. **等用户回复日志确认是项目 Bug 后**，再修改任何文件

---

## 六、NAS 操作规则

```bash
# scp 必须加 -O，否则报 "No such file or directory"
scp -O -o StrictHostKeyChecking=no 文件 wjsall@192.168.31.135:/目标路径/

# NAS 信息
# IP: 192.168.31.135 | 用户名: wjsall
# TeslaMate 目录: /volume1/docker/teslamate/
# Grafana 容器名: teslamate-grafana-1
# Grafana 地址: http://192.168.31.135:3000
```

---

## 七、关键配置备忘

| 项目 | 正确值 | 错误值（勿用） |
|------|--------|--------------|
| Grafana 语言环境变量 | `GF_USERS_DEFAULT_LANGUAGE=zh-Hans` | `GF_DEFAULT_LANGUAGE=zh-Hans` |
| PostgreSQL 数据卷路径 | `/var/lib/postgresql`（官方标准） | `/var/lib/postgresql/data`（错误） |
| Docker Hub 镜像 | `bswlhbhmt816/teslamate-chinese-dashboards:latest` | — |
| ghcr.io 镜像 | `ghcr.io/wjsall/teslamate-chinese-dashboards:latest` | — |
| Dashboard 总数 | 40个（含 9 个原创） | 38 / 39（已过时） |

---

## 八、测试发版流程

1. 本地修改 JSON 文件
2. scp 推到 NAS 测试（10 秒自动生效，无需重启）：
   ```bash
   scp -O grafana/dashboards/zh-cn/xxx.json wjsall@192.168.31.135:/volume1/docker/teslamate/dashboards/zh-cn/
   ```
3. 刷新浏览器验证（http://192.168.31.135:3000）
4. 用户确认满意后，git commit + push → GitHub Actions 自动构建镜像
