#!/bin/bash
# Open the demo screens on the host laptop: Edge Command plus one window per
# edge VM. Run as your normal desktop user (not sudo). Viewer windows reconnect
# by themselves while a VM reboots into a new image.
#   ./vm/open-demo.sh                 windowed
#   ./vm/open-demo.sh --full-screen   VM screens full screen (put them on an external monitor)
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/demo.env"
[[ $EUID -ne 0 ]] || { echo "run as your desktop user, not root"; exit 1; }

firefox --new-window "http://localhost:8080" >/dev/null 2>&1 &
for node in $NODES; do
    name=${node%%=*}
    virt-viewer --connect qemu:///system --wait --reconnect \
        --title "${name^^}" "$@" "$name" >/dev/null 2>&1 &
done
echo "Opened Edge Command and: $(for n in $NODES; do printf '%s ' "${n%%=*}"; done)"
