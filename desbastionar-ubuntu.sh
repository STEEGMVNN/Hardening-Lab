#!/usr/bin/env bash
#===============================================================================
#  UD05 · Bastionado de servidores — SCRIPT DE DESBASTIONADO (Ubuntu Desktop)
#  Máster en Ciberseguridad · U-TAD · Material docente de laboratorio
#-------------------------------------------------------------------------------
#  QUÉ HACE: deja un Ubuntu Desktop (24.04/22.04) DELIBERADAMENTE INSEGURO,
#  deshaciendo los controles de bastionado de la UD05, para que en clase se
#  vaya rebastionando paso a paso. Cada debilidad que introduce se corresponde
#  con una medida de la chuleta de comandos y con la guía de desbastionado.
#
#  ⚠  USO EXCLUSIVO EN LA VM DE LABORATORIO AISLADA (red Host-Only) Y CON
#     SNAPSHOT DE INSTALACIÓN FRESCA. No ejecutar NUNCA en un equipo real ni
#     conectado a una red de producción. Para volver al estado seguro: restaura
#     la snapshot de la VM.
#
#  USO:   sudo ./desbastionar-ubuntu.sh [-y] [--no-apt]
#           -y        no pedir confirmación (modo desatendido)
#           --no-apt  no intentar instalar paquetes (telnetd, etc.) por apt
#
#  Copias de seguridad de los ficheros modificados en: /root/desbastionado-backups-<fecha>
#  Registro de todo lo realizado en:                   /var/log/desbastionado-ud5.log
#===============================================================================
set -u

#------------------------------- parámetros -----------------------------------
ASSUME_YES=0
USE_APT=1
for arg in "$@"; do
  case "$arg" in
    -y|--yes)   ASSUME_YES=1 ;;
    --no-apt)   USE_APT=0 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Argumento desconocido: $arg"; exit 2 ;;
  esac
done

#------------------------------- preliminares ---------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Este script necesita privilegios de root. Ejecútalo con: sudo $0"
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/desbastionado-backups-${TS}"
LOG="/var/log/desbastionado-ud5.log"
mkdir -p "$BACKUP_DIR"

# Usuario de demostración de bajo privilegio (objetivo de escalada en clase)
DEMO_USER="becario"
DEMO_PASS="123456"        # contraseña débil a propósito
ROOT_PASS="toor"          # contraseña de root débil para la demo de SSH

C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_RST=$'\e[0m'

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
step() { echo; echo "${C_YEL}===== $* =====${C_RST}" | tee -a "$LOG"; }
ok()  { echo "   ${C_GRN}[hecho]${C_RST} $*" | tee -a "$LOG"; }
warn(){ echo "   ${C_RED}[aviso]${C_RST} $*" | tee -a "$LOG"; }

backup() {  # backup <fichero>
  local f="$1"
  if [[ -e "$f" ]]; then
    local dest="${BACKUP_DIR}${f}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$f" "$dest" 2>/dev/null && ok "copia de seguridad de $f"
  fi
}

#------------------------------- banner ---------------------------------------
cat <<BANNER
${C_RED}
################################################################################
#          UD05 · DESBASTIONADO de Ubuntu Desktop  (material de laboratorio)   #
#                                                                              #
#  Este script va a DEBILITAR la seguridad de ESTA máquina a propósito.        #
#  Ejecútalo SOLO en la VM de laboratorio aislada y con snapshot fresca.       #
#  Para recuperar el estado seguro: restaura la snapshot de la VM.             #
################################################################################
${C_RST}
BANNER

if [[ $ASSUME_YES -ne 1 ]]; then
  read -r -p "Escribe 'DESBASTIONAR' para continuar: " ans
  [[ "$ans" == "DESBASTIONAR" ]] || { echo "Cancelado."; exit 0; }
fi

log "=== Inicio del desbastionado UD05 (Ubuntu) $TS ==="
log "Copias de seguridad en: $BACKUP_DIR"

#==============================================================================
# 1) SSH — permitir root, contraseñas vacías, sin límite de intentos, cifrado débil
#==============================================================================
step "1) SSH débil (openssh-server)"
if ! dpkg -s openssh-server >/dev/null 2>&1; then
  if [[ $USE_APT -eq 1 ]]; then
    log "Instalando openssh-server..."
    apt-get update -qq && apt-get install -y -qq openssh-server || warn "no se pudo instalar openssh-server (¿sin internet?)"
  else
    warn "openssh-server no instalado y --no-apt activo; saltando instalación"
  fi
fi
SSHD=/etc/ssh/sshd_config
if [[ -f "$SSHD" ]]; then
  backup "$SSHD"
  # quitar directivas de bastionado previas y escribir las débiles
  sed -i -E '/^\s*(PermitRootLogin|PermitEmptyPasswords|PasswordAuthentication|MaxAuthTries|AllowGroups|AllowUsers|X11Forwarding|AllowTcpForwarding|Ciphers|MACs|KexAlgorithms|LoginGraceTime|ClientAliveInterval)\b/d' "$SSHD"
  cat >>"$SSHD" <<'EOF'

# --- UD05 DESBASTIONADO (inseguro a propósito) ---
PermitRootLogin yes
PermitEmptyPasswords yes
PasswordAuthentication yes
MaxAuthTries 100
X11Forwarding yes
AllowTcpForwarding yes
LoginGraceTime 120
# cifrados/KEX heredados y débiles (demostración de downgrade)
Ciphers aes128-cbc,3des-cbc,aes256-cbc
KexAlgorithms diffie-hellman-group1-sha1,diffie-hellman-group14-sha1
MACs hmac-md5,hmac-sha1
EOF
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1
  systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1
  ok "sshd_config debilitado: root permitido, sin límite de intentos, cifrado heredado"
else
  warn "no existe $SSHD (openssh-server no instalado)"
fi

#==============================================================================
# 2) Cuentas y contraseñas débiles (root y usuario de bajo privilegio)
#==============================================================================
step "2) Cuentas y contraseñas débiles"
if ! id "$DEMO_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$DEMO_USER" && ok "creado usuario de demo '$DEMO_USER'"
fi
echo "${DEMO_USER}:${DEMO_PASS}" | chpasswd && ok "'$DEMO_USER' con contraseña débil '$DEMO_PASS'"
echo "root:${ROOT_PASS}" | chpasswd && ok "root con contraseña débil '$ROOT_PASS' (para la demo de hydra por SSH)"
passwd -u root >/dev/null 2>&1 || true

#==============================================================================
# 3) Políticas de contraseñas y hash: pwquality laxo, SIN faillock, hash MD5
#==============================================================================
step "3) Políticas de contraseñas y hashing débiles (PAM)"
PWQ=/etc/security/pwquality.conf
backup "$PWQ"
cat >"$PWQ" <<'EOF'
# UD05 DESBASTIONADO: sin requisitos de complejidad
minlen = 1
minclass = 0
dcredit = 0
ucredit = 0
ocredit = 0
lcredit = 0
EOF
ok "pwquality laxo (minlen=1, sin complejidad)"

# quitar faillock de common-auth / common-account (bloqueo por intentos)
for f in /etc/pam.d/common-auth /etc/pam.d/common-account; do
  if [[ -f "$f" ]]; then
    backup "$f"
    sed -i '/pam_faillock/d'  "$f" && true
    sed -i '/pam_tally2/d'    "$f" && true
    ok "faillock/tally eliminado de $f (sin bloqueo por intentos fallidos)"
  fi
done

# hash débil (MD5) y caducidad desactivada
LOGINDEFS=/etc/login.defs
if [[ -f "$LOGINDEFS" ]]; then
  backup "$LOGINDEFS"
  sed -i -E 's/^\s*ENCRYPT_METHOD.*/ENCRYPT_METHOD MD5/' "$LOGINDEFS"
  grep -q '^ENCRYPT_METHOD' "$LOGINDEFS" || echo 'ENCRYPT_METHOD MD5' >>"$LOGINDEFS"
  sed -i -E 's/^\s*PASS_MAX_DAYS.*/PASS_MAX_DAYS 99999/' "$LOGINDEFS"
  sed -i -E 's/^\s*PASS_MIN_DAYS.*/PASS_MIN_DAYS 0/' "$LOGINDEFS"
  ok "login.defs: ENCRYPT_METHOD=MD5, caducidad de contraseña desactivada"
fi
# forzar pam_unix a md5 en common-password
CP=/etc/pam.d/common-password
if [[ -f "$CP" ]]; then
  backup "$CP"
  sed -i -E 's/(pam_unix\.so[^\n]*)/\1/; s/sha512/md5/g' "$CP"
  ok "common-password: pam_unix usando md5"
fi

#==============================================================================
# 4) ASLR desactivado
#==============================================================================
step "4) ASLR desactivado"
backup /etc/sysctl.conf
sed -i '/kernel.randomize_va_space/d' /etc/sysctl.conf
echo 'kernel.randomize_va_space = 0' >>/etc/sysctl.conf
sysctl -w kernel.randomize_va_space=0 >/dev/null && ok "kernel.randomize_va_space = 0"

#==============================================================================
# 5) AppArmor desactivado (perfiles en modo queja / servicio parado)
#==============================================================================
step "5) AppArmor desactivado"
if command -v aa-complain >/dev/null 2>&1; then
  aa-complain /etc/apparmor.d/* >/dev/null 2>&1 && ok "perfiles AppArmor en modo 'complain'"
fi
systemctl stop apparmor   >/dev/null 2>&1 && ok "servicio apparmor parado"
systemctl disable apparmor >/dev/null 2>&1 && ok "servicio apparmor deshabilitado en el arranque"

#==============================================================================
# 6) Permisos de ficheros sensibles y binario SUID (GTFOBins)
#==============================================================================
step "6) Permisos débiles y SUID explotable"
backup /etc/shadow
chmod 644 /etc/shadow && ok "/etc/shadow legible por todos (hashes expuestos a 'john')"
# SUID sobre find -> escalada GTFOBins:  find . -exec /bin/sh -p \; -quit
if [[ -x /usr/bin/find ]]; then
  chmod u+s /usr/bin/find && ok "SUID añadido a /usr/bin/find (escalada vía GTFOBins)"
fi
# copia de bash SUID en /tmp (segundo vector de escalada)
cp /bin/bash /tmp/rootbash 2>/dev/null && chmod 4755 /tmp/rootbash && ok "/tmp/rootbash SUID creado (escalada: /tmp/rootbash -p)"

#==============================================================================
# 7) sudo inseguro: NOPASSWD, sin log, sin pty, timeout infinito
#==============================================================================
step "7) sudo inseguro"
SUDOD=/etc/sudoers.d/90-ud05-desbastionado
cat >"$SUDOD" <<EOF
# UD05 DESBASTIONADO (inseguro a propósito)
Defaults !use_pty
Defaults timestamp_timeout=-1
# el becario puede ejecutar find como root sin contraseña -> GTFOBins
${DEMO_USER} ALL=(ALL) NOPASSWD: /usr/bin/find
EOF
chmod 440 "$SUDOD"
# quitar el registro de sudo si existía
sed -i '/logfile=.*sudo.log/d' /etc/sudoers 2>/dev/null || true
if visudo -cf /etc/sudoers >/dev/null 2>&1; then
  ok "sudoers débil: '$DEMO_USER' puede 'sudo find' sin contraseña, sin log, sin pty"
else
  warn "la validación de sudoers falló; revisa $SUDOD"
fi

#==============================================================================
# 8) Servicios/puertos innecesarios y en claro (telnet, avahi, cups)
#==============================================================================
step "8) Servicios innecesarios y en texto plano"
if [[ $USE_APT -eq 1 ]]; then
  apt-get install -y -qq telnetd inetutils-inetd >/dev/null 2>&1 \
    && { systemctl enable --now inetutils-inetd >/dev/null 2>&1; ok "telnetd instalado y activo (credenciales en claro, demo con tcpdump/hydra)"; } \
    || warn "no se pudo instalar telnetd (¿sin internet? usa --no-apt para omitir)"
else
  warn "--no-apt: no se instala telnetd"
fi
systemctl enable --now avahi-daemon >/dev/null 2>&1 && ok "avahi-daemon activo (servicio innecesario)"
systemctl enable --now cups         >/dev/null 2>&1 && ok "cups activo (servicio innecesario)"

#==============================================================================
# 9) Firewall desactivado
#==============================================================================
step "9) Firewall desactivado"
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable >/dev/null 2>&1 && ok "ufw deshabilitado"
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
  iptables -F 2>/dev/null
  ok "iptables: todas las cadenas en ACCEPT y reglas vaciadas"
fi

#==============================================================================
# 10) Red: ip_forward y redirects activados (pivote/MITM)
#==============================================================================
step "10) Reenvío de red y redirects activados"
sed -i -E '/net.ipv4.(ip_forward|conf.all.send_redirects|conf.all.accept_redirects)/d' /etc/sysctl.conf
cat >>/etc/sysctl.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 1
net.ipv4.conf.all.accept_redirects = 1
EOF
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.send_redirects=1 >/dev/null
sysctl -w net.ipv4.conf.all.accept_redirects=1 >/dev/null
ok "ip_forward=1 y redirects activados (el host puede pivotar/MITM)"

#==============================================================================
# 11) Auditoría y registro desactivados
#==============================================================================
step "11) Auditoría y logs desactivados"
systemctl stop auditd    >/dev/null 2>&1 && ok "auditd parado"
systemctl disable auditd >/dev/null 2>&1 || true
# desactivar reenvío remoto de rsyslog si estuviera configurado
if [[ -f /etc/rsyslog.d/60-remoto.conf ]]; then
  backup /etc/rsyslog.d/60-remoto.conf
  mv /etc/rsyslog.d/60-remoto.conf "${BACKUP_DIR}/60-remoto.conf.off" && ok "reenvío remoto de rsyslog desactivado"
fi

#==============================================================================
# 12) Actualizaciones automáticas desactivadas
#==============================================================================
step "12) Actualizaciones automáticas desactivadas"
AUTOUP=/etc/apt/apt.conf.d/20auto-upgrades
backup "$AUTOUP"
cat >"$AUTOUP" <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
systemctl disable --now unattended-upgrades >/dev/null 2>&1 || true
ok "unattended-upgrades desactivado"

#------------------------------- resumen --------------------------------------
step "RESUMEN"
cat <<RES | tee -a "$LOG"

   El sistema ha quedado DESBASTIONADO. Debilidades introducidas:
     1. SSH: root permitido, contraseñas vacías, 100 intentos, cifrado heredado
     2. Cuentas: root/'$ROOT_PASS' y $DEMO_USER/'$DEMO_PASS' (débiles)
     3. Contraseñas: sin complejidad, sin faillock, hash MD5
     4. ASLR desactivado
     5. AppArmor desactivado
     6. /etc/shadow legible por todos; SUID en find y /tmp/rootbash
     7. sudo: $DEMO_USER con NOPASSWD find, sin log, sin pty
     8. Servicios de más: telnet (claro), avahi, cups
     9. Firewall (ufw/iptables) desactivado
    10. ip_forward y redirects activados
    11. auditd y reenvío de logs desactivados
    12. Actualizaciones automáticas desactivadas

   Copias de seguridad: $BACKUP_DIR
   Registro:           $LOG

   ${C_YEL}En clase: id la máquina, lanzad las demos desde Kali y rebastionad
   siguiendo la guía. Entre pruebas, restaurad la snapshot fresca de la VM.${C_RST}

RES
log "=== Fin del desbastionado UD05 (Ubuntu) ==="
echo "Recomendado reiniciar la VM para que todos los cambios surtan efecto: sudo reboot"
