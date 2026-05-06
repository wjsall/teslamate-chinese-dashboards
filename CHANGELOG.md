# 更新日志

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

⚠️ stat 面板 unit 从数字改 string 必须同步把 `reduceOptions.fields` 从 `""` 改成 `"/.*/"`，否则字符串字段被默认过滤显示空（已记 memory）。

### 🐛 SQL 中文别名破坏 override（回退）

历史改动把上游 `as "$length_unit"` 翻译成 `as "单位"` / `as "效率"`，dead-string 让 override matcher 找不到列名：

- `charge-details` / `drive-details` / `ContinuousTrips`：`as "单位"` → `as "$length_unit"`
- `efficiency` / `SpeedRates`：`as "效率"` → `as "efficiency_$length_unit"`

### 🐛 charge-level 中文图例还原

之前一次 SQL 别名批量改动误把 `charge-level` 的 4 条图例（滚动 7.5%/平均/中位数/92.5% 分位）改回上游英文。本次还原。

### 🔄 上游对齐回滚

v1.6.7 v1.6.8 早期把 `charge-details` / `drive-details` 8 处 `kwatth` / `lengthkm` / `short` 改成 `none`，违反「上游有同款不改」原则——drill-down 单次详情数值小，根本不触发 Mm/MWh 换算。已全部回滚到上游原值。

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
