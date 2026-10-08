# Role: Exchange Server Mailbox (SE / 2019 on WS2022/WS2025, 2016 CU23 on WS2016) on a domain-joined guest.
# Deployed with install_guest_role AFTER the Exchange ISO is in the CD drive
# (swap the Windows ISO: qm set <vmid> --ide2 local:iso/ExchangeServerSE-x64.iso,media=cdrom).
# Runs as SYSTEM first, then re-registers itself as a domain-admin task with an
# AtStartup + 5 min repeating trigger: the role reboots twice and PrepareSchema /
# PrepareAD need Schema + Enterprise Admins.
# State machine: features -> reboot -> [dotnet -> reboot] -> prereqs -> reboot -> install -> DONE-exchange.
# Exchange 2016 media has no UCMARedist and WS2016 ships .NET 4.6.2: both come from
# download.microsoft.com (.NET 4.8 offline installer, UCMA 4.0 runtime).
# Ported from HyperVLabKit/roles/role_exchange.ps1 (Exchange 2019, Hyper-V KVP);
# read its docs/GOTCHAS.md "Exchange 2019" before debugging a failed install.
# Placeholders: __VMTAG__ __NETBIOS__ __ORG__ __LAB_PW__

$VmTag   = '__VMTAG__'
$NetBios = '__NETBIOS__'
$OrgName = '__ORG__'
$Task    = 'Lab-Role-Exchange'

$dir = 'C:\Lab'; $state = "$dir\exch-state.txt"; $log = "$dir\role_exchange.log"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Log($m) { Add-Content -Path $log -Value ((Get-Date).ToString('s') + '  ' + $m) }
function Status($s) { Set-Content -Path "$dir\status.txt" -Value "$VmTag|$s" -Encoding Ascii; Log "STATUS=$s" }

function Find-ExchangeMedia {
    # The Windows ISO also has Setup.exe in its root - ExchangeServer.msi is what makes
    # it the Exchange media (every version; UCMARedist exists only on 2019 / SE media).
    foreach ($d in (Get-PSDrive -PSProvider FileSystem).Name) {
        if ((Test-Path "${d}:\Setup.exe") -and (Test-Path "${d}:\ExchangeServer.msi")) { return "${d}:" }
    }
    return $null
}

$IsSystem = ([Security.Principal.WindowsIdentity]::GetCurrent()).Name -eq 'NT AUTHORITY\SYSTEM'
if ($IsSystem) {
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $dir\$Task.ps1"
    $st  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $t1  = New-ScheduledTaskTrigger -AtStartup
    $t2  = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $Task -Action $act -Settings $st -Trigger $t1, $t2 `
        -User "$NetBios\Administrator" -Password '__LAB_PW__' -RunLevel Highest -Force | Out-Null
    Status 'role-exch|task-registered'
    return
}

$ErrorActionPreference = 'Continue'
$step = if (Test-Path $state) { (Get-Content $state -Raw).Trim() } else { 'features' }
Log "=== fired, step=$step ==="

if ($step -eq 'done') {
    Disable-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue | Out-Null
    return
}

if ($step -eq 'features') {
    Status 'role-exch|features'
    try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue } catch {}
    $want = @(
        'Server-Media-Foundation', 'NET-Framework-45-Features', 'RPC-over-HTTP-proxy',
        'RSAT-Clustering', 'RSAT-Clustering-CmdInterface', 'RSAT-Clustering-Mgmt', 'RSAT-Clustering-PowerShell',
        'WAS-Process-Model', 'Web-Asp-Net45', 'Web-Basic-Auth', 'Web-Client-Auth', 'Web-Digest-Auth',
        'Web-Dir-Browsing', 'Web-Dyn-Compression', 'Web-Http-Errors', 'Web-Http-Logging', 'Web-Http-Redirect',
        'Web-Http-Tracing', 'Web-ISAPI-Ext', 'Web-ISAPI-Filter', 'Web-Lgcy-Mgmt-Console', 'Web-Metabase',
        'Web-Mgmt-Console', 'Web-Mgmt-Service', 'Web-Net-Ext45', 'Web-Request-Monitor', 'Web-Server',
        'Web-Stat-Compression', 'Web-Static-Content', 'Web-Windows-Auth', 'Web-WMI',
        'Windows-Identity-Foundation', 'RSAT-ADDS'
    )
    # Install-WindowsFeature rejects the whole list on one unknown name, and the
    # catalog differs between Core / Desktop and OS versions.
    $known = (Get-WindowsFeature).Name
    $feats = $want | Where-Object { $known -contains $_ }
    $miss  = $want | Where-Object { $known -notcontains $_ }
    if ($miss) { Log ('features not in catalog, skipped: ' + ($miss -join ', ')) }
    $r = Install-WindowsFeature $feats
    Log ('features success=' + $r.Success + ' restart=' + $r.RestartNeeded)
    Set-Content $state 'dotnet'
    Status 'role-exch|features-done-reboot'
    Restart-Computer -Force
    return
}

if ($step -eq 'dotnet') {
    # Exchange 2016 CU23 / 2019 need .NET Framework 4.8 (Release 528040+); WS2022+ already has it
    $rel = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
    if ($rel -ge 528040) { Set-Content $state 'prereqs'; Log ".NET release $rel - ok" }
    else {
        Status 'role-exch|dotnet48'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ndp = "$dir\ndp48.exe"
        try {
            if (-not (Test-Path $ndp)) { Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2088631' -OutFile $ndp -UseBasicParsing -TimeoutSec 900 }
            $sig = Get-AuthenticodeSignature $ndp
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { throw "bad signature: $($sig.Status)" }
            $p = Start-Process $ndp -ArgumentList '/q', '/norestart' -Wait -PassThru
            Log ('.NET 4.8 installer exit=' + $p.ExitCode)
        } catch { Log ('.NET 4.8 err: ' + $_.Exception.Message); Status 'role-exch|dotnet48-error'; return }
        Set-Content $state 'prereqs'
        Status 'role-exch|dotnet-reboot'
        Restart-Computer -Force
        return
    }
}

$step = if (Test-Path $state) { (Get-Content $state -Raw).Trim() } else { 'features' }
if ($step -eq 'prereqs') {
    $dvd = Find-ExchangeMedia
    if (-not $dvd) { Status 'role-exch|no-exchange-media'; Log 'Exchange ISO not mounted'; return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $pre = "$dir\exch-prereqs"
    New-Item -ItemType Directory -Force -Path $pre | Out-Null

    Status 'role-exch|ucma'
    $spr = Join-Path $dvd 'UCMARedist\Chains\SpeechPlatformRuntime.msi'
    if (Test-Path $spr) { Start-Process msiexec.exe -ArgumentList '/i', "`"$spr`"", '/qn', '/norestart' -Wait }
    # UCMA Setup.exe is a bootstrapper that returns immediately; poll Uninstall.
    $ucma = Join-Path $dvd 'UCMARedist\Setup.exe'
    if (-not (Test-Path $ucma)) {
        # Exchange 2016 media: UCMA 4.0 runtime from Microsoft
        $ucma = "$pre\UcmaRuntimeSetup.exe"
        if (-not (Test-Path $ucma)) {
            Invoke-WebRequest -Uri 'https://download.microsoft.com/download/2/C/4/2C47A5C1-A1F3-4843-B9FE-84C0032C61EC/UcmaRuntimeSetup.exe' -OutFile $ucma -UseBasicParsing -TimeoutSec 600
        }
    }
    $ukeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Start-Process $ucma -ArgumentList '/passive', '/norestart'
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep 10
        if (Get-ItemProperty $ukeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Unified Communications Managed API 4.0.*Runtime' }) { $ok = $true; break }
    }
    Log ('UCMA Core Runtime registered=' + $ok)

    Status 'role-exch|vcredist'
    # unpinned Microsoft URLs without upstream checksums - documented risk
    $dl = @(
        @{ n = 'vc2012.exe';  u = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe'; a = '/install /quiet /norestart' },
        @{ n = 'vc2013.exe';  u = 'https://aka.ms/highdpimfc2013x64enu'; a = '/install /quiet /norestart' },
        @{ n = 'rewrite.msi'; u = 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi'; a = $null }
    )
    foreach ($x in $dl) {
        $dst = Join-Path $pre $x.n
        try {
            if (-not (Test-Path $dst)) { Invoke-WebRequest -Uri $x.u -OutFile $dst -UseBasicParsing -TimeoutSec 300 }
            if ($x.a) { Start-Process $dst -ArgumentList $x.a -Wait }
            else { Start-Process msiexec.exe -ArgumentList '/i', $dst, '/quiet', '/norestart' -Wait }
            Log ('installed ' + $x.n)
        } catch { Log ('prereq ' + $x.n + ' err: ' + $_.Exception.Message) }
    }

    # Prereq installers leave a pending reboot; Setup then fails every prep step
    # with Rule:RebootPending.
    Set-Content $state 'install'
    Status 'role-exch|prereqs-done-reboot'
    Restart-Computer -Force
    return
}

if ($step -eq 'install') {
    $dvd = Find-ExchangeMedia
    if (-not $dvd) { Status 'role-exch|no-exchange-media'; return }
    $setup = "$dvd\Setup.exe"
    # mark before the long run: the 5 min repeat trigger must not start a second
    # Setup if this one is still going after a task restart
    Set-Content $state 'installing'

    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match 'Role$' } |
        ForEach-Object { Remove-ItemProperty -Path $_.PSPath -Name 'Watermark', 'Action' -ErrorAction SilentlyContinue }

    $accept = '/IAcceptExchangeServerLicenseTerms_DiagnosticDataOFF'
    Status 'role-exch|prepare-schema'
    $p = Start-Process $setup -ArgumentList $accept, '/PrepareSchema' -Wait -PassThru -NoNewWindow
    Log ('PrepareSchema exit=' + $p.ExitCode)
    Status 'role-exch|prepare-ad'
    $p = Start-Process $setup -ArgumentList $accept, '/PrepareAD', "/OrganizationName:$OrgName" -Wait -PassThru -NoNewWindow
    Log ('PrepareAD exit=' + $p.ExitCode)
    $p = Start-Process $setup -ArgumentList $accept, '/PrepareAllDomains' -Wait -PassThru -NoNewWindow
    Log ('PrepareAllDomains exit=' + $p.ExitCode)

    Status 'role-exch|install'
    $p = Start-Process $setup -ArgumentList $accept, '/Mode:Install', '/Roles:Mailbox' -Wait -PassThru -NoNewWindow
    Log ('Install exit=' + $p.ExitCode)
    if ($p.ExitCode -eq 0) {
        Set-Content $state 'done'
        Status 'DONE-exchange'
        Disable-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue | Out-Null
    } else {
        Set-Content $state 'failed'
        Status "role-exch|install-exit-$($p.ExitCode)"
    }
    return
}

if ($step -eq 'installing') { Log 'Setup already running or was interrupted - see C:\ExchangeSetupLogs'; return }
Log "no action for step=$step"
