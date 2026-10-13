#!/bin/bash
# One-time tablet setup (RHEL 10, registered, run as root WHILE ONLINE).
# Installs tools, pins the demo LAN IP, creates the control SSH key, installs
# the registry / tiles / dashboard services, and pre-pulls everything needed offline.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/demo.env"
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

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

if [[ "$LAN_IFACE" == virbr* ]]; then
    echo "== VM mode: libvirt network owns $LAN_IFACE ($TABLET_IP) -- created by vm/create-vms.sh"
else
    echo "== demo LAN on $LAN_IFACE = $TABLET_IP/$LAN_PREFIX"
    nmcli -t -f NAME con show | grep -qx edge-demo || \
        nmcli con add type ethernet ifname "$LAN_IFACE" con-name edge-demo \
            ipv4.method manual ipv4.addresses "$TABLET_IP/$LAN_PREFIX" ipv6.method disabled \
            connection.autoconnect yes
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

echo "== tablet kiosk autostart for the logged-in desktop user"
# VM mode shares the screen with the VM windows (vm/open-demo.sh), so no full-screen kiosk
[[ "$LAN_IFACE" == virbr* ]] && echo "   skipped in VM mode" || for home in /home/*; do
    [[ -d "$home" ]] || continue
    u=$(basename "$home")
    install -D -o "$u" -g "$u" -m 0644 /opt/edge-demo/tablet/edge-command-kiosk.desktop \
        "$home/.config/autostart/edge-command-kiosk.desktop"
done

cat <<MSG

Tablet ready.
  Dashboard : http://$TABLET_IP:8080   (also http://localhost:8080)
  Registry  : http://$REGISTRY/v2/_catalog
  Tiles     : http://$TABLET_IP:8000/services
Next (both as root -- the builds use root's podman storage and login):
  sudo podman login registry.redhat.io
  cd /opt/edge-demo && sudo ./build.sh all
MSG
