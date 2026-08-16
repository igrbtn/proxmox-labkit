#!/usr/bin/env bash
# Build the example lab: DC + three S2D nodes.
#   ./build.sh            # everything
#   ./build.sh DC01 S2D1  # only the named VMs
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
load_env
require_lab_pw
. "$KIT_ROOT/lib/pve.sh"
. "$KIT_ROOT/lib/unattend.sh"
# shellcheck disable=SC1090
. "$HERE/lab.conf"

WANT="${*:-}"
DC_IP=$(echo "$VMS" | awk -F: '$10=="dc"{print $4}')

echo "$VMS" | while IFS=: read -r vmid name node ip ram cores osdisk datadisks storage role; do
    [ -z "${vmid:-}" ] && continue
    if [ -n "$WANT" ] && ! echo " $WANT " | grep -q " $name "; then continue; fi

    echo "=== $name (vmid $vmid) on $node -> $ip"

    # per-VM guest bootstrap: template + CONFIG block filled in here
    tpl="$KIT_ROOT/guest/bootstrap_member.ps1"
    [ "$role" = "dc" ] && tpl="$KIT_ROOT/guest/bootstrap_dc_forest.ps1"
    tmp=$(mktemp -d)
    sed -e "s|__VMTAG__|$name|g" \
        -e "s|__IP__|$ip|g" \
        -e "s|__PREFIX__|$PREFIX|g" \
        -e "s|__GW__|$GATEWAY|g" \
        -e "s|__DNS__|$DC_IP|g" \
        -e "s|__DOMAIN__|$DOMAIN|g" \
        -e "s|__NETBIOS__|$NETBIOS|g" \
        -e "s|__DNS_FORWARD__|$DNS_FORWARD|g" \
        "$tpl" > "$tmp/bootstrap.ps1"

    make_unattend_iso "$name" "$tmp/bootstrap.ps1" "$node" "$WIN_IMAGE"
    rm -rf "$tmp"

    dd_count=0; dd_size=0
    if [ "$datadisks" != "0x0" ]; then
        dd_count=${datadisks%x*}
        dd_size=${datadisks#*x}
    fi
    new_lab_vm "$name" "$vmid" "$node" "$ram" "$cores" "$osdisk" "$storage" \
               "$BRIDGE" "${WIN_ISO:-ws2025-eval.iso}" "$dd_count" "$dd_size"
    start_lab_vm "$vmid" "$node"
    echo "    started (UEFI boot prompt answered)"
done

echo
echo "Watch with: LAB=$HERE/lab.conf $KIT_ROOT/bin/status.sh -w"
echo "Expect DC01|DONE-forest, then S2Dx|DONE-node, then run ./form-cluster.sh"
