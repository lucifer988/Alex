#!/usr/bin/env bash
set -euo pipefail

VERSION=1.0.0
PREFIX=${PREFIX:-/usr/local}
ETC_DIR=${ALEX_ETC_DIR:-/etc/alex}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || die '请使用 sudo bash install.sh'

install_deps() {
    local missing=() tool
    for tool in bash jq iperf3 ssh sha256sum flock ip systemctl systemd-run; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    ((${#missing[@]} == 0)) && return 0
    log "安装缺失依赖: ${missing[*]}"
    if command -v apt-get >/dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y jq iperf3 openssh-client util-linux iproute2 coreutils systemd
    elif command -v dnf >/dev/null; then
        dnf install -y jq iperf3 openssh-clients util-linux iproute coreutils systemd
    elif command -v yum >/dev/null; then
        yum install -y jq iperf3 openssh-clients util-linux iproute coreutils systemd
    else
        die '无法识别受支持的 systemd 发行版包管理器，请手工安装 jq、iperf3、openssh-client、util-linux、iproute2、systemd'
    fi

    for tool in bash jq iperf3 ssh sha256sum flock ip systemctl systemd-run; do
        command -v "$tool" >/dev/null 2>&1 || die "依赖安装后仍缺少: $tool"
    done
}

install_deps
install -d -m 0755 "$PREFIX/lib/alex/lib" "$PREFIX/sbin" "$ETC_DIR"
install -m 0644 "$SCRIPT_DIR/lib/alex-core.sh" "$PREFIX/lib/alex/lib/alex-core.sh"
install -m 0700 "$SCRIPT_DIR/alex-node" "$PREFIX/lib/alex/alex-node"
install -m 0755 "$SCRIPT_DIR/alex" "$PREFIX/lib/alex/alex"
ln -sfn "$PREFIX/lib/alex/alex" "$PREFIX/sbin/alex"

log "Alex $VERSION 已安装到 $PREFIX/sbin/alex"
log "下一步：把已核对指纹的服务端主机密钥写入 $ETC_DIR/known_hosts"
log "帮助：alex --help"
