# 🪟 Windows Server 2019 — deharden → exploit → harden

This guide walks through the Windows Server 2019 dehardening script: **how to run it**, and for every
weakness it introduces, **how an attacker exploits it** and **how you harden the system** to fix it.

- **Script:** [`scripts/windows-server-2019/Deharden-WindowsServer2019.ps1`](../scripts/windows-server-2019/Deharden-WindowsServer2019.ps1) (PowerShell)
- **New to the lab?** Read [lab-setup.md](lab-setup.md) first.

> [!WARNING]
> This script weakens the machine on purpose. Run it **only** in an isolated lab VM (Host-Only
> network) with a **fresh snapshot**. To recover a safe state, restore the snapshot.

## How to run the script

```powershell
# 1. Open PowerShell AS ADMINISTRATOR

# 2. Allow the script to run for this session only
Set-ExecutionPolicy -Scope Process Bypass -Force

# 3. Run it. It will ask you to type DEHARDEN to confirm
.\Deharden-WindowsServer2019.ps1

# Unattended mode (no confirmation):
.\Deharden-WindowsServer2019.ps1 -Force

# 4. Reboot: UAC, Defender and SMBv1 need a restart
Restart-Computer
```

> [!NOTE]
> **Windows Defender.** If **Tamper Protection** is on, the command can't disable Defender. Turn it off
> first in *Windows Security → Virus & threat protection*, then re-run the script (or do it via GPO).
> The script warns you when it couldn't.

- **Backup** of the local policy: `C:\deharden-backups-<date>\secpol-BEFORE.cfg`
- **Log** of everything done: `C:\deharden-lab.log`
- **Demo account it creates:** `trainee / Spring2026!`

Find the victim's IP with `ipconfig` and use it as `HOST` in the exploit commands below (run those from
the attacker box).

## Legend

🔴 Weakness introduced · 🟠 Exploitation (from the attacker box) · 🟢 Hardening (the fix)

## Weaknesses, exploitation and hardening

### 1. Weak password policy: no complexity, length 0, no expiry
- 🟠 **Exploit:** `hashcat -m 1000 ntlm.txt rockyou.txt` — an offline dictionary attack over captured
  NTLM hashes succeeds because trivial passwords are allowed.
- 🟢 **Harden:** `net accounts /minpwlen:14 /maxpwage:365 /uniquepw:24` and enable complexity in
  `secpol.msc`.

### 2. Account lockout disabled (unlimited spraying)
- 🟠 **Exploit:** `nxc smb HOST -u users.txt -p 'Spring2026!'` — password spraying never trips a lockout.
- 🟢 **Harden:** `net accounts /lockoutthreshold:5 /lockoutduration:15 /lockoutwindow:15`.

### 3. Guest enabled, blank passwords allowed, Administrator not renamed
- 🟠 **Exploit:**
  ```bash
  nxc smb HOST -u guest -p ''        # anonymous-ish access via Guest
  lookupsid.py dom/u:p@HOST          # enumerate the Administrator via RID 500
  ```
- 🟢 **Harden:** `net user Guest /active:no`; set `LimitBlankPasswordUse=1`;
  `Rename-LocalUser Administrator adm-lab`.

### 4. Logon: shows last user, no inactivity lock, no legal banner
- 🟠 **Exploit:** account enumeration enables targeted phishing; physical access reaches an unlocked
  session.
- 🟢 **Harden:** set `DontDisplayLastUserName=1` and `InactivityTimeoutSecs=900` (via GPO or registry).

### 5. UAC disabled (silent elevation)
- 🟠 **Exploit:** classic UAC-bypass paths like `fodhelper.exe` / `eventvwr` elevate without a prompt.
- 🟢 **Harden:** `EnableLUA=1` and `ConsentPromptBehaviorAdmin=2` (reboot required).

### 6. RDP active and NLA off
- 🟠 **Exploit:**
  ```bash
  nmap -p3389 --script rdp-ntlm-info HOST
  hydra -L users.txt -P pass.txt rdp://HOST
  ```
- 🟢 **Harden:** if RDP isn't needed, `sc config TermService start= disabled`; otherwise re-enable NLA
  with `UserAuthentication=1`.

### 7. Firewall disabled (all 3 profiles)
- 🟠 **Exploit:** `nmap -sS -p- HOST` exposes SMB/RPC/WinRM and every other listening service.
- 🟢 **Harden:** `Set-NetFirewallProfile -All -Enabled True -DefaultInboundAction Block -LogBlocked True`.

### 8. Auditing disabled (no 4625 / 4688 / 4740)
- 🟠 **Exploit:** living-off-the-land activity — PowerShell, PsExec, user creation — leaves no events
  for a defender to catch.
- 🟢 **Harden:** `auditpol /set /category:* /success:enable` and re-enable the command line in event 4688.

### 9. SMBv1 enabled, ScriptBlock logging off, autorun on
- 🟠 **Exploit:** `nmap --script smb-vuln-ms17-010 -p445 HOST`. On a patched 2019 this reports
  *not vulnerable* — it's a **detection** demo, not an RCE (see note below).
- 🟢 **Harden:** `Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol`;
  `EnableScriptBlockLogging=1`; `NoDriveTypeAutoRun=255`.

### 10. Windows Update with no automatic updates
- 🟠 **Exploit:** unpatched services keep public exploits viable — e.g. PrintNightmare
  (CVE-2021-34527).
- 🟢 **Harden:** `sconfig` (option 5: automatic) or set `NoAutoUpdate=0`.

### 11. Windows Defender disabled
- 🟠 **Exploit:** a webshell or malware can be dropped on the server with no detection.
- 🟢 **Harden:** `Set-MpPreference -DisableRealtimeMonitoring $false` and turn Tamper Protection back on.

## A note on EternalBlue (MS17-010)

The script re-enables SMBv1 for the **defensive** exercise (detect it, then disable it again). It is
**not a real RCE on Windows Server 2019** — the OS is patched, so `nmap --script smb-vuln-ms17-010`
reports *not vulnerable*. The exercise is to **detect** SMBv1 with nmap, run the defensive command
(`Get-WindowsOptionalFeature … SMB1Protocol`), and understand EternalBlue conceptually. Seeing it as a
live RCE would require a legacy target (Windows 7 / Server 2008 R2, or Metasploitable3), which is out
of scope for this lab.

## Suggested loop

For each row: **exploit it → harden it → re-run the same attack and confirm it now fails.** Then
restore the `fresh` snapshot before the next session so you always start from a known state.

➡️ Other target: [Ubuntu Desktop guide](ubuntu-desktop.md)
