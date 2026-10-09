#!/bin/bash
# Build, publish and package the edge demo images. Run as root on the tablet.
#
#   ./build.sh fetch               download ODIN AppImage + offline map tiles   (online)
#   ./build.sh base                build the shared edge-node OS image          (online: RHEL content)
#   ./build.sh roles               build c2 + isr, versions 1.0 and 1.1
#   ./build.sh publish ROLE VER    make localhost/edge-ROLE:VER the registry's demo/ROLE:latest
#   ./build.sh iso NAME IP         unattended installer ISO for one laptop (output/NAME/)
#   ./build.sh qcow2               VM disk of the C2 image for a dry run
#   ./build.sh all                 fetch + base + roles + publish 1.0 of both
#   ./build.sh reset               put both roles back to 1.0 in the registry (between demo runs)
set -euo pipefail
cd "$(dirname "$0")"
. ./demo.env
[[ $EUID -eq 0 ]] || { echo "run as root (bootc-image-builder needs rootful podman storage)"; exit 1; }

say() { printf '\n\033[1;31m==\033[0m %s\n' "$*"; }

fetch() {
    say "ODIN v$ODIN_VERSION AppImage"
    local f="c2/vendor/ODINv2-$ODIN_VERSION.AppImage"
    [[ -s "$f" ]] || curl -fL -o "$f" \
        "https://github.com/syncpoint/ODINv2/releases/download/v$ODIN_VERSION/ODINv2-$ODIN_VERSION.AppImage"
    ls -lh "$f"
    say "offline map tiles -> tiles/$TILESET.mbtiles"
    python3 tools/fetch-tiles.py --out "tiles/$TILESET.mbtiles"
    say "pre-pull build images"
    for img in "$RHEL_BOOTC" "$BIB_IMAGE" registry.access.redhat.com/ubi10/ubi:latest; do podman pull "$img"; done
}

base() {
    [[ -s base/files/usr/ssh/root.keys ]] || { echo "missing base/files/usr/ssh/root.keys -- run tablet/setup-tablet.sh first"; exit 1; }
    say "edge-base (from $RHEL_BOOTC)"
    podman build --pull=never -t localhost/edge-base:latest \
        --build-arg BASE_IMAGE="$RHEL_BOOTC" --build-arg REGISTRY="$REGISTRY" base/
}

roles() {
    for v in 1.0 1.1; do
        say "c2:$v"
        podman build -t "localhost/edge-c2:$v" \
            --build-arg VERSION="$v" --build-arg TABLET_IP="$TABLET_IP" --build-arg ODIN_VERSION="$ODIN_VERSION" c2/
    done
    say "isr:1.0 (red sweep)"
    podman build -t localhost/edge-isr:1.0 --build-arg VERSION=1.0 --build-arg ACCENT='#ee0000' \
        --build-arg TABLET_IP="$TABLET_IP" --build-arg TILESET="$TILESET" isr/
    say "isr:1.1 (amber sweep)"
    podman build -t localhost/edge-isr:1.1 --build-arg VERSION=1.1 --build-arg ACCENT='#f0b429' \
        --build-arg TABLET_IP="$TABLET_IP" --build-arg TILESET="$TILESET" isr/
    podman images --filter reference='localhost/edge-*'
}

publish() {
    local role=$1 ver=$2 ref="$REGISTRY/demo/$1:latest"
    say "publish edge-$role:$ver -> $ref"
    podman tag "localhost/edge-$role:$ver" "$ref"
    podman push --tls-verify=false "$ref"
}

iso() {
    local name=${1:?name} ip=${2:?ip}
    local pw=${ADMIN_PW:-}
    if [[ -z "$pw" ]]; then read -rsp "console password for user 'admin' on $name: " pw; echo; fi
    local out="output/$name"
    mkdir -p "$out"
    sed -e "s/@HOST@/$name/" -e "s/@IP@/$ip/" -e "s/@GATEWAY@/$TABLET_IP/" \
        -e "s/@NETMASK@/255.255.255.0/" -e "s/@ADMIN_PW@/$pw/" iso/config.toml.tmpl > "$out/config.toml"
    chmod 600 "$out/config.toml"
    say "anaconda ISO for $name ($ip) from $REGISTRY/demo/c2:latest"
    podman tag localhost/edge-c2:1.0 "$REGISTRY/demo/c2:latest"
    podman run --rm -it --privileged --pull=never \
        --security-opt label=type:unconfined_t \
        -v "$PWD/$out/config.toml:/config.toml:ro" \
        -v "$PWD/$out:/output" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "$BIB_IMAGE" --type anaconda-iso --rootfs xfs \
        "$REGISTRY/demo/c2:latest"
    rm -f "$out/config.toml"
    ls -lh "$out"/bootiso/*.iso
    echo "write it: dd if=$out/bootiso/install.iso of=/dev/sdX bs=4M status=progress oflag=sync"
}

qcow2() {
    mkdir -p output/vm
    printf '[[customizations.user]]\nname = "admin"\npassword = "%s"\ngroups = ["wheel"]\n' \
        "${ADMIN_PW:-redhat}" > output/vm/config.toml
    podman run --rm -it --privileged --pull=never \
        --security-opt label=type:unconfined_t \
        -v "$PWD/output/vm/config.toml:/config.toml:ro" \
        -v "$PWD/output/vm:/output" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "$BIB_IMAGE" --type qcow2 --rootfs xfs "$REGISTRY/demo/c2:latest"
    ls -lh output/vm/qcow2/
}

case "${1:-}" in
    fetch)   fetch ;;
    base)    base ;;
    roles)   roles ;;
    publish) publish "${2:?role}" "${3:?version}" ;;
    iso)     iso "${2:-}" "${3:-}" ;;
    qcow2)   qcow2 ;;
    reset)   publish c2 1.0; publish isr 1.0 ;;
    all)     fetch; base; roles; publish c2 1.0; publish isr 1.0 ;;
    *)       sed -n '2,13p' "$0"; exit 1 ;;
esac
