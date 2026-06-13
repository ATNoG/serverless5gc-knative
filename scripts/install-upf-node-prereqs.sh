#!/usr/bin/env bash
# Installs host prerequisites for running the free5GC UPF in Kubernetes.
# Run this on every Kubernetes node that may schedule the upf pod.

set -euo pipefail

GTP5G_VERSION="${GTP5G_VERSION:-v0.9.5}"
WORKDIR="${WORKDIR:-/tmp/gtp5g-build}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root, for example: sudo $0" >&2
    exit 1
fi

install_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y build-essential "linux-headers-$(uname -r)" git kmod
        return
    fi

    if command -v pacman >/dev/null 2>&1; then
        pacman -Sy --needed --noconfirm base-devel git kmod
        case "$(uname -r)" in
            *-lts)
                pacman -S --needed --noconfirm linux-lts-headers
                ;;
            *-zen)
                pacman -S --needed --noconfirm linux-zen-headers
                ;;
            *-hardened)
                pacman -S --needed --noconfirm linux-hardened-headers
                ;;
            *)
                pacman -S --needed --noconfirm linux-headers
                ;;
        esac
        return
    fi

    echo "Unsupported package manager. Install git, make, gcc, kmod, and headers for $(uname -r), then rerun." >&2
    exit 1
}

ensure_tun() {
    modprobe tun
    if [ ! -c /dev/net/tun ]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 0666 /dev/net/tun
    fi
    echo "tun device: $(ls -l /dev/net/tun)"
}

install_gtp5g() {
    rm -rf "$WORKDIR"
    git clone -b "$GTP5G_VERSION" --depth 1 https://github.com/free5gc/gtp5g.git "$WORKDIR"
    make -C "$WORKDIR" clean
    make -C "$WORKDIR"
    make -C "$WORKDIR" install
    depmod -a
    modprobe gtp5g
    install -m 0644 /dev/null /etc/modules-load.d/gtp5g.conf
    printf "gtp5g\n" > /etc/modules-load.d/gtp5g.conf
    lsmod | grep '^gtp5g'
}

install_packages
ensure_tun
install_gtp5g

echo "UPF node prerequisites installed."
echo "If the upf pod was already CrashLooping, restart it with:"
echo "  kubectl rollout restart deployment/upf -n default"
