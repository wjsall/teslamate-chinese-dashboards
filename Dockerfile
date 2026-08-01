# 基于 TeslaMate 官方 Grafana 镜像，锁定到具体 digest（多架构 manifest list，
# 含 linux/amd64 + linux/arm/v7 + linux/arm64，2026-07-25 用 registry API 现查确认；
# 见 .github/workflows/ghcr-build.yml 的 base-image-canary job 与 renovate.json）。
# 不再跟随裸 :latest 滚动——同一 commit 重新构建现在能得到确定的构建输入，可审计。
# Grafana 13.0.1 已用我们 45+3 个面板 + volkovlabs-form-panel 6.3.2 实测兼容。
# 升级 digest：base-image-canary 发现上游更新会自动开 issue 指导；也可手动
# `docker manifest inspect teslamate/grafana:latest` 现查后替换下面这一行。
FROM teslamate/grafana:latest@sha256:f2afcd9bdc849e65ef53c765be8590a0f0f8416709f501aa179760ea97035cf8

# 强制中文语言设置（关键！）
ENV GF_USERS_DEFAULT_LANGUAGE=zh-Hans
ENV GF_USERS_DEFAULT_LOCALE=zh-Hans

# 数据库连接默认值（用户未设置时自动生效，兼容方法四只替换镜像的场景）
ENV DATABASE_PORT=5432
ENV DATABASE_SSL_MODE=disable

# 插件目录挪到 grafana volume 外（issue #20/#21 结构性修复）
# 根因：旧版把插件装进 /var/lib/grafana/plugins，而这条路径正好是 simple-deploy.sh 挂载的
# teslamate-grafana-data volume 的挂载点。Docker 只在空卷首次挂载时拷贝镜像内容，已存在的
# 旧卷（如从官方 teslamate/grafana 迁移过来的）会直接遮蔽插件目录，导致「⚡ 分时电价配置」
# 报 panel not found。GF_PATHS_PLUGINS 是普通 ENV，可安全覆盖（已核实上游 teslamate/grafana
# 镜像未特殊处理这个变量）。改到 volume 外的 /opt/grafana-plugins 后插件不会再被卷覆盖；
# docker-entrypoint-wrapper.sh 会在每次启动时把用户旧卷里已装的插件软链回新目录，保持兼容。
ENV GF_PATHS_PLUGINS=/opt/grafana-plugins

# build-time 安装「⚡ 分时电价配置」面板所需插件
# v1.6.3 起改用 build-time grafana cli（不用 ENV）— 详见 v1.6.3 CHANGELOG 和 issue #13
# 第三方依赖：https://github.com/VolkovLabs/volkovlabs-form-panel （Apache 2.0，签名验证）
# chown 472:0 = grafana user (uid 472, root group 0) — 与上游 teslamate/grafana 的 GF_UID/GF_GID 一致，
# 不同于 NAS 仪表盘文件场景的 472:472（CLAUDE.md 第六节）。chmod 777 与上游对
# /var/lib/grafana/plugins 的权限设置对齐，兼容用户在 compose 里自定义 `user: uid:gid`
# 以非 472 身份运行容器的场景（这种场景下 entrypoint 包装脚本创建软链才不会因权限被拒）
USER root
RUN rm -f /etc/grafana/provisioning/datasources/*.yml \
          /etc/grafana/provisioning/datasources/*.yaml \
          /etc/grafana/provisioning/dashboards/*.yml \
          /etc/grafana/provisioning/dashboards/*.yaml \
 && grafana cli --pluginsDir /opt/grafana-plugins plugins install volkovlabs-form-panel 6.3.2 \
 && chown -R 472:0 /opt/grafana-plugins \
 && chmod -R 777 /opt/grafana-plugins

# entrypoint 包装脚本：把用户旧卷（/var/lib/grafana/plugins）里已装的插件软链进新插件目录，
# 保持向后兼容（用户自装插件、老版本镜像升级上来的 volkov 拷贝等）
COPY docker-entrypoint-wrapper.sh /docker-entrypoint-wrapper.sh
RUN chmod +x /docker-entrypoint-wrapper.sh

# 写入唯一的数据源配置 + 覆盖基础镜像 dashboard provisioning（避免 ×2 报错）
COPY grafana/provisioning/datasources/datasource.yml \
     /etc/grafana/provisioning/datasources/datasource.yml
COPY dashboards.yml \
     /etc/grafana/provisioning/dashboards/dashboards.yml
USER grafana

# 复制中文 Dashboard 到 TeslaMate 标准位置
COPY grafana/dashboards/zh-cn/*.json /dashboards/

# 复制 Internal Dashboards（路径必须为 /dashboards_internal/，provisioning 监听此路径）
COPY grafana/dashboards/internal/*.json /dashboards_internal/

# SQL 兼容性契约（issue #23/#29 事故预防机制，详见 config/versions.env 顶部注释）：
# 原样拷贝仓库里的 config/versions.env 进镜像，不是手动抄一遍数字——scripts/diagnose.sh
# 靠这份镜像内文件读到"这个镜像要求装到第几版 SQL"，专为方法 C（手动 docker compose pull）
# 和 Watchtower 用户设计：他们只换镜像不跑任何脚本，diagnose 必须只凭一个跑着的容器就能读到
# required revision。放在这里（USER grafana 之后、EXPOSE 之前）而不是文件靠前位置，原因跟
# 下面 VERSION LABEL 一样：这个文件改动频率高于插件版本、低于 dashboard JSON，放前面会连累
# 上面昂贵的 grafana cli plugins install 层缓存失效。
COPY config/versions.env /opt/teslamate-cn/versions.env

# 一键安装目录没有仓库的 scripts/；把同一份只读诊断入口放进镜像，用户可在
# Grafana service 正在运行时用 docker cp 取出后执行。放在所有插件安装层之后，
# 改诊断脚本不会让昂贵的 grafana cli 插件层失去缓存。
COPY --chmod=0444 scripts/diagnose.sh /opt/teslamate-cn/diagnose.sh

# 暴露端口
EXPOSE 3000

# 覆盖上游 ENTRYPOINT（原为 ["/run.sh"]，CMD 为空）：包装脚本先做插件软链兼容，
# 再 exec /run.sh 接管，原生命令行为不变
ENTRYPOINT ["/docker-entrypoint-wrapper.sh"]

# 标签信息（故意放在文件最末尾，而不是紧跟 FROM）
# 原因：ARG VERSION 的值每次发版都变，Docker 会把它计入"首次使用它的指令"（LABEL version）的
# cache key；一旦这层 cache miss，它之后的所有层也会连带 miss。如果这两行留在文件靠前的位置，
# 会连累上面昂贵的插件安装 RUN（grafana cli plugins install）和 COPY 层，导致每次 tag 发版
# 都重装一遍插件（×2 架构，linux/amd64 + linux/arm64）。挪到最后，VERSION 变化只作废这条
# 极轻的 LABEL 层本身，前面所有层继续命中缓存。
# maintainer/description 是固定值，理论上放哪都不影响缓存，为了避免 LABEL 声明分散在两处，
# 一并挪到这里。
# version 由 CI 通过 --build-arg 注入真实版本号，见 .github/workflows/ghcr-build.yml；
# 本地不传参构建时默认 "dev"，不会假冒成某个已发布的正式版本号。
ARG VERSION=dev
LABEL maintainer="wjsall"
LABEL description="TeslaMate Grafana with Chinese Dashboards"
LABEL version="${VERSION}"
