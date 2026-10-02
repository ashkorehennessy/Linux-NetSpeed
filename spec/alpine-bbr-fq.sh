#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

mkdir -p "${tmp_dir}/etc/sysctl.d" "${tmp_dir}/etc/modules-load.d"
cat >"${tmp_dir}/etc/os-release" <<'EOF'
ID=alpine
VERSION_ID=3.24.2
EOF
cat >"${tmp_dir}/etc/sysctl.conf" <<'EOF'
net.core.default_qdisc=pfifo_fast
net.ipv4.tcp_congestion_control=cubic
EOF

TCPX_ROOT="${tmp_dir}" \
TCPX_OS_RELEASE="${tmp_dir}/etc/os-release" \
TCPX_ARCH=aarch64 \
TCPX_DRY_RUN=1 \
TCPX_ASSUME_KEYS=1 \
sh "${repo_dir}/alpine-bbr-fq.sh" apply

config="${tmp_dir}/etc/sysctl.d/99-zz-tcpx-alpine.conf"
modules="${tmp_dir}/etc/modules-load.d/tcpx-bbr-fq.conf"
grep -q '^net.core.default_qdisc = fq$' "${config}"
grep -q '^net.ipv4.tcp_congestion_control = bbr$' "${config}"
grep -q '^tcp_bbr$' "${modules}"
grep -q '^sch_fq$' "${modules}"
if grep -Eq 'tcp_congestion_control|default_qdisc' "${tmp_dir}/etc/sysctl.conf"; then
    printf 'conflicting settings were not removed\n' >&2
    exit 1
fi

TCPX_ROOT="${tmp_dir}" TCPX_OS_RELEASE="${tmp_dir}/etc/os-release" TCPX_ARCH=aarch64 \
    TCPX_DRY_RUN=1 TCPX_ASSUME_KEYS=1 sh "${repo_dir}/alpine-bbr-fq.sh" remove
grep -q '^net.core.default_qdisc=pfifo_fast$' "${tmp_dir}/etc/sysctl.conf"
grep -q '^net.ipv4.tcp_congestion_control=cubic$' "${tmp_dir}/etc/sysctl.conf"
[ ! -e "${config}" ]
[ ! -e "${modules}" ]

if TCPX_ROOT="${tmp_dir}" TCPX_OS_RELEASE="${tmp_dir}/etc/os-release" TCPX_ARCH=x86_64 \
    TCPX_DRY_RUN=1 TCPX_ASSUME_KEYS=1 sh "${repo_dir}/alpine-bbr-fq.sh" apply >/dev/null 2>&1; then
    printf 'unsupported architecture was accepted\n' >&2
    exit 1
fi

printf 'alpine bbr+fq tests passed\n'
