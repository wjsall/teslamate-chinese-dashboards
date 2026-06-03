# 更新日志

## [v1.7.10] - 2026-06-03

### 🆕 新增武汉/湖北居民充电分时电价模板（社区 PR，感谢 @zc8806）

「⚡ 分时电价配置」的城市模板新增 **武汉/湖北**（第 7 个城市）。时段与电价依官方 **鄂发改价管〔2023〕320号**（居民电动汽车充电桩分时电价，自愿申请）：

- 谷 23:00–7:00 `0.43`；平 7:00–17:00 `0.58`；峰 17:00–20:00 + 22:00–23:00 `0.68`；尖 20:00–22:00 `0.78`（元/度，全年统一，无季节性尖峰）。

三处同步：`apply_city_template()` + `list_city_templates()`（`sql/install-tou.sql`）+ `tou-config.json` 下拉。**已在 NAS 实测**：`list_city_templates()` 含武汉、`apply_city_template('wuhan')` 事务回滚测产出 5 行且电价逐项吻合、24h 覆盖无缝无重叠；电价数值交叉核实过（武汉市政府门户 + 国网湖北）。— PR #28，Closes #26

### 🔧 Dockerfile 注释修正 + Grafana 13.0.1 兼容确认

`Dockerfile` 注释原写「锁定版本」，但实际是 `FROM teslamate/grafana:latest`（跟随上游、不锁定），改为准确描述并把 `LABEL version` 补到当前版本。借此在 NAS 隔离环境用 **Grafana 13.0.1** 实测：45+3 个仪表盘全部 provision 成功、零面板类型/Angular/schema 报错，`volkovlabs-form-panel 6.3.2` 也正常装载 —— 上游将来发 G13 基础镜像时可平滑跟上。

> 本版镜像同时交付自 v1.7.7 以来 v1.7.8 / v1.7.9 的改动（备份脚本接入一键安装、备份默认含密钥可独立恢复、三选一菜单等，详见下方对应段落）。**升级看到武汉选项**：重跑 `upgrade.sh` / 一键脚本补装 SQL + `docker compose pull` 拉新镜像。

## [v1.7.9] - 2026-06-01

### 🆕 备份默认自洽：连密钥一起备，避免「备份了却恢复不了」

之前 `backup.sh` 故意不备份 `ENCRYPTION_KEY`，导致一个隐蔽的坑：用户辛苦做了每日备份，真出事（磁盘挂 / 重装）把 `docker-compose.yml` 一起搞没了，光剩数据库 dump **解不开、白备**。站在用户角度，最痛的失败就是「做对了备份却恢复不了」，本版默认堵上：

- **`scripts/backup.sh` 默认连 `docker-compose.yml`（含 `ENCRYPTION_KEY`）一起快照**（存成 `teslamate-compose-SECRET.yml`，只留最新一份），让每份备份都能**独立恢复**，用户不必再手抄那串复杂的随机密钥；
- **隐私警告 + 逃生口**：含密钥意味着拿到备份的人能解你的 Tesla token（token 能控车），脚本会提醒「备份目录务必私密、别公开分享」；安全顾虑大的用户可 `INCLUDE_CONFIG=0` 关闭（关了则需自己单独留底密钥）；
- **一键脚本给可选菜单**（不用手敲 env）：设置自动备份时三选一 ——「① 含密钥(推荐) / ② 不含密钥 / ③ 否」，选 ② 自动在定时命令里加 `INCLUDE_CONFIG=0`，并提醒你单独留底密钥；
- 自动查找 `docker-compose.yml`（`COMPOSE_FILE` 可显式指定），找不到则降级为纯数据库备份并提示；
- **一键脚本 + 文档对齐**：`simple-deploy.sh` 装完凭据区加一句「这三项也都在 `docker-compose.yml` 里，没抄到可找回」（消除恐慌）；设置自动备份时说明备份已含密钥；`TROUBLESHOOTING.md#db-backup` 新增「关于密钥与隐私」+ 恢复时先把 `teslamate-compose-SECRET.yml` 改回 `docker-compose.yml`；README 同步。

> 说明：`GRAFANA_PASS` 忘了可 `docker exec ... grafana cli admin reset-admin-password` 重置，不需备份；真正不可替代的只有 `ENCRYPTION_KEY`。

## [v1.7.8] - 2026-06-01

### 🐛 修复 + 🆕 一键脚本集成备份：之前的备份提示对一键用户是假的

v1.7.7 的备份提示和文档都写「仓库自带 `scripts/backup.sh`」，但一键安装（`simple-deploy.sh` / `curl|bash`）**根本不 `git clone` 仓库**（只 `cat` 出 docker-compose.yml + 按需 curl SQL），所以一键用户机器上压根没有这个脚本 —— 提示指向了一个不存在的文件。本版修正：

- **`simple-deploy.sh` 新增 `setup_backup()`**，fresh-install 与 upgrade 两条路径都调用：
  1. **必修**：`curl` 把 `backup.sh` 拉到 `~/teslamate-chinese/backup.sh`（一键用户终于真有这个脚本了）；
  2. **交互提问**「设置每日 03:00 自动备份？[Y/n]」—— 通用 Linux 选 Y 直接幂等写入 crontab（已存在不重复加、升级时不再追问）；**群晖 DSM** 因不认普通 crontab 改打印任务计划步骤；非交互（`curl|bash`）模式跳过，提示 `AUTO_BACKUP=1` 重跑可启用；
  3. 沿用脚本原有安全保证 + 提醒 ENCRYPTION_KEY 单独留底。
- **`scripts/backup.sh` 改为单文件自包含**：没有 `lib/detect-containers.sh` 时（一键 curl 下来的单文件）内联同款容器探测兜底，`git clone` 场景仍优先复用共享 lib。
- **文档对齐**：`TROUBLESHOOTING.md#db-backup` 区分「一键用户重跑脚本最省事 / git clone 用户用 `scripts/backup.sh` / 手动 curl 单文件」三种来源，路径改为真实安装路径（`~/teslamate-chinese/backup.sh`），crontab 示例改用 `$HOME`（`~` 在 crontab 不展开）；README 升级备份段同步。

> 经验：加新依赖必须枚举所有安装入口（一键脚本 fresh + upgrade / git clone / 手动）逐一打补丁——v1.7.7 只覆盖了 clone 路径就发了。

## [v1.7.7] - 2026-06-01

### 🆕 新增 `scripts/backup.sh` —— 安全的数据库定期备份脚本

之前文档只给了一段 `pg_dump` 片段让用户自己拼，且只面向群晖 Hyper Backup，没有真正可挂定时任务的脚本，也没覆盖通用 crontab 用户。issue #25 又一次暴露大陆用户对「数据别丢」的刚需（行车历史不可逆）。

**新增 `scripts/backup.sh`**，安全第一：

- **失败绝不骗你**：`pg_dump` 报错 / 导出文件异常小 / `pg_restore -l` 校验归档损坏 —— 任一不通过立即中止，**绝不产出空文件、绝不删除任何已有备份**；
- **只在本轮成功后**才清理超出 `KEEP` 份的旧备份（count-based，比 `find -mtime` 更稳，备份再稀也不会误删最后一份）；
- 任何失败 `exit 1`（cron / 群晖任务计划据此报警），全程写日志到 `$BACKUP_DIR/backup.log`；
- 复用 `lib/detect-containers.sh` 自动探测容器（与 `upgrade.sh` 同源），可用 `DB_CONTAINER` 覆盖；env 可配 `BACKUP_DIR` / `KEEP`；
- 兼容 bash 3.2（不用 `mapfile`），只写备份、从不碰数据库，回滚天然安全。

**文档同步：**

1. `TROUBLESHOOTING.md`「定期自动备份数据库」（ASCII 锚 `#db-backup`）改为脚本驱动，并拆「**群晖 DSM** / **通用 crontab**」两个明确分支；
2. 强提醒 **ENCRYPTION_KEY 必须单独留底**（脚本不备份它，丢了恢复后 token 也解不开）；
3. 明确恢复要用 `pg_restore`（`-Fc` 格式），**不要**用 `psql <`（plain SQL 才用），并建议做完首份备份立刻演练一次恢复；
4. `README.md` 升级前备份段、`simple-deploy.sh` 部署收尾提示各加一行指引。

> 测试：本地以桩 `docker` 验证成功 / `pg_dump` 失败 / 归档损坏 / 文件过小四条路径；真机（群晖 NAS）跑通 322M 真实库导出 + `pg_restore -l` 校验 15 张表数据 + 错误容器名中止不删旧备份。`shellcheck` 通过。

> 镜像内容无变化（`scripts/` 不进 Docker 镜像，是 git 仓库脚本）。

## [v1.7.6] - 2026-05-24

### 🐛 同步上游修复：无 Geofence 时充电/行程仪表盘无法加载

**症状：** 全新部署或地理围栏被清空后，「充电记录」「行程记录」两个仪表盘顶部下拉框初始化失败，整个面板报 No data。

**根因：** Grafana 12.4.0 之后，内置 "All" 选项在 variable 查询无返回值时初始化异常（[grafana/grafana#119793](https://github.com/grafana/grafana/issues/119793)）。我们原本用「显式插入 `'All' as __text, -1 as __value` 行」的老方案绕过，这套方案在新版 Grafana 上仍会因初始值为空触发同一 bug。

**修法（同步上游 [teslamate-org/teslamate#5335](https://github.com/teslamate-org/teslamate/pull/5335)）：**

- `charges.json` / `drives.json` 的 `geofence` variable 改用 placeholder 方案：无 Geofence 时插入「占位（请先添加地理围栏）」占位行，让 Grafana 内置 `includeAll: true` 重新正常工作。
- SQL 用法（`'${geofence:pipe}' = '-1' OR geofence_id in ($geofence)`）和 `allValue: "-1"` 保持不变 —— 仪表盘所有面板的 SQL 不动，零兼容性风险。

### 🧹 清理：移除重复的「续航衰减」仪表盘

`RangeDegradation.json`（v1.7.0 从 jheredianet 移植的「续航衰减」，uid=`jchmRiqUfXgm`）与自创的 `range-degradation.json`（「续航退化分析」，uid=`range_degrad_cn`）功能重叠。后者经 11 次精调修复（浏览器崩溃、阈值误导、低电量外推噪声等用户反馈），保留为主版本；前者删除避免侧边栏混淆。

### 📊 上游核实结论（已自然规避，无需动）

借这次同步上游的机会，逐一核实了上游近期 4 项 dashboard 修复对我们的影响：

| 上游修复 | 我们状态 |
|---|---|
| #5198 trip.json `cost_mileage` 除零 | ✅ TOU 改造时已加 `nullif()` 保护 |
| 00ab26a charging-stats/statistics/trip incomplete data 处理 | ✅ 此前同步上游时已移植 `is_incomplete` 标记 |
| #5335 Geofence Placeholder | ⚠️ 真受影响 → **本版修复** |
| 5f530c5 dataLink timestamps `FLOOR/CEIL` 替代 `ROUND` | ⚠️ 仅 CurrentChargeView/CurrentDriveView 受 1ms 边界影响，暂留待后续 |

## [v1.7.5] - 2026-05-17

### 🐛 关键修复：TOU 分时电价费用偏低 5-15%（用户报告）

**症状：** Dashboard 显示的分时电价费用永远低于充电桩 App 账单。

**根因：** `compute_tou_cost()`（`sql/install-tou.sql:178`）用 `charge_energy_added`（电池**实收**电量）乘以加权电价，但实际电费应按 `charge_energy_used`（充电桩**输出**电量，含充电损耗）计费。两者通常差 5-15%（慢充损耗更大），直接导致 TOU 费用偏低。

同一个 SQL 文件里 `set_default_charging_rate()`（v1.7.3 引入）已经正确使用 `GREATEST(charge_energy_added, charge_energy_used)`，并且注释明确写明「`charge_energy_used` 是充电桩输出（含损耗），通常 > `charge_energy_added`（车实际收到）」—— 但 `compute_tou_cost`（更早写的）忘了同步，本版补上。

**v1.7.4 让影响更明显：** v1.7.4 把 6 个 dashboard 改造成走 `effective_cost()`，这个偏差从原来只在 tou-config 对账面板，扩散到 6 个 dashboard 都显示，更多用户注意到对不上账单。

**修法：**

```sql
-- sql/install-tou.sql:187
SELECT geofence_id, GREATEST(charge_energy_added, charge_energy_used)
INTO cp_geofence_id, actual_kwh
FROM charging_processes WHERE id = cp_id;
```

跟 `set_default_charging_rate` / charges 仪表盘「电价」列算法对齐。

### 🔄 升级即自动回算历史费用

旧的 `cost_tou` 旁路表数据全是按 added 算的，函数改了**不会自动重算**。本版 `scripts/upgrade.sh` 在装完 `install-tou.sql` 后会自动调用 `SELECT backfill_all_tou()`，秒级扫描所有历史充电并按新公式重算 cost_tou。

**Watchtower / 自动镜像升级用户特别注意：** Watchtower 只换镜像、不跑 `upgrade.sh`，新公式不会自动套到旧数据上。**必须手动跑一次** SQL 回算（若 PG 容器名不是 `teslamate-database-1`，先 `docker ps | grep postgres` 查名替换）。

第一步，先装最新的 `install-tou.sql`（让 `compute_tou_cost` 函数升到 v1.7.5 公式）：

```bash
curl -fsSL "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/v1.7.5/sql/install-tou.sql" \
  | docker exec -i teslamate-database-1 psql -U teslamate -d teslamate
```

第二步，回算历史费用：

```bash
docker exec -i teslamate-database-1 psql -U teslamate -d teslamate \
  -c "SELECT * FROM backfill_all_tou();"
```

输出会显示扫描了几笔、回算了几笔、跳过几笔（未配 TOU 的）。

**安全说明：** `backfill_all_tou()` 只重写 `charging_processes_tou_cost` 旁路表（TOU 计算缓存），**不动 `charging_processes.cost` 字段**（你手填的单笔单价、默认电价填的兜底价完全保留）。算法权威，旁路表即使全部重算也不会丢用户数据。

---

## [v1.7.4] - 2026-05-16

### 🐛 统一费用口径（让现有 dashboard 用上 v1.5 引入的 `effective_cost()` 函数）

之前部分费用统计 dashboard SQL 直接读 `charging_processes.cost`，没经过分时电价（TOU）旁路表。结果：在「⚡ 分时电价配置」面板 21（默认电价）或「充电记录」面板 22（单笔单价）设过单价后，旁路表 `charging_processes_tou_cost.cost_tou` 已写入真实值，但这些 dashboard 显示的仍是原始 `cp.cost`，跟「⚡ 分时电价配置」里的费用对不上。

本版把 6 个含费用统计的 dashboard SQL 里 `cp.cost` / `c.cost` / `sum(cost)` 全部改成 `effective_cost(id, cost)`：

- 旁路表有 TOU 计算结果 → 显示真实分时电价费用
- 旁路表无结果 → 自动回退原始 `cp.cost`

涉及 dashboard：

- AmortizationTracker（车辆摊销追踪）
- ChargingCostsStats（充电费用统计）
- charging-stats（充电统计）
- station-ranking（充电站排名）
- statistics（统计）
- vehicle-comparison（多车对比）

**不影响：**

- 「⚡ 分时电价配置」面板 8（家充对账）保留 `cp.cost` 原值显示，用于对比
- 「充电记录」panel 22（单笔单价 form）仍读/写 `cp.cost` 不变

### 🐛 修复 tou-config「最近 10 笔家充对账」面板时间列偏 8 小时

原 SQL 用 `(start_date AT TIME ZONE 'UTC' AT TIME ZONE '$__timezone')::timestamp(0)` 返回朴素 timestamp，Grafana 接到朴素时间戳当 UTC 二次转换 → 中国用户早 7 点充电的记录显示成下午 15 点（+8 小时）。

修法：

- 改用 `date_trunc('second', start_date AT TIME ZONE 'UTC')` 返回 `timestamp with time zone`，Grafana 按 dashboard timezone 自动转换
- 同面板另一处 `NOW() AT TIME ZONE 'Asia/Shanghai'` hardcode 也改成 `$__timezone` 自适应

### 📊 drives（行程）仪表盘小改动

- 4 个 stat 面板加 `text.titleSize: 18, valueSize: 32`，移动端 / 小屏显示更清晰
- 行程列表 SELECT 加 `duration_min` 数值列（override 设为隐藏），用于按时长数值排序，不在表格展示

### 🔧 修复：Dockerfile LABEL version 长期滞后

v1.7.2 / v1.7.3 发版漏改 Dockerfile `LABEL version`（一直停在 `1.7.1`），本版补回到 `1.7.4`，跟实际版本对齐。

### ⚠️ 升级警告（重要）

**必须用 `scripts/upgrade.sh` 升级**。仅 `docker compose pull && up -d` 不会装 / 更新 SQL 函数 —— 本版 dashboard 调用 `effective_cost()`，PG 库里没装这个函数会报：

```
function effective_cost(integer, numeric) does not exist
```

正确升级方式：

```bash
cd teslamate-chinese-dashboards
git pull
bash scripts/upgrade.sh
```

如果你已经 `docker compose pull` 升过了 / 不想跑完整 upgrade，单独补 SQL 三件套即可（若你的 PG 容器名不是 `teslamate-database-1`，先用 `docker ps | grep postgres` 查实际名字再替换）：

```bash
for f in install-coord-functions install-tou install-indexes; do
  curl -fsSL "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/v1.7.4/sql/$f.sql" \
    | docker exec -i teslamate-database-1 psql -U teslamate -d teslamate
done
```

**Watchtower / 自动镜像升级用户特别注意：** Watchtower 只拉新镜像，不会跑 SQL。新镜像启动后 dashboard 立刻引用 `effective_cost()`，没装该函数会全部报错。**必须手动跑一次上面那段 `for f in ...` SQL 装载**，否则费用 dashboard 全部报错。

`effective_cost` 函数定义在 `install-tou.sql`，没装该函数升级后费用 dashboard 全部报错。

---

## [v1.7.3] - 2026-05-11

### 🆕 新功能：默认电价（解决 issue #21 — 未关联收藏点的充电费用空）

在「⚡ 分时电价配置」仪表盘底部新增 form panel：

> 💡 **默认电价（无位置充电用此价）**

国内用户外出快充经常充在不熟悉的充电站，没设置 geofence（收藏点）时这部分充电的 cost 列空、费用统计偏低。这次加了一个全局默认电价兜底：

- 在 form 里输入一个单价（如 1.4 元/度）→ 保存
- 所有未关联收藏点的充电（AC + DC 都覆盖）立即按此价计费
- 公式：`cost = GREATEST(charge_energy_added, charge_energy_used) × 单价`，跟「充电记录」表「电价」列一致
- 不覆盖 TeslaMate 已算的 / 你手填的 cost
- 留空 + 保存 = 清回 NULL（误填回滚 escape hatch）

技术上加了新 PG 函数 `set_default_charging_rate(p_rate)`，一次完成 tou_rates 表 UPSERT + charging_processes.cost UPDATE。

### 🆕 新功能：单笔充电单价（精细级）

在「充电记录」仪表盘底部新增 form panel：

> ✏️ **单笔充电单价（手动填/改）**

下拉选某次充电（【空】排前面优先填）+ 输入单价 → 该笔 cost 立即更新。可以：

- 反复改某次（覆盖默认电价 / 修正之前误填）
- 留空 + 保存 = 清回 NULL
- 保存前有确认对话框防止误操作
- max=10 元/度 防止手滑输入 1000

适合外出快充每次单价不同的精细场景。

### 🔧 修复：从官方 TeslaMate 迁移后「分时电价配置」5 个 form panel 报 panel not found（issue #20 / #21）

`volkovlabs-form-panel` 插件被 grafana volume 覆盖的坑（dockerfile 装在 `/var/lib/grafana/plugins` 正好是 volume 挂载点）。`migrate-from-official.sh` 和 `scripts/upgrade.sh` 现在都会**自动检测 + 兜底安装**：

- 优先 `grafana cli plugins install`（在线）
- 国内 `grafana.com` 超时自动 fallback 打印 `docker cp` 路径 A 命令（无外网依赖）
- 之前吞 stderr 的问题修了（现在能看到真实错误）

### 🇨🇳 国内用户痛点系统加固：NOMINATIM_PROXY 8 道防线

issue #20 / #22 都撞同一个坑：`nominatim.openstreetmap.org` 国内访问超时导致 TeslaMate 反向地理编码失败，行程列表「起始地址 / 结束地址」列大量为空。

修法是给 teslamate 容器加一行 env `NOMINATIM_PROXY=http://你的代理IP:7890`（TeslaMate 上游专用变量，HTTP only，仅代理 Nominatim 不影响 Tesla API）。

为避免后续用户继续踩，这次在 **8 处入口**都做了引导：

1. AI 自助排查 prompt（`docs/ai-troubleshooting-prompt.md` 问题 3）
2. TROUBLESHOOTING.md `#nominatim-proxy` ASCII 锚点（source-of-truth）
3. README.md「🇨🇳 中国大陆用户专项配置」段
4. `simple-deploy.sh` 装机时 compose 模板含 `# - NOMINATIM_PROXY=...` 注释占位
5. `simple-deploy.sh` 装完「下一步」提示
6. `migrate-from-official.sh`「下一步」提示
7. `scripts/upgrade.sh`「下一步」提示
8. `.github/ISSUE_TEMPLATE/config.yml` 第一个 contact link

### 📚 AI 自助排查 prompt 全面扩充

覆盖所有历史 issue 类型（#17 dashboard JSON 脏 current / #20-21 volkov 插件 volume 覆盖 / #22 Nominatim 超时 / PG < 18 date_trunc 报错）。AI 拿到 prompt 后会先问「整 dashboard 报还是单 panel 报」决定诊断方向，对三类典型问题（地址列空 / volkov panel 报错 / 升级 SQL 函数错）直接给具体修复路径，不再泛泛"等几小时"。

### ⬆️ 升级方法（**必须用方法 A，因为含新 PG 函数**）

**方法 A（推荐，自动装新 SQL 函数）**：

```bash
cd teslamate-chinese-dashboards
git pull
bash scripts/upgrade.sh
```

**方法 B（只更新镜像，不装新 SQL）**——仅适合「不需要默认电价 form」的用户：

```bash
docker compose pull && docker compose up -d
```

走方法 B 后想用默认电价 form panel 21 时，单独跑这条补装 SQL 函数：

```bash
curl -fsSL https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/sql/install-tou.sql | docker exec -i teslamate-database-1 psql -U teslamate -d teslamate
```

新装机用户（`simple-deploy.sh` / `migrate-from-official.sh`）会自动装好新 SQL，无需额外操作。

---

## [v1.7.2] - 2026-05-11

### 🆕 加 AI 自助排查机制（多数常见问题不用开 issue 就能解决）

新增 `docs/ai-troubleshooting-prompt.md` —— 给用户一份**完整项目背景 prompt**（含项目身份 / 镜像架构 / SQL 三件套 / 容器与 service 命名 / 常见 6 类问题排查思路 / 调试命令清单 / 回答规范），复制粘贴给任意主流 AI（Claude / ChatGPT / Kimi / 通义 / 豆包 / DeepSeek）+ 附上自己的日志，AI 就能基于项目上下文给出诊断方向。

为什么有效：多数常见问题（面板找不到 / 数据为空 / 容器起不来 / 迁移失败 / 地址显示空 / 升级失败）都是看一眼日志就能定位的，但通用 AI 不懂项目细节会给错答案；带项目 prompt 的 AI 答得比维护者回 issue 还快。

### 🆕 GitHub issue 模板

加 `.github/ISSUE_TEMPLATE/bug_report.md` + `config.yml`：

- **bug report 模板**：勾选「已先问过 AI 自助排查」+ 必填日志 + AI 诊断结论字段，让开 issue 前已有 AI 第一轮诊断结果，维护者跳过重复排查直接定位
- **config.yml contact links**：禁用空白 issue，引导用户先看 AI prompt / TROUBLESHOOTING / Telegram 群

### 📚 TROUBLESHOOTING.md 顶部加「先问 AI」一节

第一屏指引用户走自助路径，AI 没解决再走手动「诊断三板斧」。

### 🔧 工具脚本：migrate-from-official.sh 自动修 volkov 插件 volume 覆盖坑

从官方 TeslaMate 迁移时，「分时电价配置」5 个 form panel 报 `panel not found` 的根因是镜像内 plugin 目录被 grafana volume 覆盖。`migrate-from-official.sh` 现在会自动检测 + 兜底修复（grafana cli 在线装失败时打印「从镜像本地复制」的 docker cp 备选路径，照顾国内 grafana.com 超时用户）。**已经踩坑的 v1.7.0 / v1.7.1 迁移用户**：拉最新脚本重跑（`curl -fsSL -o migrate-from-official.sh https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/migrate-from-official.sh && bash migrate-from-official.sh`）即自动修，或者按 [TROUBLESHOOTING.md「从官方 TeslaMate 迁移后...」](TROUBLESHOOTING.md#-从官方-teslamate-迁移后分时电价配置整页报-panel-not-found-v170--v171-迁移用户) 手动 docker cp。

### 📚 修订 docs/units-convention.md

明确「速度统一用 velocitykmh 内置」决策（项目当前 13 处 vs `"km/h"` 字符串 5 处），合并 3 条自相矛盾的时长规则为 2 条「全 SQL 拼字符串」原则；SQL 模板补类型约束注释（`secs` 必须 bigint，否则 `mod(double precision, integer)` 错）；顶部加「维护者参考资料」声明。

### 兼容性

镜像 / SQL / dashboard JSON **完全没变**——latest tag 内容跟 v1.7.1 一致。本版只是新增文档 + 改 migrate 脚本。已部署用户 `git pull` 拉新文档即可，不需要重启 / 拉镜像。

---

## [v1.7.1] - 2026-05-08

### 🐛 多车主用户「车辆标准能耗」面板 No data

`CurrentDriveView`「车辆标准能耗」SQL 用 `FROM settings WHERE id = $car_id` — `settings` 表只有一行（id=1），多车主 car_id≠1 时永远不返回。改 `FROM cars WHERE id = $car_id`。同时把 SQL alias 从 `as "效率"` 改回 `as "efficiency_$length_unit"` 跟 v1.6.8 全局原则一致。

### 🐛 SpeedTemperature 仪表盘 SQL 报「/」语法错（issue #17）

dashboard JSON 残留了上游 jheredianet 导出时的脏 `current` 值（测试车名 `Maximus` / 测试域名 `infoinnova.net` / 测试电池容量 `58.47...`），多车主用户的 Grafana 12.4 看到这些跟自己 DB 对不上时进入变量初始化 race condition，仪表盘顶部下拉框不渲染 + 下游 panel 把字面量 `$datapoints` 直接发给 PG 报「/」语法错。

修法：
- 清 `car_id` / `base_url` / `current_capacity` 三个 query 类变量的脏 current（让 Grafana 启动时按用户 DB 重新查）
- 预填 `datapoints` / `speed_step` / `temperature_step` 三个 custom 类变量的 options 数组（不依赖运行时解析 query 字段）

### 🐛 tire-pressure 仪表盘内网 IP 信息泄露

dashboard JSON 残留 `base_url.current = "http://192.168.2.249:4000"`（导出者的内网地址）。改 `current: {}` 让 Grafana 重新查。

### 🛠️ 新增 dashboard 脏值 lint

`scripts/check-dashboards-clean.sh` 扫所有 dashboard JSON 的 `templating.current` 字段，发现 IP / 域名 / 计算结果残留就阻止发版。已接进 push 前 checklist。

### 兼容性

镜像 LABEL 1.7.0 → 1.7.1。**升级方法**：`docker compose pull && docker compose up -d`，仪表盘 10 秒内自动重载。**已经撞 issue #17 的用户**：升级镜像后 SpeedTemperature 应能正常加载；如果 Grafana state 还卡住，清缓存 `docker volume rm teslamate_teslamate-grafana-data && docker compose up -d`（不影响 TeslaMate 数据）。

---

## [v1.7.0] - 2026-05-07

### 🆕 移植 jheredianet 上游 3 个仪表盘（中文化适配）

跟上游 [jheredianet/Teslamate-CustomGrafanaDashboards](https://github.com/jheredianet/Teslamate-CustomGrafanaDashboards) 对齐，把我们之前缺失的 3 个面板整体移植 + 中文化：

- **续航衰减（Range Degradation）** - 满电续航按充电过程的趋势曲线 + 1d/7d/15d/30d 滑动平均；电池统计/行程统计 stat 面板；适合判断电池衰减节奏
- **回本分析（Amortization Tracker）** - 折旧曲线 + 累计省油钱对比；输入购车价/同级燃油车油费可看到「累计节省 + 残值」与「购车成本」的交叉点（回本时间）；帮助文本完整中文化（按持有时长/按里程两套折旧逻辑解释 + 表格列说明）；货币单位本地化为人民币
- **速度与温度（Speed & Temperature）** - 14 个面板按速度档 × 温度档双维度的能耗/续航/距离热力分析；含短/长途行程分桶 + 时序对比；适合理解「冬天到底掉多少电」「高速比城市多耗多少」的实际数值

仪表盘总数 **43 → 46**。

### 🐛 回本分析数学逻辑重做（上游 bug 一年多没人发现）

老公式把「单年折旧率（递减 5pp/年）」误当作「累计残值率」用，第二年起残值反而递增（车越折越值钱）。改成累计折旧率：

- 第 1 年累计 20% → 第 2 年 35% → 第 3 年 45% → 第 4-N 年封顶 50%
- 残值现在按预期单调递减，「折旧后车价 + 累计节省」曲线与购车成本红线相交点真实反映回本时间

同时修一组 UX 问题：

- 默认值本地化：购车成本 40000 → 263500 元、同级油费 0.108 → 1 元/km、回本曲线阈值 367000 → 263500
- 「周期」下拉框、「采样间隔」等英文选项 → 中文（月/年、1小时/2小时、是/否）
- 帮助文本重写：累计节省公式、列名、「电车每公里运行成本」语义（保养摊薄不含电费）澄清

### 🐛 数据精度 + 时间窗修复（跟齐官方 teslamate-org）

- **timeline.json**：dashboard 链接 timestamp 用 `ROUND` 让 drill-down 窗口过窄丢点 → 改 FLOOR(start) / CEIL(end)（停车段 + 缺失数据段方向相反，因 start 是上一活动的 end）
- **timeline / MileageStats / ChargingCostsStats**：`convert_km(... ::integer ...)` 转 km→mile 前丢小数（mile 用户每段 trip 偏 0.5 mi）→ 改 `::numeric`
- **SpeedTemperature**：日期分桶用朴素 UTC 列没做时区转换，中国用户 23:00 行程归错日期 → 内层 `to_char` 加 `AT TIME ZONE 'UTC' AT TIME ZONE '$__timezone'`

### 🐛 单位 / 翻译 / 显示修复

- 12 个仪表盘 displayName `时长(min)` / `时长(分钟)` 统一 → `时长` + `unit: "分钟"`
- 续航衰减：override regex 跟 SQL 中文 alias 同步（`/Odometer/`→`/里程/`、`/.avg*/`→`/平均/`）；总充电量/总用电量 `unit: kwatth` → `kWh` 字符串避免 MWh 自动换算
- 速度与温度：2 处 `displayName: "Distance"` 漏译 → 「行驶距离」
- 回本分析 / 续航衰减：模板变量类型 `interval` → `custom`，加 `text : value` 中文映射

### 🔐 PostgreSQL 18 与官方对齐

官方 teslamate-org 主分支当前默认 `postgres:18-trixie`，本项目同步要求 PG 18：

- `simple-deploy.sh` 默认 PG 18（无变化）
- `migrate-from-official.sh` 新增 PG 版本探测 + 备份升级流程提示：PG ≤15 直接退出（仪表盘必报错），PG 16/17 警告但允许跳过；失败时打印完整 8 步 `pg_dumpall → 删卷 → 换 image → 恢复` 命令
- README / QUICKSTART 系统要求段加 PG 18 + 链接 TROUBLESHOOTING「PostgreSQL 大版本升级」章节

### 📚 文档

- DASHBOARD_MAP 加 v1.7.0 移植段 + 「续航衰减（上游移植）vs 续航退化分析（项目原创）」差异说明
- README / QUICKSTART / TROUBLESHOOTING / DASHBOARD_MAP 仪表盘总数 43 → 46
- TROUBLESHOOTING 新增 Grafana 密码恢复章节

### 兼容性

镜像 LABEL 1.6.9 → 1.7.0。3 个新仪表盘自动加载，无需手动操作或 SQL。**升级用户**如在 PG ≤17，迁移到本项目前请先升级到 PG 18（备份流程见 TROUBLESHOOTING）。

---

## [v1.6.9] - 2026-05-06

### 🔐 安全增强（云主机）

- **simple-deploy.sh 自动检测云主机**（DMI 字符串 + metadata 端点 + 多家厂商识别：AWS/GCP/Azure/阿里云/腾讯云/华为云/Oracle/Vultr/DO/Linode/Hetzner）。检测到云时在脚本结尾打加粗警告，引导先收紧安全组 + 加反向代理，避免 4000/3000 公网裸奔。
- **Grafana admin 密码改为脚本生成的 18 位强随机**（替换原来的 `admin/admin` 默认）。脚本结尾跟 ENCRYPTION_KEY/DATABASE_PASS 一起打印，加超大边框 + 「仅显示这一次」+ 「丢失后果」三段提醒。

### 📚 文档

- 新建 `docs/units-convention.md` — Grafana 单位决策矩阵（汇总型用字符串单位避免 Mm/MWh/weeks 误显，drill-down 用内置单位保留 i18n），固化 v1.6.7-v1.6.8 反复踩坑的经验。
- README / QUICKSTART / TROUBLESHOOTING 三处「admin/admin」表述同步更新（旧版用户仍需手动改）。

### 🐛 displayName 一致性

12 个仪表盘 14 处 `时长(min)` / `时长(分钟)` displayName → 统一为 `时长` + `unit: "分钟"`（单位由 unit 字段承载，不再混入 displayName 后缀）。

### 🐛 drives.json id=2 SQL 重复列修复

v1.6.8 cover-release 把 outer SELECT 的 `duration_min` alias 改成 `duration_str`，但 inner CTE 早就有 `TO_CHAR(duration_min, 'HH24:MI') as duration_str`（HH:MM 英文格式）。outer SELECT 同时输出两个 `duration_str` 列，PG 不报错但 Grafana override 行为不可预测。本版删除 inner CTE 的 `TO_CHAR` 死字段 + outer 的透传引用 + 失效的 `custom.hidden` override。

### 兼容性

镜像 LABEL 1.6.8 → 1.6.9。**首次安装新用户**自动获得强随机 Grafana 密码；**升级老用户** docker-compose.yml 不变（密码沿用旧的 `admin` 或之前手动设置的值），需要自己改 Grafana 后台密码。

---

## [v1.6.8] - 2026-05-06

### 🐛 单位显示修复（系统性）

对 30 个仪表盘做单位全量核对，修复三类问题：

**1. 自动换算单位让大数值显示英文前缀**

- `kwatth` 把 8842 kWh 显示为 `8.84 MWh`（charging-stats / drive-stats / trip 等）
- `lengthkm` 把 8076 km 显示为 `8 Mm`、把 0.66 km 显示为 `660.00 m`（annual-summary / vampire-drain）
- `m`（分钟）把 10080 min 显示为 `1 weeks`（drives / DCChargingCurvesByCarrier）

修法：改用字符串单位 `"kWh"` / `"km"` / `"分钟"`（Grafana 把任何非内置字符串当后缀，不换算、不本地化）。

**2. override `unit: "none"` 让数字裸显示**

CurrentDriveView / CurrentState / overview / drives / drive-stats 等的 `range_km` / `distance_km` 字段 override 是 `none`，数字旁边没单位。改回 `lengthkm`（drill-down 单次详情值小，不会触发 Mm 换算）或 `km` 字符串。

**3. 缺少中文单位/费用/能耗提示**

补全：trip / visited / station-ranking 充电费用 `元`；charges / drives / DCChargingCurvesByCarrier 时长 `分钟`；weather-efficiency / battery-health 能耗 `Wh/km`；DCChargingCurvesByCarrier 单位电费 `元/度`；vehicle-comparison 费用 `元`；trip 平均速度 `km/h`；CurrentDriveView 能耗 `Wh/km`。

### 🐛 时长面板英文 → 中文

Grafana 内置 `clocks` / `m` 单位输出 `1h:07m` / `1 weeks` 这种英文。改 SQL 输出中文字符串 + `unit: "string"`：

- TrackingDrives「持续时间」→ `1时07分`
- ContinuousTrips「长途行程」持续时间列
- drives「行程」时长列
- charge-details / drive-details 时长列（之前已做 `时:分:秒` 拼接）
- CurrentChargeView 充电时间

⚠️ stat 面板 unit 从数字改 string 必须同步把 `reduceOptions.fields` 从 `""` 改成 `"/.*/"`，否则字符串字段被默认过滤显示空。

### 🐛 SQL 中文别名破坏 override（回退）

历史改动把上游 `as "$length_unit"` 翻译成 `as "单位"` / `as "效率"`，dead-string 让 override matcher 找不到列名：

- `charge-details` / `drive-details` / `ContinuousTrips`：`as "单位"` → `as "$length_unit"`
- `efficiency` / `SpeedRates`：`as "效率"` → `as "efficiency_$length_unit"`

### 🐛 charge-level 中文图例还原

之前一次 SQL 别名批量改动误把 `charge-level` 的 4 条图例（滚动 7.5%/平均/中位数/92.5% 分位）改回上游英文。本次还原。

### 🔄 上游对齐回滚

v1.6.7 v1.6.8 早期把 `charge-details` / `drive-details` 8 处 `kwatth` / `lengthkm` / `short` 改成 `none`，违反「上游有同款不改」原则——drill-down 单次详情数值小，根本不触发 Mm/MWh 换算。已全部回滚到上游原值。

### 🐛 simple-deploy.sh 真用户撞坑追加修复

- **`set -e` 让端口检测函数静默杀死脚本**：第 184 行 `check_port_free "$port"` 端口空闲时函数返回 1（lsof/ss 没找到监听 → 返回 1），裸调用站被 `set -e` 直接退出，下面的 `case $?` 永远跑不到。**症状**：干净环境（4000/3000 都空闲）跑脚本，banner + 工作目录之后**完全静默退出**，看起来像跑完了实际啥都没装。**修法**：调用站改 `rc=0; check_port_free "$port" || rc=$?; case $rc in ...`，把命令归到 OR 列表里 `set -e` 不触发。
- **Docker 缺失时不再直接 exit**：原来检测到 Docker 没装就抛错退出让用户自己装。改为按平台 OS 分流：
  - Linux (Ubuntu/Debian/CentOS/Fedora 等)：交互模式弹「Y/n」确认 → 同意就跑 `https://get.docker.com` 一键脚本自动装 + 起 daemon
  - 群晖 DSM：拒绝命令行装（会破坏系统），引导套件中心装 Container Manager
  - macOS：引导装 Docker Desktop
  - 非交互（curl|bash 等无 tty 场景）：用 `AUTO_INSTALL_DOCKER=1` 环境变量授权或先手动装

### 🐛 发版后审计追加修复

`/full-review` 四路审计发现 3 处可见 bug，已并入本版：

- **drives.json / ContinuousTrips.json**：表格列名 `duration_min` 跟内容（中文字符串 `"1时07分"`）不一致，列头点击排序按字母序错乱（`"45分"` 排在 `"1时07分"` 前）。修法：SQL alias 改成 `duration_str`，override matcher 同步换。displayName 仍是「时长」/「持续时间」用户无感。
- **drives.json id=9「不完整的行程」**：displayName `时长(分钟)` 改成 `时长` + `unit: "分钟"`，跟其他面板的中文单位约定对齐
- **charge-details / drive-details / CurrentChargeView 时长面板**：`EXTRACT(EPOCH FROM ...) IS NULL` 时（如 drill-down 拿到一个不存在的 `$drive_id` / `$charging_process_id`）整个 CASE 链返回 NULL → stat 面板「No data」空白。修法：用 `COALESCE(EXTRACT(...), 0)` 兜底为 0 秒

### 兼容性

镜像 LABEL 1.6.7 → 1.6.8。升级方法：`docker pull` 后 `docker compose up -d`，仪表盘 10 秒内自动重载。

---

## [v1.6.7] - 2026-05-06

### 🐛 修复

**1. 备份恢复孪生残留 bug**（`TROUBLESHOOTING.md` 第「数据库备份与恢复」段）：跟 v1.6.6 修的「整机迁移」同一根问题——简易备份恢复段也漏 `DROP SCHEMA private CASCADE` + `CREATE EXTENSION cube/earthdistance`。修后跟官方完全对齐。

**2. PostgreSQL 大版本升级章节**（新增 `TROUBLESHOOTING.md`「PostgreSQL 大版本升级」）：用户改 `image: postgres:18-trixie` 不删卷直接重启会进入 `database files are incompatible with server` 反复重启循环——官方 [upgrading_postgres](https://docs.teslamate.org/docs/maintenance/upgrading_postgres) 流程之前没在我们文档里覆盖到。

**3. 子路径反代缺 WebSocket 头**（`TROUBLESHOOTING.md` 第「反向代理后访问路径报错」段）：Nginx `location /teslamate/` 块漏 `proxy_http_version 1.1` + `Upgrade` + `Connection "upgrade"` 三行——TeslaMate 用 Phoenix LiveView，缺这三行进得去主页但**实时车辆状态 / 地图轨迹不更新**。

**4. URL_PATH 默认值说明**（同段）：补一行「根路径用户无需配置（默认 `/`）」，避免根路径用户照搬子路径配置错乱。

**5. NOMINATIM_PROXY 措辞修正**（行 537）：原文「即使代理支持 HTTPS，此处也必须写 http://」容易被读成 HTTPS 流量走 http://。改成更准确的「TeslaMate 仅识别 HTTP 类型代理（HTTP CONNECT 方式），不支持 SOCKS5 / HTTPS 隧道型代理」。

**6. 内存最低要求口径**（`QUICKSTART.md` 行 46, 56）：之前写「2GB 起」，TeslaMate 官方实际是 1GB 即可——树莓派 3 / 入门 VPS 用户被我们的文档吓退过。改成「最低 1GB（推荐 2GB）」。

**7. tesla_auth 文件名后缀写死防腐**（`QUICKSTART.md` 行 317）：之前直接列 `.tar.xz` 等具体后缀，作者偶尔会调（`.zip` / `.tar.gz` 都见过）。改成「以 release 页面当下提供的为准」+ 模糊指引。

**8. README 方法 C 升级容器名硬编码**：之前写 `docker exec -i teslamate-database-1 psql ...`，用户 git clone 到不同目录名（如 `teslamate-chinese-dashboards`）时容器名会变成 `teslamate-chinese-dashboards-database-1`，命令报错。改用 `DB=$(docker compose ps -q database)` 自动检测。

**9. README 升级提示段加备份提醒 + v1.6.6 提示**：升级前没显式提醒 `pg_dump` 备份（官方强烈建议）。

**10. README 「最后更新」过期**：之前写 2026-05-02，今天 2026-05-06。

**11. DASHBOARD_MAP 漏掉 `tire-pressure` 仪表盘**：实际存在但文档完全没提，SCENE_GUIDE 里推荐用户「长途行前看胎压」却找不到分类。补到「车辆状态」分类（5 → 6 个）。

**12. DASHBOARD_MAP 漏掉 `mileage`（车辆里程曲线图）**：跟 `MileageStats`（数字汇总）是两个独立 Dashboard，文档只提了后者。补到「驾驶分析」分类（10 → 11 个）。

**13. DASHBOARD_MAP 总数说明自相矛盾**：声称 43 个 7 大类，但分类条目累加 = 45+（部分核心 Dashboard 跨分类重复列出），用户怀疑数对不上。改成显式说明「分类按主题归纳，部分跨多分类，独立 Dashboard 共 43 个」。

**14. QUICKSTART vs DASHBOARD_MAP「第一周必看」推荐 0 重合**：QUICKSTART 推 5 个（概览/驾驶记录追踪/充电记录/电池健康度/省钱分析），DASHBOARD_MAP 推 4 个（概览/最近车辆状态/充电费用统计/续航曲线图），用户照不同文档走看到完全不同推荐。统一为 QUICKSTART 的 5 个。

**15. 仪表盘单位违规一次清理（10 处）**：
- **CurrentChargeView 电压 panel 错用 `kwatt`（千瓦）**：电压应该用 `volt`（伏特），错单位让 230V 显示成「230 千瓦」
- **CurrentChargeView 里程表用非标准单位 `Km`**：改 `none` + displayName 标 `(km)`
- **internal/charge-details.json「充电能量」panel `kwatth`** + 同文件 override 里 `.*_km$` / `/.*_km/` 两处 `lengthkm` → 大数值会被自动换算（4500 kWh 显成 4.5 MWh、28000 km 显成 28 Mm）
- **internal/drive-details.json 4 处违规**：「温度」/「轮胎压力」用 `short`（数字会自动 k/M 缩写），「能耗 (净)」/「能量回收」用 `kwatth`（同样自动换算问题），override 里 `km` 字段也是 `lengthkm`
- 全部改 `unit: none` + displayName 在尾部加 `(km)` / `(kWh)` 等单位标注

### 兼容性

镜像 LABEL 1.6.6 → 1.6.7。仪表盘 JSON 修了 2 处单位错误，**升级用户需要重新拉镜像让新仪表盘自动加载** 才能看到电压显示修复。

---

## [v1.6.6] - 2026-05-06

### 🐛 修复（数据迁移真 bug）

整机迁移恢复流程跟 [TeslaMate 官方 backup_restore](https://docs.teslamate.org/docs/maintenance/backup_restore) 不对齐，**2 个真 bug** 会让用户踩坑：

1. **`private` schema 不清理 → Tesla token 解密失败**：旧版用 `pg_restore -c` 只 drop public schema 对象，TeslaMate 的 `private` schema（存 OAuth 加密对象）不被清理 → 残留旧 token 加密元数据 → 恢复后 token 解密失败 → 用户被迫重新授权
2. **缺 `cube` + `earthdistance` extension 显式重建 → pg_restore 直接报错卡死**：旧版「先 `docker compose up -d database` 单起数据库 → pg_restore」流程，单起的 database 容器**不会自动装** `cube` / `earthdistance` extension（这俩是 teslamate 容器初始化时建的）→ pg_restore 报 `type "cube" does not exist`，用户卡死

**修法**（`TROUBLESHOOTING.md` 整机迁移恢复步骤）：
- 改成先 `docker compose up -d` 完整启动让 teslamate 自动建 schema + extensions
- 停 teslamate 防止写冲突
- 显式 `DROP SCHEMA public + private CASCADE` + `CREATE EXTENSION cube + earthdistance`
- `pg_restore` 去掉 `-c`（已手动 DROP）
- 整体跟官方 backup_restore 流程对齐

### ⚠️ 影响范围 / 谁需要做什么

- **已用过我们旧版迁移流程 + token 解密失败被迫重授权过** → 这就是这个 bug 的症状。重授权后数据无丢失，仅 token 那一步受影响
- **将来要做迁移的所有用户** → 必须用 v1.6.6 新版恢复步骤
- **未做过迁移的用户** → 不受影响，无需任何动作

### 兼容性

升级到 v1.6.6 不需要任何额外动作。仅 `TROUBLESHOOTING.md` 文档修复，镜像内容跟 v1.6.5 一致。

---

## [v1.6.5] - 2026-05-03

### 🐛 修复

- **群晖 NAS 用户上传 Dashboard JSON 后看不到**（`TROUBLESHOOTING.md`）：scp 上去的文件属主是 `wjsall:admin`，DSM 的隐藏 ACL 让 grafana 容器读不了，自动加载（provisioning）静默失败。新增 chown 472:472 修复模板（zh-cn 仪表盘 + internal 仪表盘两条命令分别给）
- **ARM NAS（树莓派 / Apple Silicon NAS）拉 mosquitto 失败导致整堆服务起不来**（`TROUBLESHOOTING.md`）：增加 `DISABLE_MQTT=true` 回退方案——主功能（车辆数据 + 仪表盘）不依赖 MQTT，关掉 mosquitto 不影响核心使用
- **`README.md` / `QUICKSTART.md` / `simple-deploy.sh` 升级章节误用 `wget`**：macOS 默认没装 wget 会报 `command not found`，统一改 `curl`

### 🆕 新增

- **「整机迁移」3 件套备份恢复流程**（`TROUBLESHOOTING.md`）：旧 NAS → 新 NAS / 重装 DSM / 换云服务器场景，含「配置 + 数据库备份 + Grafana 数据卷」三件备份方法和恢复顺序，避免迁移漏内容
- **公网部署「流量爆表防护」章节**（`TROUBLESHOOTING.md`）：直接公网开放 :4000 :3000 = 任何人能看车辆位置/历史行程，强烈推荐 Tailscale 走虚拟内网，云服务器关掉公网端口
- **公网部署「失败告警」可选配置**（`TROUBLESHOOTING.md`）：uptime-kuma 监控容器存活，挂了发邮件/微信通知
- **「装完了？下一步看哪些仪表盘？」引导**（`QUICKSTART.md`）：第一周必看 5 个核心仪表盘 + 进阶玩法（充电分析 / 驾驶习惯 / 维护提醒 / 趋势对比），链 DASHBOARD_MAP / SCENE_GUIDE 找完整目录

### 📚 文档修复

- **TeslaMate 3.0 浏览器 OAuth 登录已被上游移除**：`QUICKSTART.md` 之前写的「方法 B：点 `Sign in with Tesla` 大按钮跳 `auth.tesla.cn`」流程在 TeslaMate 3.0 不存在了——登录页只剩 Access Token / Refresh Token 两个粘贴框，**唯一登录方式**是用 Auth for Tesla App 拿 token 后粘贴。原方法 B 整段删除
- **国内账号不再需要改 `TESLA_API_HOST` / `TESLA_WSS_HOST`**：TeslaMate 3.0 会从 token 的 issuer (auth.tesla.cn) 自动识别为中国区，自动用 `owner-api.vn.cloud.tesla.cn` / `streaming.vn.cloud.tesla.cn`。`QUICKSTART.md` / `README.md` / `simple-deploy.sh` / `TROUBLESHOOTING.md` 同步去掉「中国账号必须设环境变量」的过时指引
- **`TROUBLESHOOTING.md` 登录失败排查**：从「OAuth 浏览器跳转排查」改为「token 粘贴失败排查」（`Tokens are invalid` / `account_locked` / 网络不通 / 系统时间偏差）

### 🇨🇳 国内镜像源更新

- **替换两个已失效的 Docker 镜像加速器**：`dockerproxy.cn`（曾是国内最常推荐的镜像之一）和 `hub-mirror.c.163.com`（NetEase 镜像）实测都已下线（HTTP 000 / 不响应）。`README.md` / `QUICKSTART.md` / `TROUBLESHOOTING.md` / `simple-deploy.sh` 全部替换为 2026-05 实测可用的：
  - `https://docker.1ms.run`
  - `https://docker.m.daocloud.io`
  - `https://docker.cnb.cool`

### 🆕 群晖 NAS 用户专属指引

- **DSM 7.x 反向代理 + Let's Encrypt 教程**（`TROUBLESHOOTING.md`）：4 步打通 `https://teslamate.your-domain.com` 域名访问，自动续期，不暴露 `:4000` `:3000` 端口
- **DSM 7.2+ Container Manager「项目」模式部署**（`TROUBLESHOOTING.md`）：纯 GUI 部署，不用 SSH，照着点几下完成；含升级和「项目卡 STOPPED」的坑修
- **NAS bind mount 迁移指引**（`TROUBLESHOOTING.md`）：把数据从 Docker 命名卷搬到 NAS 共享文件夹的 6 步流程，含数据库备份留底、权限 chown 列表、回滚方案

### 🛠 一键脚本（`simple-deploy.sh`）改进

- **端口预检**：装之前先 `lsof / ss / netstat` 检查 `4000` / `3000` 是否被占用（群晖：Portainer / Bitwarden 占 3000；macOS：Vite / Next.js / Rails 占 3000），冲突时直接退出并提示具体占用进程，不让容器启动失败再排查
- **支持 `TM_PORT` / `GF_PORT` 环境变量改端口**：端口冲突或想自定义时跑 `TM_PORT=14000 GF_PORT=13000 bash simple-deploy.sh`，脚本自动改 docker-compose.yml 端口映射 + 改最后的访问地址提示
- **修正脚本结尾「使用 OAuth 授权」措辞**为「TeslaMate 3.0 仅支持 Token 粘贴登录」，与实际行为一致，避免装完后用户找不到「Sign in with Tesla」按钮

### 🔄 工具推荐改进

- **拿 Tesla token 的工具改推 [tesla_auth 桌面版](https://github.com/adriankumpf/tesla_auth/releases)**：TeslaMate 主作者 Adrian Kumpf 维护，跨平台（macOS / Windows / Linux 原生二进制），开源可信。原 Auth for Tesla iOS App 退为「国内 iOS 备选」并明示需要美区 / 港区 Apple ID 才能下载（之前文档没说，国内大陆账号点开就看不到 App）

### 🐛 收尾修复（同一发版补完）

- **`scripts/diagnose.sh` 错误日志匹配过严**：原 `grep -ic "error\|failed"` 会把正常日志里的 `0 errors` / `error: false` / `error_count=0` 都计入告警噪声。Grafana 改为严格匹配 `lvl=eror\b|level=error\b|permission denied`，TeslaMate 改为匹配 `[error] / [crit] / fatal / MatchError` 等真错误标记
- **NAS bind mount 章节 uid 注释**（`TROUBLESHOOTING.md`）：`chown 999/472/1883` 三个数字加注释说明分别来自 postgres / grafana / mosquitto 官方镜像 Dockerfile 里硬编码的 USER 指令（不是任意数），并给出 `docker exec ... id` 验证命令
- **Token 登录 `account_locked` 排查链接区分国内 / 国际**（`TROUBLESHOOTING.md`）：之前给的密码重置链接是 `tesla.com`，国内大陆账号在 tesla.cn 体系下登不进；现按账号区分给两条链接

### 🆕 新增 `scripts/diagnose.sh` 一键诊断脚本

跑一行 `bash scripts/diagnose.sh`，自动检查：Docker / 4 个容器状态 / 端口监听 / 数据库连通 + 车辆数 + 行程数 / 坐标函数 / TOU 表 / Grafana 镜像版本 / form-panel 插件 / 最近 5 分钟错误日志 / Tesla API 国内外端点连通性。失败项给出具体修复命令。报 issue 时附上输出能省 N 轮排查。

### 兼容性

升级到 v1.6.5 不需要任何额外动作。仅文档/脚本注释的更新。

---

## [v1.6.4] - 2026-05-04

### 🔒 安全修复

- **新装时数据库密码随机生成**（之前硬编码 `password`，公网暴露 5432 会被默认密码拖库）
- **`docker-compose.yml` 创建时自动 `chmod 600`**（文件含 `ENCRYPTION_KEY` + DB 密码 + Tesla token，避免共享服务器其他用户读到）

### 🐛 修复

- **文档路径前后不一致**：`simple-deploy.sh` 创建的目录是 `~/teslamate-chinese`，但 `QUICKSTART.md` / `TROUBLESHOOTING.md` / `README.md` 多处写成 `~/teslamate-chinese-dashboards`，用户按文档 `cd` 必报错。统一为 `~/teslamate-chinese`
- **macOS 用户跑文档第一条命令报 `wget: command not found`**：`README.md` / `QUICKSTART.md` / `simple-deploy.sh` 所有 `wget` 替换为 `curl`
- **群晖 SSH 用户跑 `simple-deploy.sh` 因无 docker 组权限静默失败**：增加 `docker info` 实测，给出 DSM 专用修法（控制面板开 root SSH 或用 Container Manager GUI 部署）
- **CentOS 7 / Ubuntu 18 老镜像跑 `simple-deploy.sh` 中段失败**：自动检测 `docker compose`（v2）和 `docker-compose`（v1），脚本兼容两种

### 🆕 改进

- **`simple-deploy.sh` 跑完打印 `ENCRYPTION_KEY` + 数据库密码 + 备份提醒**：避免错过这两个关键密钥导致未来迁移失败
- **群晖 NAS 用户**：`docker not found` 错误提示加「Container Manager」套件名指引

### 兼容性

升级到 v1.6.4 不需要任何额外动作。已有 `docker-compose.yml` 和数据卷不动。

---

## [v1.6.3] - 2026-05-04

### 🐛 真 Bug 修复：Grafana 12+ form-panel 静默装不上（影响 v1.5.0+ 所有用户）

`Dockerfile` 的 `ENV GF_INSTALL_PLUGINS="volkovlabs-form-panel 6.3.2"` 在新版 Grafana 上**不生效**，导致「⚡ 分时电价配置」仪表盘所有 form-panel 红三角。详见 issue #13。

**根因**：

1. Grafana 12+ 重命名 `GF_INSTALL_PLUGINS` → `GF_PLUGINS_PREINSTALL`，旧名作为别名保留但走同一份预装机制
2. 上游 [teslamate-org/teslamate](https://github.com/teslamate-org/teslamate/blob/main/grafana/Dockerfile) 显式设 `GF_PLUGINS_PREINSTALL_DISABLED=true` 关掉了整个预装机制
3. 旧名是别名 → DISABLED 同时盖住 `GF_INSTALL_PLUGINS` → form-panel 没装

**影响范围**：v1.5.0 及以后所有镜像用户都中招（v1.5.0 是引入 form-panel 的版本）。早期 base image 用 Grafana 11 没事。

**修法**：改用 构建时 `grafana cli plugins install`，绕开所有 env var 风险（`Dockerfile`）。

```dockerfile
USER root
RUN grafana cli --pluginsDir /var/lib/grafana/plugins \
    plugins install volkovlabs-form-panel 6.3.2
USER grafana
```

**升级方法**：

**全新用户**（首次部署）：直接拉 v1.6.3+ 镜像，构建时自动带 form-panel。

**已有 grafana 数据卷的升级用户**（重要 ⚠️）：除了升级镜像，还要 **运行时装一次** 把插件落到数据卷里。Issue #13 实测发现：Docker 命名卷 `teslamate-grafana-data:/var/lib/grafana` 在首次创建后**只用卷自己的内容**，新镜像里构建时装的插件**被卷盖住进不去**。

```bash
# 已有用户（任何旧版本升 v1.6.3）
docker compose pull grafana
docker compose up -d --force-recreate grafana
# ↓ 关键这步：运行时装一次插件到数据卷里（永久生效）
docker exec --user root teslamate-grafana-1 grafana cli plugins install volkovlabs-form-panel 6.3.2 \
 && docker compose restart grafana \
 && sleep 10 \
 && docker exec teslamate-grafana-1 grafana cli plugins ls | grep volkovlabs-form-panel
# 期望: volkovlabs-form-panel @ 6.3.2
```

**用 `scripts/upgrade.sh` 升级的用户**：脚本第 6 步自动检测 + 触发 运行时装，**不需要手动跑上面的命令**。

### 📚 文档

- `TROUBLESHOOTING.md` 「分时电价配置面板空白」段落改写：解释 Docker 数据卷坑 + 给一条 运行时装的命令 + 谁不受影响的对照表
- `CHANGELOG` 升级方法补充「已有数据卷用户必须 运行时装一次」

---

## [v1.6.2] - 2026-05-03

### 🔒 安全：SQL 远程拉取支持锁固定版本

`simple-deploy.sh` 和 `migrate-from-official.sh` 现在都支持环境变量锁版本拉取 SQL：

```bash
SQL_REF=v1.6.2 bash simple-deploy.sh
REPO_REF=v1.6.2 bash migrate-from-official.sh
```

**为什么有用**：维护者 GitHub 账号被盗时，攻击者推恶意 SQL 到 main，所有用 main ref 的 watchtower 用户下次升级会拉到 → psql 执行 → 数据库层 RCE。锁固定 tag 后此风险被消除（除非攻击者能改已发布 tag，难度高）。

**默认仍是 main**（跟 :latest 镜像同步，零摩擦）。需要的用户主动锁。详见 README 新增章节「[🔒 SQL 远程拉取的信任模型](README.md#sql-trust-model)」。

### 🛠️ 工程债：抽 `scripts/check-sql-trio.sh` 校验脚本

新增 `scripts/check-sql-trio.sh`：grep 5 处用户可见入口（simple-deploy / migrate / upgrade / README / QUICKSTART）必须都引用 SQL 三件套（install-coord-functions / install-tou / install-indexes），漏改直接报错退出。

**首次跑就抓到一个真 bug**：QUICKSTART.md 详细文档列表漏了 `install-indexes`，已修。

### 📚 文档

- README 方法 C 加 `REF=main` 注释，明确 SQL 拉取的 ref 可替换为具体 tag
- QUICKSTART 详细文档列表补 `install-indexes.sql` 引用

### ✅ 上游 bug port — 0 工作量（已合并）

实测核对了原本计划要 port 的 3 个上游 bug fix：

- ✅ [#5198](https://github.com/teslamate-org/teslamate/pull/5198) cost_mileage 除零修复 → 我们 fork 的 trip.json 已含 `nullif()` 包裹
- ✅ [#5199](https://github.com/teslamate-org/teslamate/pull/5199) 无 Geofence 时 Charges/Drives 加载失败 → charges.json + drives.json 已含 `geofences_incl_all_option` CTE
- ✅ [2026-03-22 incomplete data 处理](https://github.com/teslamate-org/teslamate/commit/00ab26adb998d919c552c2968341b22bf36c4819) → charging-stats / statistics / trip 三个 dashboard 都已含 `is_incomplete` 标记

应该是之前 v3.0 升级时随同合并，**用户已经受益**。

## [v1.6.1] - 2026-05-02

### 🆕 性能优化：positions 表索引（来自上游 issue [#5306](https://github.com/teslamate-org/teslamate/issues/5306)）

新增 `sql/install-indexes.sql`：在 TeslaMate 核心表 `positions` 上加 `(car_id, date)` btree 索引，覆盖「按车按时间倒序取最新」类查询。

- **受益面板**：电池健康（State of Health）、行程列表、充电费用统计、省钱分析、天气-能耗关联（v1.6.0）、分时电价回填（v1.5.0 `backfill_all_tou`）
- **实测**：单车 80 万行受影响查询从 200ms 降到 < 5ms（来自上游 issue 报告）
- **幂等**：`CREATE INDEX IF NOT EXISTS`，重跑零副作用；上游若将来正式合 migration 不会冲突

### 🐛 Bug 修复 — `simple-deploy.sh` 漏装分时电价 SQL（v1.5.0 遗留）

v1.5.0 引入分时电价系统时，`simple-deploy.sh`（一键脚本）只装了坐标函数，**漏装了 `install-tou.sql`**。结果：用 `simple-deploy.sh` 部署的用户打开「⚡ 分时电价配置」仪表盘时函数不存在，5 个配置面板全显示红三角，「24 小时电价分布」全 0。

本次 `simple-deploy.sh` 升级路径 + 新装路径都补齐 SQL 三件套（坐标函数 + 分时电价 + 性能索引）。

### 📚 文档/工作流

- **README 方法 C**：原本两条独立 `curl` 改成 `for f in install-coord-functions install-tou install-indexes; do curl ... ; done` 循环，并显著标注 **Watchtower 自动升镜像的用户每次升级后只需重跑这一段**就能拿到最新 SQL 改动
- **`scripts/upgrade.sh`**：6 步 → 7 步（[5/7] 是新加的索引步骤），并修了文件顶部注释里的步骤号错乱（[1/4] / [2/6] / [3/6] 混乱 → 全部 [N/7] 一致）
- **`migrate-from-official.sh`**：交互+非交互两个 SQL 安装段都加 `install-indexes`
- **`tou-config` 仪表盘顶部 markdown**：加「⚡ 范围说明」blockquote 明确 TOU 只作用于家充（交流慢充），直流快充按桩侧上报金额计费、不参与本表分时重算

### 🔧 内部

- 新建 `sql/install-indexes.sql` 独立文件而非塞进 `install-tou.sql`：日后上游 #5306 合 migration 时方便单独删
- 索引名 `idx_positions_car_id_date_btree`（带 `_btree` 后缀避免和上游可能采用的命名冲突）

## [v1.6.0] - 2026-04-30

### 🆕 新增「🌡️ 天气-能耗关联」仪表盘（中文版独有）

国内特斯拉车主 #1 痛点：「冬天到底掉多少电」。这个仪表盘用 TeslaMate 已记录的**每次行驶外部温度 + 续航损耗**，量化温度对能耗的真实影响。

- **温度桶能耗曲线**：每 2°C 一档，柱高=该桶中位 Wh/km，柱色冷蓝→热红，**16°C 最省 / 38°C 最费**一目了然
- **4 KPI**：平均温度 / 平均能耗 / 最冷月能耗 / 最热月能耗
- **月度双轴**：蓝线月均温度 vs 黄柱月均能耗，反相关一眼看到
- **温度区间柱图**：5 档（≤0/0-10/10-20/20-30/>30°C）平均能耗
- **季节对比表**：冬春夏秋行程数/里程/温度/能耗/vs 全年均值 % 全部列出

仪表盘由 `scripts/build-weather-efficiency.py` 生成，含 self-check 防止 SQL CTE 漏粘贴。

### 🐛 Bug 修复 — Grafana 12 xychart 渲染失败

3 个 xychart 面板缺少 Grafana 12 必需字段（`pointShape` / `pointStrokeWidth` / `axisBorderShow` / `fillOpacity`），渲染时报 Err：

- `ChargingCurveStats.json` panel 29「超级充电站充电曲线」、panel 32「其他直流充电曲线」
- `DCChargingCurvesByCarrier.json` panel 32「充电运营商包含: $carrier」

补齐字段后正常渲染。

### 📊 UI 优化

- **5 个 stat 面板**清理死字段 `fixedColor`（`color.mode=thresholds` 下不生效）：`internal/drive-details`、`CurrentChargeView`、`CurrentDriveView`、`CurrentState`、`TrackingDrives`
- **`station-ranking`** 删除自循环 `displayName: "${__field.name}"`
- **文档计数同步**：26 处「40 个/42 个」→「43 个」、「9 个原创」→「12 个原创」（README/QUICKSTART/DASHBOARD_MAP/SCENE_GUIDE/CLAUDE）

### 🔧 内部

- `scripts/build-weather-efficiency.py`：抽常量（`WH_PER_KM_*` `MIN_*` `TEMP_COLOR_STEPS`）、`MONTHLY_CTE` 复用、`if __name__ == "__main__"` guard、self-check assert 每个 panel 都包含 `WITH d AS (`
- 季节对比 SQL 优化：`EXTRACT(MONTH ...)` 算一次（`month_local`）替代 8 次重复，大表上省 200-400ms
- `scatter_panel` helper 加 `y_field` 参数，消除 panel 间共享假列名的 hack

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
