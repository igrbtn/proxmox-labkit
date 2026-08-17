# S2D cluster build, runs inside the first node.
# Self-selecting mode - no arguments needed, because arguments do not survive
# the ssh -> qm guest exec -> powershell quoting chain reliably:
#   running as SYSTEM (how the guest agent invokes it) -> register itself as a
#   scheduled task under the domain admin and start it; creating a cluster needs
#   domain rights that SYSTEM does not have.
#   running as anyone else (that task) -> do the actual work.
# Placeholders are filled by form-cluster.sh.
param([switch]$Register)
$IsSystem = ([Security.Principal.WindowsIdentity]::GetCurrent()).Name -eq 'NT AUTHORITY\SYSTEM'
if ($IsSystem) { $Register = $true }

$Nodes      = @(__NODES__)
$ClusterName = '__CLUSTER__'
$ClusterIP  = '__CLUSTER_IP__'
$DcName     = '__DC__'
$NetBios    = '__NETBIOS__'

$dir = 'C:\Lab'; $log = "$dir\cluster.log"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Log($m) { Add-Content -Path $log -Value ((Get-Date).ToString('s') + '  ' + $m) }
function Status($s) { Set-Content -Path "$dir\status.txt" -Value "CLUSTER|$s" -Encoding Ascii; Log "STATUS=$s" }

if ($Register) {
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Lab\cluster.ps1'
    $st  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    $t   = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1))
    Register-ScheduledTask -TaskName 'Lab-Cluster' -Action $act -Settings $st -Trigger $t `
        -User "$NetBios\Administrator" -Password '__LAB_PW__' -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName 'Lab-Cluster'
    Status 'task-registered'
    return
}

$ErrorActionPreference = 'Continue'
Log "=== cluster build start, nodes: $($Nodes -join ',') ==="

Status 'validate'
try {
    Test-Cluster -Node $Nodes -Include 'Inventory', 'Network', 'System Configuration', 'Storage Spaces Direct' -ErrorAction SilentlyContinue | Out-Null
} catch { Log ('test-cluster: ' + $_.Exception.Message) }

if (-not (Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue)) {
    Status 'create-cluster'
    try {
        New-Cluster -Name $ClusterName -Node $Nodes -StaticAddress $ClusterIP -NoStorage -ErrorAction Stop | Out-Null
        Log 'cluster created'
        Start-Sleep 45
    } catch { Log ('new-cluster ERROR: ' + $_.Exception.Message); Status 'create-error'; return }
}

# witness: the DC hosts the share; the cluster computer object needs access,
# and it only exists after New-Cluster - hence the ordering here
Status 'witness'
try {
    Invoke-Command -ComputerName $DcName -ScriptBlock {
        param($cno)
        $acct = "$cno$"
        Grant-SmbShareAccess -Name 'Witness' -AccountName $acct -AccessRight Full -Force -ErrorAction SilentlyContinue | Out-Null
        $acl = Get-Acl 'C:\Witness'
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($acct, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl 'C:\Witness' $acl
    } -ArgumentList $ClusterName -ErrorAction Stop
    Set-ClusterQuorum -Cluster $ClusterName -FileShareWitness "\\$DcName\Witness" -ErrorAction Stop | Out-Null
    Log 'file share witness configured'
} catch { Log ('witness ERROR: ' + $_.Exception.Message) }

Status 'enable-s2d'
# Fail fast if the nodes do not actually expose their data disks. Enabling S2D
# with zero visible disks "succeeds" and leaves an empty pool - the confusing
# failure this lab hit once: disks without a serial= never show up as
# PhysicalDisk, and SAN policy keeps added disks offline.
$ss = Get-StorageSubSystem -FriendlyName 'Clustered*'
$avail = ($ss | Get-PhysicalDisk -ErrorAction SilentlyContinue | Measure-Object).Count
Log "physical disks visible to the cluster: $avail"
if ($avail -lt 3) {
    Log 'too few disks - check that every data disk has a unique serial and is online'
    Status 'no-disks'
    return
}
# Idempotent: a re-run must not fail on work that is already done. Enable-Cluster
# StorageSpacesDirect throws when S2D is already on, and the orchestrator does
# retry this script, so check the real state instead of trusting the exit code.
if ((Get-ClusterS2D -ErrorAction SilentlyContinue).State -eq 'Enabled' -and
    (Get-StoragePool -FriendlyName 'S2DPool' -ErrorAction SilentlyContinue)) {
    Log 'S2D already enabled and pool exists - skipping'
} else {
    try {
        # virtual data disks report MediaType Unspecified -> eligibility checks must be skipped;
        # no cache tier in a lab with a single (virtual) media type
        Enable-ClusterStorageSpacesDirect -Confirm:$false -SkipEligibilityChecks -CacheState Disabled -PoolFriendlyName 'S2DPool' -ErrorAction Stop | Out-Null
        Log 'S2D enabled'
    } catch {
        Log ('enable-s2d returned: ' + $_.Exception.Message)
        # The cmdlet reports failures it then recovers from, so believe the pool,
        # not the exception.
        Start-Sleep 20
        if (-not (Get-StoragePool -FriendlyName 'S2DPool' -ErrorAction SilentlyContinue)) {
            Log 'no pool after enable - giving up'
            Status 's2d-error'
            return
        }
        Log 'pool exists despite the error - continuing'
    }
}

Status 'create-volume'
try {
    if (-not (Get-VirtualDisk -FriendlyName 'Vol01' -ErrorAction SilentlyContinue)) {
        # three nodes -> three-way mirror is chosen automatically
        New-Volume -StoragePoolFriendlyName 'S2DPool' -FriendlyName 'Vol01' -FileSystem CSVFS_ReFS -Size 40GB -ErrorAction Stop | Out-Null
    }
    Log 'volume Vol01 created'
} catch { Log ('volume ERROR: ' + $_.Exception.Message) }

Status 'DONE-cluster'
Disable-ScheduledTask -TaskName 'Lab-Cluster' -ErrorAction SilentlyContinue | Out-Null
Log '=== done ==='
