#!/usr/bin/env bash
# Full unattended deployment of a lab: destroy -> build -> wait for the domain ->
# wait for the members -> post steps (cluster, roles) -> verify -> statistics.
#
#   LAB=labs/example-ad-s2d/lab.conf ./bin/deploy-all.sh
#   LAB=... ./bin/deploy-all.sh --keep     # skip the destroy phase
#
# Every wait is bounded, every phase is logged: the run either finishes or says
# which phase timed out. Progress goes to $LAB_LOG (default /tmp/labkit.log) as
# well as stdout, because a backgrounded run buffers stdout until it exits.
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"
load_env
require_lab_pw
. "$KIT_ROOT/lib/pve.sh"

LAB_CONF="${LAB:-}"
if [ -z "$LAB_CONF" ]; then
    count=$(find "$KIT_ROOT/labs" -name lab.conf 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" = "1" ] || { echo "set LAB=labs/<name>/lab.conf" >&2; exit 1; }
    LAB_CONF=$(find "$KIT_ROOT/labs" -name lab.conf)
fi
# shellcheck disable=SC1090
. "$LAB_CONF"
LAB_DIR="$(cd "$(dirname "$LAB_CONF")" && pwd)"

LOG="${LAB_LOG:-/tmp/labkit.log}"
: > "$LOG"
TIMINGS=$(mktemp)
mark() { echo "$1 $(date -u +%s)" >> "$TIMINGS"; }
say()  { echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$LOG"; }

# Capture the status text first, then match it. Piping into `grep -q` under
# `set -o pipefail` is a trap: grep exits on the first match, the status script
# dies of SIGPIPE, and the predicate reports failure even though the string was
# there - the wait then runs to its timeout against an already finished phase.
lab_status()   { "$KIT_ROOT/bin/status.sh" 2>/dev/null; }
has_forest()   { local s; s=$(lab_status); case "$s" in *DONE-forest*) return 0;; *) return 1;; esac; }
members_ready() { local s n; s=$(lab_status); n=$(printf '%s\n' "$s" | grep -c 'DONE-node'); [ "$n" -ge "${EXPECT_NODES:-1}" ]; }
cluster_done() { local s; s=$(lab_status); case "$s" in *DONE-cluster*) return 0;; *) return 1;; esac; }

wait_for() {
    local label="$1" maxmin="$2"; shift 2
    local deadline=$(( $(date -u +%s) + maxmin * 60 ))
    while [ "$(date -u +%s)" -lt "$deadline" ]; do
        if "$@"; then return 0; fi
        sleep 30
    done
    say "TIMEOUT waiting for $label after ${maxmin}m"
    return 1
}

EXPECT_NODES=$(printf '%s\n' "$VMS" | awk -F: '$10=="node"' | grep -c .)

mark START
say "=== phase 0: destroy"
if [ "${1:-}" != "--keep" ]; then
    printf '%s\n' "$VMS" | while IFS=: read -r vmid name node ip rest; do
        [ -z "${vmid:-}" ] && continue
        pve_node "$node" "qm stop $vmid >/dev/null 2>&1; sleep 2; qm destroy $vmid --purge 1 >/dev/null 2>&1; rm -f /var/lib/vz/template/iso/unattend-$name.iso" >/dev/null 2>&1
        say "    $name destroyed"
    done
fi
mark DESTROYED

say "=== phase 1: create and start VMs"
"$LAB_DIR/build.sh" >>"$LOG" 2>&1
mark VMS_CREATED

say "=== phase 2: waiting for the domain (Windows install + promo)"
wait_for "forest" 45 has_forest || exit 1
mark FOREST_READY
say "domain is up"

if [ "$EXPECT_NODES" -gt 0 ]; then
    say "=== phase 3: waiting for $EXPECT_NODES member(s) to join"
    wait_for "members" 40 members_ready || exit 1
    mark MEMBERS_READY
    say "members joined"
fi

if [ -x "$LAB_DIR/form-cluster.sh" ]; then
    say "=== phase 4: forming the cluster"
    # members report DONE the moment the join verifies, but a reboot can still
    # be in flight, so the first attempt may hit a guest that is not answering
    sleep 60
    for attempt in 1 2 3; do
        say "form-cluster attempt $attempt"
        "$LAB_DIR/form-cluster.sh" >>"$LOG" 2>&1
        sleep 90
        case "$(lab_status)" in *CLUSTER\|*) say "cluster script is running"; break;; esac
        say "no progress yet, retrying"
    done
    wait_for "cluster" 30 cluster_done || exit 1
    mark CLUSTER_DONE
    say "cluster is up"
fi

say "=== phase 5: cleanup (unattend ISOs carry the password)"
printf '%s\n' "$VMS" | while IFS=: read -r vmid name node ip rest; do
    [ -z "${vmid:-}" ] && continue
    pve_node "$node" "qm set $vmid --delete ide0 >/dev/null 2>&1; rm -f /var/lib/vz/template/iso/unattend-$name.iso" >/dev/null 2>&1
done
mark FINISHED

echo
echo "================= PHASE TIMINGS ================="
python3 - "$TIMINGS" <<'PY'
import sys
ts = {k: int(v) for k, v in (l.split() for l in open(sys.argv[1]) if l.strip())}
labels = [('DESTROYED', 'destroy old lab'), ('VMS_CREATED', 'create + start VMs'),
          ('FOREST_READY', 'Windows install + DC promo'), ('MEMBERS_READY', 'members install + join'),
          ('CLUSTER_DONE', 'cluster + storage'), ('FINISHED', 'cleanup')]
prev = ts['START']
print('%-32s %10s %12s' % ('phase', 'duration', 'cumulative'))
print('-' * 56)
for key, label in labels:
    if key not in ts:
        continue
    d, c = ts[key] - prev, ts[key] - ts['START']
    print('%-32s %6d:%02d %9d:%02d' % (label, d // 60, d % 60, c // 60, c % 60))
    prev = ts[key]
tot = prev - ts['START']
print('-' * 56)
print('%-32s %6d:%02d' % ('TOTAL', tot // 60, tot % 60))
PY
