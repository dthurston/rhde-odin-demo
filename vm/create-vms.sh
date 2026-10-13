#!/bin/bash
# Single-laptop mode: this host is the control node (registry, tiles, Edge
# Command) and the edge nodes in demo.env NODES run as KVM virtual machines on
# an isolated libvirt network that reuses the demo LAN addresses.
#
#   sudo ./vm/create-vms.sh              create network + VMs (skips what already exists)
#   sudo ./vm/create-vms.sh --recreate   delete the VMs and start them over from the built disk
#                                        (rm output/vm/qcow2/disk.qcow2 first to rebuild that too)
#
# Prerequisites: demo.env has LAN_IFACE=virbr-edge, tablet/setup-tablet.sh has
# run, and the images are built and published (sudo ./build.sh all).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
. ./demo.env
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

NET=edge-demo
BRIDGE=virbr-edge
VM_RAM=${VM_RAM:-4096}       # MiB per VM; ODIN (Electron) wants ~4 GB
VM_CPUS=${VM_CPUS:-2}
IMGDIR=/var/lib/libvirt/images
BASE_DISK=$IMGDIR/edge-base.qcow2
VIRSH=(virsh --connect qemu:///system)

say()  { printf '\n\033[1;31m==\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*"; }
mac()  { printf '52:54:00:ed:00:%02x' "$1"; }

recreate=0
[[ "${1:-}" == --recreate ]] && recreate=1

[[ "$LAN_IFACE" == "$BRIDGE" ]] || { echo "VM mode needs LAN_IFACE=$BRIDGE in demo.env (now: $LAN_IFACE)"; exit 1; }
[[ "$LAN_PREFIX" == 24 ]] || { echo "the VM network assumes LAN_PREFIX=24"; exit 1; }

say "virtualization packages"
grep -Eq 'vmx|svm' /proc/cpuinfo || warn "CPU virtualization (VT-x/AMD-V) not visible -- enable it in the BIOS"
dnf -y install qemu-kvm libvirt-daemon-kvm libvirt-client virt-install virt-viewer edk2-ovmf
for d in qemu network storage nodedev secret; do systemctl enable --now "virt${d}d.socket"; done
if [[ -n "${SUDO_USER:-}" ]] && ! id -nG "$SUDO_USER" | grep -qw libvirt; then
    usermod -aG libvirt "$SUDO_USER"
    warn "added $SUDO_USER to the libvirt group -- log out and back in before running vm/open-demo.sh"
fi

say "isolated network $NET ($BRIDGE = $TABLET_IP/24, no route out)"
if ! "${VIRSH[@]}" net-info "$NET" &>/dev/null; then
    xml=$(mktemp)
    {
        echo "<network>"
        echo "  <name>$NET</name>"
        echo "  <bridge name='$BRIDGE' stp='on' delay='0'/>"
        echo "  <ip address='$TABLET_IP' netmask='255.255.255.0'>"
        echo "    <dhcp>"
        echo "      <range start='${TABLET_IP%.*}.100' end='${TABLET_IP%.*}.199'/>"
        i=0
        for node in $NODES; do
            i=$((i + 1))
            echo "      <host mac='$(mac $i)' name='${node%%=*}' ip='${node#*=}'/>"
        done
        echo "    </dhcp>"
        echo "  </ip>"
        echo "</network>"
    } > "$xml"
    "${VIRSH[@]}" net-define "$xml"
    rm -f "$xml"
    "${VIRSH[@]}" net-autostart "$NET"
fi
"${VIRSH[@]}" net-info "$NET" | grep -q 'Active:.*yes' || "${VIRSH[@]}" net-start "$NET"

say "firewall (libvirt zone)"
if systemctl is-active -q firewalld; then
    firewall-cmd --permanent --zone=libvirt --add-port=5000/tcp --add-port=8000/tcp --add-port=8080/tcp
    firewall-cmd --reload
fi
modprobe sch_netem && modprobe sch_prio

if (( recreate )); then
    say "removing existing VMs"
    for node in $NODES; do
        name=${node%%=*}
        "${VIRSH[@]}" destroy "$name" &>/dev/null || true
        "${VIRSH[@]}" undefine "$name" --nvram &>/dev/null || true
        rm -f "$IMGDIR/$name.qcow2"
    done
    # Keeps output/vm/qcow2/disk.qcow2 (slow to build); delete it to bake in newer images
    rm -f "$BASE_DISK"
fi

say "edge node disk"
[[ -s output/vm/qcow2/disk.qcow2 ]] || ./build.sh qcow2
if [[ ! -f "$BASE_DISK" ]]; then
    cp --sparse=always output/vm/qcow2/disk.qcow2 "$BASE_DISK"
    chmod 0444 "$BASE_DISK"   # shared read-only backing file; each VM writes to its own overlay
fi

osinfo=linux2022
virt-install --osinfo list 2>/dev/null | grep -qw rhel10.0 && osinfo=rhel10.0

i=0
for node in $NODES; do
    i=$((i + 1))
    name=${node%%=*} ip=${node#*=}
    if "${VIRSH[@]}" dominfo "$name" &>/dev/null; then
        say "$name exists -- leaving it alone (use --recreate to rebuild)"
        "${VIRSH[@]}" start "$name" &>/dev/null || true
        continue
    fi
    say "VM $name ($ip, $(mac $i), ${VM_RAM} MiB, ${VM_CPUS} vCPU)"
    qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_DISK" "$IMGDIR/$name.qcow2"
    virt-install --connect qemu:///system \
        --name "$name" --memory "$VM_RAM" --vcpus "$VM_CPUS" --cpu host-passthrough \
        --osinfo "$osinfo" --import --boot uefi \
        --disk "path=$IMGDIR/$name.qcow2,format=qcow2,bus=virtio" \
        --network "network=$NET,mac=$(mac $i),model=virtio" \
        --graphics vnc,listen=127.0.0.1 --video virtio \
        --rng /dev/urandom --noautoconsole
done

say "waiting for the edge nodes to answer over SSH"
for node in $NODES; do
    name=${node%%=*} ip=${node#*=}
    for _ in $(seq 60); do
        if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$ip" true 2>/dev/null; then
            echo "  $name ($ip) up"
            continue 2
        fi
        sleep 5
    done
    warn "$name ($ip) not answering after 5 min -- open its screen with vm/open-demo.sh to see why"
done

cat <<MSG

Edge VMs ready. Next, as your normal desktop user (not sudo):
  ./vm/open-demo.sh          dashboard + both VM screens
Then do the one-time ODIN setup in each VM (README, "Configure ODIN").
MSG
