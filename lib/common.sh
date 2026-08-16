#!/usr/bin/env bash
# ProxMoxLabKit shared helpers: .env loading, ssh wrappers, token substitution.
# Source from every entry point:  . "$(dirname "$0")/../lib/common.sh"
# ASCII only.

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- config -----------------------------------------------------------------

load_env() {
    # An already-exported variable wins; .env only fills the gaps.
    local f="${1:-$KIT_ROOT/.env}"
    if [ -f "$f" ]; then
        set -a
        # shellcheck disable=SC1090
        . "$f"
        set +a
    fi
    : "${PVE_SSH:?PVE_SSH is not set - copy .env.example to .env and fill it in}"
}

require_lab_pw() {
    : "${LAB_PW:?LAB_PW is not set - needed because this script uses the __LAB_PW__ token}"
    # LAB_PW is embedded into single-quoted PowerShell strings and into XML,
    # so refuse the characters that would break out of those contexts.
    case "$LAB_PW" in
        *[\'\"\;\<\>\&\`]*)
            echo "LAB_PW contains a forbidden character (quote, ; < > & backtick)." >&2
            echo "Allowed: letters, digits, @ # % ^ * ( ) - _ + = . ," >&2
            exit 1 ;;
    esac
}

# --- ssh --------------------------------------------------------------------

# -n is mandatory: without it ssh eats the stdin of "while read" loops over the
# VM list and only the first machine is ever processed.
SSH_OPTS="-n -o BatchMode=yes -o StrictHostKeyChecking=no"

pve() {
    # run a command on the Proxmox entry node
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$PVE_SSH" "$@"
}

pve_node() {
    # run a command on a specific cluster node, hopping through the entry node
    local node="$1"; shift
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$PVE_SSH" "ssh -n -o StrictHostKeyChecking=no $node \"$*\""
}

pve_stdin() {
    # feed a here-doc script to the entry node (no nested quoting headaches)
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PVE_SSH" 'bash -s'
}

# --- secrets ----------------------------------------------------------------

render_secret() {
    # Replace the __LAB_PW__ token in a file, in place, without ever putting the
    # password on a command line. Python does an ordinal replace - sed would
    # mangle passwords containing & or \.
    local file="$1"
    require_lab_pw
    LAB_PW="$LAB_PW" python3 - "$file" <<'PY'
import os, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read().replace('__LAB_PW__', os.environ['LAB_PW'])
open(p, 'w', encoding='utf-8').write(s)
PY
}

render_secret_xml() {
    # same, but XML-escaped (autounattend.xml)
    local file="$1"
    require_lab_pw
    LAB_PW="$LAB_PW" python3 - "$file" <<'PY'
import os, sys, xml.sax.saxutils as x
p = sys.argv[1]
s = open(p, encoding='utf-8').read().replace('__LAB_PW__', x.escape(os.environ['LAB_PW']))
open(p, 'w', encoding='utf-8').write(s)
PY
}
