#!/usr/bin/env bash
# Run a PowerShell one-liner inside a lab guest through the qemu guest agent.
#   ./bin/exec.sh S2D1 "Get-ClusterNode"
# base64/EncodedCommand avoids every quoting problem between bash, ssh, qm and
# PowerShell.
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"
load_env

LAB_CONF="${LAB:-}"
if [ -z "$LAB_CONF" ]; then
    count=$(find "$KIT_ROOT/labs" -name lab.conf 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" = "1" ] || { echo "set LAB=labs/<name>/lab.conf" >&2; exit 1; }
    LAB_CONF=$(find "$KIT_ROOT/labs" -name lab.conf)
fi
# shellcheck disable=SC1090
. "$LAB_CONF"

TARGET="${1:?usage: exec.sh <VMNAME> <powershell>}"
shift
CMD="$*"
[ -z "$CMD" ] && { echo "usage: exec.sh <VMNAME> <powershell>"; exit 1; }

row=$(echo "$VMS" | awk -F: -v n="$TARGET" '$2==n{print $1":"$3}')
[ -z "$row" ] && { echo "unknown VM: $TARGET"; exit 1; }
vmid=${row%%:*}; node=${row##*:}

B64=$(printf '%s' "$CMD" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
pve_node "$node" "qm guest exec $vmid --timeout 300 -- powershell.exe -NoProfile -EncodedCommand $B64" |
python3 -c "
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    if d.get('out-data'): print(d['out-data'].rstrip())
    if d.get('err-data'): print('ERR:', d['err-data'].rstrip(), file=sys.stderr)
    if d.get('exitcode', 0) not in (0, None): sys.exit(d['exitcode'])
except json.JSONDecodeError:
    print(raw)
"
