#!/bin/sh

set -eu

SCRIPT_VERSION="1.0.0"
ROOT="${TCPX_ROOT:-}"
DRY_RUN="${TCPX_DRY_RUN:-0}"
ASSUME_KEYS="${TCPX_ASSUME_KEYS:-0}"
OS_RELEASE_FILE="${TCPX_OS_RELEASE:-${ROOT}/etc/os-release}"
PROC_SYS_ROOT="${TCPX_PROC_SYS_ROOT:-/proc/sys}"
MEMINFO_FILE="${TCPX_MEMINFO:-/proc/meminfo}"
ARCH="${TCPX_ARCH:-$(uname -m)}"
SYSCTL_DIR="${ROOT}/etc/sysctl.d"
SYSCTL_FILE="${SYSCTL_DIR}/99-zz-tcpx-alpine.conf"
MODULES_DIR="${ROOT}/etc/modules-load.d"
MODULES_FILE="${MODULES_DIR}/tcpx-bbr-fq.conf"
STATE_DIR="${ROOT}/var/lib/tcpx-alpine"
STATE_FILE="${STATE_DIR}/original-acceleration.conf"
CONFLICT_STATE="${STATE_DIR}/main-sysctl-conflicts.conf"
MAIN_SYSCTL="${ROOT}/etc/sysctl.conf"

info() {
    printf '[信息] %s\n' "$*"
}

warn() {
    printf '[注意] %s\n' "$*" >&2
}

die() {
    printf '[错误] %s\n' "$*" >&2
    exit 1
}

require_platform() {
    [ -f "${OS_RELEASE_FILE}" ] || die "找不到 ${OS_RELEASE_FILE}"
    # shellcheck disable=SC1090
    . "${OS_RELEASE_FILE}"
    [ "${ID:-}" = "alpine" ] || die "此精简脚本仅支持 Alpine Linux"
    case "${ARCH}" in
        aarch64|arm64) ;;
        *) die "此精简脚本仅支持 Alpine arm64/aarch64，当前架构：${ARCH}" ;;
    esac
}

require_root() {
    if [ "${DRY_RUN}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 或 doas 运行"
    fi
}

sysctl_value() {
    sysctl -n "$1" 2>/dev/null || true
}

remember_original_acceleration() {
    [ "${DRY_RUN}" = "1" ] && return 0
    [ -f "${STATE_FILE}" ] && return 0
    mkdir -p "${STATE_DIR}"
    {
        printf 'net.core.default_qdisc=%s\n' "$(sysctl_value net.core.default_qdisc)"
        printf 'net.ipv4.tcp_congestion_control=%s\n' "$(sysctl_value net.ipv4.tcp_congestion_control)"
    } >"${STATE_FILE}"
}

load_existing_modules() {
    if [ "${DRY_RUN}" = "1" ]; then
        info "演练模式：跳过加载 tcp_bbr、sch_fq"
    else
        command -v modprobe >/dev/null 2>&1 || die "缺少 modprobe，请先运行：apk add kmod"
        modprobe tcp_bbr || die "当前内核不提供 tcp_bbr 模块；脚本不会替换内核"
        modprobe sch_fq || die "当前内核不提供 sch_fq 模块；脚本不会替换内核"
        available="$(sysctl_value net.ipv4.tcp_available_congestion_control)"
        case " ${available} " in
            *" bbr "*) ;;
            *) die "模块加载后仍未发现 BBR；请检查当前 Alpine 内核配置" ;;
        esac
    fi

    mkdir -p "${MODULES_DIR}"
    tmp="${MODULES_FILE}.tmp.$$"
    {
        printf '%s\n' '# Load the modules already shipped by the Alpine kernel.'
        printf '%s\n' 'tcp_bbr'
        printf '%s\n' 'sch_fq'
    } >"${tmp}"
    mv "${tmp}" "${MODULES_FILE}"
}

remove_conflicting_main_settings() {
    [ -f "${MAIN_SYSCTL}" ] || return 0
    if grep -Eq '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control)[[:space:]]*=' "${MAIN_SYSCTL}"; then
        mkdir -p "${STATE_DIR}"
        grep -E '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control)[[:space:]]*=' \
            "${MAIN_SYSCTL}" >"${CONFLICT_STATE}"
        backup="${MAIN_SYSCTL}.tcpx-alpine.bak"
        [ -f "${backup}" ] || cp -p "${MAIN_SYSCTL}" "${backup}"
        tmp="${MAIN_SYSCTL}.tmp.$$"
        sed -E '/^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control)[[:space:]]*=/d' \
            "${MAIN_SYSCTL}" >"${tmp}"
        mv "${tmp}" "${MAIN_SYSCTL}"
        warn "已备份并移除 /etc/sysctl.conf 中冲突的 BBR/FQ 设置"
    fi
}

key_supported() {
    [ "${ASSUME_KEYS}" = "1" ] && return 0
    key_path=$(printf '%s' "$1" | tr . /)
    [ -e "${PROC_SYS_ROOT}/${key_path}" ]
}

append_setting() {
    key=$1
    value=$2
    output=$3
    if key_supported "${key}"; then
        printf '%s = %s\n' "${key}" "${value}" >>"${output}"
    else
        warn "当前内核没有 ${key}，已跳过"
    fi
}

config_has_key() {
    file=$1
    wanted=$2
    awk -F= -v wanted="${wanted}" '
        {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == wanted) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "${file}"
}

detect_resources() {
    mem_kb=$(awk '/^MemTotal:/ {print $2; exit}' "${MEMINFO_FILE}" 2>/dev/null || true)
    [ -n "${mem_kb}" ] || mem_kb=524288
    mem_mb=$((mem_kb / 1024))
    if command -v nproc >/dev/null 2>&1; then
        cpu_count=$(nproc)
    else
        cpu_count=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)
    fi
    [ "${cpu_count:-0}" -gt 0 ] || cpu_count=1

    if [ "${mem_mb}" -ge 8192 ]; then
        socket_max=67108864
        somaxconn=65535
        syn_backlog=65535
    elif [ "${mem_mb}" -ge 2048 ]; then
        socket_max=33554432
        somaxconn=32768
        syn_backlog=32768
    elif [ "${mem_mb}" -ge 1024 ]; then
        socket_max=16777216
        somaxconn=16384
        syn_backlog=16384
    else
        socket_max=8388608
        somaxconn=8192
        syn_backlog=8192
    fi

    netdev_backlog=$((cpu_count * 10000))
    if [ "${netdev_backlog}" -lt 16384 ]; then
        netdev_backlog=16384
    elif [ "${netdev_backlog}" -gt 100000 ]; then
        netdev_backlog=100000
    fi
}

write_sysctl_config() {
    detect_resources
    mkdir -p "${SYSCTL_DIR}"
    tmp="${SYSCTL_FILE}.tmp.$$"
    : >"${tmp}"
    {
        printf '%s\n' '# Alpine arm64 BBR + FQ and conservative network tuning.'
        printf '%s\n' '# Managed by alpine-bbr-fq.sh; no kernel packages are installed.'
    } >>"${tmp}"

    append_setting fs.file-max 524288 "${tmp}"
    append_setting net.core.somaxconn "${somaxconn}" "${tmp}"
    append_setting net.core.netdev_max_backlog "${netdev_backlog}" "${tmp}"
    append_setting net.core.rmem_max "${socket_max}" "${tmp}"
    append_setting net.core.wmem_max "${socket_max}" "${tmp}"
    append_setting net.core.rmem_default 262144 "${tmp}"
    append_setting net.core.wmem_default 262144 "${tmp}"
    append_setting net.ipv4.tcp_rmem "4096 131072 ${socket_max}" "${tmp}"
    append_setting net.ipv4.tcp_wmem "4096 65536 ${socket_max}" "${tmp}"
    append_setting net.ipv4.tcp_mtu_probing 1 "${tmp}"
    append_setting net.ipv4.tcp_slow_start_after_idle 0 "${tmp}"
    append_setting net.ipv4.tcp_max_syn_backlog "${syn_backlog}" "${tmp}"
    append_setting net.ipv4.tcp_syncookies 1 "${tmp}"
    append_setting net.ipv4.tcp_fin_timeout 15 "${tmp}"
    append_setting net.ipv4.tcp_keepalive_time 600 "${tmp}"
    append_setting net.ipv4.tcp_keepalive_intvl 15 "${tmp}"
    append_setting net.ipv4.tcp_keepalive_probes 3 "${tmp}"
    append_setting net.ipv4.tcp_tw_reuse 1 "${tmp}"
    append_setting net.ipv4.ip_local_port_range "1024 65535" "${tmp}"
    append_setting net.ipv4.tcp_fastopen 3 "${tmp}"
    append_setting net.ipv4.tcp_ecn 1 "${tmp}"
    append_setting net.core.default_qdisc fq "${tmp}"
    append_setting net.ipv4.tcp_congestion_control bbr "${tmp}"

    mv "${tmp}" "${SYSCTL_FILE}"
}

apply_settings() {
    require_platform
    require_root
    remember_original_acceleration
    load_existing_modules
    remove_conflicting_main_settings
    write_sysctl_config

    if [ "${DRY_RUN}" = "1" ]; then
        info "演练完成，生成：${SYSCTL_FILE}"
        return 0
    fi

    if ! sysctl -e -p "${SYSCTL_FILE}"; then
        die "应用 sysctl 失败"
    fi
    current_cc="$(sysctl_value net.ipv4.tcp_congestion_control)"
    current_qdisc="$(sysctl_value net.core.default_qdisc)"
    [ "${current_cc}" = "bbr" ] || die "BBR 未生效，当前拥塞控制：${current_cc:-unknown}"
    [ "${current_qdisc}" = "fq" ] || die "FQ 未生效，当前队列算法：${current_qdisc:-unknown}"
    info "Alpine arm64 BBR + FQ 与 sysctl 优化已生效"
}

show_status() {
    require_platform
    printf '架构: %s\n' "${ARCH}"
    printf '可用拥塞控制: %s\n' "$(sysctl_value net.ipv4.tcp_available_congestion_control)"
    printf '当前拥塞控制: %s\n' "$(sysctl_value net.ipv4.tcp_congestion_control)"
    printf '当前队列算法: %s\n' "$(sysctl_value net.core.default_qdisc)"
    if [ -f "${SYSCTL_FILE}" ]; then
        printf '持久化配置: %s\n' "${SYSCTL_FILE}"
    else
        printf '持久化配置: 未安装\n'
    fi
}

remove_settings() {
    require_platform
    require_root
    rm -f "${SYSCTL_FILE}" "${MODULES_FILE}"
    if [ "${DRY_RUN}" != "1" ] && [ -s "${STATE_FILE}" ]; then
        sysctl -e -p "${STATE_FILE}" || true
    fi
    if [ -s "${CONFLICT_STATE}" ]; then
        [ -f "${MAIN_SYSCTL}" ] || : >"${MAIN_SYSCTL}"
        while IFS= read -r saved_line; do
            saved_key=$(printf '%s\n' "${saved_line}" | sed -E 's/[[:space:]]*=.*$//; s/^[[:space:]]*//')
            if ! config_has_key "${MAIN_SYSCTL}" "${saved_key}"; then
                printf '%s\n' "${saved_line}" >>"${MAIN_SYSCTL}"
            fi
        done <"${CONFLICT_STATE}"
    fi
    rm -f "${STATE_FILE}" "${CONFLICT_STATE}"
    info "已移除本脚本管理的持久化配置；其它 sysctl 文件未改动"
}

show_menu() {
    while :; do
        printf '\nAlpine arm64 BBR + FQ/sysctl 精简版 v%s\n' "${SCRIPT_VERSION}"
        printf '1. 应用 BBR + FQ 与网络 sysctl 优化\n'
        printf '2. 查看状态\n'
        printf '3. 移除本脚本配置\n'
        printf '0. 退出\n'
        printf '请选择: '
        read answer || exit 0
        case "${answer}" in
            1) apply_settings ;;
            2) show_status ;;
            3) remove_settings ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac
    done
}

case "${1:-menu}" in
    apply) apply_settings ;;
    status) show_status ;;
    remove) remove_settings ;;
    menu) show_menu ;;
    *) die "用法：$0 [apply|status|remove|menu]" ;;
esac
