#!/usr/bin/env bash
# Form the S2D cluster once every node reports DONE-node and the DC DONE-forest.
# The script is pushed into the first node through the guest agent; it notices it
# runs as SYSTEM and re-registers itself as a domain-admin scheduled task,
# because creating a cluster needs domain rights the agent does not have.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
load_env
require_lab_pw
. "$KIT_ROOT/lib/pve.sh"
# shellcheck disable=SC1090
. "$HERE/lab.conf"

VMID=$(echo "$VMS" | awk -F: '$10=="node"{print $1; exit}')
NODE=$(echo "$VMS" | awk -F: '$10=="node"{print $3; exit}')
NODE_LIST=$(echo "$VMS" | awk -F: '$10=="node"{printf "%s\047%s\047", sep, $2; sep=","}')
DC_NAME=$(echo "$VMS" | awk -F: '$10=="dc"{print $2}')

tmp=$(mktemp -d)
sed -e "s|__NODES__|$NODE_LIST|g" \
    -e "s|__CLUSTER__|$CLUSTER_NAME|g" \
    -e "s|__CLUSTER_IP__|$CLUSTER_IP|g" \
    -e "s|__DC__|$DC_NAME|g" \
    -e "s|__NETBIOS__|$NETBIOS|g" \
    "$KIT_ROOT/roles/role_s2d_cluster.ps1" > "$tmp/cluster.ps1"
render_secret "$tmp/cluster.ps1"
B64=$(base64 < "$tmp/cluster.ps1" | tr -d '\n')
rm -rf "$tmp"

echo "Pushing cluster script into VM $VMID on $NODE ..."
pve_node "$NODE" "qm guest exec $VMID --timeout 120 -- powershell.exe -NoProfile -Command 'New-Item -ItemType Directory -Force -Path C:\\\\Lab | Out-Null; [IO.File]::WriteAllBytes(\\\"C:\\\\Lab\\\\cluster.ps1\\\", [Convert]::FromBase64String(\\\"$B64\\\"))'" >/dev/null

echo "Starting cluster build ..."
pve_node "$NODE" "qm guest exec $VMID --timeout 120 -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\\\Lab\\\\cluster.ps1" >/dev/null

echo "Started. Watch: LAB=$HERE/lab.conf $KIT_ROOT/bin/status.sh -w  (expect CLUSTER|DONE-cluster)"
