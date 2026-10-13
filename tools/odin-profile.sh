#!/bin/bash
# Golden ODIN profile: configure ODIN once (project, offline map, live ISR
# source, map view, drawn units), capture it, then push it to any edge node.
# Also the quickest way to wipe audience changes between demo runs.
#
#   sudo ./tools/odin-profile.sh capture edge-a     save edge-a's ODIN setup to odin/profile.tgz
#   sudo ./tools/odin-profile.sh apply edge-b       replace edge-b's ODIN setup with the saved one
#   sudo ./tools/odin-profile.sh apply all          ... on every node in demo.env NODES
#
# The node's screen goes blank for ~10 s: GDM is stopped so ODIN closes its
# databases cleanly, then started again (kiosk + ODIN come back by themselves).
# The profile lives in the edgeop home (/var), so it survives image switches.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/demo.env"
[[ $EUID -eq 0 ]] || { echo "run with sudo (needs the control SSH key)"; exit 1; }

PROFILE=$HERE/odin/profile.tgz
SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

usage() { sed -n '2,12p' "$0"; exit 1; }
ip_of() {
    local node
    for node in $NODES; do [[ "${node%%=*}" == "$1" ]] && { echo "${node#*=}"; return; }; done
    echo "unknown node '$1' (demo.env NODES: $NODES)" >&2; exit 1
}

# Shared remote preamble: stop the graphical session so ODIN exits, restart on any exit
QUIESCE='
set -e
trap "systemctl start gdm" EXIT
systemctl stop gdm
for _ in 1 2 3 4 5; do pgrep -u edgeop -f /usr/lib/odin/ >/dev/null || break; sleep 1; done
pkill -KILL -u edgeop -f /usr/lib/odin/ 2>/dev/null || true
cd /var/home/edgeop
mkdir -p .config
cd .config
'

capture() {
    local name=$1 ip
    ip=$(ip_of "$name")
    mkdir -p "$(dirname "$PROFILE")"
    echo "== capturing ODIN profile from $name ($ip)"
    # Caches are rebuilt by ODIN; Singleton* locks name the source host and
    # would make ODIN refuse to start on another node
    "${SSH[@]}" "root@$ip" "$QUIESCE"'
d=$(for n in ODINv2 odin-v2 ODIN; do [ -d "$n" ] && { echo "$n"; break; }; done)
[ -n "$d" ] || { echo "no ODIN profile under /var/home/edgeop/.config (has ODIN run here?): $(ls)" >&2; exit 3; }
echo "   profile dir: ~/.config/$d" >&2
tar czf - --exclude="$d/Singleton*" --exclude="$d/Cache" --exclude="$d/Code Cache" \
    --exclude="$d/GPUCache" --exclude="$d/DawnCache" --exclude="$d/DawnGraphiteCache" \
    --exclude="$d/DawnWebGPUCache" --exclude="$d/Crashpad" "$d"
' > "$PROFILE.tmp" || { rm -f "$PROFILE.tmp"; exit 1; }
    mv "$PROFILE.tmp" "$PROFILE"
    echo "   saved $PROFILE ($(du -h "$PROFILE" | cut -f1))"
    echo "   to keep it in git: copy it into your clone's odin/ folder and commit"
}

apply_one() {
    local name=$1 ip
    ip=$(ip_of "$name")
    echo "== applying ODIN profile to $name ($ip)"
    "${SSH[@]}" "root@$ip" "$QUIESCE"'
cat > /tmp/odin-profile.tgz
d=$(tar tzf /tmp/odin-profile.tgz | head -1 | cut -d/ -f1)
rm -rf "./$d"
tar xzf /tmp/odin-profile.tgz
rm -f /tmp/odin-profile.tgz
chown -R edgeop:edgeop /var/home/edgeop/.config
restorecon -R /var/home/edgeop/.config 2>/dev/null || true
echo "   restored ~/.config/$d" >&2
' < "$PROFILE"
}

case "${1:-}" in
    capture)
        [[ -n "${2:-}" ]] || usage
        capture "$2" ;;
    apply)
        [[ -n "${2:-}" ]] || usage
        [[ -s "$PROFILE" ]] || { echo "no $PROFILE yet -- run: sudo $0 capture <configured-node>"; exit 1; }
        if [[ "$2" == all ]]; then
            for node in $NODES; do apply_one "${node%%=*}"; done
        else
            apply_one "$2"
        fi ;;
    *) usage ;;
esac
