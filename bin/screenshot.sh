#!/usr/bin/env bash
# Grab the console of a lab VM and save it locally as PNG.
# Use when a guest is silent: it shows a stuck UEFI prompt, a BSOD or a logon
# screen, which tells you instantly whether setup is running at all.
#   ./bin/screenshot.sh DC01 [out.png]
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"
load_env
. "$KIT_ROOT/lib/pve.sh"

LAB_CONF="${LAB:-}"
if [ -z "$LAB_CONF" ]; then
    count=$(find "$KIT_ROOT/labs" -name lab.conf 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" = "1" ] || { echo "set LAB=labs/<name>/lab.conf" >&2; exit 1; }
    LAB_CONF=$(find "$KIT_ROOT/labs" -name lab.conf)
fi
# shellcheck disable=SC1090
. "$LAB_CONF"

TARGET="${1:?usage: screenshot.sh <VMNAME> [out.png]}"
OUT="${2:-$TARGET.png}"
row=$(echo "$VMS" | awk -F: -v n="$TARGET" '$2==n{print $1":"$3}')
[ -z "$row" ] && { echo "unknown VM: $TARGET"; exit 1; }
vmid=${row%%:*}; node=${row##*:}

tmp=$(mktemp -d)
pve_node "$node" "echo 'screendump /tmp/kit-$vmid.ppm' | qm monitor $vmid >/dev/null 2>&1" >/dev/null
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PVE_SSH" \
    "ssh -n -o StrictHostKeyChecking=no $node 'cat /tmp/kit-$vmid.ppm'" > "$tmp/shot.ppm" 2>/dev/null
pve_node "$node" "rm -f /tmp/kit-$vmid.ppm" >/dev/null 2>&1 || true

if python3 -c "import PIL" 2>/dev/null; then
    python3 -c "
from PIL import Image
im = Image.open('$tmp/shot.ppm')
im.save('$OUT')
print('saved $OUT', im.size)
"
else
    mv "$tmp/shot.ppm" "${OUT%.png}.ppm"
    echo "saved ${OUT%.png}.ppm (install Pillow for PNG conversion)"
fi
rm -rf "$tmp"
