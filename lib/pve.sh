#!/usr/bin/env bash
# Proxmox building blocks: create/start/destroy lab VMs, run things inside them.
# Sourced by lab build scripts after lib/common.sh. ASCII only.

new_lab_vm() {
    # new_lab_vm <name> <vmid> <node> <ram_mb> <cores> <osdisk_gb> <storage>
    #            <bridge> <win_iso> [datadisk_count] [datadisk_gb]
    # UEFI + q35. OS disk on SATA so Windows installs without extra drivers.
    # NIC is e1000 on purpose - WinPE only injects boot-critical drivers, so
    # virtio-net never reaches the installed system and the guest boots with no
    # network at all.
    local name="$1" vmid="$2" node="$3" ram="$4" cores="$5" osdisk="$6" storage="$7"
    local bridge="$8" iso="$9" ddcount="${10:-0}" ddsize="${11:-0}"

    pve_node "$node" "
      qm status $vmid >/dev/null 2>&1 && { qm stop $vmid --skiplock 1 >/dev/null 2>&1 || true; sleep 2; qm destroy $vmid --purge 1 >/dev/null 2>&1 || true; }
      qm create $vmid --name $name --memory $ram --cores $cores --sockets 1 --cpu host \
        --machine q35 --bios ovmf --efidisk0 $storage:1,efitype=4m,pre-enrolled-keys=0 \
        --scsihw virtio-scsi-single --net0 e1000,bridge=$bridge \
        --ostype win11 --agent enabled=1 --tablet 0 --onboot 0
      qm set $vmid --sata0 $storage:$osdisk,cache=writeback
      qm set $vmid --ide2 local:iso/$iso,media=cdrom
      qm set $vmid --ide0 local:iso/unattend-$name.iso,media=cdrom
      qm set $vmid --boot order=ide2\;sata0
    "

    # Data disks (S2D and friends). serial= is REQUIRED and must be unique across
    # the cluster: without it Windows reports an empty SerialNumber, Storage
    # Spaces never exposes the disk as a PhysicalDisk, and the pool stays empty
    # while every health check still reports success.
    if [ "$ddcount" -gt 0 ]; then
        local i
        for i in $(seq 1 "$ddcount"); do
            pve_node "$node" "qm set $vmid --scsi$i $storage:$ddsize,ssd=1,serial=${name}d$i"
        done
    fi
}

start_lab_vm() {
    # start_lab_vm <vmid> <node>
    # Answers the UEFI "Press any key to boot from CD or DVD" prompt: without a
    # keypress the firmware falls through to the empty disk and installation
    # never begins. Only the first seconds are keyed - a later keypress would
    # restart setup from scratch on the next reboot.
    local vmid="$1" node="$2"
    pve_node "$node" "
      qm start $vmid
      for i in \$(seq 1 12); do echo 'sendkey ret' | qm monitor $vmid >/dev/null 2>&1; sleep 1; done
    "
}

lab_guest_status() {
    # lab_guest_status <vmid> <node> [ip] -> "<vmstate> | <guest status>"
    # Falls back to a ping when the agent is silent: a guest that answers on the
    # network is installing or has simply lost its virtio-serial driver, which
    # is very different from a guest that is dead.
    local vmid="$1" node="$2" ip="${3:-}"
    pve_node "$node" "
      st=\$(qm status $vmid 2>/dev/null | awk '{print \$2}')
      gs=\$(qm guest exec $vmid --timeout 8 -- cmd.exe /c type C:\\\\Lab\\\\status.txt 2>/dev/null | sed -n 's/.*\"out-data\" : \"\\(.*\\)\\\\r.*/\\1/p')
      if [ -z \"\$gs\" ]; then
        if [ -n '$ip' ] && ping -c1 -W1 '$ip' >/dev/null 2>&1; then
          gs='(no agent, but answers on the network)'
        else
          gs='(agent silent - installing or booting)'
        fi
      fi
      echo \"\$st | \$gs\"
    "
}

install_guest_role() {
    # install_guest_role <vmid> <node> <local role script> <task name> [key=value ...]
    # Renders a role template, pushes it into the guest through the agent and
    # starts it. Roles that need domain rights re-register themselves as a
    # domain-admin task from inside (the agent runs as SYSTEM, which cannot
    # create clusters or an Enterprise CA).
    local vmid="$1" node="$2" script="$3" task="$4"; shift 4
    local tmp; tmp=$(mktemp -d)
    cp "$script" "$tmp/role.ps1"
    local kv
    for kv in "$@"; do
        # ordinal sed on plain tokens; secrets go through render_secret below
        sed -i.bak "s|__${kv%%=*}__|${kv#*=}|g" "$tmp/role.ps1" && rm -f "$tmp/role.ps1.bak"
    done
    render_secret "$tmp/role.ps1"
    local b64; b64=$(base64 < "$tmp/role.ps1" | tr -d '\n')
    rm -rf "$tmp"

    pve_node "$node" "qm guest exec $vmid --timeout 120 -- powershell.exe -NoProfile -Command 'New-Item -ItemType Directory -Force -Path C:\\\\Lab | Out-Null; [IO.File]::WriteAllBytes(\\\"C:\\\\Lab\\\\$task.ps1\\\", [Convert]::FromBase64String(\\\"$b64\\\"))'" >/dev/null
    pve_node "$node" "qm guest exec $vmid --timeout 120 -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\\\Lab\\\\$task.ps1" >/dev/null
}

lab_screenshot() {
    # lab_screenshot <vmid> <node> [outfile-on-node]
    local vmid="$1" node="$2" out="${3:-/tmp/vm-$1.ppm}"
    pve_node "$node" "echo 'screendump $out' | qm monitor $vmid >/dev/null 2>&1; ls -l $out"
}
