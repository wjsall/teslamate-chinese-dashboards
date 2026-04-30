# 基于 TeslaMate 官方 Grafana 镜像（锁定版本，避免上游变更导致容器崩溃）
FROM teslamate/grafana:latest

# 标签信息
LABEL maintainer="wjsall"
LABEL description="TeslaMate Grafana with Chinese Dashboards"
LABEL version="1.5.0"

# 强制中文语言设置（关键！）
ENV GF_USERS_DEFAULT_LANGUAGE=zh-Hans
ENV GF_USERS_DEFAULT_LOCALE=zh-Hans

# 数据库连接默认值（用户未设置时自动生效，兼容方法四只替换镜像的场景）
ENV DATABASE_PORT=5432
ENV DATABASE_SSL_MODE=disable

# 预装「⚡ 分时电价配置」仪表盘所需插件（v1.5.0 起）
# 用 GF_INSTALL_PLUGINS 让 Grafana 启动时自动装，比 RUN grafana-cli 镜像更小
# pin 主版本号防止上游 breaking change；升级前请先在测试环境验证
# 第三方依赖：https://github.com/VolkovLabs/volkovlabs-form-panel （Apache 2.0，签名验证）
ENV GF_INSTALL_PLUGINS="volkovlabs-form-panel 6.3.2"

# 清除基础镜像自带的所有数据源配置（避免 TeslaMate.yml 等旧文件与新配置同时加载导致 ×2 报错）
# 再写入唯一的数据源配置文件
# 同时覆盖 Dashboard 路径配置（/dashboards 和 /dashboards_internal）
USER root
RUN rm -f /etc/grafana/provisioning/datasources/*.yml \
          /etc/grafana/provisioning/datasources/*.yaml \
          /etc/grafana/provisioning/dashboards/*.yml \
          /etc/grafana/provisioning/dashboards/*.yaml
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
