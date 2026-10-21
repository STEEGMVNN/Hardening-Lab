#Requires -Version 5.1
<#
===============================================================================
  Servers-Hardening · DEHARDENING SCRIPT (Windows Server 2019)
  An open-source lab for learning system hardening
-------------------------------------------------------------------------------
  WHAT IT DOES: it leaves a Windows Server 2019 DELIBERATELY INSECURE by undoing
  common hardening controls, so you can practise re-hardening the system step by
  step. It is the Windows counterpart of the Ubuntu script: it introduces the
  same kinds of weakness (accounts, policies, firewall, services, auditing,
  legacy protocols) adapted to Windows. Each weakness maps to a row in the
  companion guide (docs/windows-server-2019.md).

  WARNING: USE ONLY INSIDE AN ISOLATED LAB VM (Host-Only network) WITH A
  FRESH-INSTALL SNAPSHOT. Never run this on a real machine or on a production
  network. To return to a safe state: restore the VM snapshot.

  USAGE (PowerShell as Administrator):
      Set-ExecutionPolicy -Scope Process Bypass -Force
      .\Deharden-WindowsServer2019.ps1 [-Force]
          -Force   do not ask for confirmation (unattended mode)

  Backups (secpol and registry export) in:
      C:\deharden-backups-<date>
  Log of everything done in:
      C:\deharden-lab.log
===============================================================================
#>

[CmdletBinding()]
param([switch]$Force)

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

# Low-privilege demo user (the target in the exercises) and weak passwords
$DemoUser = 'trainee'
$DemoPass = 'Password1'     # weak AND present in rockyou.txt: crackable offline (hashcat)
                            # and predictable enough for password spraying. A hardened
                            # policy (min length 14 + complexity) would reject it.

function Log  ($m){ $line="[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m; $line | Tee-Object -FilePath $Log -Append | Out-Null; Write-Host $line }
function Step ($m){ Write-Host ""; Write-Host "===== $m =====" -ForegroundColor Yellow; "===== $m =====" | Out-File $Log -Append }
function OK   ($m){ Write-Host "   [done] $m" -ForegroundColor Green; "   [done] $m" | Out-File $Log -Append }
function WarnMsg ($m){ Write-Host "   [warn] $m" -ForegroundColor Red;  "   [warn] $m" | Out-File $Log -Append }

function Set-Reg($Path,$Name,$Value,$Type='DWord'){
    if(-not (Test-Path $Path)){ New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# --- banner ---
Write-Host ""
Write-Host "################################################################################" -ForegroundColor Red
Write-Host "#     Servers-Hardening . DEHARDENING of Windows Server 2019 (lab only)         #" -ForegroundColor Red
Write-Host "#                                                                              #" -ForegroundColor Red
Write-Host "#  This script will WEAKEN the security of THIS machine on purpose.             #" -ForegroundColor Red
Write-Host "#  Run it ONLY in an isolated lab VM with a fresh snapshot.                     #" -ForegroundColor Red
Write-Host "#  To recover a safe state: restore the VM snapshot.                            #" -ForegroundColor Red
Write-Host "################################################################################" -ForegroundColor Red
Write-Host ""

if (-not $Force) {
    $ans = Read-Host "Type 'DEHARDEN' to continue"
    if ($ans -ne 'DEHARDEN') { Write-Host "Cancelled."; exit 0 }
}

Log "=== Dehardening started (Windows Server 2019) $ts ==="
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
  -replace 'MinimumPasswordLength\s*=\s*\d+', 'MinimumPasswordLength = 0' `
  -replace 'MinimumPasswordAge\s*=\s*\d+', 'MinimumPasswordAge = 0' `
  -replace 'ClearTextPassword\s*=\s*\d', 'ClearTextPassword = 0' |
  Set-Content $cfg
secedit /configure /db "$env:TEMP\secpol.sdb" /cfg $cfg /areas SECURITYPOLICY | Out-Null
OK "complexity off, minimum length 0, no expiry (demo: spraying / dictionary)"

#==============================================================================
# 2) Account lockout disabled (unlimited spraying)
#==============================================================================
Step "2) Account lockout disabled"
net accounts /lockoutthreshold:0 | Out-Null
OK "lockout threshold = 0 (accounts never lock out)"

#==============================================================================
# 3) Accounts: Guest enabled, blank passwords allowed, weak user
#==============================================================================
Step "3) Weak accounts"
# Guest account enabled (name depends on OS language)
$guest = Get-LocalUser | Where-Object { $_.SID -like 'S-1-5-21-*-501' }
if ($guest) { Enable-LocalUser -Name $guest.Name; OK "Guest account '$($guest.Name)' enabled" }
# allow blank-password accounts to be used over the network
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LimitBlankPasswordUse' 0
OK "LimitBlankPasswordUse = 0 (blank-password accounts usable over the network)"
# low-privilege demo user with a weak password
if (-not (Get-LocalUser -Name $DemoUser -ErrorAction SilentlyContinue)) {
    $sec = ConvertTo-SecureString $DemoPass -AsPlainText -Force
    New-LocalUser -Name $DemoUser -Password $sec -PasswordNeverExpires -AccountNeverExpires | Out-Null
    Add-LocalGroupMember -Group 'Users' -Member $DemoUser -ErrorAction SilentlyContinue
    OK "user '$DemoUser' with weak password '$DemoPass'"
}
# local Administrator NOT renamed -> enumerable via RID 500 (left on purpose)
OK "Administrator keeps its default name (enumerable via RID 500)"

#==============================================================================
# 4) Interactive logon: show last user, no lock, no banner
#==============================================================================
Step "4) Weak interactive logon"
$sysPol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-Reg $sysPol 'DontDisplayLastUserName' 0
Set-Reg $sysPol 'InactivityTimeoutSecs'   0
Set-Reg $sysPol 'DisableCAD'              1
Set-Reg $sysPol 'LegalNoticeCaption'      '' 'String'
Set-Reg $sysPol 'LegalNoticeText'         '' 'String'
OK "last user is shown, no inactivity lock, no legal banner"

#==============================================================================
# 5) UAC disabled (silent elevation)
#==============================================================================
Step "5) UAC disabled"
Set-Reg $sysPol 'EnableLUA' 0
Set-Reg $sysPol 'ConsentPromptBehaviorAdmin' 0
Set-Reg $sysPol 'PromptOnSecureDesktop' 0
OK "EnableLUA=0 and ConsentPromptBehaviorAdmin=0 (needs reboot; UAC-bypass demo)"

#==============================================================================
# 6) RDP enabled without NLA (brute force / historic BlueKeep)
#==============================================================================
Step "6) RDP enabled and NLA off"
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0
Set-Service -Name TermService -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name TermService -ErrorAction SilentlyContinue
# disable Network Level Authentication
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
OK "RDP active, NLA disabled (demo: nmap rdp-ntlm-info / hydra rdp)"

#==============================================================================
# 7) Windows Defender Firewall disabled (all profiles)
#==============================================================================
Step "7) Firewall disabled"
Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False
OK "firewall disabled on all 3 profiles (demo: nmap -p- finds every service)"

#==============================================================================
# 8) Advanced auditing disabled (no trace for the SOC)
#==============================================================================
Step "8) Auditing disabled"
auditpol /set /category:* /success:disable /failure:disable | Out-Null
# remove the command line from event 4688
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' 'ProcessCreationIncludeCmdLine_Enabled' 0
OK "all audit subcategories set to 'no auditing'; 4688 without command line"

#==============================================================================
# 9) SMBv1 enabled, ScriptBlock logging off, autorun on
#==============================================================================
Step "9) SMBv1, ScriptBlock logging and autorun"
# enable SMBv1 (legacy protocol; patched on 2019 -> treated as a detection demo with nmap)
Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force -ErrorAction SilentlyContinue
OK "SMBv1 enabled (demo: nmap --script smb-vuln-ms17-010 -> detection; not RCE on patched 2019)"
# disable PowerShell ScriptBlock logging
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' 'EnableScriptBlockLogging' 0
OK "ScriptBlock logging disabled (obfuscated PowerShell goes unnoticed)"
# autorun / autoplay enabled
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 0
OK "autorun enabled (malicious USB auto-executes)"

#==============================================================================
# 10) Windows Update: no automatic updates
#==============================================================================
Step "10) Automatic updates disabled"
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 1
OK "NoAutoUpdate=1 (the server never installs patches -> public exploits stay viable)"

#==============================================================================
# 11) Windows Defender (antivirus) disabled
#==============================================================================
Step "11) Windows Defender disabled"
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
    Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
    OK "Defender real-time protection disabled"
} catch {
    WarnMsg "could not disable Defender by command (Tamper Protection is blocking it)."
    WarnMsg "Disable 'Tamper Protection' first in Windows Security, then re-run, or do it via GPO."
}
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware' 1
OK "DisableAntiSpyware=1 policy applied (full effect after reboot)"

#==============================================================================
# SUMMARY
#==============================================================================
Step "SUMMARY"
@"

   The system is now DEHARDENED. Weaknesses introduced:
     1. Password policy: no complexity, length 0, no expiry
     2. Account lockout disabled (unlimited spraying)
     3. Guest enabled, blank passwords allowed, '$DemoUser'/'$DemoPass'
     4. Logon: shows last user, no inactivity lock, no legal banner
     5. UAC disabled
     6. RDP active and NLA off
     7. Firewall disabled (3 profiles)
     8. Auditing disabled (no 4625/4688/4740)
     9. SMBv1 enabled, ScriptBlock logging off, autorun on
    10. Windows Update with no automatic updates
    11. Windows Defender disabled (if Tamper Protection allows it)

   Backups: $BackupDir (secpol-BEFORE.cfg)
   Log:     $Log

   Next: find the machine's IP, run the exploitation demos, then re-harden
   following docs/windows-server-2019.md. Between runs, restore the fresh VM snapshot.
   SOME CHANGES (UAC, Defender, SMBv1) REQUIRE A REBOOT: Restart-Computer
"@ | Tee-Object -FilePath $Log -Append | Write-Host

Log "=== Dehardening finished (Windows Server 2019) ==="
