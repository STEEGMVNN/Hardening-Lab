#!/usr/bin/env bash
#===============================================================================
#  Servers-Hardening · DEHARDENING SCRIPT (Ubuntu Desktop)
#  An open-source lab for learning system hardening
#-------------------------------------------------------------------------------
#  WHAT IT DOES: it leaves an Ubuntu Desktop (24.04 / 22.04) DELIBERATELY
#  INSECURE by undoing common hardening controls, so you can practise
#  re-hardening the system step by step. Each weakness it introduces maps to a
#  row in the companion guide (docs/ubuntu-desktop.md): the misconfiguration,
#  how it is exploited, and the command that fixes it.
#
#  WARNING: USE ONLY INSIDE AN ISOLATED LAB VM (Host-Only network) WITH A
#  FRESH-INSTALL SNAPSHOT. Never run this on a real machine or on a production
#  network. To return to a safe state: restore the VM snapshot.
#
#  USAGE:  sudo ./deharden-ubuntu.sh [-y] [--no-apt]
#            -y        do not ask for confirmation (unattended mode)
#            --no-apt  do not try to install packages (telnetd, etc.) via apt
#
#  Backups of every modified file go to: /root/deharden-backups-<date>
#  A log of everything done goes to:      /var/log/deharden-lab.log
#===============================================================================
set -u

#------------------------------- parameters -----------------------------------
ASSUME_YES=0
USE_APT=1
for arg in "$@"; do
  case "$arg" in
    -y|--yes)   ASSUME_YES=1 ;;
    --no-apt)   USE_APT=0 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown argument: $arg"; exit 2 ;;
  esac
done

#------------------------------- preliminaries --------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "This script needs root privileges. Run it with: sudo $0"
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/deharden-backups-${TS}"
LOG="/var/log/deharden-lab.log"
mkdir -p "$BACKUP_DIR"

# Low-privilege demo user (the privilege-escalation target in the exercises)
DEMO_USER="trainee"
DEMO_PASS="123456"        # deliberately weak password
ROOT_PASS="toor"          # weak root password for the SSH brute-force demo

C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_RST=$'\e[0m'

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
step() { echo; echo "${C_YEL}===== $* =====${C_RST}" | tee -a "$LOG"; }
ok()  { echo "   ${C_GRN}[done]${C_RST} $*" | tee -a "$LOG"; }
warn(){ echo "   ${C_RED}[warn]${C_RST} $*" | tee -a "$LOG"; }

backup() {  # backup <file>
  local f="$1"
  if [[ -e "$f" ]]; then
    local dest="${BACKUP_DIR}${f}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$f" "$dest" 2>/dev/null && ok "backed up $f"
  fi
}

#------------------------------- banner ---------------------------------------
cat <<BANNER
${C_RED}
################################################################################
#          Servers-Hardening · DEHARDENING of Ubuntu Desktop (lab only)        #
#                                                                              #
#  This script will WEAKEN the security of THIS machine on purpose.            #
#  Run it ONLY in an isolated lab VM with a fresh snapshot.                    #
#  To recover a safe state: restore the VM snapshot.                           #
################################################################################
${C_RST}
BANNER

if [[ $ASSUME_YES -ne 1 ]]; then
  read -r -p "Type 'DEHARDEN' to continue: " ans
  [[ "$ans" == "DEHARDEN" ]] || { echo "Cancelled."; exit 0; }
fi

log "=== Dehardening started (Ubuntu) $TS ==="
log "Backups in: $BACKUP_DIR"

#==============================================================================
# 1) SSH — allow root, empty passwords, no retry limit, weak crypto
#==============================================================================
step "1) Weak SSH (openssh-server)"
if ! dpkg -s openssh-server >/dev/null 2>&1; then
  if [[ $USE_APT -eq 1 ]]; then
    log "Installing openssh-server..."
    apt-get update -qq && apt-get install -y -qq openssh-server || warn "could not install openssh-server (no internet?)"
  else
    warn "openssh-server not installed and --no-apt is set; skipping installation"
  fi
fi
SSHD=/etc/ssh/sshd_config
if [[ -f "$SSHD" ]]; then
  backup "$SSHD"
  # remove any previous hardening directives and write the weak ones
  sed -i -E '/^\s*(PermitRootLogin|PermitEmptyPasswords|PasswordAuthentication|MaxAuthTries|AllowGroups|AllowUsers|X11Forwarding|AllowTcpForwarding|Ciphers|MACs|KexAlgorithms|LoginGraceTime|ClientAliveInterval)\b/d' "$SSHD"
  cat >>"$SSHD" <<'EOF'

# --- DEHARDENING (insecure on purpose) ---
PermitRootLogin yes
PermitEmptyPasswords yes
PasswordAuthentication yes
MaxAuthTries 100
X11Forwarding yes
AllowTcpForwarding yes
LoginGraceTime 120
# legacy / weak ciphers and KEX (downgrade demonstration)
Ciphers aes128-cbc,3des-cbc,aes256-cbc
KexAlgorithms diffie-hellman-group1-sha1,diffie-hellman-group14-sha1
MACs hmac-md5,hmac-sha1
EOF
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1
  systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1
  ok "sshd_config weakened: root allowed, no retry limit, legacy crypto"
else
  warn "$SSHD does not exist (openssh-server not installed)"
fi

#==============================================================================
# 2) Weak accounts and passwords (root and a low-privilege user)
#==============================================================================
step "2) Weak accounts and passwords"
if ! id "$DEMO_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$DEMO_USER" && ok "created demo user '$DEMO_USER'"
fi
echo "${DEMO_USER}:${DEMO_PASS}" | chpasswd && ok "'$DEMO_USER' set with weak password '$DEMO_PASS'"
echo "root:${ROOT_PASS}" | chpasswd && ok "root set with weak password '$ROOT_PASS' (for the SSH hydra demo)"
passwd -u root >/dev/null 2>&1 || true

#==============================================================================
# 3) Password policy and hashing: lax pwquality, NO faillock, MD5 hashes
#==============================================================================
step "3) Weak password policy and hashing (PAM)"
PWQ=/etc/security/pwquality.conf
backup "$PWQ"
cat >"$PWQ" <<'EOF'
# DEHARDENING: no complexity requirements
minlen = 1
minclass = 0
dcredit = 0
ucredit = 0
ocredit = 0
lcredit = 0
EOF
ok "lax pwquality (minlen=1, no complexity)"

# remove faillock from common-auth / common-account (lockout on failed attempts)
for f in /etc/pam.d/common-auth /etc/pam.d/common-account; do
  if [[ -f "$f" ]]; then
    backup "$f"
    sed -i '/pam_faillock/d'  "$f" && true
    sed -i '/pam_tally2/d'    "$f" && true
    ok "faillock/tally removed from $f (no lockout on failed logins)"
  fi
done

# weak hash (MD5) and expiry disabled
LOGINDEFS=/etc/login.defs
if [[ -f "$LOGINDEFS" ]]; then
  backup "$LOGINDEFS"
  sed -i -E 's/^\s*ENCRYPT_METHOD.*/ENCRYPT_METHOD MD5/' "$LOGINDEFS"
  grep -q '^ENCRYPT_METHOD' "$LOGINDEFS" || echo 'ENCRYPT_METHOD MD5' >>"$LOGINDEFS"
  sed -i -E 's/^\s*PASS_MAX_DAYS.*/PASS_MAX_DAYS 99999/' "$LOGINDEFS"
  sed -i -E 's/^\s*PASS_MIN_DAYS.*/PASS_MIN_DAYS 0/' "$LOGINDEFS"
  ok "login.defs: ENCRYPT_METHOD=MD5, password expiry disabled"
fi
# force pam_unix to md5 in common-password
CP=/etc/pam.d/common-password
if [[ -f "$CP" ]]; then
  backup "$CP"
  sed -i -E '/pam_unix\.so/ s/sha512/md5/g' "$CP"
  ok "common-password: pam_unix using md5"
fi

#==============================================================================
# 4) ASLR disabled
#==============================================================================
step "4) ASLR disabled"
backup /etc/sysctl.conf
sed -i '/kernel.randomize_va_space/d' /etc/sysctl.conf
echo 'kernel.randomize_va_space = 0' >>/etc/sysctl.conf
sysctl -w kernel.randomize_va_space=0 >/dev/null && ok "kernel.randomize_va_space = 0"

#==============================================================================
# 5) AppArmor disabled (profiles in complain mode / service stopped)
#==============================================================================
step "5) AppArmor disabled"
if command -v aa-complain >/dev/null 2>&1; then
  aa-complain /etc/apparmor.d/* >/dev/null 2>&1 && ok "AppArmor profiles set to 'complain' mode"
fi
systemctl stop apparmor   >/dev/null 2>&1 && ok "apparmor service stopped"
systemctl disable apparmor >/dev/null 2>&1 && ok "apparmor service disabled at boot"

#==============================================================================
# 6) Weak permissions on sensitive files and an exploitable SUID binary
#==============================================================================
step "6) Weak permissions and exploitable SUID"
backup /etc/shadow
chmod 644 /etc/shadow && ok "/etc/shadow world-readable (hashes exposed to 'john')"
# SUID on find -> GTFOBins privilege escalation:  find . -exec /bin/sh -p \; -quit
if [[ -x /usr/bin/find ]]; then
  chmod u+s /usr/bin/find && ok "SUID added to /usr/bin/find (escalation via GTFOBins)"
fi
# SUID copy of bash in /tmp (second escalation vector)
cp /bin/bash /tmp/rootbash 2>/dev/null && chmod 4755 /tmp/rootbash && ok "/tmp/rootbash SUID created (escalation: /tmp/rootbash -p)"

#==============================================================================
# 7) Insecure sudo: NOPASSWD, no log, no pty, infinite timeout
#==============================================================================
step "7) Insecure sudo"
SUDOD=/etc/sudoers.d/90-lab-deharden
cat >"$SUDOD" <<EOF
# DEHARDENING (insecure on purpose)
Defaults !use_pty
Defaults timestamp_timeout=-1
# the trainee can run find as root without a password -> GTFOBins
${DEMO_USER} ALL=(ALL) NOPASSWD: /usr/bin/find
EOF
chmod 440 "$SUDOD"
# drop sudo logging if it existed
sed -i '/logfile=.*sudo.log/d' /etc/sudoers 2>/dev/null || true
if visudo -cf /etc/sudoers >/dev/null 2>&1; then
  ok "weak sudoers: '$DEMO_USER' can 'sudo find' with no password, no log, no pty"
else
  warn "sudoers validation failed; review $SUDOD"
fi

#==============================================================================
# 8) Unnecessary / cleartext services and ports (telnet, avahi, cups)
#==============================================================================
step "8) Unnecessary and cleartext services"
if [[ $USE_APT -eq 1 ]]; then
  apt-get install -y -qq telnetd inetutils-inetd >/dev/null 2>&1 \
    && { systemctl enable --now inetutils-inetd >/dev/null 2>&1; ok "telnetd installed and active (cleartext credentials, demo with tcpdump/hydra)"; } \
    || warn "could not install telnetd (no internet? use --no-apt to skip)"
else
  warn "--no-apt: telnetd not installed"
fi
systemctl enable --now avahi-daemon >/dev/null 2>&1 && ok "avahi-daemon active (unnecessary service)"
systemctl enable --now cups         >/dev/null 2>&1 && ok "cups active (unnecessary service)"

#==============================================================================
# 9) Firewall disabled
#==============================================================================
step "9) Firewall disabled"
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable >/dev/null 2>&1 && ok "ufw disabled"
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
  iptables -F 2>/dev/null
  ok "iptables: all chains set to ACCEPT and rules flushed"
fi

#==============================================================================
# 10) Network: ip_forward and redirects enabled (pivot / MITM)
#==============================================================================
step "10) Network forwarding and redirects enabled"
sed -i -E '/net.ipv4.(ip_forward|conf.all.send_redirects|conf.all.accept_redirects)/d' /etc/sysctl.conf
cat >>/etc/sysctl.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 1
net.ipv4.conf.all.accept_redirects = 1
EOF
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.send_redirects=1 >/dev/null
sysctl -w net.ipv4.conf.all.accept_redirects=1 >/dev/null
ok "ip_forward=1 and redirects enabled (the host can pivot / MITM)"

#==============================================================================
# 11) Auditing and logging disabled
#==============================================================================
step "11) Auditing and logs disabled"
systemctl stop auditd    >/dev/null 2>&1 && ok "auditd stopped"
systemctl disable auditd >/dev/null 2>&1 || true
# disable remote rsyslog forwarding if it was configured
if [[ -f /etc/rsyslog.d/60-remote.conf ]]; then
  backup /etc/rsyslog.d/60-remote.conf
  mv /etc/rsyslog.d/60-remote.conf "${BACKUP_DIR}/60-remote.conf.off" && ok "remote rsyslog forwarding disabled"
fi

#==============================================================================
# 12) Automatic updates disabled
#==============================================================================
step "12) Automatic updates disabled"
AUTOUP=/etc/apt/apt.conf.d/20auto-upgrades
backup "$AUTOUP"
cat >"$AUTOUP" <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
systemctl disable --now unattended-upgrades >/dev/null 2>&1 || true
ok "unattended-upgrades disabled"

#------------------------------- summary --------------------------------------
step "SUMMARY"
cat <<RES | tee -a "$LOG"

   The system is now DEHARDENED. Weaknesses introduced:
     1. SSH: root allowed, empty passwords, 100 retries, legacy crypto
     2. Accounts: root/'$ROOT_PASS' and $DEMO_USER/'$DEMO_PASS' (weak)
     3. Passwords: no complexity, no faillock, MD5 hashing
     4. ASLR disabled
     5. AppArmor disabled
     6. /etc/shadow world-readable; SUID on find and /tmp/rootbash
     7. sudo: $DEMO_USER with NOPASSWD find, no log, no pty
     8. Extra services: telnet (cleartext), avahi, cups
     9. Firewall (ufw/iptables) disabled
    10. ip_forward and redirects enabled
    11. auditd and log forwarding disabled
    12. Automatic updates disabled

   Backups: $BACKUP_DIR
   Log:     $LOG

   ${C_YEL}Next: find the machine's IP, run the exploitation demos, then re-harden
   following docs/ubuntu-desktop.md. Between runs, restore the fresh VM snapshot.${C_RST}

RES
log "=== Dehardening finished (Ubuntu) ==="
echo "It is recommended to reboot the VM so every change takes effect: sudo reboot"
