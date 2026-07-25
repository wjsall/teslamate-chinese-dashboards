#!/bin/sh
# entrypoint 包装脚本：把用户遗留在 grafana volume 里的插件软链到新插件目录，保持向后兼容
#
# 背景：GF_PATHS_PLUGINS 从 /var/lib/grafana/plugins（teslamate-grafana-data volume 挂载点
# 内部）挪到 /opt/grafana-plugins（volume 外），避免已存在的旧卷（如从官方 teslamate/grafana
# 迁移过来的）遮蔽镜像里装好的插件（issue #20/#21）。
#
# 迁移到新路径后，Grafana 不会再扫描旧路径 /var/lib/grafana/plugins，用户自己在旧路径装的
# 插件会"消失"。本脚本在每次容器启动时，把旧卷里用户自装的插件软链进新目录，弥补这一点。
#
# 幂等：重复启动不出错（已存在的软链/目录会跳过）。
# 同名冲突不覆盖镜像自带插件：新目录里已有同名条目（如镜像自带的 volkovlabs-form-panel）时
# 跳过，不用旧卷里的版本覆盖。
USER_DIR=/var/lib/grafana/plugins
NEW_DIR="${GF_PATHS_PLUGINS:-/opt/grafana-plugins}"

if [ -d "$USER_DIR" ]; then
  for d in "$USER_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    if [ -e "$NEW_DIR/$name" ]; then
      continue
    fi
    if ln -sfn "$d" "$NEW_DIR/$name"; then
      echo "docker-entrypoint-wrapper: linked legacy plugin '$name' into $NEW_DIR"
    else
      echo "docker-entrypoint-wrapper: WARNING failed to link plugin '$name' into $NEW_DIR" >&2
    fi
  done
fi

# /run.sh 是上游 teslamate/grafana 镜像提供的原生 entrypoint；这里显式检查一下，
# 万一上游改了路径/去掉了这个文件，容器会给出明确报错而不是静默失败退出
[ -x /run.sh ] || { echo "docker-entrypoint-wrapper: FATAL: /run.sh not found or not executable" >&2; exit 1; }

exec /run.sh "$@"
