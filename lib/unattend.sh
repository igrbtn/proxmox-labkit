#!/usr/bin/env bash
# Build a per-VM unattend ISO: autounattend.xml + guest bootstrap + virtio
# drivers + qemu-guest-agent. Sourced by lab build scripts.
#
# Why one ISO instead of three CDs: q35 has few IDE slots, and everything the
# guest needs at first boot fits in ~25 MB.
# ASCII only.

make_unattend_iso() {
    # $1 vm name, $2 guest bootstrap file (local), $3 target proxmox node,
    # $4 windows image name inside install.wim
    local name="$1" bootstrap="$2" node="$3" image="$4"
    local tmp; tmp=$(mktemp -d)
    # virtio-win driver folders by preference: a driver built for a newer Windows does not
    # load on an older one, so WS2016 sets VIRTIO_OSV="2k16", Windows 11 "w11 2k25"
    local osv_list="${VIRTIO_OSV:-2k25 2k22 w11 2k19}"

    mkdir -p "$tmp/lab"
    cp "$bootstrap" "$tmp/lab/bootstrap.ps1"
    cp "$KIT_ROOT/guest/arm.ps1" "$tmp/lab/arm.ps1"
    render_secret "$tmp/lab/bootstrap.ps1"

    # WinPE driver paths: the CD letter is unknown at that stage, so offer every
    # plausible one - Setup silently skips the paths that do not exist.
    local drv="<component name=\"Microsoft-Windows-PnpCustomizationsWinPE\" processorArchitecture=\"amd64\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\"><DriverPaths>"
    local k=1
    for L in D E F G; do
        drv="$drv<PathAndCredentials wcm:action=\"add\" wcm:keyValue=\"$k\"><Path>$L:\\virtio</Path></PathAndCredentials>"
        k=$((k + 1))
    done
    drv="$drv</DriverPaths></component>"

    sed -e "s|__COMPUTERNAME__|$name|g" -e "s|__IMAGE__|$image|g" -e "s|__DRIVERPATHS__|$drv|g" \
        "$KIT_ROOT/lib/autounattend.xml.tpl" > "$tmp/autounattend.xml"
    render_secret_xml "$tmp/autounattend.xml"

    tar -C "$tmp" -czf "$tmp/payload.tgz" autounattend.xml lab
    pve "mkdir -p /tmp/kit-$name"
    scp -q -o StrictHostKeyChecking=no "$tmp/payload.tgz" "${PVE_SSH}:/tmp/kit-$name/"
    rm -rf "$tmp"

    # Assemble the ISO on the entry node, then ship it to the node that will run
    # the VM (ISO storage is local per node).
    pve "
        set -e
        cd /tmp/kit-$name && tar xzf payload.tgz && rm -f payload.tgz
        mkdir -p virtio guest-agent /mnt/kit-virtio
        mountpoint -q /mnt/kit-virtio || mount -o loop,ro /var/lib/vz/template/iso/${VIRTIO_ISO:-virtio-win.iso} /mnt/kit-virtio
        # virtio-win layout: amd64/<osver> carries ONLY storage drivers for WinPE;
        # everything else lives per component. vioserial is the critical one - the
        # guest agent runs without it but its host channel stays dead.
        for comp in vioserial NetKVM Balloon vioscsi viostor pvpanic qemupciserial; do
          for osv in $osv_list; do
            if [ -d \"/mnt/kit-virtio/\$comp/\$osv/amd64\" ]; then
              cp -r \"/mnt/kit-virtio/\$comp/\$osv/amd64\"/* virtio/ 2>/dev/null
              break
            fi
          done
        done
        for osv in $osv_list; do
          [ -d /mnt/kit-virtio/amd64/\$osv ] && cp -r /mnt/kit-virtio/amd64/\$osv/* virtio/ 2>/dev/null && break
        done
        cp -r /mnt/kit-virtio/guest-agent/* guest-agent/ 2>/dev/null || true
        umount /mnt/kit-virtio 2>/dev/null || true
        genisoimage -quiet -J -r -V UNATTEND -o /tmp/unattend-$name.iso .
        chmod 600 /tmp/unattend-$name.iso
        if [ '$node' != \"\$(hostname)\" ]; then
          scp -q -o StrictHostKeyChecking=no /tmp/unattend-$name.iso $node:/var/lib/vz/template/iso/
          ssh -n -o StrictHostKeyChecking=no $node 'chmod 600 /var/lib/vz/template/iso/unattend-$name.iso'
          rm -f /tmp/unattend-$name.iso
        else
          mv /tmp/unattend-$name.iso /var/lib/vz/template/iso/
        fi
        rm -rf /tmp/kit-$name
    "
}
