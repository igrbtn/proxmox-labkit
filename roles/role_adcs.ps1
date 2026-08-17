# Role: Enterprise Root CA on a domain-joined guest.
# Deployed with install_guest_role. Runs as SYSTEM first, notices it needs
# domain rights (Enterprise CA setup requires Enterprise Admins) and
# re-registers itself as a scheduled task under the domain admin.
# Placeholders: __VMTAG__ __CA_NAME__ __NETBIOS__ __LAB_PW__

$VmTag   = '__VMTAG__'
$CaName  = '__CA_NAME__'
$NetBios = '__NETBIOS__'

$dir = 'C:\Lab'; $log = "$dir\role_adcs.log"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Log($m) { Add-Content -Path $log -Value ((Get-Date).ToString('s') + '  ' + $m) }
function Status($s) { Set-Content -Path "$dir\status.txt" -Value "$VmTag|$s" -Encoding Ascii; Log "STATUS=$s" }

$IsSystem = ([Security.Principal.WindowsIdentity]::GetCurrent()).Name -eq 'NT AUTHORITY\SYSTEM'
if ($IsSystem) {
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Lab\role_adcs.ps1'
    $st  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $t   = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1))
    Register-ScheduledTask -TaskName 'Lab-Role-ADCS' -Action $act -Settings $st -Trigger $t `
        -User "$NetBios\Administrator" -Password '__LAB_PW__' -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName 'Lab-Role-ADCS'
    Status 'role-adcs|task-registered'
    return
}

$ErrorActionPreference = 'Continue'
if (Get-Service CertSvc -ErrorAction SilentlyContinue) {
    Status 'role-adcs|DONE-adcs'
    Disable-ScheduledTask -TaskName 'Lab-Role-ADCS' -ErrorAction SilentlyContinue | Out-Null
    return
}
Status 'role-adcs|features'
Install-WindowsFeature ADCS-Cert-Authority -IncludeManagementTools | Out-Null
Status 'role-adcs|install'
try {
    Install-AdcsCertificationAuthority -CAType EnterpriseRootCa -CACommonName $CaName -Force -ErrorAction Stop | Out-Null
    Log ('CertSvc: ' + (Get-Service CertSvc).Status)
    Status 'role-adcs|DONE-adcs'
} catch {
    Log ('adcs ERROR: ' + $_.Exception.Message)
    Status 'role-adcs|error'
}
Disable-ScheduledTask -TaskName 'Lab-Role-ADCS' -ErrorAction SilentlyContinue | Out-Null

# NOTE: the default WebServer template grants Enroll to nobody useful. To issue
# certs with certreq, grant Enroll on the template (extended right
# 0e10c968-78fb-11d2-90d4-00c04f79dc55) or enroll as an Enterprise Admin.
