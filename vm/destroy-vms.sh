#!/bin/bash
# Remove the edge VMs, their disks and the edge-demo network.
# Images, registry, tiles and output/vm/qcow2/disk.qcow2 are kept.
#   sudo ./vm/destroy-vms.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/demo.env"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
VIRSH=(virsh --connect qemu:///system)

names=$(for n in $NODES; do printf '%s ' "${n%%=*}"; done)
read -rp "Delete VMs ${names}(including their ODIN settings) and the edge-demo network? [y/N] " ok
[[ "$ok" == [yY] ]] || exit 0

for node in $NODES; do
    name=${node%%=*}
    "${VIRSH[@]}" destroy "$name" &>/dev/null || true
    "${VIRSH[@]}" undefine "$name" --nvram &>/dev/null && echo "removed $name" || true
    rm -f "/var/lib/libvirt/images/$name.qcow2"
done
rm -f /var/lib/libvirt/images/edge-base.qcow2
"${VIRSH[@]}" net-destroy edge-demo &>/dev/null || true
"${VIRSH[@]}" net-undefine edge-demo &>/dev/null && echo "removed network edge-demo" || true
