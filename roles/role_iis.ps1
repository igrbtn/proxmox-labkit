# Role: IIS web server. Local-only work, so it runs straight from the guest
# agent context (SYSTEM) - no scheduled task, no domain rights needed.
# Placeholders: __VMTAG__

$VmTag = '__VMTAG__'
$Features = @('Web-Server', 'Web-Mgmt-Console', 'Web-Asp-Net45')

$ErrorActionPreference = 'Continue'
$dir = 'C:\Lab'; $log = "$dir\role_iis.log"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Log($m) { Add-Content -Path $log -Value ((Get-Date).ToString('s') + '  ' + $m) }
function Status($s) { Set-Content -Path "$dir\status.txt" -Value "$VmTag|$s" -Encoding Ascii; Log "STATUS=$s" }

Status 'role-iis|features'
$r = Install-WindowsFeature $Features
Log ('features success=' + $r.Success + ' restart=' + $r.RestartNeeded)
if ((Get-Service W3SVC -ErrorAction SilentlyContinue).Status -eq 'Running') {
    Status 'role-iis|DONE-iis'
} else {
    Status 'role-iis|error'
}
