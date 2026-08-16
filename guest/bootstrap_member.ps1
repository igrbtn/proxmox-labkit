# HCI lab guest bootstrap: S2D cluster node - static IP, domain join,
# clustering features. Cluster creation itself happens later from the host
# script (form-cluster.sh) once all nodes report DONE-node.
# Placeholders are filled by build-lab.sh. Survives reboots via C:\Lab\state.txt.

$VmTag   = '__VMTAG__'
$IP      = '__IP__'
$Prefix  = __PREFIX__
$Gateway = '__GW__'
$DnsSrv  = '__DNS__'
$Domain  = '__DOMAIN__'
$NetBios = '__NETBIOS__'

$ErrorActionPreference = 'Continue'
$dir = 'C:\Lab'; $stateFile = "$dir\state.txt"; $log = "$dir\bootstrap.log"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Log($m) { Add-Content -Path $log -Value ((Get-Date).ToString('s') + '  ' + $m) }
function Status($s) { Set-Content -Path "$dir\status.txt" -Value "$VmTag|$s" -Encoding Ascii; Log "STATUS=$s" }

function Install-VirtioDrivers {
    # MUST run before the guest agent: the agent talks to the host over
    # virtio-serial, and WinPE only injects boot-critical drivers, so vioserial
    # is missing on a fresh install. Without it QEMU-GA installs but never runs.
    # This also (re)installs vioscsi so the S2D data disks are visible.
    foreach ($d in (Get-PSDrive -PSProvider FileSystem).Name) {
        $path = "${d}:\virtio"
        if (Test-Path $path) {
            Get-ChildItem -Path $path -Filter *.inf -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                & pnputil.exe /add-driver $_.FullName /install | Out-Null
            }
            Log "virtio drivers installed from $path"
            return
        }
    }
    Log 'virtio driver folder not found on any drive'
}

function Install-GuestAgent {
    if ((Get-Service QEMU-GA -ErrorAction SilentlyContinue).Status -eq 'Running') { return }
    foreach ($d in (Get-PSDrive -PSProvider FileSystem).Name) {
        $msi = "${d}:\guest-agent\qemu-ga-x86_64.msi"
        if (Test-Path $msi) {
            Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart' -Wait
            Start-Service QEMU-GA -ErrorAction SilentlyContinue
            Log ("guest agent installed from $msi, service: " + (Get-Service QEMU-GA -ErrorAction SilentlyContinue).Status)
            return
        }
    }
    Log 'guest agent MSI not found on any drive'
}

$step = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { 'start' }
Log "=== fired, step=$step ==="

if ($step -eq 'start') {
    Status 'bootstrap|waiting-setup'
    for ($i = 0; $i -lt 90; $i++) {
        $sip  = (Get-ItemProperty 'HKLM:\SYSTEM\Setup' -Name SystemSetupInProgress -ErrorAction SilentlyContinue).SystemSetupInProgress
        $oobe = (Get-ItemProperty 'HKLM:\SYSTEM\Setup' -Name OOBEInProgress -ErrorAction SilentlyContinue).OOBEInProgress
        if (($sip -ne 1) -and ($oobe -ne 1)) { break }
        Start-Sleep 10
    }
    Install-VirtioDrivers
    Install-GuestAgent
    Status 'bootstrap|network'
    # hard gate: joining a domain without a NIC cannot work
    $ifc = $null
    for ($i = 0; $i -lt 30; $i++) {
        $ifc = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
        if ($ifc) { break }
        Start-Sleep 10
    }
    if (-not $ifc) {
        Log 'no NIC in Up state - check the network driver'
        Status 'bootstrap|no-nic'
        return
    }
    try {
        Get-NetIPAddress -InterfaceIndex $ifc.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute -InterfaceIndex $ifc.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $ifc.ifIndex -IPAddress $IP -PrefixLength $Prefix -DefaultGateway $Gateway -ErrorAction Stop | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $ifc.ifIndex -ServerAddresses $DnsSrv
        Log "static IP $IP, DNS $DnsSrv set on $($ifc.Name)"
    } catch {
        Log ('net cfg ERROR: ' + $_.Exception.Message)
        Status 'bootstrap|net-error'
        return
    }

    Status 'bootstrap|features'
    $r = Install-WindowsFeature Failover-Clustering, FS-FileServer -IncludeManagementTools
    Log ('features success=' + $r.Success + ' restart=' + $r.RestartNeeded)

    Status 'bootstrap|waiting-dc'
    $dcUp = $false
    for ($i = 0; $i -lt 90; $i++) {
        try { if (Resolve-DnsName -Name $Domain -Type A -Server $DnsSrv -ErrorAction Stop) { $dcUp = $true; break } } catch { Start-Sleep 20 }
    }
    if (-not $dcUp) { Status 'bootstrap|dc-not-ready'; Log 'DC did not answer; will retry on next trigger'; return }

    # next state BEFORE joining: Add-Computer reboots the machine
    Set-Content $stateFile 'joined'
    Status 'bootstrap|joining'
    try {
        $sec  = ConvertTo-SecureString '__LAB_PW__' -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential("$NetBios\Administrator", $sec)
        Add-Computer -DomainName $Domain -Credential $cred -Force -Restart -ErrorAction Stop
        Log 'Add-Computer issued (reboot expected)'
    } catch {
        Log ('join ERROR: ' + $_.Exception.Message)
        Status 'bootstrap|join-error'
        Set-Content $stateFile 'start'
    }
    return
}

if ($step -eq 'joined') {
    Status 'bootstrap|verify'
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.PartOfDomain -and $cs.Domain -eq $Domain) {
        # SAN policy leaves added disks offline on Windows Server, and S2D can
        # only claim online writable disks. Local disks have a Number; disk 0
        # is the OS disk.
        Get-Disk | Where-Object { $_.Number -ne $null -and $_.Number -gt 0 } | ForEach-Object {
            Set-Disk -Number $_.Number -IsOffline $false -ErrorAction SilentlyContinue
            Set-Disk -Number $_.Number -IsReadOnly $false -ErrorAction SilentlyContinue
        }
        Start-Sleep 3
        Get-PhysicalDisk -CanPool $true -ErrorAction SilentlyContinue |
            ForEach-Object { Log ('poolable disk: ' + $_.FriendlyName + ' sn=' + $_.SerialNumber + ' ' + [math]::Round($_.Size/1GB) + 'GB') }
        Set-Content $stateFile 'done'
        Status 'DONE-node'
        Log ('joined domain: ' + $cs.Domain)
        Disable-ScheduledTask -TaskName 'Lab-Bootstrap' -ErrorAction SilentlyContinue | Out-Null
    } else {
        Status 'bootstrap|not-joined-yet'
        Log ('not joined: PartOfDomain=' + $cs.PartOfDomain + ' Domain=' + $cs.Domain)
    }
    return
}
Log "no action for step=$step"
