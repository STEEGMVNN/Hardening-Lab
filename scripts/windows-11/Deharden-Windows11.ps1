#Requires -Version 5.1
<#
===============================================================================
  Hardening-Lab · DEHARDENING SCRIPT (Windows 11 Pro / Enterprise)
  An open-source lab for learning system hardening
-------------------------------------------------------------------------------
  WHAT IT DOES: it leaves a freshly installed Windows 11 DELIBERATELY INSECURE,
  like a badly managed endpoint/laptop, so you can practise re-hardening it step
  by step. It is the endpoint counterpart of the Windows Server 2019 script:
  it focuses on the weaknesses that matter on a workstation (a user running as
  local admin, remote admin with local accounts, an open SMB share, RDP without
  NLA, no auditing, Defender + SmartScreen off). Each weakness maps to a row in
  the companion guide (docs/windows-11.md).

  WARNING: USE ONLY INSIDE AN ISOLATED LAB VM (Host-Only / Internal network)
  WITH A FRESH-INSTALL SNAPSHOT. Never run this on a real machine or on a
  production network. To return to a safe state: restore the VM snapshot.

  BEFORE YOU RUN IT: turn off "Tamper Protection" by hand in
  Windows Security > Virus & threat protection > Manage settings. No script can
  disable it; the script warns you when Tamper Protection blocked it.

  USAGE (PowerShell as Administrator):
      Set-ExecutionPolicy -Scope Process Bypass -Force
      .\Deharden-Windows11.ps1 [-ComputerName lab-win11] [-Force]
          -ComputerName  rename the computer (applied after a reboot)
          -Force         do not ask for confirmation (unattended mode)

  Backups (secpol export) in:
      C:\deharden-backups-<date>
  Log of everything done in:
      C:\deharden-lab.log
===============================================================================
#>

[CmdletBinding()]
param(
    [string]$ComputerName,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

# --- requires Administrator ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

$ts        = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupDir = "C:\deharden-backups-$ts"
$Log       = "C:\deharden-lab.log"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

# Low-privilege-by-name but LOCAL ADMIN demo user (realistic for a poorly managed
# laptop), with a weak password that is present in rockyou.txt: crackable offline
# (hashcat) and predictable enough for password spraying. A hardened policy
# (min length 14 + complexity) would reject it.
$DemoUser  = 'trainee'
$DemoPass  = 'Password1'
$ShareName = 'Shared'
$SharePath = 'C:\Shared'

function Log  ($m){ $line="[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m; $line | Tee-Object -FilePath $Log -Append | Out-Null; Write-Host $line }
function Step ($m){ Write-Host ""; Write-Host "===== $m =====" -ForegroundColor Yellow; "===== $m =====" | Out-File $Log -Append }
function OK   ($m){ Write-Host "   [done] $m" -ForegroundColor Green; "   [done] $m" | Out-File $Log -Append }
function WarnMsg ($m){ Write-Host "   [warn] $m" -ForegroundColor Red;  "   [warn] $m" | Out-File $Log -Append }

function Set-Reg($Path,$Name,$Value,$Type='DWord'){
    if(-not (Test-Path $Path)){ New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# resolve group / account names from their SID so the script works on any OS language
function Get-NameFromSid($sid){
    (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value
}

# --- banner ---
Write-Host ""
Write-Host "################################################################################" -ForegroundColor Red
Write-Host "#       Hardening-Lab . DEHARDENING of Windows 11 (lab only)                    #" -ForegroundColor Red
Write-Host "#                                                                              #" -ForegroundColor Red
Write-Host "#  This script will WEAKEN the security of THIS machine on purpose.             #" -ForegroundColor Red
Write-Host "#  Run it ONLY in an isolated lab VM with a fresh snapshot.                     #" -ForegroundColor Red
Write-Host "#  To recover a safe state: restore the VM snapshot.                            #" -ForegroundColor Red
Write-Host "################################################################################" -ForegroundColor Red
Write-Host ""

$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -match 'Home') {
    WarnMsg "Windows 11 Home has no Remote Desktop server and no Group Policy editor. Use Pro or Enterprise."
}

if (-not $Force) {
    $ans = Read-Host "Type 'DEHARDEN' to continue"
    if ($ans -ne 'DEHARDEN') { Write-Host "Cancelled."; exit 0 }
}

Log "=== Dehardening started (Windows 11) $ts ==="
Log "System: $($os.Caption) $($os.Version)"
Log "Backups in: $BackupDir"

#==============================================================================
# 0) Back up the local security policy
#==============================================================================
Step "0) Back up the local security policy"
secedit /export /cfg "$BackupDir\secpol-BEFORE.cfg" | Out-Null
OK "secpol exported to $BackupDir\secpol-BEFORE.cfg"

#==============================================================================
# 1) Weak password policy (length 0, no complexity, no expiry)
#==============================================================================
Step "1) Weak password policy"
net accounts /minpwlen:0 /maxpwage:unlimited /uniquepw:0 | Out-Null
$cfg = "$env:TEMP\secpol-mod.cfg"
secedit /export /cfg $cfg | Out-Null
(Get-Content $cfg) `
  -replace 'PasswordComplexity\s*=\s*\d', 'PasswordComplexity = 0' `
  -replace 'MinimumPasswordLength\s*=\s*\d+', 'MinimumPasswordLength = 0' |
  Set-Content $cfg
secedit /configure /db "$env:TEMP\secpol.sdb" /cfg $cfg /areas SECURITYPOLICY | Out-Null
OK "complexity off, minimum length 0, no expiry (demo: spraying / dictionary)"

#==============================================================================
# 2) Account lockout disabled (unlimited spraying)
#    Windows 11 ships with a lockout threshold of 10; here it is removed entirely.
#==============================================================================
Step "2) Account lockout disabled"
net accounts /lockoutthreshold:0 | Out-Null
OK "lockout threshold = 0 (dictionary attacks never lock the account)"

#==============================================================================
# 3) Weak user that is a LOCAL ADMIN + remote admin with local accounts
#==============================================================================
Step "3) Weak local-admin user '$DemoUser'"
# idempotent: ALWAYS (re)set the password so re-runs converge.
$sec = ConvertTo-SecureString $DemoPass -AsPlainText -Force
if (Get-LocalUser -Name $DemoUser -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $DemoUser -Password $sec -PasswordNeverExpires $true
    OK "user '$DemoUser' already existed -> password reset to '$DemoPass'"
} else {
    New-LocalUser -Name $DemoUser -Password $sec -FullName 'Trainee (local admin)' -PasswordNeverExpires -AccountNeverExpires | Out-Null
    OK "user '$DemoUser' created"
}
# add to the local Administrators group by SID (S-1-5-32-544) -> works on any OS language
Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $DemoUser -ErrorAction SilentlyContinue
OK "'$DemoUser' set with weak password '$DemoPass', member of $(Get-NameFromSid 'S-1-5-32-544')"
# local admin accounts get a full token over the network (lets NetExec/psexec
# administer the box with the local account -> lateral movement demo)
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'LocalAccountTokenFilterPolicy' 1
OK "LocalAccountTokenFilterPolicy = 1 (remote admin with local accounts)"

#==============================================================================
# 4) SMB exposed: private profile, open share, no auth delay
#==============================================================================
Step "4) SMB exposed"
Get-NetConnectionProfile | ForEach-Object {
    Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
}
OK "network profile = Private"
Set-Service -Name LanmanServer -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name LanmanServer -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $SharePath | Out-Null
"Internal lab document: sample customer list (test data only)." | Out-File "$SharePath\customers.txt" -Encoding utf8
if (-not (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name $ShareName -Path $SharePath -FullAccess (Get-NameFromSid 'S-1-1-0') | Out-Null
}
OK "share \\$env:COMPUTERNAME\$ShareName with Full Control for $(Get-NameFromSid 'S-1-1-0')"
# Windows 11 24H2 waits 2 s after each failed SMB authentication; remove it so
# the dictionary attack runs at full speed.
try {
    Set-SmbServerConfiguration -InvalidAuthenticationDelayTimeInMs 0 -Force -ErrorAction Stop
    OK "SMB failed-authentication delay = 0 ms"
} catch {
    OK "this Windows build has no SMB authentication delay (pre-24H2)"
}

#==============================================================================
# 5) RDP enabled without NLA (brute force)
#==============================================================================
Step "5) RDP enabled and NLA off"
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 0
Set-Service -Name TermService -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name TermService -ErrorAction SilentlyContinue
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
OK "RDP active on 3389, NLA disabled ('$DemoUser' is a local admin, so it can sign in over RDP)"

#==============================================================================
# 6) Windows Defender Firewall disabled (all 3 profiles)
#==============================================================================
Step "6) Firewall disabled"
Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False
OK "firewall disabled on all 3 profiles (demo: nmap -p- finds every service)"

#==============================================================================
# 7) Advanced auditing disabled (no trace for the SOC)
#==============================================================================
Step "7) Auditing disabled"
auditpol /set /category:* /success:disable /failure:disable | Out-Null
# remove the command line from event 4688
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' 'ProcessCreationIncludeCmdLine_Enabled' 0
OK "all audit subcategories set to 'no auditing' (no 4625 / 4688 / 4740)"

#==============================================================================
# 8) Microsoft Defender real-time protection and SmartScreen disabled
#==============================================================================
Step "8) Microsoft Defender and SmartScreen"
$mp = $null
try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { }
if ($mp -and $mp.IsTamperProtected) {
    WarnMsg "Tamper Protection is ON: Defender cannot be disabled by command."
    WarnMsg "Turn it off in Windows Security -> Virus & threat protection, then re-run the script."
} else {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
    Set-MpPreference -MAPSReporting Disabled -SubmitSamplesConsent NeverSend -ErrorAction SilentlyContinue
    # policy so it does not turn itself back on
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableRealtimeMonitoring' 1
    OK "real-time protection, download scanning and cloud protection disabled"
}
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'SmartScreenEnabled' 0
OK "Windows and Edge SmartScreen disabled (a downloaded payload runs with no warning)"

#==============================================================================
# 9) Computer name (optional)
#==============================================================================
if ($ComputerName) {
    Step "9) Computer name"
    Rename-Computer -NewName $ComputerName -Force -ErrorAction SilentlyContinue
    OK "the computer will be named '$ComputerName' after a reboot"
}

#==============================================================================
# SUMMARY
#==============================================================================
Step "SUMMARY"
@"

   The system is now DEHARDENED. Weaknesses introduced:
     1. Password policy: no complexity, length 0, no expiry
     2. Account lockout disabled (unlimited spraying)
     3. '$DemoUser' / '$DemoPass', LOCAL ADMIN + remote admin with local accounts
     4. SMB exposed with the open share '$ShareName' (Full Control for Everyone)
     5. RDP active and NLA off
     6. Firewall disabled (3 profiles)
     7. Auditing disabled (no 4625 / 4688 / 4740)
     8. Defender real-time protection and SmartScreen disabled (if Tamper Protection allows it)

   Backups: $BackupDir (secpol-BEFORE.cfg)
   Log:     $Log

   Next: reboot (Restart-Computer) and confirm in Windows Security that real-time
   protection is still off. Then run the exploitation demos from the attacker box
   and re-harden following docs/windows-11.md. Between runs, restore the fresh VM snapshot.
"@ | Tee-Object -FilePath $Log -Append | Write-Host

Log "=== Dehardening finished (Windows 11) ==="
