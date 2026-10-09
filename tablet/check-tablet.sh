#!/bin/bash
# Pre-show health check for the tablet (edge-cmd) and the laptops it drives.
#   sudo ./tablet/check-tablet.sh
# Exit code is the number of FAILs (0 = ready to demo).
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/demo.env"
[[ $EUID -eq 0 ]] || { echo "run with sudo (needs root's podman images and SSH key)"; exit 1; }

fails=0 warns=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }
get() { curl -s --max-time 3 "$@"; }

section "Network"
if ip -4 addr show dev "$LAN_IFACE" 2>/dev/null | grep -q "inet $TABLET_IP/"; then
    pass "$LAN_IFACE has $TABLET_IP"
else
    fail "$LAN_IFACE does not have $TABLET_IP  (nmcli con up edge-demo; check LAN_IFACE in demo.env)"
fi
if ip link show "$LAN_IFACE" 2>/dev/null | grep -q "state UP"; then
    pass "$LAN_IFACE link is up"
else
    fail "$LAN_IFACE link is down (cable / switch / dongle?)"
fi

section "Services"
for svc in edge-registry edge-tiles edge-command; do
    if systemctl is-active -q "$svc"; then pass "$svc running"
    else fail "$svc not running  (systemctl status $svc)"; fi
done

section "Registry  http://$REGISTRY"
catalog=$(get "http://$REGISTRY/v2/_catalog")
if [[ -z "$catalog" ]]; then
    fail "registry not answering"
else
    for role in c2 isr; do
        if [[ "$catalog" == *"demo/$role"* ]]; then
            ver=$(get -H "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
                    "http://$REGISTRY/v2/demo/$role/manifests/latest" \
                  | python3 -c 'import sys, json; print(json.load(sys.stdin)["config"]["digest"])' 2>/dev/null \
                  | xargs -I{} curl -s --max-time 3 "http://$REGISTRY/v2/demo/$role/blobs/{}" \
                  | python3 -c 'import sys, json; print(json.load(sys.stdin)["config"]["Labels"]["org.opencontainers.image.version"])' 2>/dev/null)
            pass "demo/$role:latest published (v${ver:-?})"
        else
            fail "demo/$role missing  (sudo ./build.sh publish $role 1.0)"
        fi
    done
fi

section "Map tiles"
if [[ -s "$HERE/tiles/$TILESET.mbtiles" ]]; then
    pass "tiles/$TILESET.mbtiles present ($(du -h "$HERE/tiles/$TILESET.mbtiles" | cut -f1))"
else
    fail "tiles/$TILESET.mbtiles missing  (sudo ./build.sh fetch)"
fi
if get "http://$TABLET_IP:8000/services" | grep -q "\"$TILESET\""; then
    pass "ODIN tile server lists '$TILESET'  (http://$TABLET_IP:8000/services)"
else
    fail "ODIN tile server doesn't list '$TILESET'  (systemctl restart edge-tiles)"
fi
code=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "http://$TABLET_IP:8080/tiles/$TILESET/12/720/1621")
[[ "$code" == 200 ]] && pass "ISR tile endpoint serves imagery" || fail "ISR tile endpoint returned $code"

section "Edge Command  http://$TABLET_IP:8080"
state=$(get "http://$TABLET_IP:8080/api/state")
if [[ -n "$state" ]]; then
    pass "dashboard API answering"
    while read -r level msg; do
        [[ $level == PASS ]] && pass "$msg" || warn "$msg"
    done < <(echo "$state" | python3 -c '
import sys, json
s = json.load(sys.stdin)
if s.get("mock"):
    print("WARN dashboard is in MOCK mode")
mode = s["link"]["mode"]
print("PASS data link FULL" if mode == "full" else "WARN data link is " + mode.upper() + " (tap FULL before the show)")
t = s["tracks"]
print("PASS ISR feed live: %s tracks from %s" % (t["count"], t["from"]) if t["count"]
      else "WARN no ISR tracks arriving (no laptop in the ISR role?)")
for n in s["nodes"].values():
    if n["phase"] not in ("online", "busy"):
        print("WARN dashboard shows %s as %s" % (n["name"], n["phase"].upper()))')
else
    fail "dashboard not answering  (systemctl status edge-command)"
fi
if curl -s --max-time 3 "http://$TABLET_IP:8080/live/tracks" | grep -q '^data:'; then
    pass "ODIN live source streaming  (http://$TABLET_IP:8080/live/tracks)"
else
    fail "live track stream not responding"
fi

section "DDIL simulator"
if lsmod | grep -q sch_netem; then pass "netem module loaded"
else fail "netem not loaded  (dnf install kernel-modules-extra && modprobe sch_netem)"; fi
if tc qdisc show dev "$LAN_IFACE" 2>/dev/null | grep -q netem; then
    warn "link shaping is ACTIVE on $LAN_IFACE (tap FULL on the dashboard)"
else
    pass "no link shaping active"
fi

section "Images on the tablet"
for img in edge-base:latest edge-c2:1.0 edge-c2:1.1 edge-isr:1.0 edge-isr:1.1; do
    podman image exists "localhost/$img" && pass "localhost/$img" || fail "localhost/$img missing  (sudo ./build.sh roles)"
done

section "Laptops"
[[ -f "$SSH_KEY" ]] || fail "control key $SSH_KEY missing (re-run setup-tablet.sh)"
for node in $NODES; do
    name=${node%%=*} ip=${node#*=}
    if ! ping -c1 -W1 "$ip" >/dev/null 2>&1; then
        fail "$name ($ip) not reachable"
        continue
    fi
    out=$(ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$ip" \
              'cat /usr/share/edge-demo/role; systemctl get-default; date +%s' 2>/dev/null)
    if [[ -z "$out" ]]; then
        fail "$name ($ip) pings but SSH failed"
        continue
    fi
    { read -r role ver; read -r target; read -r epoch; } <<<"$out"
    pass "$name ($ip) up, role ${role^^} v$ver"
    [[ "$target" == graphical.target ]] || fail "$name boots to $target  (systemctl set-default graphical.target)"
    drift=$(( epoch - $(date +%s) )); drift=${drift#-}
    (( drift < 300 )) || warn "$name clock is off by $((drift / 60)) min"
done

section "Disk"
avail=$(df --output=avail -BG /var/lib/containers 2>/dev/null | tail -1 | tr -dc 0-9)
(( ${avail:-0} >= 10 )) && pass "${avail}G free for containers" || warn "only ${avail:-?}G free under /var/lib/containers"

printf '\n\033[1mResult:\033[0m %d fail, %d warn — %s\n' "$fails" "$warns" \
    "$([[ $fails -eq 0 ]] && echo 'ready to demo' || echo 'fix the FAILs above')"
exit "$fails"
