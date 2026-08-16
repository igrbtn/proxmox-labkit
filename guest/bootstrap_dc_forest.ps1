# HCI lab guest bootstrap: first domain controller + file share witness.
# Placeholders are filled by build-lab.sh; runs as scheduled task Lab-Bootstrap
# (SYSTEM) and survives the dcpromo reboot via C:\Lab\state.txt.
# Status is written to C:\Lab\status.txt and read from the host with
# "qm guest exec" (qemu-guest-agent), which replaces Hyper-V KVP here.

$VmTag   = '__VMTAG__'
$IP      = '__IP__'
$Prefix  = __PREFIX__
$Gateway = '__GW__'
$Domain  = '__DOMAIN__'
$NetBios = '__NETBIOS__'
$Forward = '__DNS_FORWARD__'

$ErrorActionPreference = 'Continue'
$dir = 'C:\Lab'; $stateFile = "$dir\state.txt"; $log = "$dir\bootstrap.log"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Log($m) { Add-Content -Path $log -Value ((Get-Date).ToString('s') + '  ' + $m) }
function Status($s) { Set-Content -Path "$dir\status.txt" -Value "$VmTag|$s" -Encoding Ascii; Log "STATUS=$s" }

function Install-VirtioDrivers {
    # MUST run before the guest agent: the agent talks to the host over
    # virtio-serial, and WinPE only injects boot-critical drivers, so vioserial
    # is missing on a fresh install. Without it QEMU-GA installs but never runs.
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
    # qemu-guest-agent lives on the virtio-win CD; without it the host cannot
    # run commands or read status inside the guest.
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
    # Promoting a DC without a working NIC produces a broken forest, so this is
    # a hard gate: no adapter -> stop and retry on the next task trigger.
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
        Set-DnsClientServerAddress -InterfaceIndex $ifc.ifIndex -ServerAddresses 127.0.0.1
        Log "static IP $IP set on $($ifc.Name)"
    } catch {
        Log ('net cfg ERROR: ' + $_.Exception.Message)
        Status 'bootstrap|net-error'
        return
    }
    Status 'bootstrap|features'
    $r = Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools
    Log ('features success=' + $r.Success)
    # next state BEFORE promoting: Install-ADDSForest reboots the machine
    Set-Content $stateFile 'promote'
    Status 'bootstrap|promoting'
    try {
        Import-Module ADDSDeployment
        $dsrm = ConvertTo-SecureString '__LAB_PW__' -AsPlainText -Force
        Install-ADDSForest -DomainName $Domain -DomainNetbiosName $NetBios `
            -ForestMode 'WinThreshold' -DomainMode 'WinThreshold' -InstallDns:$true `
            -SafeModeAdministratorPassword $dsrm -NoRebootOnCompletion:$false -Force:$true
        Log 'Install-ADDSForest returned (reboot pending)'
    } catch {
        Log ('promote ERROR: ' + $_.Exception.Message)
        Status 'bootstrap|promote-error'
        Set-Content $stateFile 'start'
    }
    return
}

if ($step -eq 'promote') {
    Status 'bootstrap|verify'
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            if ((Get-ADDomain -ErrorAction Stop).DNSRoot -eq $Domain) { $ok = $true; break }
        } catch { Start-Sleep 20 }
    }
    if (-not $ok) { Status 'bootstrap|adws-not-ready'; return }

    # DNS forwarder so guests can still resolve the outside world
    try {
        Set-DnsServerForwarder -IPAddress $Forward -PassThru -ErrorAction Stop | Out-Null
        Log "forwarder set to $Forward"
    } catch { Log ('forwarder: ' + $_.Exception.Message) }

    # file share witness for the S2D cluster (this DC is the witness)
    try {
        New-Item -ItemType Directory -Force -Path 'C:\Witness' | Out-Null
        if (-not (Get-SmbShare -Name 'Witness' -ErrorAction SilentlyContinue)) {
            New-SmbShare -Name 'Witness' -Path 'C:\Witness' -FullAccess "$NetBios\Domain Admins" | Out-Null
        }
        Log 'witness share ready (cluster account is granted later by the host script)'
    } catch { Log ('witness: ' + $_.Exception.Message) }

    Set-Content $stateFile 'done'
    Status 'DONE-forest'
    Disable-ScheduledTask -TaskName 'Lab-Bootstrap' -ErrorAction SilentlyContinue | Out-Null
    return
}
Log "no action for step=$step"
