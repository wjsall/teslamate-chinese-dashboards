# 基于 TeslaMate 官方 Grafana 镜像（锁定版本，避免上游变更导致容器崩溃）
FROM teslamate/grafana:latest

# 标签信息
LABEL maintainer="wjsall"
LABEL description="TeslaMate Grafana with Chinese Dashboards"
LABEL version="1.6.6"

# 强制中文语言设置（关键！）
ENV GF_USERS_DEFAULT_LANGUAGE=zh-Hans
ENV GF_USERS_DEFAULT_LOCALE=zh-Hans

# 数据库连接默认值（用户未设置时自动生效，兼容方法四只替换镜像的场景）
ENV DATABASE_PORT=5432
ENV DATABASE_SSL_MODE=disable

# build-time 安装「⚡ 分时电价配置」面板所需插件
# v1.6.3 起改用 build-time grafana cli（不用 ENV）— 详见 v1.6.3 CHANGELOG 和 issue #13
# 第三方依赖：https://github.com/VolkovLabs/volkovlabs-form-panel （Apache 2.0，签名验证）
# chown 472:0 = grafana user (uid 472, root group 0) — 与上游 teslamate/grafana 的 GF_UID/GF_GID 一致，
# 不同于 NAS 仪表盘文件场景的 472:472（CLAUDE.md 第六节）
USER root
RUN rm -f /etc/grafana/provisioning/datasources/*.yml \
          /etc/grafana/provisioning/datasources/*.yaml \
          /etc/grafana/provisioning/dashboards/*.yml \
          /etc/grafana/provisioning/dashboards/*.yaml \
 && grafana cli --pluginsDir /var/lib/grafana/plugins plugins install volkovlabs-form-panel 6.3.2 \
 && chown -R 472:0 /var/lib/grafana/plugins

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

# 暴露端口
EXPOSE 3000
