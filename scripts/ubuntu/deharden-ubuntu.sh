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
#  USAGE:  sudo ./deharden-ubuntu.sh [-y] [--no-apt] [--no-web] [--ftp]
#            -y        do not ask for confirmation (unattended mode)
#            --no-apt  do not try to install packages (telnetd, etc.) via apt
#            --no-web  do not install the vulnerable web app (DVWA)
#            --ftp     also build a vulnerable FTP server (opt-in; needs PROFTPD_SRC_URL,
#                      since old ProFTPD versions are not reliably downloadable). Example:
#                      sudo PROFTPD_SRC_URL=file:///root/proftpd-1.3.3c.tar.gz ./deharden-ubuntu.sh --ftp
#
#  Backups of every modified file go to: /root/deharden-backups-<date>
#  A log of everything done goes to:      /var/log/deharden-lab.log
#===============================================================================
set -u

#------------------------------- parameters -----------------------------------
ASSUME_YES=0
USE_APT=1
INSTALL_WEB=1
INSTALL_FTP=0          # opt-in: old ProFTPD is not reliably downloadable, so off by default
for arg in "$@"; do
  case "$arg" in
    -y|--yes)   ASSUME_YES=1 ;;
    --no-apt)   USE_APT=0 ;;
    --no-web)   INSTALL_WEB=0 ;;
    --ftp)      INSTALL_FTP=1 ;;
    --no-ftp)   INSTALL_FTP=0 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Unknown argument: $arg"; exit 2 ;;
  esac
done

# Optional ProFTPD module (opt-in via --ftp). Old ProFTPD releases are not reliably
# downloadable by script (not on GitHub; SourceForge/FTP block automated pulls), so the
# operator supplies the source via PROFTPD_SRC_URL (http(s):// or file://). PROFTPD_VERSION
# is only used to name files and pick the convenience mirror URLs. See docs/ubuntu-desktop.md.
PROFTPD_VERSION="${PROFTPD_VERSION:-1.3.3c}"
# If PROFTPD_SRC_URL is set it is used as the only source; otherwise the script tries the
# built-in HTTPS candidate list below (FTP is avoided: it is often blocked by VM NAT).
PROFTPD_SRC_URL="${PROFTPD_SRC_URL:-}"

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
# weak/legacy algorithms ADDED alongside the modern ones. nmap's ssh2-enum-algos still
# flags the weak offer (the downgrade weakness), but keeping the modern algorithms means a
# current OpenSSH client / hydra can still negotiate the handshake and run the brute-force
# demo. Offering ONLY legacy algos makes modern clients refuse to connect at all.
Ciphers aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-ctr,aes128-ctr,aes128-cbc,3des-cbc,aes256-cbc
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
MACs hmac-sha2-256,hmac-sha2-512,hmac-sha1,hmac-md5
EOF
  # Ubuntu includes /etc/ssh/sshd_config.d/*.conf BEFORE the rest of the main file, and the
  # first value wins -- so a cloud/server drop-in like 50-cloud-init.conf with
  # 'PasswordAuthentication no' would silently override what we just appended. Put the weak
  # auth directives in a 00- drop-in so they take precedence over any other drop-in.
  if [[ -d /etc/ssh/sshd_config.d ]]; then
    cat >/etc/ssh/sshd_config.d/00-deharden.conf <<'EOF'
# DEHARDENING (insecure on purpose) - sorts first, so it wins over other drop-ins
PermitRootLogin yes
PermitEmptyPasswords yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
MaxAuthTries 100
EOF
    chmod 644 /etc/ssh/sshd_config.d/00-deharden.conf
  fi
  # validate the config before restarting so we never leave sshd unable to start
  SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
  if "$SSHD_BIN" -t 2>>"$LOG"; then
    systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1
    ok "sshd_config weakened: root allowed, password auth on, no retry limit, legacy+modern crypto"
  else
    warn "sshd config test failed; NOT restarting sshd to avoid lockout (see $LOG). Review $SSHD"
  fi
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

# IMPORTANT: re-set the demo passwords now that MD5 is active, so the hashes
# stored in /etc/shadow are MD5 ($1$...). The passwords set in step 2 were
# hashed with the system default (yescrypt/SHA-512); without this re-hash the
# 'john --format=md5crypt' / 'hashcat -m 500' demo would not match.
echo "${DEMO_USER}:${DEMO_PASS}" | chpasswd -c MD5 2>/dev/null || echo "${DEMO_USER}:${DEMO_PASS}" | chpasswd
echo "root:${ROOT_PASS}"         | chpasswd -c MD5 2>/dev/null || echo "root:${ROOT_PASS}"         | chpasswd
ok "demo passwords re-hashed as MD5 (\$1\$) in /etc/shadow (crackable with john/hashcat -m 500)"

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
step "5) AppArmor disabled + vulnerable web app (DVWA)"
if command -v aa-complain >/dev/null 2>&1; then
  aa-complain /etc/apparmor.d/* >/dev/null 2>&1 && ok "AppArmor profiles set to 'complain' mode"
fi
systemctl stop apparmor   >/dev/null 2>&1 && ok "apparmor service stopped"
systemctl disable apparmor >/dev/null 2>&1 && ok "apparmor service disabled at boot"

# Install DVWA (Damn Vulnerable Web Application) so the impact of an UNCONFINED web
# service is tangible: a command-injection / LFI flaw in DVWA can read /etc/passwd
# (and /etc/shadow, made world-readable in step 6). With AppArmor enforcing an Apache
# profile, that same read would be denied -- that is the control this step removes.
if [[ $INSTALL_WEB -eq 1 && $USE_APT -eq 1 ]]; then
  log "Installing DVWA stack (apache2, php, mariadb)..."
  export DEBIAN_FRONTEND=noninteractive
  if apt-get install -y -qq apache2 mariadb-server php php-mysqli php-gd libapache2-mod-php git >/dev/null 2>&1; then
    systemctl enable --now mariadb >/dev/null 2>&1
    systemctl enable --now apache2 >/dev/null 2>&1
    DVWA_DIR=/var/www/html/dvwa
    if [[ ! -d "$DVWA_DIR" ]]; then
      git clone -q --depth 1 https://github.com/digininja/DVWA.git "$DVWA_DIR" 2>/dev/null || warn "could not clone DVWA (no internet?)"
    fi
    if [[ -d "$DVWA_DIR" ]]; then
      # config: point DVWA at the local DB
      cp "$DVWA_DIR/config/config.inc.php.dist" "$DVWA_DIR/config/config.inc.php" 2>/dev/null
      sed -i "s/'db_user' ] *= *'[^']*'/'db_user' ]   = 'dvwa'/"      "$DVWA_DIR/config/config.inc.php" 2>/dev/null
      sed -i "s/'db_password' ] *= *'[^']*'/'db_password' ] = 'p@ssw0rd'/" "$DVWA_DIR/config/config.inc.php" 2>/dev/null
      chown -R www-data:www-data "$DVWA_DIR"
      # database + app user
      mysql -e "CREATE DATABASE IF NOT EXISTS dvwa; CREATE USER IF NOT EXISTS 'dvwa'@'localhost' IDENTIFIED BY 'p@ssw0rd'; GRANT ALL ON dvwa.* TO 'dvwa'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null \
        && ok "DVWA database created"
      # allow the classic command-injection / file-inclusion lessons out of the box
      sed -i "s/allow_url_include *= *Off/allow_url_include = On/" /etc/php/*/apache2/php.ini 2>/dev/null
      systemctl restart apache2 >/dev/null 2>&1
      ok "DVWA installed at http://<IP>/dvwa  (login admin/password, set security to 'low')"
      ok "web service runs UNCONFINED (no AppArmor): command injection can 'cat /etc/passwd'"
    fi
  else
    warn "could not install the DVWA stack (no internet? use --no-web to skip)"
  fi
elif [[ $INSTALL_WEB -eq 0 ]]; then
  warn "--no-web: DVWA not installed"
else
  warn "--no-apt: DVWA not installed"
fi

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
# SUID copy of bash in a PERSISTENT path (second escalation vector). Not /tmp, which can be
# wiped on reboot -- and this script recommends a reboot at the end.
cp /bin/bash /usr/local/bin/rootbash 2>/dev/null && chmod 4755 /usr/local/bin/rootbash \
  && ok "/usr/local/bin/rootbash SUID created (escalation: /usr/local/bin/rootbash -p)"

#==============================================================================
# 7) Insecure sudo: NOPASSWD, no log, no pty, infinite timeout
#==============================================================================
step "7) Insecure sudo"
SUDOD=/etc/sudoers.d/90-lab-deharden
# Per-user Defaults (scoped to the trainee) + the NOPASSWD rule. We use a large positive
# timestamp_timeout instead of -1: some sudo builds reject a negative value, and an invalid
# file left in /etc/sudoers.d can break sudo entirely.
cat >"$SUDOD" <<EOF
# DEHARDENING (insecure on purpose)
# trainee: no tty required, credentials cached ~a week (effectively "no re-prompt"), no log
Defaults:${DEMO_USER} !use_pty, timestamp_timeout=9999
${DEMO_USER} ALL=(ALL) NOPASSWD: /usr/bin/find
EOF
chmod 440 "$SUDOD"
# drop sudo logging if it existed
sed -i '/logfile=.*sudo.log/d' /etc/sudoers 2>/dev/null || true
# validate the drop-in itself; if it's invalid, REMOVE it so sudo keeps working
if visudo -cf "$SUDOD" >>"$LOG" 2>&1; then
  ok "weak sudoers: '$DEMO_USER' can 'sudo find' with no password, no log, no pty"
else
  rm -f "$SUDOD"
  warn "sudoers validation failed; removed $SUDOD to keep sudo working (see $LOG)"
fi

#==============================================================================
# 8) Unnecessary / cleartext services and ports (telnet, avahi, cups)
#==============================================================================
step "8) Unnecessary / cleartext services and a vulnerable FTP server"
if [[ $USE_APT -eq 1 ]]; then
  # 'telnetd' on older Ubuntu, 'inetutils-telnetd' on newer -> try both
  if apt-get install -y -qq inetutils-inetd telnetd >/dev/null 2>&1 \
     || apt-get install -y -qq inetutils-inetd inetutils-telnetd >/dev/null 2>&1; then
    systemctl enable --now inetutils-inetd >/dev/null 2>&1
    systemctl restart inetutils-inetd >/dev/null 2>&1   # pick up the telnet inetd.conf line
    ok "telnet server installed and active on 23 (cleartext credentials, demo with tcpdump/hydra)"
  else
    warn "could not install a telnet server (no internet? use --no-apt to skip)"
  fi
else
  warn "--no-apt: telnet server not installed"
fi
systemctl enable --now avahi-daemon >/dev/null 2>&1 && ok "avahi-daemon active (unnecessary service)"
systemctl enable --now cups         >/dev/null 2>&1 && ok "cups active (unnecessary service)"

# --- ProFTPD 1.3.3c: a legacy FTP server with a public exploit, built from source ---
# Not in apt (too old), so we compile it. This teaches the full outdated-software loop:
#   nmap -sV -> "ProFTPD 1.3.3c"  ->  searchsploit/msfconsole  ->  UPDATE (not delete) -> re-test
# The famous backdoor RCE needs the trojaned tarball (set PROFTPD_SRC_URL); see the guide.
if [[ $INSTALL_FTP -eq 1 && $USE_APT -eq 1 ]]; then
  log "Building ProFTPD ${PROFTPD_VERSION} from source (this can take a few minutes)..."
  apt-get install -y -qq build-essential wget ca-certificates >/dev/null 2>&1
  SRC=/usr/local/src
  mkdir -p "$SRC"
  TARBALL="$SRC/proftpd-${PROFTPD_VERSION}.tar.gz"
  # Old ProFTPD releases are not hosted on GitHub and the SourceForge/FTP mirrors often
  # block or interstitial scripted downloads, so the reliable way is to provide the source
  # yourself via PROFTPD_SRC_URL (http(s):// or file://). We still try a couple of public
  # mirrors as a convenience, but will fall back to clear guidance if they fail.
  if [[ -n "$PROFTPD_SRC_URL" ]]; then
    FTP_URLS=("$PROFTPD_SRC_URL")
  else
    FTP_URLS=(
      "https://sourceforge.net/projects/proftpd/files/proftpd/${PROFTPD_VERSION}/proftpd-${PROFTPD_VERSION}.tar.gz/download"
      "ftp://ftp.proftpd.org/historic/release/proftpd-${PROFTPD_VERSION}.tar.gz"
    )
  fi
  dl_ok=0
  for u in "${FTP_URLS[@]}"; do
    log "  trying $u"
    if wget -q --no-check-certificate --timeout=30 --tries=2 "$u" -O "$TARBALL" 2>>"$LOG" && [[ -s "$TARBALL" ]]; then
      dl_ok=1; break
    fi
  done
  if [[ $dl_ok -eq 1 ]]; then
    ( cd "$SRC" && tar xzf "$TARBALL" ) 2>>"$LOG"
    # detect the extracted folder name (GitHub and the official tarball differ slightly)
    PDIR="$SRC/$(tar tzf "$TARBALL" 2>/dev/null | head -1 | cut -d/ -f1)"
    if [[ -d "$PDIR" ]]; then
      # -fcommon / implicit-decl flags let this 2010-era code build on modern gcc
      if [[ -f "$PDIR/configure" ]]; then
        ( cd "$PDIR" \
            && ./configure --prefix=/usr/local/proftpd CFLAGS="-fcommon -Wno-implicit-function-declaration" >>"$LOG" 2>&1 \
            && make -j"$(nproc)" >>"$LOG" 2>&1 \
            && make install >>"$LOG" 2>&1 )
      else
        warn "ProFTPD source has no ./configure script; set PROFTPD_SRC_URL to an official release tarball"
      fi
      if [[ -x /usr/local/proftpd/sbin/proftpd ]]; then
        # minimal standalone config on port 21 with an 'ftpuser' login
        id ftpuser >/dev/null 2>&1 || useradd -m -s /bin/bash ftpuser
        echo 'ftpuser:ftp123' | chpasswd
        cat >/usr/local/proftpd/etc/proftpd.conf <<'PFTP'
ServerName "Lab FTP"
ServerType standalone
Port 21
User nobody
Group nogroup
DefaultRoot ~
<Limit LOGIN>
  AllowAll
</Limit>
PFTP
        cat >/etc/systemd/system/proftpd-lab.service <<'UNIT'
[Unit]
Description=Vulnerable lab ProFTPD 1.3.3c
After=network.target
[Service]
Type=forking
ExecStart=/usr/local/proftpd/sbin/proftpd -c /usr/local/proftpd/etc/proftpd.conf
Restart=no
[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable --now proftpd-lab >/dev/null 2>&1 \
          && ok "ProFTPD ${PROFTPD_VERSION} running on port 21 (login ftpuser/ftp123; nmap -sV shows the version)" \
          || warn "ProFTPD built but the service failed to start; check $LOG"
      else
        warn "ProFTPD did not compile on this system; check $LOG (use --no-ftp to skip)"
      fi
    else
      warn "could not unpack the ProFTPD source"
    fi
  else
    warn "could not download ProFTPD from the public mirrors (see $LOG)."
    warn "Provide the source yourself and re-run, e.g.:"
    warn "  sudo PROFTPD_SRC_URL=file:///root/proftpd-${PROFTPD_VERSION}.tar.gz ./deharden-ubuntu.sh --ftp"
  fi
elif [[ $INSTALL_FTP -eq 0 ]]; then
  log "ProFTPD module skipped (opt-in). Enable with --ftp and PROFTPD_SRC_URL. See docs/ubuntu-desktop.md (row 8b)."
else
  warn "--no-apt: ProFTPD not built"
fi

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
     5. AppArmor disabled + DVWA web app (unconfined; reads /etc/passwd via web flaw)
     6. /etc/shadow world-readable; SUID on find and /usr/local/bin/rootbash
     7. sudo: $DEMO_USER with NOPASSWD find, no log, no pty
     8. Extra services: telnet (cleartext), avahi, cups (+ vulnerable ProFTPD if run with --ftp)
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
