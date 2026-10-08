# Register the self-driving bootstrap task. Runs from the specialize pass, so it
# must stay light: no servicing work here, only the task registration.
#
# If this script fails, the guest is dead in the water - no task, no bootstrap,
# no status, no network. Hence the fallback: a repeating trigger is nice to have
# (it gives a guest whose dependency is not ready a second chance without a
# reboot), but never at the cost of not registering the task at all.
$ErrorActionPreference = 'Continue'

# WS2016 (and older): the ScheduledTasks CIM cmdlets do not work in specialize -
# New-ScheduledTaskAction returns null and nothing gets registered. SetupComplete.cmd
# runs at the end of setup as SYSTEM with the Task Scheduler up, so it re-runs this
# script; on newer Windows the second registration is a harmless -Force overwrite.
$sc = "$env:windir\Setup\Scripts"
if (-not (Test-Path "$sc\SetupComplete.cmd")) {
    New-Item -ItemType Directory -Force -Path $sc | Out-Null
    Set-Content -Path "$sc\SetupComplete.cmd" -Encoding Ascii -Value 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Lab\arm.ps1'
}

$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Lab\bootstrap.ps1'
$pr  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$st  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
$t1  = New-ScheduledTaskTrigger -AtStartup

$ok = $false
try {
    # No RepetitionDuration on purpose: omitting it repeats indefinitely, while
    # a bounded value pushes the next run far into the future and MaxValue is
    # rejected outright by Register-ScheduledTask.
    $t2 = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName 'Lab-Bootstrap' -Action $act -Principal $pr -Settings $st -Trigger $t1, $t2 -Force -ErrorAction Stop | Out-Null
    $ok = $true
} catch {
    "repeating trigger failed: $($_.Exception.Message)" | Out-File C:\Lab\arm.log -Append
}

if (-not $ok) {
    $t2 = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2))
    Register-ScheduledTask -TaskName 'Lab-Bootstrap' -Action $act -Principal $pr -Settings $st -Trigger $t1, $t2 -Force | Out-Null
    'registered without repetition' | Out-File C:\Lab\arm.log -Append
}
