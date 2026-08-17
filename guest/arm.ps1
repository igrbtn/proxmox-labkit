# Register the self-driving bootstrap task. Runs from the specialize pass, so it
# must stay light: no servicing work here, only the task registration.
$ErrorActionPreference = 'Continue'
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Lab\bootstrap.ps1'
$pr  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$st  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
$t1  = New-ScheduledTaskTrigger -AtStartup
# Repeat every 5 minutes: a node whose dependency is not ready yet (DC still
# promoting, DNS not answering) rewinds its state and must get another chance
# without waiting for a reboot. The state machine disables the task when done.
# RepetitionDuration stays at MaxValue on purpose: a bounded duration next to
# -Once schedules the next run a day out instead of in five minutes.
$t2  = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)
Register-ScheduledTask -TaskName 'Lab-Bootstrap' -Action $act -Principal $pr -Settings $st -Trigger $t1, $t2 -Force
