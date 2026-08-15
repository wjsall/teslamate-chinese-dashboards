# 故障排查手册

> 遇到问题不要慌，按症状找原因，一步一步来。

---

## 🤖 先问 AI 自助排查（推荐第一步）

多数常见问题（面板找不到 / 数据为空 / 容器起不来 / 迁移失败 / 地址显示空 / 升级失败）AI 拿到日志能给出诊断方向，比开 issue 等回复快得多。

**操作 3 步：**

1. 打开 [docs/ai-troubleshooting-prompt.md](docs/ai-troubleshooting-prompt.md) 看完整 prompt
2. 把里面 ✂️ 之间的整段 prompt 复制到任意主流 AI
3. 在 prompt 末尾贴上脱敏后的最小相关输出和问题，提交

AI 会先按症状要求最小只读证据，并给出已确认、可能与未知项。日志和文本请先脱敏；不要提供密钥、密码、Token、VIN 或精确位置。任何重启、写 SQL、改权限、升级镜像或删除操作，都应先说明影响、备份和回滚方式，再等待你确认。

**AI 没解决** → 再来 [GitHub issues](https://github.com/wjsall/teslamate-chinese-dashboards/issues) 报告，附上 AI 的诊断结论让维护者跳过重复排查。

---

## 🔍 诊断三板斧（手动排查）

遇到任何问题，先执行这三个命令：

```bash
# 1. 查看所有容器状态
docker compose ps

# 2. 查看所有服务日志（最近50行）
docker compose logs --tail=50

# 3. 查看特定服务日志（实时）
docker compose logs -f teslamate   # TeslaMate 日志
docker compose logs -f grafana     # Grafana 日志
docker compose logs -f database    # 数据库日志
docker compose logs -f mosquitto   # MQTT 日志
```

**健康状态应该是这样的：**
```
NAME         STATUS          PORTS
teslamate    Up 2 hours      0.0.0.0:4000->4000/tcp
database     Up 2 hours
grafana      Up 2 hours      0.0.0.0:3000->3000/tcp
mosquitto    Up 2 hours
```

如果某个服务显示 `Restarting` 或 `Exited`，说明有问题。

---

## 📦 安装问题

### ❌ Docker 安装失败

**症状**：`bash simple-deploy.sh` 报错说 Docker 未找到

**解决：**
```bash
# Ubuntu / Debian
curl -fsSL https://get.docker.com | bash
sudo usermod -aG docker $USER
newgrp docker   # 立即生效（或重新登录）

# 验证
docker run hello-world
```

---

### ❌ 端口被占用

**症状**：
```
Error starting: Bind for 0.0.0.0:4000 failed: port is already allocated
Error starting: Bind for 0.0.0.0:3000 failed: port is already allocated
```

**查找占用进程：**
```bash
# 查看谁在用 4000 端口
sudo lsof -i :4000
sudo lsof -i :3000
```

**解决方案 A：停止占用端口的程序**
```bash
sudo kill -9 <PID>
```

**解决方案 B：修改 TeslaMate/Grafana 端口**
编辑 `docker-compose.yml`，把端口改掉，例如改成 `4001:4000`：
```yaml
ports:
  - 4001:4000   # 左边是宿主机端口，右边是容器端口
```
然后访问 `http://localhost:4001`

---

<a id="image-pull-cn"></a>

### ❌ 镜像拉取失败（国内网络）

**症状**：
```
Error response from daemon: Get "https://ghcr.io/...": dial tcp: i/o timeout
```

**解决方案 A：切换到 Docker Hub 镜像（最简单，推荐）**

将 `docker-compose.yml` 中 grafana 的 `image` 替换为 Docker Hub 地址：
```yaml
image: bswlhbhmt816/teslamate-chinese-dashboards:latest
```
Docker Hub 在中国大陆访问比 ghcr.io 稳定得多，无需额外配置。

**解决方案 B：配置 Docker 镜像加速**
```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://docker.cnb.cool"
  ]
}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

**解决方案 C：使用代理**
```bash
# 临时设置代理
export HTTP_PROXY=http://你的代理IP:端口
export HTTPS_PROXY=http://你的代理IP:端口
docker compose pull
```

**解决方案 D：在能访问的机器上拉取并导出**
```bash
# 有网络的机器上
docker pull ghcr.io/wjsall/teslamate-chinese-dashboards:latest
docker save ghcr.io/wjsall/teslamate-chinese-dashboards:latest | gzip > grafana-chinese.tar.gz
# 传到目标机器
scp grafana-chinese.tar.gz user@server:~/
# 目标机器上加载
docker load < grafana-chinese.tar.gz
```

---

### ❌ 权限不足

**症状**：
```
Permission denied while trying to connect to the Docker daemon socket
```

**解决：**
```bash
sudo usermod -aG docker $USER
newgrp docker
# 或者重新登录
```

---

## 📊 仪表盘问题

<a id="repair-sql-install"></a>

### ❌ 地图 / 分时电价面板报 `function lat_for_map(...) does not exist`（更新镜像后高频）

**症状**：地图整页或某些面板报错 `db query error: ERROR: function lat_for_map(unknown, numeric, numeric) does not exist`（或 `lng_for_map` / `effective_cost` / `compute_tou_cost` 等）。

**根因**：这些是本项目的**自定义 SQL 函数**（坐标转换、分时电价计费），不在 Grafana 镜像里，要单独装进数据库。报这个错 = **没装、或更新镜像后没重装 SQL 四件套**。⚠️ **跟 PostgreSQL 版本无关，别去升级 PG**。

**修复**——重装 SQL 四件套（坐标函数 / 单位换算 / 分时电价 / 性能索引）：

```bash
# 容器名不是 teslamate-database-1 时先 docker compose ps -q database 查实际名
DB=$(docker compose ps -q database)
[ -n "$DB" ] || { echo "❌ database 容器没起来"; exit 1; }
# 默认自动解析最新正式 Release（与 :latest 镜像版本对齐，见「三种更新通道」）；
# 想锁到具体版本或滚动 main 通道，先 export SQL_REF=v1.6.2 / SQL_REF=main
set -o pipefail
REF="${SQL_REF:-$(curl -fsSL --max-time 10 https://api.github.com/repos/wjsall/teslamate-chinese-dashboards/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')}"
# API 限流时换一条不吃限流的路（网页 /releases/latest 会 302 到具体 tag），与安装脚本同样两条路
if [ -z "$REF" ]; then
  REF=$(curl -sSI --max-time 10 https://github.com/wjsall/teslamate-chinese-dashboards/releases/latest 2>/dev/null | grep -i '^location:' | tr -d '\r' | sed 's|.*/||')
  case "$REF" in v[0-9]*) : ;; *) REF="" ;; esac
fi
# 两条都没查出版本号就停下：不改用 main，否则装的是「正式版镜像 + 未发布 SQL」的混搭。
# 去 Releases 页面抄一个版本号，再 export SQL_REF=v1.9.1 重跑本段即可。
[ -n "$REF" ] || { echo "❌ 没查出版本号：export SQL_REF=<版本号> 后重跑（版本号见 https://github.com/wjsall/teslamate-chinese-dashboards/releases）"; exit 1; }
for f in install-coord-functions install-unit-functions install-tou install-indexes; do
  if ! curl -fsSL "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REF}/sql/${f}.sql" \
    | docker exec -i "$DB" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1; then
    echo "❌ ${f}.sql 安装失败"
    exit 1
  fi
done
# 记录 SQL 兼容性 revision（issue #23/#29 事故预防机制），让 scripts/diagnose.sh 之后不再
# 报 sql_revision_mismatch。四个文件都装成功才走到这一步，失败不影响上面已经修好的功能。
REV=$(curl -fsSL "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/${REF}/config/versions.env" \
  | grep -m1 '^SQL_COMPAT_REVISION=' | cut -d= -f2 | tr -d '[:space:]\r')
if [ -n "$REV" ]; then
  docker exec -i "$DB" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 <<SQL
CREATE TABLE IF NOT EXISTS teslamate_cn_extension_meta (
    id INTEGER PRIMARY KEY DEFAULT 1,
    sql_revision INTEGER NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    project_version TEXT,
    CONSTRAINT teslamate_cn_extension_meta_singleton CHECK (id = 1)
);
INSERT INTO teslamate_cn_extension_meta (id, sql_revision, updated_at, project_version)
VALUES (1, ${REV}, now(), '${REF}')
ON CONFLICT (id) DO UPDATE SET sql_revision = EXCLUDED.sql_revision, updated_at = EXCLUDED.updated_at, project_version = EXCLUDED.project_version;
SQL
fi
docker compose restart grafana
```

脚本使用 `CREATE OR REPLACE` / `IF NOT EXISTS`，可安全重跑；一键安装用户直接重跑 `simple-deploy.sh` 也会自动安装。默认自动解析最新正式 Release（与 `:latest` 镜像版本对齐，同一个 ref）；需要锁到具体版本或切到滚动 main 通道，先执行 `export SQL_REF=v1.6.2` 或 `export SQL_REF=main`，三条通道详见 [信任模型](#sql-trust-model)。装完刷新即恢复。

### ❌ 单位换算面板报 `function convert_km(...) does not exist`

**症状**：里程、温度、海拔或胎压面板报 `convert_km` / `convert_celsius` / `convert_m` / `convert_tire_pressure does not exist`。

**根因**：这四个函数来自 `sql/install-unit-functions.sql`，报错说明单位换算 SQL 没有安装，或更新镜像后没有重装。这也不是 PostgreSQL 版本问题。

**修复**：执行上一节的 SQL 四件套循环，不要只单独更新 Grafana 镜像。

<a id="manual-migration-fallback"></a>

### ❌ 无法运行迁移脚本，需要手动切换官方 Grafana 镜像

正常迁移请回到 README 的 [方法 D](README.md#upgrade-method-d)，由 `migrate-from-official.sh` 统一完成预检、备份、换镜像、SQL 安装和回滚。只有脚本预检无法通过、且你已经备份配置与仪表盘 JSON 时，才用下面的旧式手动兜底。

先把原 `docker-compose.yml` 的 `grafana` service 改两处；`ports`、`volumes` 和 `restart` 保持原样：

```yaml
grafana:
  image: bswlhbhmt816/teslamate-chinese-dashboards:latest   # 原 teslamate/grafana:latest
  environment:
    - DATABASE_USER=teslamate
    - DATABASE_PASS=password
    - DATABASE_NAME=teslamate
    - DATABASE_HOST=database
    - GF_USERS_DEFAULT_LANGUAGE=zh-Hans
```

如果需要让 Grafana 从干净数据卷重新载入本项目仪表盘，可执行：

```bash
docker compose stop grafana
docker volume rm teslamate_teslamate-grafana-data
docker compose pull grafana
docker compose up -d grafana
```

> ⚠️ 这不会删除独立 `teslamate-db` 卷中的车辆数据，但会删除 Grafana 数据卷里的用户、书签和自定义设置。项目名不是 `teslamate` 时卷名会不同，先用 `docker volume ls` 确认；不要照抄删除不认识的卷。

最后执行本页上一节的 [四个 SQL 安装文件修复循环](#repair-sql-install)。它会安装坐标转换、单位换算、分时电价和性能索引，任一文件失败即停止。

<a id="form-panel-migration-repair"></a>

<a id="plugin-not-found"></a>

### ❌ 从官方 TeslaMate 迁移后「⚡ 分时电价配置」整页报 panel not found（v1.7.0 / v1.7.1 迁移用户）

**症状**：跑完 `migrate-from-official.sh` 后，打开「⚡ 分时电价配置」时整个仪表盘显示 `panel not found`，仪表盘列表里能搜到、Grafana 日志全是 INFO 无 ERROR。**v1.7.2+ 的 migrate 脚本已经自动修，这一节给已经踩坑的用户自助修复。**

> **新版镜像已从架构上解决这个问题**（[issue #20](https://github.com/wjsall/teslamate-chinese-dashboards/issues/20)、[issue #21](https://github.com/wjsall/teslamate-chinese-dashboards/issues/21)）：插件目录改到了 `teslamate-grafana-data` volume 外的 `/opt/grafana-plugins`，不会再被旧卷覆盖。`docker compose pull grafana && docker compose up -d --force-recreate grafana` 拉到新版镜像即可根治，不需要走下面的手动步骤。**以下内容保留给还没升级、仍在用旧版镜像的用户自助修复。**

**根因（旧版镜像）**：「⚡ 分时电价配置」里 5 个 panel 用 `volkovlabs-form-panel` 第三方插件。旧版镜像 build 时把它装在 `/var/lib/grafana/plugins`，但这条路径**正好是 Grafana volume `teslamate-grafana-data` 的挂载点**。从官方迁移来的用户，他们的 volume 来自官方 grafana 镜像（没装 volkov），切镜像时 volume 覆盖镜像的 plugin 目录 → 镜像里装好的插件用不上。

> 下面命令里的 `teslamate-grafana-1` 是默认容器名。如果你用 `-p someproject` 起的，容器名会变成 `someproject-grafana-1`——按 `docker ps | grep grafana` 实际结果替换。

**修复路径 A — 从我们镜像本地复制 plugin（推荐，国内用户首选，无外网依赖）**：

```bash
# 1. 先拉最新镜像（本地缓存的 :latest 很可能还是旧版，不重新拉 /opt/grafana-plugins 不存在）
docker pull bswlhbhmt816/teslamate-chinese-dashboards:latest

# 2. 临时启动一个用我们镜像的容器（不挂 volume，纯镜像层；新版镜像插件在 /opt/grafana-plugins）
docker create --name volkov-tmp bswlhbhmt816/teslamate-chinese-dashboards:latest

# 3. cp 出 plugin
docker cp volkov-tmp:/opt/grafana-plugins/volkovlabs-form-panel /tmp/volkovlabs-form-panel
docker rm volkov-tmp

# 4. cp 进运行中的 grafana 容器（写入旧版镜像仍在读取的 /var/lib/grafana/plugins）+ 修 owner
docker cp /tmp/volkovlabs-form-panel teslamate-grafana-1:/var/lib/grafana/plugins/
docker exec --user root teslamate-grafana-1 chown -R 472:472 /var/lib/grafana/plugins/volkovlabs-form-panel
docker compose restart grafana
rm -rf /tmp/volkovlabs-form-panel
```

**修复路径 B — grafana cli 在线装（需访问 grafana.com，国内常超时）**：

```bash
docker exec --user root teslamate-grafana-1 \
    grafana cli --pluginsDir /var/lib/grafana/plugins plugins install volkovlabs-form-panel 6.3.2
docker compose restart grafana
```

> `--user root` 仅本次 docker exec 内有效，命令退出后 grafana 进程恢复 grafana user，不是持久权限提升。

等 30 秒后 Ctrl+F5 刷新「⚡ 分时电价配置」，5 个 form panel 应该全部恢复。

**或者**重跑迁移脚本（v1.7.2+ 的 migrate-from-official.sh 会自动检测 + 装这插件，国内超时时也会打印两条路径的命令让你选）：

```bash
# 先拉最新脚本（你本地可能是 v1.7.1 之前的旧版没这个修复逻辑）
curl -fsSL -o migrate-from-official.sh \
    https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/migrate-from-official.sh
bash migrate-from-official.sh    # 识别到已在我们镜像 → 会问要不要重装 SQL + 修 plugin
```

**确诊命令**（新版镜像看 `/opt/grafana-plugins`，旧版镜像看 `/var/lib/grafana/plugins`；看不到 `volkovlabs-form-panel` 目录就是这个坑）：

```bash
docker exec teslamate-grafana-1 ls /opt/grafana-plugins 2>/dev/null || docker exec teslamate-grafana-1 ls /var/lib/grafana/plugins
```

**如需安装额外的 Grafana 插件（新版镜像用户）**：请用命令行方式安装并重启容器，插件才能在下次 `docker compose pull && docker compose up -d`（重建容器）后继续保留：

```bash
docker exec --user root teslamate-grafana-1 \
    grafana cli --pluginsDir /var/lib/grafana/plugins plugins install <插件名>
docker compose restart grafana
```

**通过 Grafana 网页界面（Administration → Plugins）安装的插件，在容器重建后会丢失**，建议改用上面的命令行方式安装。

**降级提醒**：如果你从新版镜像降级回旧版镜像，插件目录会回到旧位置，可能需要按本节上面的手动方案重新安装插件。

---

### ❌ 自定义 / 上传仪表盘 JSON 后 Grafana 看不到（群晖 NAS 用户高发）

**症状**：把改过的仪表盘 JSON 通过 File Station / scp 推到 `/volume1/docker/teslamate/dashboards/zh-cn/`，重启 grafana 也不生效，仪表盘还是旧版。

**根因**：DSM File Station / scp 上传的文件属主是你本地用户（`wjsall:admin` 之类），但 Grafana 容器跑的是 uid `472`，**读不了你的文件**（DSM 隐藏 ACL 让 grafana 看上去 permission denied 但 自动加载静默跳过）。

**修法**：上传后必须 chown 到容器 uid：

```bash
# zh-cn 仪表盘（挂到容器内 /dashboards/）
ssh wjsall@192.168.31.135 \
  "docker exec --user root teslamate-grafana-1 chown 472:472 /dashboards/<filename>.json"

# internal 仪表盘（挂到容器内 /dashboards_internal/）
ssh wjsall@192.168.31.135 \
  "docker exec --user root teslamate-grafana-1 chown 472:472 /dashboards_internal/<filename>.json"
```

> ⚠️ 容器内 `chown grafana:grafana` 报 `unknown user`，必须用 uid `472:472`（数字形式）。

**判断是否中招**：

```bash
docker logs teslamate-grafana-1 | grep -i "permission denied"
```

看到对应文件名就是这个坑。

**永久修法（一劳永逸）**：在 NAS 任务计划里建一个每分钟跑一次的脚本：

```bash
docker exec --user root teslamate-grafana-1 chown -R 472:472 /dashboards /dashboards_internal
```

这样以后任何 scp / File Station 上传都自动修。

---

### ❌ 仪表盘显示空白 / 无数据

**Step 1：确认 TeslaMate 有数据**
```bash
docker compose exec database psql -U teslamate -c "SELECT COUNT(*) FROM drives;"
docker compose exec database psql -U teslamate -c "SELECT COUNT(*) FROM charges;"
```
如果返回 `0`，说明还没有数据（车辆刚授权，等待同步）。

**Step 2：检查数据源连接**
- 打开 Grafana → 左侧菜单 → Connections → Data Sources
- 点击 `TeslaMate` 数据源
- 点击 `Save & Test`
- 应显示绿色 `Database Connection OK`

**Step 3：检查时间范围**
Grafana 右上角的时间范围选择，默认是 `Last 6 hours`。如果车辆数据是昨天的，需要调宽时间范围。

**Step 4：重启 Grafana**
```bash
docker compose restart grafana
```

---

### ❌ 仪表盘显示英文而非中文

**症状**：打开 Grafana 界面全是英文，或者仪表盘面板标题是英文

**解决 1：确认语言环境变量**
查看 `docker-compose.yml` 中 grafana 服务是否有：
```yaml
environment:
  - GF_USERS_DEFAULT_LANGUAGE=zh-Hans
```

**解决 2：确认使用的是中文镜像**
```bash
docker compose ps grafana
# 应该显示以下任一合法镜像：
# bswlhbhmt816/teslamate-chinese-dashboards:latest
# ghcr.io/wjsall/teslamate-chinese-dashboards:latest
```

**解决 3：清除浏览器缓存**
```
Ctrl+Shift+R（Windows/Linux）
Cmd+Shift+R（macOS）
```

**解决 4：重启 Grafana**
```bash
docker compose restart grafana
```

---

### ❌ 某些面板显示 "No data"

**常见原因 1：数据库里确实没有这段时间的数据**
- 调整时间范围（右上角时钟图标）

**常见原因 2：数据源 UID 不匹配**

打开 Grafana → 左侧 **Connections → Data sources** → 看名字是否为 `TeslaMate`（区分大小写）。如果不是，点开数据源把 `UID` 改成 `TeslaMate`，所有面板的 SQL 查询都用这个固定 UID 引用。

**常见原因 3：数据库连接超时**
```bash
docker compose logs grafana | grep -i "error\|failed"
```

---

### ❌ TeslaMate 登录失败（Token 粘贴提交后报错）

> ℹ️ **TeslaMate 3.0 已移除浏览器 OAuth 登录**——登录页只有 Access Token + Refresh Token 两个粘贴框，没有「Sign in with Tesla」大按钮。本节专门讲粘贴 token 后失败的排查。

**症状**：登录页粘贴 token 点提交后出现以下任一情况：
- 报 `Tokens are invalid`
- 报 `Your Tesla account is locked`
- 一直转圈无响应
- 提交后跳回登录页没有进展

**逐项排查：**

#### 1. Token 是否过期 / 复制完整？

`access_token` 通常 ≥ 2000 字符，`refresh_token` 约 100 字符。粘贴时容易因换行/空格导致截断：
- 重新打开 Auth for Tesla App，重新生成一对（点 App 内「重新登录」或「刷新」）
- 复制时**长按整段 → 全选 → 复制**，避免只复制可见部分
- 粘贴到 TeslaMate 后用浏览器开发者工具看输入框 value 长度，是否被空格污染

#### 2. 账号被锁

如果 App 里反复登录失败，特斯拉会锁账号几小时。看到 `Your Tesla account is locked due to too many failed sign in attempts`：
- **国内大陆账号**：去 [Tesla 中国官网](https://www.tesla.cn/teslaaccount/forgot-password) 重置密码（用 `tesla.com` 那边登不进去，国内账号在 tesla.cn 体系下）
- **国际账号**：去 [Tesla 官网](https://www.tesla.com/teslaaccount/forgot-password) 重置密码
- 等几小时后再用 tesla_auth / Auth for Tesla 重新生成 token

#### 3. 服务器到 Tesla 服务器网络不通

```bash
# 中国账号
curl -fsI https://auth.tesla.cn
curl -fsI https://owner-api.vn.cloud.tesla.cn

# 国际账号
curl -fsI https://auth.tesla.com
curl -fsI https://owner-api.teslamotors.com
```
任一报错（超时、连接拒绝、SSL 握手失败）→ 服务器网络不通 → 配代理或换可用网络。

#### 4. TeslaMate 容器看具体报错

```bash
docker compose logs --tail 100 teslamate | grep -iE "error|failed|tokens"
```
看到 `:token_refresh` → token 已被 Tesla 服务端废弃，Auth for Tesla App 重新生成
看到 SSL/TLS 错误 → 服务器系统时间偏差太多（`date` 看一下，必要时 `chronyd` / `systemctl restart systemd-timesyncd`）

#### 5. 用工具拿 token 的具体步骤

TeslaMate 3.0 没有别的登录方式，token 必须从外部工具来。**推荐 tesla_auth 桌面版**（TeslaMate 主作者维护、跨平台、不需要 Apple ID 切区）：

1. 下载：[github.com/adriankumpf/tesla_auth/releases](https://github.com/adriankumpf/tesla_auth/releases) 选对应平台二进制
2. 解压后双击运行 → 弹出窗口登录 Tesla 账号
3. 显示 `access_token` 和 `refresh_token` 两段字符串，复制下来
4. 回 TeslaMate 登录页（**直接显示两个输入框，不是折叠的**）粘贴两段 token，点 `Sign in`

**国内 iOS 用户备选：**
- App Store 搜「Auth for Tesla」**需要美区 / 港区 Apple ID**，国内大陆账号看不到这个 App
- 不想切区的，去家人/朋友的美区 iPhone 装一下，或者直接用 macOS / Windows 桌面版 tesla_auth

绑定后 TeslaMate 用 refresh_token 自动续期，长期不需要重新拿。

完整步骤 + 截图见 [QUICKSTART.md 第四步「授权 Tesla 账号」](QUICKSTART.md#step-4)。

---

### ❌ 容器启动后无限重启

**症状**：`docker compose ps` 显示 `Restarting`

**排查步骤：**
```bash
# 查看最近的错误日志
docker compose logs --tail=20 grafana
docker compose logs --tail=20 teslamate
```

**常见原因：数据库未就绪**
等待约 30 秒后重试：
```bash
docker compose restart teslamate grafana
```

**常见原因：ENCRYPTION_KEY 变更**
如果修改过 `ENCRYPTION_KEY`，Token 无法解密，TeslaMate 会崩溃。**ENCRYPTION_KEY 一旦设置不能更改**（除非重新授权 Tesla 账号）。

**常见原因：端口冲突**
见上方「端口被占用」章节。

**常见原因：mosquitto 拉不下来 → TeslaMate 卡 MQTT 连接（群晖 ARM 用户高发）**

群晖 ARM 系列（DS218j / DS118 等）拉 `eclipse-mosquitto:2` 经常超时失败，TeslaMate 启动后报 `MQTT connection refused` 反复重启。

**MQTT 是可选功能**（只用于 / 实时推送外部 home assistant 等场景），不用 MQTT 也不影响数据收集 / 仪表盘。**禁掉即可解决**：

```yaml
# docker-compose.yml 的 teslamate service 改：
services:
  teslamate:
    environment:
      - DISABLE_MQTT=true       # ← 加这一行
      # - MQTT_HOST=mosquitto   # ← 注释掉这一行（如果有）
```

然后整个 mosquitto service 也可以删（节省内存）：

```yaml
# 删掉 docker-compose.yml 末尾的 mosquitto: 整段
# 也删 volumes 段的 mosquitto-conf / mosquitto-data
```

`docker compose up -d` 重启后 TeslaMate 不再尝试连 MQTT，启动正常。

---

### ❌ Grafana admin 密码忘了 / 找回不到

v1.6.9+ 用 `simple-deploy.sh` 装的，Grafana 密码是脚本生成的强随机串（不再是 `admin/admin`）。两条恢复路径：

**方法 1（最快）：从 docker-compose.yml 直接读**

脚本把生成的密码已写进 `docker-compose.yml` 环境变量（mode 600，仅文件所有者可读）：

```bash
grep GF_SECURITY_ADMIN_PASSWORD ~/teslamate-chinese/docker-compose.yml
# 输出：- GF_SECURITY_ADMIN_PASSWORD=xxxxxxxxxxxxxxxxxx
```

群晖 / 别的部署目录的话改成对应路径。

**方法 2：用 grafana CLI 强制重置**

容器内跑（无需停服务，立即生效）：

```bash
docker exec -it teslamate-grafana-1 grafana-cli admin reset-admin-password '新密码'
```

⚠️ 命令行参数会留在 bash history，建议改完后 `history -d $(history 1)` 清掉这一条。

**方法 3：改 docker-compose.yml + restart（持久化新密码）**

```bash
# 编辑 docker-compose.yml
sed -i 's|GF_SECURITY_ADMIN_PASSWORD=.*|GF_SECURITY_ADMIN_PASSWORD=新密码|' ~/teslamate-chinese/docker-compose.yml
docker compose -f ~/teslamate-chinese/docker-compose.yml up -d grafana
```

⚠️ Grafana 启动时只在 admin 账号**首次创建**时用 `GF_SECURITY_ADMIN_PASSWORD`；之后改这个 ENV 不会生效。所以方法 3 只对全新装/重建数据卷的场景有用，已经在跑的实例改这个 ENV 不顶用，请用方法 2。

---

### ❌ 「自定义新车电池容量」「自定义新车最大续航里程」每次刷新重置为 0

Grafana textbox 变量只活在 URL 里，刷新就丢。两个方法选一个：

**方法 1（推荐）：URL 书签** —— 在仪表盘填好值后，浏览器地址栏会出现 `?var-custom_kwh_new=82&var-custom_max_range=600`，把整个 URL 存书签，以后直接从书签打开。

**方法 2（仅自用）：改 JSON 默认值** —— 编辑 `grafana/dashboards/zh-cn/battery-health.json`，把 `custom_kwh_new` / `custom_max_range` 两个变量的 `current` / `query` / `options` 里 `"0"` 全改成你的实际值（如 `"82"`）。保存后等 10 秒 Grafana 自动 reload。

---

## 🚗 数据问题

### ❌ 车辆数据不更新

**Step 1：检查 TeslaMate 日志**
```bash
docker compose logs -f teslamate
```
正常日志应包含类似 `Fetching vehicle data` 的内容。

**Step 2：确认 Tesla API 授权有效**
访问 `http://localhost:4000`，看是否显示正确的车辆信息。如果显示未登录，重新授权。

**Step 3：检查网络连通性**
```bash
# 在宿主机直接测（teslamate 容器没装 curl）
# 国内账号
curl -fsI https://auth.tesla.cn
curl -fsI https://owner-api.vn.cloud.tesla.cn

# 国际账号
curl -fsI https://auth.tesla.com
curl -fsI https://owner-api.teslamotors.com
```

**Step 4：检查 MQTT 连接**
```bash
docker compose logs mosquitto
# 应该看到 TeslaMate 的连接记录
```

---

### ❌ 行程数据缺失

**可能原因：**
- 行程中 GPS 信号丢失
- 车辆在行程中进入休眠（短途多次停车）
- TeslaMate 服务在行程中重启

**查看不完整数据：**
打开 Grafana → **「不完整的数据」**仪表盘，可以看到哪些行程 / 充电缺少了数据。

**手动导入历史数据（如有 TeslaFi / Tesla API 备份）：**
将数据放入 `./import/` 目录，TeslaMate 会自动处理。

---

### ❌ 地图不显示

**症状**：行程追踪页面地图空白

**常见原因 1：网络无法访问 OpenStreetMap**
OpenStreetMap 地图服务在国内可能受限。

**常见原因 2：浏览器控制台有 CORS 错误**
```
按 F12 → Console 标签 → 查看是否有地图相关错误
```

**解决方法 1（v1.4.2+ 推荐）：使用顶部「地图源」下拉框切换到高德地图**

打开任一含地图的仪表盘，顶部下拉框「地图源」选「高德地图」即可（瓦片直连国内 CDN，无需代理）。详见 [QUICKSTART.md](QUICKSTART.md) 「地图源切换 + 自动 GCJ-02 坐标纠偏」章节。

**解决方法 2：自建瓦片代理**
1. 在可访问海外的服务器上架设 OSM 瓦片代理
2. 编辑面板 → Map layers → Base layer → URL template 填入代理地址

### ❌ 切换高德/谷歌路网后车辆标记偏离道路 100~700 米

**原因：坐标系差异 + 未装 PostgreSQL 坐标转换函数**

高德 / 谷歌中国区域路网瓦片用 **GCJ-02（火星坐标系）**，TeslaMate 记录的是 **WGS-84（GPS 原始）**。两者在中国境内偏差 100~700 米。

**解决：**执行本页 [四个 SQL 安装文件修复循环](#repair-sql-install)，其中包含 v1.4.2+ 的坐标转换函数，并会一并补齐单位换算、分时电价和性能索引。

执行后会显示「坐标转换函数安装成功 (天安门测试通过): (39.91522, 116.40407)」自检通过提示。装完刷新仪表盘（Ctrl+Shift+R），轨迹会自动贴合道路。

> 不在意精度的话，切回 OSM / Carto / 谷歌卫星即可（都是 WGS-84，无偏差）。

### ❌ 仪表盘顶部「地图源」下拉框看不到

**症状**：升级到 v1.4.2 后，仪表盘顶部下拉框区域空白或只看到旧变量

**排查步骤：**
1. **强刷浏览器**：Ctrl+Shift+R（Windows）/ Cmd+Shift+R（Mac），清掉 Grafana 前端缓存
2. **重启 Grafana 容器**：`docker compose restart grafana`，触发仪表盘自动加载重新生效
3. **确认你打开的是含地图的仪表盘**：只有 9 个仪表盘有此下拉框（CurrentChargeView / CurrentDriveView / CurrentState / TrackingDrives / charging-stats / trip / visited / charge-details / drive-details）
4. **确认仓库是 v1.4.2+**：`head -3 CHANGELOG.md` 应显示 `## [v1.4.2]` 或更新版本

### ❌ 装 PostgreSQL 坐标转换函数报错

**症状**：执行 `docker exec -i teslamate-database-1 psql ...` 时报错

**常见原因 + 解决：**

| 报错关键字 | 原因 | 解决 |
|----------|------|------|
| `No such container: teslamate-database-1` | 容器名不对 | 先 `docker ps` 找你的 PostgreSQL 容器名（一般是 `teslamate-database-1` / `teslamate_database_1` 或 `postgres`），用真实名替换 |
| `database "teslamate" does not exist` | 数据库名不对 | TeslaMate 默认 DB 名就叫 teslamate；如自定义过，把命令里的 `teslamate teslamate` 第二个换成你的实际 DB 名 |
| `permission denied` | 用户权限不足 | TeslaMate 默认 superuser 是 `teslamate`；如改过，把 `-U teslamate` 替换 |
| `function pi() does not exist` | PostgreSQL 版本太低 | 函数依赖 PostgreSQL 9.0+ 内置 pi()；TeslaMate 官方镜像满足，正常不会触发 |

**确认装好的快速测试：**
```bash
docker exec teslamate-database-1 psql -U teslamate -d teslamate \
  -c "SELECT lat_for_map('autonavi.com', 39.913818, 116.397828);"
# 应输出 39.9152217625129（不是原值 39.913818）
```

输出原值说明函数没装上或 URL 不匹配；输出转换后的值说明工作正常。

---

### ❌ 行程地址不显示（显示为空或仅有坐标）

**症状**：行程列表中出发地、目的地显示为空，或仪表盘中地点名称无法正确显示

**原因：Nominatim 地址解析服务在国内无法访问**

TeslaMate 使用 [Nominatim](https://nominatim.openstreetmap.org)（OpenStreetMap 地理编码服务）将 GPS 坐标转换为可读地址。该服务在中国大陆网络环境下通常无法直连，导致地址字段始终为空。

> 注意：这与「地图不显示」是两个独立问题。地图显示的是瓦片图层，地址显示依赖 Nominatim API 查询，二者需要分别解决。

**解决：配置 Nominatim 代理**

TeslaMate 现已原生支持通过 `NOMINATIM_PROXY` 环境变量为地址解析配置代理，编辑 `docker-compose.yml`，在 `teslamate` 服务的 environment 中添加：

```yaml
services:
  teslamate:
    environment:
      # ... 其他配置 ...
      - NOMINATIM_PROXY=http://代理IP:端口
```

配置后重启 TeslaMate：
```bash
docker compose restart teslamate
```

> **注意：TeslaMate 仅识别 HTTP 类型代理**（HTTP CONNECT 方式），不支持 SOCKS5 代理或仅 HTTPS 隧道型代理。格式为 `http://代理IP:端口`，例如 Clash / V2Ray 默认在 `http://127.0.0.1:7897`。代理会用于反解 OSM Nominatim 的请求（即使最终是去 https://nominatim.openstreetmap.org），所以 scheme 写 `http://` 即可。配置后历史行程的地址也会在下次处理时自动补全。

---

## 🌐 网络问题

<a id="nominatim-proxy"></a>

### 🇨🇳 行程列表地址列空 / 地图地名乱 — Nominatim 国内反查超时（中国大陆用户高频问题）

**症状**：
- 「行程列表」仪表盘起始地址 / 结束地址列大量空，只有收藏点（Geofence，数据库中称地理围栏）地址有显示
- `SELECT COUNT(*) FROM addresses` 数量远小于 `drives` 数量

**根因**：TeslaMate 用 OpenStreetMap Nominatim（`nominatim.openstreetmap.org`）做反向地理编码，**国内访问常超时**。反查失败的 drive 的 `start_address_id` / `end_address_id` 永远 NULL，地址列就空了。

**确诊**：

```bash
docker exec teslamate-database-1 psql -U teslamate -d teslamate -c "SELECT COUNT(*) AS total, COUNT(start_address_id) AS with_start_addr, COUNT(end_address_id) AS with_end_addr, COUNT(start_geofence_id) AS in_geofence FROM drives WHERE car_id = 1;"
```

`with_start_addr` 远小于 `total` 就是这个问题。

**修复**：给 TeslaMate 容器配 Nominatim 代理（**TeslaMate 专用 env，只一行，HTTP only，只代理 Nominatim 流量，不影响 Tesla API**），在 `docker-compose.yml` 的 `teslamate` service 里加：

```yaml
services:
  teslamate:
    environment:
      # ... 已有 ENCRYPTION_KEY / TZ 等 ...
      - NOMINATIM_PROXY=http://代理地址:端口
```

代理地址按场景填：
- NAS 上跑 Clash docker 容器：`http://<Clash容器名>:7890`（需同 docker network）或 `http://<NAS内网IP>:7890`
- NAS 宿主机跑代理：`http://<NAS内网IP>:7890`（推荐，最稳）
- 路由器 / 软路由：`http://<路由器IP>:7890`

**注意**：
- 仅支持 **HTTP**（不是 HTTPS / SOCKS5）。Clash 默认 HTTP 端口是 7890（不是 SOCKS5 的 7891）
- 不需要配 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` 等通用 env —— 这个变量只代理 Nominatim 一处
- 不影响 Tesla API（设计意图：国内 Tesla API 需直连不能走代理）

改完重启 + 验证：

```bash
docker compose up -d teslamate
docker compose logs -f teslamate | grep -iE "nominatim|geocod"
```

应该看到 `Geocoding ... → 城市/街道` 成功而不是 timeout / connection refused。

**等待恢复**：

TeslaMate 启动时扫 `start_address_id IS NULL` 的 drive 重新入反查队列。几小时到一天，`addresses` 表会从几百涨到几千，行程列表地址列陆续补全。监控进度：

```bash
docker exec teslamate-database-1 psql -U teslamate -d teslamate -c "SELECT COUNT(*) FROM addresses;"
```

数字一直涨就是在跑。

---

### ❌ 国内无法访问 ghcr.io 镜像

见上方「镜像拉取失败（国内网络）」章节。

---

### ❌ 防火墙阻止访问

如果你的服务器有防火墙（如阿里云/腾讯云安全组），需要开放端口：

```bash
# Ubuntu UFW
sudo ufw allow 4000/tcp   # TeslaMate
sudo ufw allow 3000/tcp   # Grafana

# CentOS firewalld
sudo firewall-cmd --permanent --add-port=4000/tcp
sudo firewall-cmd --permanent --add-port=3000/tcp
sudo firewall-cmd --reload
```

云服务器还需要在控制台的「安全组/防火墙」页面添加入站规则。

---

### ❌ 从外网访问（公网 IP）

⚠️ **直接把 TeslaMate `:4000` 暴露到公网 = 任何人能看到你的车辆位置/历史行程**。Grafana `:3000` 自 v1.6.9 起脚本自动生成强随机密码（旧版 admin/admin 一秒被攻破）。**强烈建议先看 [QUICKSTART.md - 云服务器场景：安全防护必读](QUICKSTART.md#cloud-security)** 完整 5 级防护清单。

简版快速选项（详细操作见上述 QUICKSTART 章节）：
1. **Tailscale / ZeroTier**（推荐新手）：虚拟内网，云服务器关掉公网端口，本地像局域网访问
2. **Cloudflare Tunnel**：免费 + 自动 HTTPS，需要域名
3. **反向代理（Nginx/Caddy）+ Basic Auth + HTTPS**：最灵活，需运维经验

无论选哪种，都要：
- ✅ Grafana 密码（v1.6.9+ 自动强随机；旧版 admin/admin 务必手动改）
- ✅ 云服务器安全组里 4000/3000 不要 `0.0.0.0/0` 全开放
- ✅ docker-compose.yml 端口绑定改 `127.0.0.1:` 前缀（如果配反向代理）

---

### 🟢 群晖 DSM 7.x 反向代理 + Let's Encrypt（推荐 NAS 用户）

**目标：** 用域名 `teslamate.your-domain.com` HTTPS 访问，不暴露 `:4000` `:3000` 端口。

**前置条件：**
- DSM 7.0+
- 一个能解析到你 NAS 公网 IP（或 DDNS）的域名
- 路由器已把 80 / 443 端口转发到 NAS

**步骤 1：申请 Let's Encrypt 证书**

1. **控制面板 → 安全性 → 证书 → 新增 → 添加新证书 → 从 Let's Encrypt 取得证书**
2. **域名** 填 `teslamate.your-domain.com`，**电邮** 填你能收信的邮箱
3. 点确定，DSM 自动用 80 端口完成 ACME 验证
4. 提示「证书已添加」即成功（**域名不解析 / 80 端口不通会失败**，先 `curl -I http://teslamate.your-domain.com` 验证）

**步骤 2：配反向代理**

1. **控制面板 → 登录门户 → 高级 → 反向代理服务器 → 新增**
2. **来源**：协议 `HTTPS` / 主机名 `teslamate.your-domain.com` / 端口 `443`
3. **目的地**：协议 `HTTP` / 主机名 `localhost` / 端口 `4000`（TeslaMate 主页）
4. 切到「自定义标头」标签页 → **新增 → 创建** → 选 **WebSocket**（TeslaMate 实时更新依赖 WS，不加这条会卡）
5. 保存。如果还要给 Grafana 配反代，新建一条规则：来源 `grafana.your-domain.com:443` → 目的地 `localhost:3000`

**步骤 3：绑定证书到域名**

控制面板 → 安全性 → 证书 → 选刚申请的证书 → **设置 → 把 `teslamate.your-domain.com` 服务的证书改为这张**。

**步骤 4：关掉端口直连**

打开浏览器测试 `https://teslamate.your-domain.com` 能进 → 改 `~/teslamate-chinese/docker-compose.yml`，给 teslamate 端口加 `127.0.0.1:` 前缀（仅本机访问，反代用），重启容器：
```yaml
    ports:
      - 127.0.0.1:4000:4000
```

**证书自动续期：** Let's Encrypt 90 天到期，DSM 默认每天 03:00 检查 → 30 天内到期自动续期，**不用手动管**。

> ⚠️ 证书续期失败常见原因：80 端口路由器忘了转发，或被 ISP 封。检查路径：控制面板 → 通知 → 看 ACME renewal 的失败日志。

---

### 🟢 群晖 Container Manager 「项目」部署（DSM 7.2+ 推荐）

**适用场景：** DSM 7.2+ 移除了 Docker 套件、用 Container Manager 替代。命令行不熟、想纯 GUI 部署的群晖小白。

**步骤 1：装 Container Manager**

控制面板 → 套件中心 → 搜「Container Manager」→ 安装。

**步骤 2：准备 docker-compose.yml**

DSM File Station 进入 `/volume1/docker/`，新建子文件夹 `teslamate`，并在其中再新建一个子文件夹 `import`（下方模板挂载了 `./import:/opt/app/import`，DSM **不会自动创建**这个目录，不建会在启动时报 `Bind mount failed: ... import does not exist`）。回到 `teslamate` 文件夹，**右键 → 新建文件 → 命名 `docker-compose.yml`**，内容粘贴下方完整模板（**记得替换两个红色占位符**）：

```yaml
services:
  teslamate:
    image: teslamate/teslamate:latest
    restart: always
    cap_drop:
      - all
    ports:
      - 4000:4000
    volumes:
      - ./import:/opt/app/import
    environment:
      - ENCRYPTION_KEY=【请改成 openssl rand -hex 32 生成的 64 位字符串】
      - DATABASE_USER=teslamate
      - DATABASE_PASS=【请改成 openssl rand -base64 24 生成的密码】
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - MQTT_HOST=mosquitto
      - TZ=Asia/Shanghai

  database:
    image: postgres:18-trixie
    restart: always
    volumes:
      - teslamate-db:/var/lib/postgresql
    environment:
      - POSTGRES_USER=teslamate
      - POSTGRES_PASSWORD=【与上面 DATABASE_PASS 同一个密码】
      - POSTGRES_DB=teslamate

  grafana:
    image: bswlhbhmt816/teslamate-chinese-dashboards:latest
    restart: always
    ports:
      - 3000:3000
    volumes:
      - teslamate-grafana-data:/var/lib/grafana
    environment:
      - DATABASE_USER=teslamate
      - DATABASE_PASS=【与上面 DATABASE_PASS 同一个密码】
      - DATABASE_NAME=teslamate
      - DATABASE_HOST=database
      - GF_SECURITY_ADMIN_PASSWORD=【建议改成强密码，simple-deploy.sh v1.6.9+ 会自动生成】
      - GF_USERS_DEFAULT_LANGUAGE=zh-Hans

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

> **生成两个密钥的方法**（任选一种）：
> - **DSM 套件中心装「Text Editor / 终端机」**：开终端，跑 `openssl rand -hex 32`（这是 ENCRYPTION_KEY）+ `openssl rand -base64 24 | tr -d '/+=' | cut -c1-24`（这是 DATABASE_PASS），把输出粘到 yml 里
> - **任何 Mac / Linux 桌面**：终端跑同样命令，复制粘贴
> - **没终端**：用 [random-string-generator.com](https://www.random-string-generator.com/) 生成 64 位 hex（不推荐，第三方网站存在泄露风险，本地终端跑更稳）

⚠️ **`ENCRYPTION_KEY` 用于加密 Tesla token，丢了下次装就解密不出来**。生成完立刻抄到 1Password / Bitwarden / Keychain。

**步骤 3：在 Container Manager 里建项目**

1. Container Manager → **项目 → 新增**
2. **项目名称**：`teslamate-chinese`（建议保持此值；若改名，下面终端命令里的 `COMPOSE_PROJECT_NAME` 也要同步改）
3. **路径**：选刚刚放 docker-compose.yml 的文件夹（如 `/docker/teslamate`）
4. **来源**：选「使用现有的 docker-compose.yml」
5. 点「下一步」→ Container Manager 自动解析 compose，列出 4 个服务（teslamate / database / grafana / mosquitto）
6. **下一步 → 完成 → 启动项目**

**步骤 4：等容器拉取启动**

进度条到 100% 后，浏览器访问 `http://NAS-IP:4000` 进 TeslaMate。

**步骤 5：安装 SQL 四件套（坐标转换 / 单位换算 / 分时电价 / 性能索引）**

Container Manager 只是起了原始官方 TeslaMate + 我们的 Grafana 镜像，Grafana 镜像本身不会自动把函数装进 PostgreSQL——地图、单位换算、分时电价这几类面板要先装函数才能用。用步骤 2 装的「Text Editor / 终端机」套件开个普通终端，先执行：

```bash
cd /volume1/docker/teslamate
export COMPOSE_PROJECT_NAME=teslamate-chinese
```

> 如果项目实际放在其他存储卷或目录，请把第一行换成真实路径；如果步骤 3 使用了其他项目名称，请同步修改第二行。

然后执行本页 [四个 SQL 安装文件修复循环](#repair-sql-install)（从当前项目探测 database 容器，任一文件失败即退出）。

**升级时：** Container Manager → 项目 → 选 `teslamate-chinese` → **操作 → 重新构建** 即可重新拉镜像（实际等价于 `docker compose pull && docker compose up -d`）。

> ⚠️ Container Manager 项目模式有个坑：第一次启动失败后，**项目状态会卡在 STOPPED**，但部分容器其实启动了一半。**清理方法**：项目页面 → 操作 → 停止 → 清理 → 重新构建。

---

### ❌ 反向代理后访问路径报错（子路径部署）

**症状**：通过反向代理将 TeslaMate 部署在子路径下（如 `/teslamate/`），访问时出现资源加载失败或页面空白。

**解决：配置 URL_PATH 环境变量**

> ℹ️ **根路径用户无需配置**（`URL_PATH` 默认值就是 `/`）。仅当你要把 TeslaMate 挂到子路径（如 `https://your-domain/teslamate/`）时才设置。

在 `docker-compose.yml` 的 `teslamate` 服务中添加：

```yaml
services:
  teslamate:
    environment:
      # ... 其他配置 ...
      - URL_PATH=/teslamate
```

同时需要在反向代理（Nginx/Caddy）中正确配置路径转发，例如 Nginx：

```nginx
location /teslamate/ {
    proxy_pass http://localhost:4000/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;

    # ⚠ 关键：TeslaMate 用 Phoenix LiveView，必须显式 upgrade WebSocket
    # 缺这三行进得去主页但实时车辆状态 / 地图轨迹不更新
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

> **注意**：`URL_PATH` 值不要加末尾斜杠（写 `/teslamate` 而非 `/teslamate/`）。

---

## 🌍 公网部署专项（云服务器用户）

### ⚠️ 流量爆表防护

云服务器（阿里云轻量 / 腾讯云轻量 / AWS Lightsail）通常按**月流量包**计费，公网暴露 Grafana 后高德/谷歌瓦片可能让流量飙升。

**典型场景**：

- 阿里云轻量 `1Mbps / 100GB` 套餐
- 你 + 家人手机经常打开「足迹地图」/ 「驾驶记录追踪」，每次加载几百张地图瓦片
- **1 周打满 100GB**（高德瓦片每张 ~30KB，3000 张 ≈ 100MB，1 周访问 1000 次就 100GB）

**3 种解决方案**：

| 方案 | 说明 | 推荐度 |
|---|---|---|
| ✅ **Tailscale / 自建 WireGuard** | 不开公网，只在自己设备间通信，**0 流量消耗** | ⭐⭐⭐⭐⭐ |
| ⚠️ Cloudflare 反代 | 中间挡一层 CDN 缓存瓦片 | ⭐⭐⭐ 减少但不消除 |
| ⚠️ Grafana 切换 OSM 默认 | OSM 瓦片小（~10KB），但**国内访问慢** | ⭐⭐ 小流量但卡 |

**强烈建议**：除非确实需要公网访问，**用 Tailscale** —— 5 分钟设置，免费，所有家人手机一并接入，流量为 0。

详见 [QUICKSTART → cloud-security 章节](QUICKSTART.md#cloud-security) 的 Tailscale 段。

### ⚠️ 服务挂了你怎么知道？— 失败告警可选配置

TeslaMate / Grafana 容器 OOM / 数据库挂 / Tesla token 过期 等情况下，**默认无任何通知**，你只能下次打开 Grafana 才发现「数据停在三周前」。

**配 uptime-kuma 5 分钟搞定**：

```yaml
# 在你 docker-compose.yml 末尾加这个 service：
  uptime-kuma:
    image: louislam/uptime-kuma:1
    restart: always
    ports:
      - 3001:3001
    volumes:
      - uptime-kuma-data:/app/data

# 也别忘了 volumes 段加：
volumes:
  uptime-kuma-data:
```

`docker compose up -d` 后访问 `http://你机器:3001`：

- 添加监控：`http://localhost:4000` (TeslaMate)、`http://localhost:3000` (Grafana)
- 频率：每 60 秒 ping 一次
- 通知：Telegram / 微信 (PushDeer / Bark) / 邮件 / Discord 任选

挂了 1 分钟内手机收到告警。

> ⚠️ uptime-kuma 是**第三方开源项目**，本项目不强制集成，仅作可选推荐。

---

## 🔄 升级问题

### 正常升级入口

正常升级命令只在 [README → 升级到最新版](README.md#upgrade-latest) 维护，按一键脚本、git clone、自写 Compose / Watchtower 或官方版迁移选择一条。这里仅保留升级失败后的修复方法。

如果你只执行过 `docker compose pull` / `docker compose up -d` 或由 Watchtower 自动换过镜像，新版本涉及 SQL 时可能报 `lat_for_map`、`convert_km`、`effective_cost` 等自定义函数不存在。这不是 PostgreSQL 版本问题，执行本页唯一的 [四个 SQL 安装文件修复循环](#repair-sql-install) 即可。

---

<a id="postgresql-upgrade"></a>

### PostgreSQL 大版本升级（如 17 → 18）

只在完整报错明确指向四参数 `generate_series(timestamp with time zone, timestamp with time zone, interval, text/unknown) does not exist`，且版本低于 16 时，才需要为兼容性安排升级。PG 15 已支持 `date_trunc(text, timestamptz, text)`；仅看到 `date_trunc` 报错时，请先保留完整错误和 SQL，确认函数签名、参数类型及实际版本，不要直接做大版本升级。

⚠️ **不能直接改 `image: postgres:18-trixie` 重启**——PostgreSQL 大版本之间数据文件不兼容，直接换镜像会让 database 容器进入 `database files are incompatible with server` 反复重启循环。**必须按官方流程：备份 → 删卷 → 换镜像 → 恢复**。

参考：[TeslaMate 官方 upgrading_postgres](https://docs.teslamate.org/docs/maintenance/upgrading_postgres)

```bash
cd ~/teslamate-chinese

# 1. 先用旧 PG 容器做完整备份（关键！换镜像前最后机会）
docker compose exec -T database pg_dump -U teslamate teslamate > pg-pre-upgrade.sql

# 2. 完全停服（包括数据库）
docker compose down

# 3. 删旧的命名卷（数据文件在这里，PG 大版本不兼容必须删）
# 自动找 PG 数据卷名：项目目录不叫 teslamate 时卷名前缀会变
DB_VOL=$(docker volume ls -q | grep teslamate-db | head -1)
[ -z "$DB_VOL" ] && { echo "❌ 找不到 teslamate-db 卷，可能你之前用了 bind mount。手动删 PG 数据目录，跳过这一步"; exit 1; }
echo "将删除卷：$DB_VOL"
docker volume rm "$DB_VOL"
# ⚠ 这一步会删除整个数据库文件，没有备份千万别跑！

# 4. 修改 docker-compose.yml 把 image 改成新版本：
#    image: postgres:18-trixie  # 或更新版本

# 5. 启动 database 让它用新版本初始化空数据库
docker compose up -d database
sleep 30   # 等新 PG 完成首次初始化

# 6. 恢复（按上节「数据库备份与恢复」的恢复流程）
docker compose stop teslamate 2>/dev/null || true
docker compose exec -T database psql -U teslamate teslamate <<'EOF'
DROP SCHEMA public CASCADE;
DROP SCHEMA private CASCADE;
CREATE SCHEMA public;
CREATE EXTENSION cube WITH SCHEMA public;
CREATE EXTENSION earthdistance WITH SCHEMA public;
EOF
docker compose exec -T database psql -U teslamate teslamate < pg-pre-upgrade.sql

# 7. 启动其他服务
docker compose up -d
```

> 跳过任一步都会丢数据。**第 1 步备份是唯一保险**——备份没做就跑第 3 步 = 行车记录全丢且无法恢复。

---

<a id="tou-rollback"></a>

### v1.5.0 分时电价升级排错 / 回滚

#### 仪表盘报 `function effective_cost(...) does not exist`

`install-tou.sql` 没装上。执行本页唯一的 [四个 SQL 安装文件修复循环](#repair-sql-install)，不要只补一个文件；正常升级入口见 [README](README.md#upgrade-latest)。

#### 「⚡ 分时电价配置」仪表盘空白 / 不显示表单

Grafana 缺 `volkovlabs-form-panel` 插件。**v1.6.3+ 镜像 构建时已装**，但**升级用户需要额外做一步 运行时装**（Docker 数据卷会盖住镜像里新装的插件）。详见 [issue #13](https://github.com/wjsall/teslamate-chinese-dashboards/issues/13)。

##### 修法（**所有受影响用户都跑这条**）

```bash
docker exec --user root teslamate-grafana-1 grafana cli plugins install volkovlabs-form-panel 6.3.2 \
 && docker compose restart grafana \
 && sleep 10 \
 && docker exec teslamate-grafana-1 grafana cli plugins ls | grep volkovlabs-form-panel
```

**期望输出**：

```
volkovlabs-form-panel @ 6.3.2
```

装一次后**永久生效**（Grafana 数据卷持久化）。

##### 为什么升级镜像本身不够（Docker 数据卷坑）

TeslaMate 标准 compose 有 `teslamate-grafana-data:/var/lib/grafana` 命名卷。Docker 命名卷的行为：

> **首次创建容器时**从镜像挂载点**拷贝初始内容**，**之后只用卷自己的内容**。

后果：
- 已经跑过 grafana 的用户 → 卷里是旧镜像的 plugins/，**新镜像里的 form-panel 进不去卷**
- 全新用户首次 `docker compose up` → 卷是空的，从 v1.6.3+ 镜像拷贝（**含 form-panel**）✅

`--force-recreate` 只销毁容器实例，**不动卷**。所以已有 grafana 卷的用户必须 运行时装一次。

##### 谁不受影响

| 用户类型 | 是否需要 运行时装 |
|---|---|
| 全新装（首次 `docker compose up`，卷为空）| ❌ 不需要，v1.6.3+ 镜像自动带 |
| 用 `scripts/upgrade.sh` 升级 | ❌ 不需要，脚本自动检测 + 触发 运行时装 |
| **手动 `docker compose pull + up -d`（任何旧版本升 v1.6.3）** | ✅ 需要，跑上面的命令 |
| 自己组 compose 没用我们镜像 | ✅ 需要，跑上面的命令 |

#### 主仪表盘费用数字突然变了

如果你**配了分时电价**，所有费用面板会自动按 分时电价真实价显示，跟之前 TeslaMate 默认估算的数字会有 1-5% 差异（TeslaMate 默认按充电点配的固定单价 × 度数算，分时电价是按时段逐秒加权）。这是预期行为。

**想恢复原数字**：

```bash
# 选项 1：清空 分时电价配置（保留函数和旁路表，下次想用还能用）
docker exec teslamate-database-1 psql -U teslamate -d teslamate \
  -c "TRUNCATE tou_rates RESTART IDENTITY CASCADE; TRUNCATE charging_processes_tou_cost"

# 选项 2：把仪表盘 SQL 改回原 cost（git clone 用户）
python3 scripts/wrap-cost-with-tou-view.py --revert
```

#### 完全卸载分时电价（恢复到 v1.4.x 状态）

**TeslaMate 任何表都没动**，可以彻底拆除。一行调 `uninstall_tou()` PG 函数：

```bash
docker exec teslamate-database-1 psql -U teslamate -d teslamate \
  -c "SELECT uninstall_tou(); DROP FUNCTION uninstall_tou();"

# 仪表盘 SQL 也改回去（git clone 用户）
python3 scripts/wrap-cost-with-tou-view.py --revert
```

`uninstall_tou()` 用 `pg_proc` 自动找全部 tou_* / _tou_* 函数，并删除触发器和旁路表，不会跟 install-tou.sql 函数列表漂移。

> ⚠ 调用会 **CASCADE 删除所有依赖 `tou_rates` / `charging_processes_tou_cost` 的对象（包括你自己建的视图）**。卸载前先跑 `\d+ tou_rates` 看 referenced by 列表确认没要保的。

#### 分时电价计算不对劲（充电费用看上去不合理）

打开「⚡ 分时电价配置」仪表盘，看「⚠ 配置审计」面板：
- **时段空缺**：某些小时没配置 → 那段时间充电会按 NULL → 仪表盘回退到原 `cost`
- **时段重叠**：同一小时被多条记录覆盖 → 系统按 ID 最小的那条算，其他失效
- **月份空缺**：整个月没落入任何季节 → 那个月充电按 NULL → 回退到原 `cost`

修法：用「⚡ 一键填一整季节」重新覆盖，或「✏️ 修改单价」/「🗑️ 删除整段」精修。
改完点底部「**🔄 重算所有历史充电**」按钮重算历史。

---

### ❌ 升级后数据丢失 / 仪表盘错乱

**不要慌，数据通常在数据库里没问题。**

```bash
# 确认数据库数据完整
docker compose exec database psql -U teslamate -c "SELECT COUNT(*) FROM drives;"
```

仪表盘错乱通常是 Grafana 缓存问题：
```bash
docker compose restart grafana
# 然后清除浏览器缓存：Ctrl+Shift+R
```

---

### 数据库备份与恢复

> ℹ️ 流程跟 [TeslaMate 官方 backup_restore](https://docs.teslamate.org/docs/maintenance/backup_restore) 对齐。**恢复前必须先 `DROP SCHEMA public + private CASCADE` + `CREATE EXTENSION cube + earthdistance`**，不然 Tesla token 解密会失败（被迫重新授权），且新机器上 `pg_restore` 报 `type "cube" does not exist`。详细数据迁移流程见上节「整机迁移」。
>
> v1.6.6 修复的正是旧恢复流程漏掉 `DROP SCHEMA private` 与 `CREATE EXTENSION cube` 的问题。如果你过去整机迁移后遇到 Token 解密失败、被迫重新授权，通常就是这个原因；当前流程已包含修复。背景见 [v1.6.6 发版说明](https://github.com/wjsall/teslamate-chinese-dashboards/releases/tag/v1.6.6)。

**备份**（plain SQL 格式，简单 + 跨版本兼容）：
```bash
cd ~/teslamate-chinese
docker compose exec -T database pg_dump -U teslamate teslamate > backup_$(date +%Y%m%d_%H%M).sql
```

**恢复**（必须跟官方流程一致）：
```bash
cd ~/teslamate-chinese

# 1. 完整启动一次（让 teslamate 自动建好 schema 和 extensions）
docker compose up -d
sleep 30

# 2. 停 teslamate 防止恢复时写冲突（database 保持运行）
docker compose stop teslamate

# 3. 清空 schema + 重建 extensions（跟官方 backup_restore 对齐，关键步骤）
docker compose exec -T database psql -U teslamate teslamate <<'EOF'
DROP SCHEMA public CASCADE;
DROP SCHEMA private CASCADE;
CREATE SCHEMA public;
CREATE EXTENSION cube WITH SCHEMA public;
CREATE EXTENSION earthdistance WITH SCHEMA public;
EOF

# 4. 恢复 SQL 数据
docker compose exec -T database psql -U teslamate teslamate < backup_20260315_1200.sql

# 5. 启动 teslamate
docker compose start teslamate
```

---

## 🚚 迁移与备份

### 整机迁移（旧 NAS → 新 NAS / 重装 DSM / 换云服务器）

⚠️ **必须备份的 3 件**（缺一不可，少一个都恢复不了）：

| 项 | 不备份的后果 |
|---|---|
| 1. **`docker-compose.yml`**（含 `ENCRYPTION_KEY` + 数据库密码）| Tesla token 永远解密不出来，必须重新授权 |
| 2. **PostgreSQL 数据库备份**（`drives` / `charges` / `positions` / `cars` 全部历史）| 行车记录全丢 |
| 3. **Grafana 数据卷**（自定义书签 / 用户 / 配置）| 你改过的仪表盘设置丢，45 个仪表盘会自动重新加载 |

**备份步骤（旧机器上跑）**：

```bash
cd ~/teslamate-chinese

# 1. 备份 docker-compose.yml + .env
tar czf teslamate-config.tar.gz docker-compose.yml .env 2>/dev/null

# 2. 备份数据库（pg_dump）
docker compose exec -T database \
  pg_dump -U teslamate -d teslamate -Fc -f /tmp/teslamate.dump
docker cp $(docker compose ps -q database):/tmp/teslamate.dump ./teslamate.dump

# 3. 备份 Grafana 数据卷
docker run --rm \
  -v teslamate_teslamate-grafana-data:/data \
  -v $(pwd):/backup alpine \
  tar czf /backup/grafana-data.tar.gz -C /data .

# 4. 把 3 个备份文件下载到本机 / 网盘 / 移动硬盘
ls -lh teslamate-config.tar.gz teslamate.dump grafana-data.tar.gz
```

**恢复步骤（新机器上）**：

> ⚠️ **关键 vs 旧版**：旧版「先起 database → pg_restore -c」流程会踩两个坑：(1) `private` schema 不被 `-c` 清理 → 旧 token 加密对象残留 → Tesla token 解密失败被迫重新授权；(2) 单起 database 容器时 `cube` / `earthdistance` extension 没装 → pg_restore 报 `type "cube" does not exist`。下面流程跟 [TeslaMate 官方 backup_restore](https://docs.teslamate.org/docs/maintenance/backup_restore) 对齐，避坑。

```bash
# 1. 装回 TeslaMate
mkdir -p ~/teslamate-chinese
cd ~/teslamate-chinese

# 2. 恢复 docker-compose.yml + .env（含 ENCRYPTION_KEY，必须保持一致）
tar xzf teslamate-config.tar.gz

# 3. 完整启动一次（让 teslamate 容器自动建好 schema 和 extensions）
docker compose up -d
sleep 30   # 等 teslamate 完成首次 schema/extension 初始化

# 4. 停 teslamate 防止恢复时写冲突（database 保持运行）
docker compose stop teslamate

# 5. 清空 schema + 重建 extensions（跟官方 backup_restore 对齐）
docker compose exec -T database psql -U teslamate teslamate <<'EOF'
DROP SCHEMA public CASCADE;
DROP SCHEMA private CASCADE;
CREATE SCHEMA public;
CREATE EXTENSION cube WITH SCHEMA public;
CREATE EXTENSION earthdistance WITH SCHEMA public;
EOF

# 6. 恢复数据库（用 -Fc 格式备份文件 → pg_restore，不带 -c 因为已手动 DROP）
docker cp teslamate.dump $(docker compose ps -q database):/tmp/teslamate.dump
docker compose exec -T database \
  pg_restore -U teslamate -d teslamate /tmp/teslamate.dump

# 7. 恢复 Grafana 数据卷
docker run --rm \
  -v teslamate_teslamate-grafana-data:/data \
  -v $(pwd):/backup alpine \
  tar xzf /backup/grafana-data.tar.gz -C /data

# 8. 启动 teslamate
docker compose start teslamate
```

> **如果你已经按旧版流程恢复过 + token 解密失败被迫重授权过**：那是这个 bug 的症状。现在用新流程不会再遇到。如果还有 4S 店保养记录或其他业务数据是从备份恢复来的，旧版流程不会丢，仅 token 那一项受影响。

<a id="db-backup"></a>

### 定期自动备份数据库

只想定期留一份数据库快照（不迁移）。用 **`backup.sh`**，安全第一：

- 导出失败（`pg_dump` 报错 / 文件异常小 / 归档损坏）→ **立即中止，绝不产出空文件、绝不删除任何已有备份**；
- 只有本轮确认成功，才清理超出保留份数的旧备份；
- **默认连 `docker-compose.yml`（含 `ENCRYPTION_KEY`）一起快照**（存成 `teslamate-compose-SECRET.yml`），让这份备份能**独立恢复**——否则光有数据库 dump、没密钥，恢复后 token 解不开（详见下方「关于密钥与隐私」）；
- 任何失败 `exit 1`（cron / 任务计划能据此报警），全程写日志到 `$BACKUP_DIR/backup.log`。

**最省事：一键安装用户重跑安装脚本**

`simple-deploy.sh` 会自动把 `backup.sh` 下载到 `~/teslamate-chinese/backup.sh`，并让你三选一：**① 是，备份含密钥（推荐，能独立恢复）/ ② 是，备份不含密钥（需自己留底密钥）/ ③ 否**——选 ① / ② 后，通用 Linux 直接帮你写好 crontab、群晖打印 DSM 任务计划步骤。已经装过的，重跑一次脚本（走升级模式）同样会问。非交互（`curl|bash`）模式想直接设：`AUTO_BACKUP=1` 重跑（默认含密钥，不含再加 `INCLUDE_CONFIG=0`）。

**手动用脚本（git clone 用户 / 想自己控制）**

脚本位置：`git clone` 用户在仓库 `scripts/backup.sh`；一键安装用户在 `~/teslamate-chinese/backup.sh`；都没有就手动拉（单文件即可跑，内置容器探测兜底）：

```bash
curl -fsSL https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/main/scripts/backup.sh \
  -o ~/teslamate-chinese/backup.sh
```

先手动验证能跑通（路径换成你脚本的实际位置）：

```bash
BACKUP_DIR=~/teslamate-chinese/backups KEEP=7 bash ~/teslamate-chinese/backup.sh
```

成功后会在 `BACKUP_DIR` 生成 `teslamate-YYYYmmdd_HHMM.dump`（`-Fc` 压缩格式）+ 一份 `teslamate-compose-SECRET.yml`（含密钥的配置，只留最新一份），并自动只保留最近 `KEEP` 份 dump。可配环境变量：`BACKUP_DIR`（默认 `./backups`）/ `KEEP`（默认 `4`）/ `DB_CONTAINER`（留空自动探测）/ `INCLUDE_CONFIG`（默认 `1`；设 `0` 则备份不含密钥）/ `COMPOSE_FILE`（`docker-compose.yml` 路径，留空自动找）。

跑通后挂到定时任务，按环境二选一：

**A. 群晖 DSM**

控制面板 ▸ 任务计划 ▸ 新增 ▸ 计划的任务 ▸ 用户定义的脚本：
- 用户账号：`root`（需要能跑 docker）
- 计划：例如「每天 03:00」
- 任务设置 ▸ 运行命令（把路径换成你脚本的实际位置，用绝对路径）：

```bash
BACKUP_DIR=/volume1/backup KEEP=7 bash /root/teslamate-chinese/backup.sh
```

**B. 通用 Linux / Docker（crontab）**

```bash
crontab -e
# 加一行：每天 03:00 备份、保留 7 份（用绝对路径，~ 在 crontab 里不展开）
0 3 * * *  BACKUP_DIR=$HOME/teslamate-chinese/backups KEEP=7 bash $HOME/teslamate-chinese/backup.sh >> $HOME/teslamate-chinese/backups/cron.log 2>&1
```

> 🔐 **关于密钥与隐私**：默认每个备份目录里会有一份 `teslamate-compose-SECRET.yml`（就是你的 `docker-compose.yml`，含 `ENCRYPTION_KEY`）。好处是这份备份能**独立恢复**，你不必再手抄密钥。代价：**谁拿到这份备份就能解出你的 Tesla token（token 能控车）**——所以备份目录务必私密（自己的 NAS / 私有网盘即可），**别公开分享，发论坛求助前先把这个文件删掉**。完全不想包含密钥：备份命令加 `INCLUDE_CONFIG=0`（那就得自己单独留底 `ENCRYPTION_KEY`，否则恢复后 token 解不开、必须重新授权）。

> 🔁 **恢复 + 演练**：数据库 dump 是 `-Fc` 格式，恢复要用 `pg_restore`（见上面「整机迁移」恢复步骤 5–6：先 `DROP SCHEMA` + 重建 extensions，再 `pg_restore`），**不要**用 `psql < xxx.sql`（那是 plain SQL 的恢复法，对 `.dump` 不适用）。新机器上先把 `teslamate-compose-SECRET.yml` 改回 `docker-compose.yml`（密钥就齐了）再恢复数据库。强烈建议做完第一次备份后**立刻演练一次恢复到测试库**——没验证过能恢复的备份，不算备份。

---

### 🟡 进阶：把数据从 Docker 命名卷迁到 NAS 共享文件夹（bind mount）

**适用场景：** 群晖 / 威联通用户想把 Postgres 数据库 / Grafana 数据放到能直接通过 NAS 文件浏览器看见的路径，方便用 Hyper Backup / Snapshot Replication 备份。

> ⚠️ **这是有损操作（涉及停服 + 文件搬运），新装直接用 bind mount 比迁移简单**。已经在跑的用户，**先做完整数据库备份再开始**（见上节「定期自动备份数据库」）。

**步骤：**

1. **停服 + 整库备份留底（保险）**
   ```bash
   cd ~/teslamate-chinese
   docker exec teslamate-database-1 pg_dump -U teslamate teslamate > /volume1/backup/teslamate-pre-bindmount.dump
   docker compose down
   ```

2. **从命名卷拷数据到目标路径**

   先找到命名卷的实际宿主路径：
   ```bash
   docker volume inspect teslamate_teslamate-db | grep Mountpoint
   # 输出类似 /var/lib/docker/volumes/teslamate_teslamate-db/_data
   ```

   建好目标目录并拷过去（保留属主 / 权限，**这一步必须 sudo**）：
   ```bash
   sudo mkdir -p /volume1/docker/teslamate/data/{db,grafana,mosquitto-conf,mosquitto-data}
   sudo cp -a /var/lib/docker/volumes/teslamate_teslamate-db/_data/. /volume1/docker/teslamate/data/db/
   sudo cp -a /var/lib/docker/volumes/teslamate_teslamate-grafana-data/_data/. /volume1/docker/teslamate/data/grafana/
   sudo cp -a /var/lib/docker/volumes/teslamate_mosquitto-conf/_data/. /volume1/docker/teslamate/data/mosquitto-conf/
   sudo cp -a /var/lib/docker/volumes/teslamate_mosquitto-data/_data/. /volume1/docker/teslamate/data/mosquitto-data/
   ```

3. **改 docker-compose.yml**

   把 `database` / `grafana` / `mosquitto` 三个服务的 `volumes:` 段改成 bind mount：
   ```yaml
   database:
     volumes:
       - /volume1/docker/teslamate/data/db:/var/lib/postgresql

   grafana:
     volumes:
       - /volume1/docker/teslamate/data/grafana:/var/lib/grafana

   mosquitto:
     volumes:
       - /volume1/docker/teslamate/data/mosquitto-conf:/mosquitto/config
       - /volume1/docker/teslamate/data/mosquitto-data:/mosquitto/data
   ```

   把文件最底部 `volumes:` 段（声明 4 个命名卷的部分）整段删除（已经不用了）。

4. **修权限**（关键，permission 错容器起来报错）：
   ```bash
   # 999 = postgres 官方镜像内置的 postgres 用户 uid（固定值，不能改）
   sudo chown -R 999:999 /volume1/docker/teslamate/data/db
   # 472 = Grafana 官方镜像内置的 grafana 用户 uid（固定值，不能改）
   sudo chown -R 472:472 /volume1/docker/teslamate/data/grafana
   # 1883 = eclipse-mosquitto 镜像内置的 mosquitto 用户 uid（固定值，不能改）
   sudo chown -R 1883:1883 /volume1/docker/teslamate/data/mosquitto-conf /volume1/docker/teslamate/data/mosquitto-data
   ```

   > 这三个 uid 来自各官方镜像 Dockerfile 里硬编码的 `USER` 指令，不是任意数。`docker exec teslamate-database-1 id` 验证 = `uid=999(postgres)`。

5. **启动 + 验证**：
   ```bash
   docker compose up -d
   docker compose logs -f database | grep -i "ready\|error"
   ```

   看到 `database system is ready to accept connections` 即成功。打开 TeslaMate 主页验证数据完整。

6. **确认无问题后删旧命名卷**（可选，省宿主磁盘空间）：
   ```bash
   docker volume rm teslamate_teslamate-db teslamate_teslamate-grafana-data \
                    teslamate_mosquitto-conf teslamate_mosquitto-data
   ```

> ⚠️ **任一步骤出错**：恢复方案 = `docker compose down` → 把 docker-compose.yml volumes 段改回命名卷 → `docker compose up -d` → `docker exec -i teslamate-database-1 psql -U teslamate -d teslamate < /volume1/backup/teslamate-pre-bindmount.dump`。所以第 1 步的备份必须先做。

---

## 🔧 完整重置

### 重置（保留数据）

```bash
cd ~/teslamate-chinese
docker compose down          # 停止并删除容器
docker compose up -d         # 重新创建并启动
```

数据保存在 Docker 命名卷中，`down` 命令不会删除数据。

### 完全重置（清除所有数据）

> ⚠️ **不可恢复！** 执行前请先备份数据库！

```bash
cd ~/teslamate-chinese
docker compose down -v       # 停止并删除容器和卷（数据会丢失！）
docker compose up -d         # 重新开始
```

---

## 📋 常见错误日志对照

| 错误信息 | 含义 | 解决方法 |
|----------|------|----------|
| `could not connect to server: Connection refused` | 数据库未就绪 | 等待 30 秒，重启 TeslaMate |
| `FATAL: password authentication failed` | 数据库密码错误 | 检查 DATABASE_PASS 和 POSTGRES_PASSWORD 是否一致 |
| `crypto: AES.decrypt: Data is not valid` | 加密密钥不匹配 | 不能更改 ENCRYPTION_KEY，需重新授权 |
| `connection refused (os error 111)` | MQTT 连接失败 | 检查 mosquitto 容器状态 |
| `invalid character '<' looking for beginning of value` | API 返回 HTML 错误页 | Tesla API 暂时不可用，等待重试 |
| `Exit 1` / `Exit 137` | 内存不足 | 增加服务器内存或关闭其他程序 |
| `no space left on device` | 磁盘满了 | 清理磁盘空间 |

---

## 💬 还是解决不了？

1. 源码目录先运行 `bash scripts/diagnose.sh`；一键安装目录没有该文件时，按 [AI 安全排障提示](docs/ai-troubleshooting-prompt.md) 从同版本 Grafana 镜像取出。也可按症状收集不超过三项最小只读证据。
2. 提交 Issue：https://github.com/wjsall/teslamate-chinese-dashboards/issues
3. 提供脱敏后的症状、实际操作、相关服务的日志片段和 AI 结论（如有）；不要上传完整 `.env`、密钥、Token、VIN、地址或精确 GPS。

<a id="sql-trust-model"></a>

## 🔒 SQL 远程拉取的信任模型

升级路径中的所有「SQL 安装文件」（`install-coord-functions` / `install-unit-functions` / `install-tou` / `install-indexes`）、`scripts/backup.sh` 和 `config/versions.env` 都是从 GitHub 拉到本地用 `psql`/`bash` 执行。这是**典型的 `curl | bash` 信任模型**：

- ✅ **传输安全**：HTTPS + GitHub 证书，中间人无法篡改
- ⚠️ **来源信任**：你信任 `wjsall/teslamate-chinese-dashboards` 仓库的内容
- ⚠️ **维护者风险**：若维护者 GitHub 账号被盗，攻击者可推恶意 SQL → 下次升级拉到恶意脚本 → psql 执行 → **数据库层任意代码执行**

### 脚本还会下载并执行「另一份自己」

除了上面那些 SQL / 配套文件，`simple-deploy.sh` 和 `migrate-from-official.sh` 在开跑早期还会**下载并 `exec` 一份同名脚本**，这一点值得单独说清楚，因为它执行的是 bash 而不只是 SQL：

- **拉的是什么**：`https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/<版本号>/simple-deploy.sh`（迁移脚本同理，取 `migrate-from-official.sh`），版本号就是上面解析出的正式版 tag。
- **为什么**：README 给的命令是 `curl .../main/simple-deploy.sh | bash`，脚本本体来自 `main`。也就是说 SQL、配套脚本、镜像都锁到了正式版，唯独**安装逻辑本身**是未发布代码——推上 `main` 那一刻就对所有新用户生效。换成正式版 tag 下的同名脚本继续执行，整套安装才真的来自同一次发布。
- **信任边界没有变大**：拉的是同一个仓库、同一个 HTTPS 来源，只是把 ref 从 `main` 收紧到某个正式 tag（比 `main` 更严，不是更松）。
- **三个安全阀**：环境变量 `TESLAMATE_CN_PINNED` 防止无限接力；`TARGET_REF=main`（你主动选滚动通道）时不做这一步；下载失败时**打印提示并继续用当前这份脚本**，不会因为网络问题装不了。
- **想先审再跑**：把脚本下到本地看过之后，用 `TESLAMATE_CN_PINNED=1 bash simple-deploy.sh` 运行——这个变量就是上面那个"防接力"的阀门，脚本会认为自己已经是选定的那一份，直接跑你看过的代码，不再去下载。（不加这个变量的话，即使脚本已经在本地，它仍会去拉目标 tag 下的同名脚本，跑的是刚下载的那一份。）

### `TARGET_REF`：统一推导「这次装的镜像」和「这次装的 SQL」

`simple-deploy.sh` / `migrate-from-official.sh` 内部有一个 `TARGET_REF` 开关，统一决定「这次装的 SQL / 配套脚本版本」，并据此推导镜像 tag，避免出现「正式版镜像 + main 分支未发布 SQL」的混搭。三条通道：

| 通道 | 怎么用 | 行为 |
|---|---|---|
| **正式版（默认）** | 不传任何变量 | 脚本自动查 GitHub 最新 Release 拿到具体版本号（如 `v1.8.4`），SQL / `scripts/backup.sh` / `config/versions.env` 都从这个版本号对应的 tag 拉取；镜像 tag 写 `latest`（Docker Hub / GHCR 的 `latest` 只在打正式 tag 时更新，语义上就是"当前最新正式版"，且是可变 tag，此后 `docker compose pull` 会持续跟着新版本走，不会像钉死数字 tag 那样永久停在安装当次的版本） |
| **指定版本** | `TARGET_REF=v1.8.4 bash simple-deploy.sh` | 镜像和 SQL 都锁定到这个具体版本号（镜像 tag 如 `:1.8.4`），不管当前最新版是什么，也不会跟着未来的 `docker compose pull` 自动升级 |
| **滚动 main** | `TARGET_REF=main bash simple-deploy.sh` | 镜像和 SQL 都跟 main 分支最新构建（CI 每次 push main 都会构建一个 `:main` tag 镜像，拿最新 bug 修复最快，但未必经过完整发版验证） |

**优先级**：单独设置 `SQL_REF` / `REPO_REF` / `GRAFANA_IMAGE` / `NEW_IMAGE` 这些具体变量，会覆盖 `TARGET_REF` 的推导结果——高级用户想让 SQL 和镜像分开锁定（例如镜像用某个 commit sha 构建的 GHCR tag、SQL 锁某个 commit SHA）时用这条路。不单独设置时，两者都跟着 `TARGET_REF` 走。

```bash
# 默认：自动解析最新正式 Release，镜像与 SQL 同版本
bash simple-deploy.sh

# 锁定到指定正式版
TARGET_REF=v1.8.4 bash simple-deploy.sh

# 滚动 main 通道（想抢先用某个未发布修复）
TARGET_REF=main bash simple-deploy.sh

# 高级：单独覆盖某个具体变量（优先级最高）
SQL_REF=v1.6.2 GRAFANA_IMAGE=bswlhbhmt816/teslamate-chinese-dashboards:1.6.2 bash simple-deploy.sh
REPO_REF=v1.6.2 NEW_IMAGE=bswlhbhmt816/teslamate-chinese-dashboards:1.6.2 bash migrate-from-official.sh
```

**解析不出版本号时会怎样**：脚本用两条路查「最新正式 Release」——先走未认证 GitHub API（限速 60 次/小时/IP，NAS、公司共享出口 IP 容易触发），API 没结果时再走 `github.com/.../releases/latest` 的网页重定向（不吃 API 限流，限流场景下通常还通）。

两条都没查出版本号（GitHub 整体访问不了、代理拦截、仓库暂无 Release）时，**脚本报错退出，不会自动改用 `main` 分支继续装**。早期版本会在这里回退到 `main` 拉 SQL、镜像仍用 `latest`，结果正是这套机制要消灭的混搭：正式版镜像配未发布的 SQL，而这个组合没有被任何测试跑过。宁可让你多打一个参数，也不装一套没人验证过的组合。

撞上这个报错时：如果是限流，等一会儿重试通常就好；如果是访问不了 GitHub，等多久都没用，直接指定版本号重跑（版本号可以从任意能打开 [Releases 页面](https://github.com/wjsall/teslamate-chinese-dashboards/releases) 的设备上抄）：

```bash
TARGET_REF=v1.9.1 bash simple-deploy.sh
```

显式传 `TARGET_REF`（具体版本号或 `main`）本来就会跳过这次解析，不发这个网络请求。

`git clone` 用户的 `scripts/upgrade.sh` 不用 `TARGET_REF`——它跑在本地 checkout 里，SQL 直接读本地文件（`git pull` 之后就是最新代码，没有远程 ref 的问题）；唯一的默认值是 `PROJECT_IMAGE`（仅用于插件修复兜底命令的提示文本），会按本地 `git describe --tags --exact-match` 自动判断：checkout 正好在某个正式版 tag 上就对应那个数字 tag，否则（本地在 main 分支上，领先于最新正式版）对应 `:main`。

### 想强化安全的用户：锁固定版本

```bash
# 原（默认，自动解析最新正式 Release）
curl -fsSL "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/v1.8.4/sql/install-tou.sql" | ...

# 锁死到某个具体版本（有安全洁癖的用户，不随发版自动变化）
curl -fsSL "https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/v1.6.2/sql/install-tou.sql" | ...
```

或者跑 `simple-deploy.sh` / `migrate-from-official.sh` 时传 `TARGET_REF`（见上表）。锁版本后**升级到新功能需要手动改 ref 数字**（不会自动升）。这是**安全 vs 便利的 trade-off**，按你需求选。

### 为什么默认不是固定版本号

- 大部分用户希望"重跑脚本就能拿到最新正式版"，固定 ref 反而要求每次发版都记得改文档/命令里的版本号——这正是我们要避免的模式（发版了但常用入口没跟着更新）
- 默认解析「最新 Release」而不是「main 滚动分支」：稳定安装拿到的永远是**经过完整发版验证**的版本，而不是刚合并、可能还没跑完冒烟测试的 main 分支内容
- 想要「重跑就拿最新未发布修复」的用户，显式传 `TARGET_REF=main` 即可，不作为默认行为
- 维护者账号被盗概率低（GitHub 2FA），破坏面广（所有用户）—— **这条主要靠 GitHub 账号防御 + 你愿意时锁版本**
- 仓库公开，每条 SQL commit 都可审计，社区和我（维护者）第一时间能看到异常 push

### 取舍：锁定正式版之后，脚本 hotfix 不再是「push 即生效」

在引入 `TARGET_REF` 之前，`simple-deploy.sh` / `migrate-from-official.sh` 默认都是从 `main` 拉取 SQL，纯脚本层面的 bug 修复只要 push 到 main 就对所有新用户立刻生效，不需要走发版流程。锁定到「最新正式 Release」之后，**默认通道的用户只有在下一次正式发版（打 tag）后才能拿到脚本 / SQL 层面的修复**——这是为了换取"镜像和 SQL 永远来自同一次经过验证的提交"这个更重要的一致性保证，但确实牺牲了 hotfix 的即时性。

补偿路径：
- **脚本 / SQL 的紧急修复走 patch 版发布**（`vX.Y.(Z+1)`），不再等到攒够功能才发版；小版本号 bump 的成本本来就很低。
- **想抢先拿到还没发版的修复**，显式传 `TARGET_REF=main`（滚动通道），代价是失去"镜像与 SQL 严格对齐"的保证——这也是为什么滚动通道不作为默认。
- 这条取舍只影响**远程拉取路径**（一键脚本 / 迁移脚本）；`git clone` 用户跑 `scripts/upgrade.sh` 永远拿到的是 `git pull` 之后的本地最新代码，不受这个限制。

### Cloudflare 镜像（避免直连 GitHub raw）

国内访问 `raw.githubusercontent.com` 偶尔不稳，可以替换成镜像。**注意信任边界**：

- **`ghproxy.com` 等第三方镜像** ⚠️ — 镜像运营方能改返回内容（实际是新加一个 MITM 信任点），仅在你信任该镜像方时使用
- **自建 Cloudflare Worker 转发 raw 内容** ✅ — 你完全控制 Worker 源码 → 等价直连
