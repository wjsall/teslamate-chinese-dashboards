#!/bin/bash
# diagnose.sh 行为回归测试：用 PATH 中的假 docker/curl 构造确定性的部署状态，
# 不启动、不停止、也不修改真实容器。

set -u

SELF_PATH=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
COMMAND_NAME=$(basename "$0")

mock_compose_ps() {
    local include_all=0 svc="" arg
    shift 2 # compose ps
    for arg in "$@"; do
        case "$arg" in
            -a|-aq|-qa|--all) include_all=1 ;;
            -*) ;;
            *) svc="$arg" ;;
        esac
    done

    case "$svc" in
        teslamate) echo cid_tm ;;
        database) echo cid_db ;;
        grafana)
            if [ "${MOCK_SCENARIO}" = "stopped_container" ] && [ "$include_all" -ne 1 ]; then
                return 0
            fi
            echo cid_gf
            ;;
        mosquitto)
            case "${MOCK_SCENARIO}" in
                mqtt_disabled|external_mqtt) ;;
                *) echo cid_mq ;;
            esac
            ;;
    esac
}

mock_inspect() {
    local format="$2" cid="$3"
    case "$format" in
        *State.Status*)
            if [ "$cid" = "cid_gf" ] && [ "${MOCK_SCENARIO}" = "stopped_container" ]; then
                echo exited
            else
                echo running
            fi
            ;;
        *State.StartedAt*) echo '2026-08-01T00:00:00Z' ;;
        *Config.Image*) echo 'ghcr.io/wjsall/teslamate-chinese-dashboards:1.9.5' ;;
        *Config.Labels*) echo '1.9.5' ;;
        *Config.Env*)
            case "$cid" in
                cid_tm)
                    if [ "${MOCK_SCENARIO}" = "custom_database" ]; then
                        echo 'DATABASE_USER=custom_user'
                        echo 'DATABASE_NAME=custom_db'
                    else
                        echo 'DATABASE_USER=teslamate'
                        echo 'DATABASE_NAME=teslamate'
                    fi
                    if [ "${MOCK_SCENARIO}" = "mqtt_disabled" ]; then
                        echo 'DISABLE_MQTT=true'
                    elif [ "${MOCK_SCENARIO}" = "external_mqtt" ]; then
                        echo 'DISABLE_MQTT=false'
                        echo 'MQTT_HOST=mqtt.example'
                    else
                        echo 'DISABLE_MQTT=false'
                        echo 'MQTT_HOST=mosquitto'
                    fi
                    ;;
                cid_db)
                    if [ "${MOCK_SCENARIO}" = "custom_database" ]; then
                        echo 'POSTGRES_USER=custom_user'
                        echo 'POSTGRES_DB=custom_db'
                    else
                        echo 'POSTGRES_USER=teslamate'
                        echo 'POSTGRES_DB=teslamate'
                    fi
                    ;;
                cid_gf) echo 'GF_PATHS_PLUGINS=/opt/grafana-plugins' ;;
            esac
            ;;
    esac
}

mock_db_exec() {
    local joined="$*"
    if [ "${MOCK_SCENARIO}" = "custom_database" ]; then
        case "$joined" in
            *'-U custom_user -d custom_db'*) ;;
            *) return 1 ;;
        esac
    fi

    case "$joined" in
        *'FROM cars'*) echo 1 ;;
        *'FROM drives'*) echo 2 ;;
        *'FROM charging_processes'*) echo 3 ;;
        *'diagnose:coord-contract'*) echo 5 ;;
        *'count(DISTINCT proname)'*) echo 5 ;;
        *'diagnose:unit-contract'*) echo 5 ;;
        *"prosrc LIKE '%kPa%'"*) echo 1 ;;
        *'diagnose:tou-contract'*)
            if [ "${MOCK_SCENARIO}" = "partial_tou" ]; then echo 7; else echo 8; fi
            ;;
        *"relname='tou_rates'"*) echo 1 ;;
        *'count(*) FROM public.tou_rates'*) echo 2 ;;
        *'count(*) FROM tou_rates'*) echo 2 ;;
        *'teslamate_cn_extension_meta'*) echo 12 ;;
        *'SELECT 1'*) return 0 ;;
        *) return 0 ;;
    esac
}

mock_docker_exec() {
    local cid="$1"
    shift
    case "$cid" in
        cid_db) mock_db_exec "$@" ;;
        cid_gf)
            case "$*" in
                *'/opt/teslamate-cn/versions.env'*) echo 'SQL_COMPAT_REVISION=12' ;;
                *'grafana cli'*)
                    echo 'installed plugins:'
                    echo
                    if [ "${MOCK_SCENARIO}" = "plugin_mismatch" ]; then
                        echo 'volkovlabs-form-panel @ 6.2.0'
                    else
                        echo 'volkovlabs-form-panel @ 6.3.2'
                    fi
                    ;;
                *'plugin.json'*)
                    if [ "${MOCK_SCENARIO}" = "plugin_mismatch" ]; then echo 6.2.0; else echo 6.3.2; fi
                    ;;
                *'volkovlabs-form-panel'*) return 0 ;;
                *) return 0 ;;
            esac
            ;;
        cid_tm)
            case "$*" in
                *'nc -z'*)
                    [ "${MOCK_SCENARIO}" != "container_api_blocked" ]
                    ;;
                *) return 0 ;;
            esac
            ;;
        *) return 0 ;;
    esac
}

mock_docker() {
    case "${1:-}" in
        --version) echo 'Docker version 29.4.3, build test' ;;
        info) return 0 ;;
        compose)
            case "${2:-}" in
                version) echo '2.40.0' ;;
                ps) mock_compose_ps "$@" ;;
            esac
            ;;
        ps)
            # Compose service 查找已覆盖测试目标；回退列表保持为空。
            return 0
            ;;
        inspect)
            shift
            mock_inspect "$@"
            ;;
        port)
            case "$2" in
                cid_tm)
                    if [ "${MOCK_SCENARIO}" = "custom_ports" ]; then echo '0.0.0.0:14000'; else echo '0.0.0.0:4000'; fi
                    ;;
                cid_gf)
                    if [ "${MOCK_SCENARIO}" = "custom_ports" ]; then echo '0.0.0.0:13000'; else echo '0.0.0.0:3000'; fi
                    ;;
            esac
            ;;
        exec)
            shift
            mock_docker_exec "$@"
            ;;
        logs)
            case "$*" in
                *cid_gf*)
                    [ "${MOCK_SCENARIO}" = "stopped_container" ] && echo 'grafana stopped reason'
                    ;;
                *cid_tm*) echo 'Fetching vehicle data' ;;
            esac
            ;;
        *) return 0 ;;
    esac
}

mock_curl() {
    # 旧实现会从宿主机探测 Tesla API；container_api_blocked 场景故意让宿主机成功，
    # 证明宿主机成功不能替容器自证。端口探测也返回 HTTP 响应。
    printf '200'
}

case "$COMMAND_NAME" in
    docker) mock_docker "$@"; exit $? ;;
    curl) mock_curl "$@"; exit $? ;;
    lsof|ss|netstat) exit 1 ;;
esac

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
DIAGNOSE="$ROOT_DIR/scripts/diagnose.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/teslamate-diagnose-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"
for name in docker curl lsof ss netstat; do
    ln -s "$SELF_PATH" "$MOCK_BIN/$name"
done

PASS=0
FAIL=0

pass_test() {
    PASS=$((PASS + 1))
    printf '  ✅ %s\n' "$1"
}

fail_test() {
    FAIL=$((FAIL + 1))
    printf '  ❌ %s\n' "$1"
}

run_diagnose() {
    local scenario="$1"
    set +e
    LAST_OUTPUT=$(PATH="$MOCK_BIN:$PATH" MOCK_SCENARIO="$scenario" bash "$DIAGNOSE" --verify 2>&1)
    LAST_CODE=$?
    set -e
}

assert_case() {
    local label="$1" scenario="$2" expected_code="$3" required="$4" forbidden="${5:-}"
    run_diagnose "$scenario"
    if [ "$LAST_CODE" -eq "$expected_code" ] \
       && printf '%s\n' "$LAST_OUTPUT" | grep -Fq -- "$required" \
       && { [ -z "$forbidden" ] || ! printf '%s\n' "$LAST_OUTPUT" | grep -Fq -- "$forbidden"; }; then
        pass_test "$label"
    else
        fail_test "${label}（exit=${LAST_CODE}；期待 ${expected_code}；必须含：${required}；不得含：${forbidden}）"
        if [ "${DIAG_TEST_VERBOSE:-0}" = "1" ]; then
            printf '%s\n' "$LAST_OUTPUT" | sed 's/^/      | /'
        fi
    fi
}

assert_case '关闭 MQTT 不要求 mosquitto 容器' mqtt_disabled 0 'RESULT=HEALTHY' 'mosquitto 容器未找到'
assert_case '外部 MQTT 不要求本地 mosquitto 容器' external_mqtt 0 'MQTT 使用外部 broker（mqtt.example）' 'mosquitto 容器未找到'
assert_case '自定义数据库用户与库名可诊断' custom_database 0 'RESULT=HEALTHY' '数据库无法连接'
assert_case '端口来自容器实际映射' custom_ports 0 'Grafana 监听 :13000' 'Grafana 监听 :3000'
assert_case '停止容器仍能定位并显示日志' stopped_container 1 'grafana stopped reason' 'grafana 容器未找到'
assert_case '容器内 API 不通不能由宿主机成功掩盖' container_api_blocked 1 'REASONS=datasource_unreachable' 'RESULT=HEALTHY'
assert_case '插件版本不符返回 DEGRADED' plugin_mismatch 2 'REASONS=plugin_version_mismatch' 'RESULT=HEALTHY'
assert_case 'TOU 对象不完整返回 DEGRADED' partial_tou 2 'REASONS=sql_object_missing' 'RESULT=HEALTHY'

printf '诊断脚本行为测试：通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
