# 🐧 Ubuntu Desktop — deharden → exploit → harden

This guide walks through the Ubuntu dehardening script: **how to run it**, and for every weakness it
introduces, **how an attacker exploits it** and **how you harden the system** to fix it.

- **Script:** [`scripts/ubuntu/deharden-ubuntu.sh`](../scripts/ubuntu/deharden-ubuntu.sh) (Bash)
- **Tested on:** Ubuntu Desktop 24.04 and 22.04
- **New to the lab?** Read [lab-setup.md](lab-setup.md) first.

> [!WARNING]
> This script weakens the machine on purpose. Run it **only** in an isolated lab VM (Host-Only
> network) with a **fresh snapshot**. To recover a safe state, restore the snapshot.

## How to run the script

```bash
# 1. Copy the script to the victim VM and make it executable
chmod +x deharden-ubuntu.sh

# 2. Run it as root. It will ask you to type DEHARDEN to confirm
sudo ./deharden-ubuntu.sh

# Options:
#   -y        unattended mode (no confirmation prompt)
#   --no-apt  don't install packages (telnetd) if the VM has no internet
sudo ./deharden-ubuntu.sh -y --no-apt

# 3. Reboot so ASLR, AppArmor and services settle into their weak state
sudo reboot
```

- **Backups** of every modified file: `/root/deharden-backups-<date>/`
- **Log** of everything done: `/var/log/deharden-lab.log`
- **Demo accounts it creates:** `root / toor` and `trainee / 123456`

Find the victim's IP with `ip a` and use it as `IP` in the exploit commands below (run those from the
attacker box).

## Legend

🔴 Weakness introduced · 🟠 Exploitation (from the attacker box) · 🟢 Hardening (the fix)

## Weaknesses, exploitation and hardening

### 1. SSH wide open: root allowed, no retry limit, legacy crypto
- 🟠 **Exploit:** `hydra -l root -P rockyou.txt ssh://IP` — brute-force root with no cap on attempts.
- 🟢 **Harden:** in `/etc/ssh/sshd_config` set
  ```
  PermitRootLogin no
  PermitEmptyPasswords no
  MaxAuthTries 4
  AllowGroups sshadmins
  ```
  plus modern `Ciphers`/`MACs`/`KexAlgorithms`, then `systemctl restart ssh`.

### 2. Weak passwords (`root/toor`, `trainee/123456`)
- 🟠 **Exploit:** `hydra -L users.txt -P rockyou.txt ssh://IP` — a tiny wordlist cracks these instantly.
- 🟢 **Harden:** set strong passwords (`passwd trainee`) and enforce the policy from row 3.

### 3. No complexity, no lockout (faillock), MD5 hashes
- 🟠 **Exploit:** `john --format=md5crypt shadow` cracks the weak hashes offline; online, `hydra ssh://IP`
  runs forever because nothing locks out.
- 🟢 **Harden:**
  - `/etc/security/pwquality.conf`: `minlen=14`, `minclass=4`
  - `/etc/pam.d/common-auth`: `auth requisite pam_faillock.so preauth deny=5 unlock_time=900`
  - `/etc/login.defs`: `ENCRYPT_METHOD SHA512`

### 4. ASLR disabled
- 🟠 **Exploit:** with `gdb` / `pwntools`, memory-corruption exploits (e.g. ret2libc) become trivial
  because addresses are fixed between runs.
- 🟢 **Harden:** `sysctl -w kernel.randomize_va_space=2` and make it permanent in `/etc/sysctl.conf`.

### 5. AppArmor disabled (processes unconfined)
- 🟠 **Exploit:** a compromised service (e.g. a web app) is no longer confined, so it can read
  `/etc/shadow` and move laterally.
- 🟢 **Harden:** `systemctl enable --now apparmor` then `aa-enforce /etc/apparmor.d/*`.

### 6. `/etc/shadow` world-readable; SUID on `find` and `/tmp/rootbash`
- 🟠 **Exploit:**
  ```bash
  cat /etc/shadow | john            # hashes now readable by anyone
  find . -exec /bin/sh -p \; -quit  # SUID find -> root shell (GTFOBins)
  /tmp/rootbash -p                  # SUID bash copy -> root shell
  ```
- 🟢 **Harden:** `chmod 640 /etc/shadow`; `chmod u-s /usr/bin/find`; `rm /tmp/rootbash`; audit with
  `find / -perm -4000 -type f`.

### 7. Insecure sudo: `trainee` has NOPASSWD, no log, no pty
- 🟠 **Exploit:** `sudo find . -exec /bin/sh \; -quit` — escalates straight to root via GTFOBins.
- 🟢 **Harden:** remove the `NOPASSWD` rule from `/etc/sudoers.d/`; with `visudo` set
  `Defaults use_pty`, `Defaults logfile="/var/log/sudo.log"`, `Defaults timestamp_timeout=15`.

### 8. Extra services: telnet (cleartext), avahi, cups
- 🟠 **Exploit:**
  ```bash
  tcpdump -i eth0 port 23                 # telnet credentials in cleartext
  hydra -L users.txt -P pass.txt telnet://IP
  nmap -sV IP                             # unneeded services expand the attack surface
  ```
- 🟢 **Harden:** `apt purge telnetd`; `systemctl disable --now avahi-daemon cups`.

### 9. Firewall disabled
- 🟠 **Exploit:** `nmap -sS -p- IP` — every port is reachable.
- 🟢 **Harden:** `ufw default deny incoming`; `ufw allow 22/tcp`; `ufw enable`.

### 10. Network forwarding and redirects enabled
- 🟠 **Exploit:** the host can act as a MITM/pivot — `arpspoof`, `ettercap`.
- 🟢 **Harden:** `sysctl -w net.ipv4.ip_forward=0` and `net.ipv4.conf.all.send_redirects=0`
  (persist in `/etc/sysctl.conf`).

### 11. Auditing and log forwarding disabled
- 🟠 **Exploit:** `rm -rf /var/log/*` — after compromising root, the attacker erases the trail and
  nothing is shipped off-box.
- 🟢 **Harden:** `systemctl enable --now auditd` with rules such as `-w /etc/sudoers -p wa -k scope`;
  configure remote rsyslog forwarding.

### 12. Automatic updates disabled
- 🟠 **Exploit:** `searchsploit <service> <version>` → `msfconsole` — unpatched services keep known
  public exploits viable.
- 🟢 **Harden:** `apt update && apt upgrade`; re-enable `unattended-upgrades`.

## Suggested loop

For each row: **exploit it → harden it → re-run the same attack and confirm it now fails.** Then
restore the `fresh` snapshot before the next session so you always start from a known state.

➡️ Next target: [Windows Server 2019 guide](windows-server-2019.md)
