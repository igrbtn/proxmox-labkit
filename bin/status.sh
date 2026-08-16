#!/usr/bin/env bash
# Show lab progress: Proxmox VM state + in-guest status (via qemu guest agent).
# Reads the VM table from the lab config given as $LAB (default: labs/*/lab.conf
# if there is exactly one).
#   ./bin/status.sh [-w]        -w = watch, refresh every 60 s
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"
load_env
. "$KIT_ROOT/lib/pve.sh"

LAB_CONF="${LAB:-}"
if [ -z "$LAB_CONF" ]; then
    count=$(find "$KIT_ROOT/labs" -name lab.conf 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" = "1" ]; then
        LAB_CONF=$(find "$KIT_ROOT/labs" -name lab.conf)
    else
        echo "set LAB=labs/<name>/lab.conf (found $count lab configs)" >&2
        exit 1
    fi
fi
# shellcheck disable=SC1090
. "$LAB_CONF"

show() {
    echo "$VMS" | while IFS=: read -r vmid name node ip rest; do
        [ -z "${vmid:-}" ] && continue
        line=$(lab_guest_status "$vmid" "$node" "$ip" 2>/dev/null)
        printf '%-6s %-8s %-14s %s\n' "$name" "$node" "$ip" "${line:-unreachable}"
    done
}

if [ "${1:-}" = "-w" ]; then
    while true; do clear; date '+%H:%M:%S'; echo; show; sleep 60; done
else
    show
fi
