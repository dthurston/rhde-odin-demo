#!/bin/bash
# Control-node setup (RHEL 10, registered, run as root WHILE ONLINE).
# Asks whether the edge nodes are physical laptops or VMs on this machine,
# records that in /opt/edge-demo/demo.env, installs tools, pins the demo LAN
# IP, creates the control SSH key, installs the registry / tiles / dashboard
# services, and pre-pulls everything needed offline. Safe to re-run.
#
#   sudo ./tablet/setup-tablet.sh                  ask
#   sudo ./tablet/setup-tablet.sh --physical [NIC] tablet + laptops on a wired LAN
#   sudo ./tablet/setup-tablet.sh --virtual        one laptop + edge VMs (vm/create-vms.sh)
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/demo.env"
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

VM_BRIDGE=virbr-edge
RUNTIME_ENV=/opt/edge-demo/demo.env

# Previous choice (if set up before) is the default
if [[ -f "$RUNTIME_ENV" ]]; then
    LAN_IFACE=$(sed -n 's/^LAN_IFACE=//p' "$RUNTIME_ENV" | tail -1)
fi
current=physical
[[ "$LAN_IFACE" == "$VM_BRIDGE" ]] && current=virtual

wired_nics() {
    nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2 == "ethernet" && $1 !~ /^(veth|vnet|virbr|podman)/'
}

mode=${1:-} nic=${2:-}
case "$mode" in
    --physical) mode=physical ;;
    --virtual)  mode=virtual ;;
    "")
        if [[ -t 0 ]]; then
            echo
            echo "How will the edge nodes run?"
            echo "  1) physical  this machine drives real edge laptops over a wired switch"
            echo "  2) virtual   this machine also runs the edge nodes as VMs"
            read -rp "Choose 1 or 2 [default: $current]: " ans
            case "${ans,,}" in
                1|p|physical) mode=physical ;;
                2|v|virtual)  mode=virtual ;;
                "")           mode=$current ;;
                *) echo "unknown choice: $ans"; exit 1 ;;
            esac
        else
            mode=$current
        fi ;;
    *) sed -n '2,10p' "$0"; exit 1 ;;
esac

if [[ "$mode" == virtual ]]; then
    nic=$VM_BRIDGE
elif [[ -z "$nic" ]]; then
    mapfile -t nics < <(wired_nics)
    (( ${#nics[@]} )) || { echo "no wired ethernet port found -- plug in the USB-ethernet adapter and re-run"; exit 1; }
    default=1
    for i in "${!nics[@]}"; do
        [[ "${nics[$i]%%:*}" == "$LAN_IFACE" ]] && default=$((i + 1))
    done
    if [[ -t 0 ]] && (( ${#nics[@]} > 1 )); then
        echo
        echo "Which wired port is cabled to the demo switch?"
        for i in "${!nics[@]}"; do
            IFS=: read -r dev _ state <<<"${nics[$i]}"
            printf '  %d) %-18s %s\n' $((i + 1)) "$dev" "$state"
        done
        read -rp "Choose [default: $default]: " ans
        ans=${ans:-$default}
        [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#nics[@]} )) || { echo "unknown choice: $ans"; exit 1; }
        default=$ans
    fi
    nic=${nics[$((default - 1))]%%:*}
fi
echo "== mode: $mode, demo LAN interface: $nic"

echo "== packages"
dnf -y install podman skopeo python3 git jq iproute-tc kernel-modules-extra firefox \
              bash-completion openssh-clients
# netem/prio qdiscs used by the DDIL link simulator
modprobe sch_netem && modprobe sch_prio
printf 'sch_netem\nsch_prio\n' > /etc/modules-load.d/edge-demo.conf

echo "== project -> /opt/edge-demo"
if [[ "$HERE" != /opt/edge-demo ]]; then
    mkdir -p /opt/edge-demo
    cp -a "$HERE"/. /opt/edge-demo/
fi

echo "== recording LAN_IFACE=$nic in $RUNTIME_ENV"
sed -i "s|^LAN_IFACE=.*|LAN_IFACE=$nic|" "$RUNTIME_ENV"
. "$RUNTIME_ENV"

if [[ "$mode" == virtual ]]; then
    echo "== virtual mode: libvirt network owns $LAN_IFACE ($TABLET_IP) -- created by vm/create-vms.sh"
    # a wired edge-demo profile from an earlier physical setup would claim the same address
    if nmcli -t -f NAME con show | grep -qx edge-demo; then
        nmcli con down edge-demo &>/dev/null || true
        nmcli con modify edge-demo connection.autoconnect no
    fi
else
    echo "== demo LAN on $LAN_IFACE = $TABLET_IP/$LAN_PREFIX"
    if nmcli -t -f NAME con show | grep -qx edge-demo; then
        nmcli con modify edge-demo connection.interface-name "$LAN_IFACE" connection.autoconnect yes
    else
        nmcli con add type ethernet ifname "$LAN_IFACE" con-name edge-demo \
            ipv4.method manual ipv4.addresses "$TABLET_IP/$LAN_PREFIX" ipv6.method disabled \
            connection.autoconnect yes
    fi
    nmcli con up edge-demo || echo "!! could not bring up $LAN_IFACE yet (cable unplugged?) -- it will autoconnect"
fi

echo "== firewall"
if systemctl is-active -q firewalld; then
    # default zone for the wired LAN; libvirt zone for VMs on the virtual bridge
    for zone in "" libvirt; do
        [[ -z "$zone" ]] || firewall-cmd --get-zones | grep -qw "$zone" || continue
        firewall-cmd --permanent ${zone:+--zone=$zone} --add-port=5000/tcp --add-port=8000/tcp --add-port=8080/tcp
    done
    firewall-cmd --reload
fi

echo "== control SSH key"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
[[ -f "$SSH_KEY" ]] || ssh-keygen -t ed25519 -N "" -C edge-command -f "$SSH_KEY"
install -D -m 0644 "$SSH_KEY.pub" /opt/edge-demo/base/files/usr/ssh/root.keys

echo "== registry trusts (plain HTTP on the isolated LAN)"
printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "$REGISTRY" \
    > /etc/containers/registries.conf.d/50-edge-demo.conf

echo "== services"
mkdir -p /var/lib/edge-registry /opt/edge-demo/tiles
install -m 0644 /opt/edge-demo/tablet/quadlets/*.container /etc/containers/systemd/
install -m 0644 /opt/edge-demo/tablet/edge-command.service /etc/systemd/system/
podman pull docker.io/library/registry:2
podman pull ghcr.io/consbio/mbtileserver:latest
systemctl daemon-reload
systemctl start edge-registry.service edge-tiles.service
systemctl enable --now edge-command.service

echo "== full-screen dashboard at login"
# Virtual mode shares the screen with the VM windows (vm/open-demo.sh), so no kiosk there
for home in /home/*; do
    [[ -d "$home" ]] || continue
    u=$(basename "$home")
    autostart="$home/.config/autostart/edge-command-kiosk.desktop"
    if [[ "$mode" == physical ]]; then
        install -D -o "$u" -g "$u" -m 0644 /opt/edge-demo/tablet/edge-command-kiosk.desktop "$autostart"
    else
        rm -f "$autostart"
    fi
done

cat <<MSG

Control node ready ($mode mode, demo LAN on $LAN_IFACE).
  Dashboard : http://$TABLET_IP:8080   (also http://localhost:8080)
  Registry  : http://$REGISTRY/v2/_catalog
  Tiles     : http://$TABLET_IP:8000/services
Next (as root -- the builds use root's podman storage and login):
  sudo podman login registry.redhat.io
  cd /opt/edge-demo && sudo ./build.sh all
MSG
if [[ "$mode" == virtual ]]; then
    echo "  sudo ./vm/create-vms.sh            # network + edge VMs"
    echo "  ./vm/open-demo.sh                  # as your desktop user, after logging out and back in"
else
    echo "  sudo ./build.sh iso edge-a 10.10.10.11   # one installer USB per laptop"
fi
