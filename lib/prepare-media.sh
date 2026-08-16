#!/usr/bin/env bash
# Download the Windows Server ISO and virtio-win onto the Proxmox nodes, and
# spread them across every node that will run a lab VM (ISO storage is local).
#
#   ./lib/prepare-media.sh                 # all cluster nodes
#   ./lib/prepare-media.sh pve-01 pve-02   # only these
#
# Windows Server 2025 evaluation is used by default (180 days). Override with
# WIN_URL / WIN_ISO in .env if you have your own media.
set -euo pipefail
. "$(dirname "$0")/common.sh"
load_env

WIN_ISO="${WIN_ISO:-ws2025-eval.iso}"
WIN_URL="${WIN_URL:-https://go.microsoft.com/fwlink/?linkid=2293312}"
VIRTIO_ISO="${VIRTIO_ISO:-virtio-win.iso}"
VIRTIO_URL="${VIRTIO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"

NODES="$*"
if [ -z "$NODES" ]; then
    NODES=$(pve "pvesh get /nodes --output-format json" | python3 -c "import sys,json;print(' '.join(n['node'] for n in json.load(sys.stdin)))")
fi
echo "target nodes: $NODES"

echo "Downloading media on the entry node (this takes a while) ..."
pve "
    cd /var/lib/vz/template/iso
    [ -s $WIN_ISO ]    || curl -sL --retry 5 -C - -o $WIN_ISO '$WIN_URL'
    [ -s $VIRTIO_ISO ] || curl -sL --retry 5 -C - -o $VIRTIO_ISO '$VIRTIO_URL'
    ls -lh $WIN_ISO $VIRTIO_ISO | awk '{print \$5, \$9}'
"

for n in $NODES; do
    pve "
        if [ \"\$(hostname)\" != '$n' ]; then
            for f in $WIN_ISO $VIRTIO_ISO; do
                ssh -n -o StrictHostKeyChecking=no $n \"test -s /var/lib/vz/template/iso/\$f\" 2>/dev/null ||
                    scp -q -o StrictHostKeyChecking=no /var/lib/vz/template/iso/\$f $n:/var/lib/vz/template/iso/
            done
        fi
    "
    echo "  $n: media ready"
done

echo
echo "Image names inside install.wim (use one as WIN_IMAGE in the lab config):"
pve "
    mkdir -p /mnt/kit-win
    mountpoint -q /mnt/kit-win || mount -o loop,ro /var/lib/vz/template/iso/$WIN_ISO /mnt/kit-win
    python3 - <<'PY'
import re, os
p = '/mnt/kit-win/sources/install.wim'
sz = os.path.getsize(p)
with open(p, 'rb') as f:
    f.seek(max(0, sz - 8*1024*1024))
    t = f.read().decode('utf-16-le', errors='ignore')
seen = []
for n in re.findall(r'NAME.([A-Za-z0-9 ()\-]{5,60}?)./NAME', t):
    if n not in seen:
        seen.append(n)
for i, n in enumerate(seen, 1):
    print('  %d: %s' % (i, n))
PY
    umount /mnt/kit-win 2>/dev/null || true
"
