#!/usr/bin/env bash
# =============================================================================
# install-router.sh  —  Dell R630 + Mellanox ConnectX-4 jako router BGP
#
# Instaluje i uruchamia na Debianie 13 (trixie):
#   * VPP 26.06 zbudowany ze źródeł (DPDK + sterownik mlx5), linux-cp, sFlow
#   * BIRD 3 (repo CZ.NIC) w netns "dataplane"
#   * SNMP: snmpd + vpp-snmp-agent (liczniki z VPP dla LibreNMS)
#   * sFlow: hsflowd z modułem VPP (eksport próbek do FastNetMon / kolektora)
#   * strojenie: hugepages, izolacja rdzeni NUMA karty, moduły mlx5, irqbalance
#   * etckeeper: historia zmian /etc w git (commit po każdym etapie)
#   * automatyczny restart VPP i BIRD po awarii + alarm w logu
#   * monitoring RAID (mdadm) i dysków (smartd), SNMP dla LibreNMS
#   * router-monitor: logowanie przeciążeń VPP/CPU w czasie rzeczywistym (styl syslog ASR)
#
#   * firewall tranzytu: /etc/router/firewall.conf + router-fw (ACL w VPP, blokady doraźne, liczniki trafień)
#   * interfejsy: /etc/router/ifaces.conf (VLAN-y, adresy IPv4/IPv6, loopbacki, opisy)
#     + router-ifaces (zmiany różnicowe, odtwarzanie po starcie VPP, wykrywanie rozjazdu)
#
# Nie konfiguruje sesji BGP — to robi drugi skrypt.
#
# Wszystko, co skrypt pobiera, kompiluje i loguje, trafia do:
#   /root/router_install_data/
#     src/      źródła (VPP, host-sflow, vpp-snmp-agent)
#     debs/     zbudowane paczki .deb
#     logs/     install.log + osobny log każdego etapu
#     state/    znaczniki ukończonych etapów (wznawianie po błędzie)
#     backup/   kopie oryginalnych plików systemowych sprzed zmian
#     MANIFEST.txt  raport: co i gdzie zostało zainstalowane / zapisane
#
# Użycie (jako root):
#   ./install-router.sh                            # pełna instalacja / wznowienie
#   ./install-router.sh 0000:82:00.0 0000:82:00.1  # porty podane ręcznie
#   ./install-router.sh --from 7                   # wykonaj ponownie od etapu 7
#   ./install-router.sh --reset                    # zapomnij ukończone etapy
#   ./install-router.sh --check                    # tylko sprawdzenie (po restarcie)
#   ./install-router.sh --reboot                   # po udanej instalacji od razu restart serwera
#   ./install-router.sh --audit                    # tylko audyt sprzętu/BIOS i zalecenia, bez zmian
#   ./install-router.sh --yes                      # bez pytań (instalacja nienadzorowana)
#   ./install-router.sh upgrade_script             # tylko aktualizacja programów routera (bez restartu VPP/BIRD)
#   ./install-router.sh upgrade_script --dry-run   # pokaż, co by się zmieniło, bez zapisywania
#   ./install-router.sh --version                  # wersja skryptu i wersja zainstalowana na routerze
#
# Po instalacji: dokumentacja /opt/router/README.md, kontrola stanu: router-check
#
# Po błędzie: usuń przyczynę i uruchom ponownie TO SAMO polecenie.
# Ukończone etapy zostaną pominięte, skrypt wznowi pracę od etapu z błędem.
#
# Adres PCI portów:  lspci -D | grep -i mellanox
# =============================================================================
set -Euo pipefail

SCRIPT_VERSION="1.3.0"         # wersja skryptu; podbij przy każdej zmianie programów (upgrade_script porównuje treść plików)
# ============================ USTAWIENIA =====================================
NIC_PCI_DEFAULT="0000:82:00.0 0000:82:00.1" # porty Mellanox, które przejmie VPP
VPP_VERSION="v26.06"           # tag wydania VPP
VPP_WORKERS=auto               # auto = dobór do rdzeni i modelu karty; albo liczba, np. 12
PORT_MTU=1500                  # MTU portów VPP i VLAN-ów: standard Ethernet (ustawiane przy starcie VPP, przed podniesieniem portu)
ROUTER_ID=""                   # puste = IPv4 interfejsu z trasą domyślną (eth2)
SNMP_COMMUNITY=""              # puste = wygeneruj losowe
SNMP_ALLOW="192.168.80.0/24"   # skąd wolno odpytywać SNMP (IP/prefiks LibreNMS)
SFLOW_COLLECTOR=""             # IP kolektora sFlow (FastNetMon); puste = brak
SFLOW_SAMPLING=10000           # próbkowanie 1:N
VPP_HANG_RESTART=1             # 1 = router-monitor restartuje VPP, gdy ten się zawiesi (30 s bez heartbeat)
HUGEPAGES_2M=auto              # auto = 25% RAM (max 16 GB); albo liczba stron 2 MB, np. 8192
AUTO_NOSMT=1                   # 1 = przy włączonym HT dodaj "nosmt" do kernela
AUTO_CSTATE=1                  # 1 = przy głębokich C-states ogranicz je do C1 w kernelu
PANIC_REBOOT_SEC=10            # restart serwera N s po kernel panic
WATCHDOG_SEC=60                # watchdog sprzętowy: restart po N s całkowitego zawieszenia
# --- powiadomienia e-mail (puste ALERT_EMAILS = bez maili) ---
ALERT_EMAILS=""                # odbiorcy, po przecinku: "noc@firma.pl, dyzurny@firma.pl"
SMTP_HOST=""                   # serwer SMTP, np. smtp.firma.pl
SMTP_PORT=587
SMTP_SECURITY=starttls         # starttls (587) | ssl (465) | none (25)
SMTP_USER=""                   # login SMTP
SMTP_PASS=""                   # hasło SMTP (trafi tylko do /etc/router/notify.conf, tryb 600)
SMTP_FROM=""                   # nadawca, np. router-lodz2@firma.pl
MAIL_MAX_SEV=5                 # wysyłaj poziomy 1..N (1 = krytyczne ... 5 = zakończenia zdarzeń)
MAIL_SEND="CRASH SERVICES BOOT RAID DISKS NIC_FW VPP_STATE VPP_DROPS VPP_LOAD VPP_PUNT SYS_CPU IFACES FIREWALL OTHER"  # co wysyłać (router-notify categories)
MAIL_SEND_CLEAR=yes            # yes = wysyłaj też zakończenia zdarzeń (np. LOAD_NORMAL z czasem trwania)
# --- iDRAC: odczyt ustawień BIOS do audytu (Redfish); puste = audyt wnioskuje z Linuksa ---
IDRAC_HOST=""                  # adres iDRAC, np. 192.168.80.110
IDRAC_USER="root"
IDRAC_PASS=""
# --- narzędzie NVIDIA do firmware karty (pierwszy działający adres) ---
MLXUP_URLS=("https://www.mellanox.com/downloads/firmware/mlxup/4.30.0/SFX/linux_x64/mlxup"
            "https://www.mellanox.com/downloads/firmware/mlxup/4.26.0/SFX/linux_x64/mlxup")
DATA_DIR=/root/router_install_data
REBOOT_AFTER=0                 # 1 = restart serwera po udanej instalacji (albo flaga --reboot)
# =============================================================================

SRC_DIR=$DATA_DIR/src
DEB_DIR=$DATA_DIR/debs
LOG_DIR=$DATA_DIR/logs
STATE_DIR=$DATA_DIR/state
BACKUP_DIR=$DATA_DIR/backup
MAIN_LOG=$LOG_DIR/install.log
MANIFEST=$DATA_DIR/MANIFEST.txt
MAN_DB=$STATE_DIR/manifest.tsv
ENV_FILE=$DATA_DIR/router-install.env
TOTAL_STAGES=23

MODE=install
ASSUME_YES=0
DRY_RUN=0
VERSION_FILE=/etc/router/version
FROM_STAGE=0
RESET=0
PCI_ARGS=()
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive
CUR_STAGE="00 start"

c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_hdr=$'\e[1;36m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
now()  { date '+%F %T'; }
say()  { printf '  %s→%s %s\n' "$c_dim" "$c_off" "$*"; }
ok()   { printf '  %s[OK]%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '  %s[UWAGA]%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '  %s[BŁĄD]%s %s\n' "$c_err" "$c_off" "$*"; exit 1; }

usage() { sed -n '2,/^# =\{20,\}/p' "$0" | grep '^#'; exit 0; }

while (($#)); do
  case "$1" in
    --check)  MODE=check ;;
    --reset)  RESET=1 ;;
    --reboot) REBOOT_AFTER=1 ;;
    --audit)  MODE=audit ;;
    --yes|-y) ASSUME_YES=1 ;;
    upgrade_script|--upgrade-script|--upgrade-scripts) MODE=upgrade ;;
    --dry-run) DRY_RUN=1 ;;
    --version|-V) MODE=version ;;
    --from)   shift; [[ ${1:-} =~ ^[0-9]+$ ]] || { echo "--from wymaga numeru etapu"; exit 1; }; FROM_STAGE=$((10#$1)) ;;
    -h|--help) usage ;;
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:*|[0-9a-fA-F][0-9a-fA-F]:*) PCI_ARGS+=("$1") ;;
    *) echo "Nieznany argument: $1 (zobacz --help)"; exit 1 ;;
  esac
  shift
done

if [[ $MODE == version ]]; then
  echo "install-router.sh: wersja $SCRIPT_VERSION"
  if [[ -f $VERSION_FILE ]]; then sed 's/^/  na routerze: /' "$VERSION_FILE"
  else echo "  na routerze: brak $VERSION_FILE (instalacja sprzed wersjonowania albo router jeszcze nie zainstalowany)"; fi
  exit 0
fi
((DRY_RUN)) && [[ $MODE != upgrade ]] && { echo "--dry-run działa tylko z upgrade_script"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Uruchom jako root."; exit 1; }
mkdir -p "$SRC_DIR" "$DEB_DIR" "$LOG_DIR" "$STATE_DIR" "$BACKUP_DIR"
chmod 700 "$DATA_DIR"
exec > >(tee -a "$MAIN_LOG") 2>&1
((RESET)) && { rm -f "$STATE_DIR"/*.done; echo "Wyzerowano listę ukończonych etapów."; }

# ------------------------------------------------------------------ pomocnicze
expand_cpulist() {   # "1,3,5-9" -> "1 3 5 6 7 8 9"
  local IFS=, part a b i out=()
  for part in $1; do
    if [[ $part == *-* ]]; then a=${part%-*}; b=${part#*-}; for ((i=a; i<=b; i++)); do out+=("$i"); done
    else out+=("$part"); fi
  done
  echo "${out[@]}"
}
join_by() { local IFS="$1"; shift; echo "$*"; }
normalize_pci() { local p="${1,,}"; [[ $p =~ ^[0-9a-f]{4}: ]] || p="0000:$p"; echo "$p"; }
netdev_of() { ls "/sys/bus/pci/devices/$1/net" 2>/dev/null | head -n1 || true; }
bird_unit() {
  local u
  for u in bird.service bird3.service; do
    systemctl list-unit-files "$u" --no-legend 2>/dev/null | grep -q "^$u" && { echo "${u%.service}"; return; }
  done
  echo bird
}

# --- rejestr zmian (MANIFEST) ------------------------------------------------
# rodzaje: file, service, pkg, dir, backup, other
man_add() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$CUR_STAGE" "$3" >>"$MAN_DB"; }

# put_file <ścieżka> <opis> [tryb]  — treść ze stdin; oryginał trafia do backup/
put_file() {
  local path=$1 desc=$2 mode=${3:-644}
  if [[ -e $path && ! -e $BACKUP_DIR$path ]] && ! grep -qxF "$path" "$STATE_DIR/created.list" 2>/dev/null; then
    mkdir -p "$BACKUP_DIR$(dirname "$path")"
    cp -a "$path" "$BACKUP_DIR$path"
    man_add backup "$BACKUP_DIR$path" "oryginał $path sprzed zmian"
    say "kopia oryginału: $BACKUP_DIR$path"
  fi
  mkdir -p "$(dirname "$path")"
  cat >"$path"
  chmod "$mode" "$path"
  grep -qxF "$path" "$STATE_DIR/created.list" 2>/dev/null || echo "$path" >>"$STATE_DIR/created.list"
  man_add file "$path" "$desc"
  say "zapisano $path"
}

# zapis /etc/router/notify.conf (hasło SMTP — tylko root, poza historią etckeeper)
write_notify_conf() {
  mkdir -p /etc/router
  touch /etc/.gitignore
  grep -qxF 'router/notify.conf' /etc/.gitignore || echo 'router/notify.conf' >>/etc/.gitignore
  [[ -d /etc/.git ]] && { git -C /etc rm -q --cached router/notify.conf >/dev/null 2>&1 || true; }
  umask 077
  {
    echo "# Powiadomienia e-mail routera (install-router.sh). Zmiany działają w ciągu 5 s; test: router-notify test"
    echo "# Kategorie: router-notify categories"
    printf 'ALERT_EMAILS="%s"\n' "$ALERT_EMAILS"
    printf 'SMTP_HOST="%s"\n' "$SMTP_HOST"
    printf 'SMTP_PORT=%s\n' "$SMTP_PORT"
    printf 'SMTP_SECURITY=%s\n' "$SMTP_SECURITY"
    printf 'SMTP_USER="%s"\n' "$SMTP_USER"
    printf 'SMTP_PASS="%s"\n' "$SMTP_PASS"
    printf 'SMTP_FROM="%s"\n' "$SMTP_FROM"
    printf 'MAIL_SEND="%s"\n' "$MAIL_SEND"
    printf 'MAIL_SEND_CLEAR=%s\n' "$MAIL_SEND_CLEAR"
    printf 'MAIL_MAX_SEV=%s\n' "$MAIL_MAX_SEV"
    echo "MAIL_MIN_INTERVAL=60"
    echo "MAIL_MAX_PER_HOUR=30"
  } >/etc/router/notify.conf
  umask 022
  chmod 600 /etc/router/notify.conf
}

# --- uruchamianie etapów -----------------------------------------------------
run_stage() {   # run_stage <nr> <nazwa> <funkcja>
  local num=$1 name=$2 fn=$3 slog start rc dur
  slog="$LOG_DIR/$num-$fn.log"
  CUR_STAGE="$num $name"
  if [[ -f $STATE_DIR/$num.done ]] && { ((FROM_STAGE == 0)) || ((10#$num < FROM_STAGE)); }; then
    printf '\n%s[%s] ETAP %s/%s  %s — pominięty (ukończony %s)%s\n' \
      "$c_dim" "$(now)" "$num" "$TOTAL_STAGES" "$name" "$(cat "$STATE_DIR/$num.done")" "$c_off"
    return 0
  fi
  rm -f "$STATE_DIR/$num.done"
  printf '\n%s[%s] ETAP %s/%s  %s%s\n' "$c_hdr" "$(now)" "$num" "$TOTAL_STAGES" "$name" "$c_off"
  printf '  %slog etapu: %s%s\n' "$c_dim" "$slog" "$c_off"
  printf '\n===== [%s] ETAP %s %s =====\n' "$(now)" "$num" "$name" >>"$slog"
  start=$(date +%s)
  (
    set -Eeuo pipefail
    trap 'printf "  %s[BŁĄD]%s polecenie: %s (linia %s)\n" "$c_err" "$c_off" "$BASH_COMMAND" "$LINENO"' ERR
    "$fn"
  ) 2>&1 | tee -a "$slog"
  rc=${PIPESTATUS[0]}
  dur=$(( $(date +%s) - start ))
  if ((rc == 0)); then
    now >"$STATE_DIR/$num.done"
    if [[ -d /etc/.git ]] && command -v etckeeper >/dev/null; then
      etckeeper commit "install-router.sh: etap $num $name" >/dev/null 2>&1 || true
    fi
    printf '%s[%s] ETAP %s/%s  %s — ZAKOŃCZONY POMYŚLNIE (%dm%02ds)%s\n' \
      "$c_ok" "$(now)" "$num" "$TOTAL_STAGES" "$name" $((dur / 60)) $((dur % 60)) "$c_off"
  else
    printf '\n%s[%s] ETAP %s/%s  %s — BŁĄD (kod %s, po %dm%02ds)%s\n' \
      "$c_err" "$(now)" "$num" "$TOTAL_STAGES" "$name" "$rc" $((dur / 60)) $((dur % 60)) "$c_off"
    printf '%s----- ostatnie linie logu etapu (%s) -----%s\n' "$c_err" "$slog" "$c_off"
    tail -n 25 "$slog"
    cat <<EOF
${c_err}-----------------------------------------------------------------${c_off}
Co dalej:
  1. Przeczytaj log etapu:  less $slog
  2. Usuń przyczynę (np. brak internetu, brak miejsca, błąd w ustawieniach).
  3. Uruchom ponownie to samo polecenie:  $0 ${PCI_ARGS[*]}
     Ukończone etapy zostaną pominięte, praca wznowi się od etapu $num.
  Wymuszenie powtórki od wybranego etapu:  $0 --from <nr>
EOF
    exit "$rc"
  fi
}

if ((${#PCI_ARGS[@]})); then NIC_PCI=("${PCI_ARGS[@]}")
elif [[ $MODE == check || $MODE == upgrade ]] && [[ -f /etc/router/router.env ]]; then
  read -ra NIC_PCI <<<"$(sed -n 's/^INST_NIC_PCI="\(.*\)"$/\1/p' /etc/router/router.env)"
  ((${#NIC_PCI[@]})) || read -ra NIC_PCI <<<"$NIC_PCI_DEFAULT"
else read -ra NIC_PCI <<<"$NIC_PCI_DEFAULT"; fi
for i in "${!NIC_PCI[@]}"; do NIC_PCI[$i]=$(normalize_pci "${NIC_PCI[$i]}"); done

# =============================================================================
# PROGRAMY routera (/opt/router/bin) — jedno źródło treści dla instalacji i dla upgrade_script
# =============================================================================
prog_router_fw_update() {
  local bdf=${NIC_PCI[0]#0000:} fdir=$DATA_DIR/firmware
  cat <<EOF
#!/bin/bash
# router-fw-update — aktualizacja firmware karty Mellanox/NVIDIA. Uruchamiaj RĘCZNIE, w oknie serwisowym.
#   router-fw-update            pokaż obecną i dostępną wersję, potem zapytaj o aktualizację
#   router-fw-update --online   użyj najnowszego firmware z serwera NVIDIA (zamiast obrazu w mlxup)
#   router-fw-update --check    tylko pokaż wersje
# Nowy firmware zadziała dopiero po restarcie serwera (do tego czasu karta pracuje na starym).
set -uo pipefail
BDF="$bdf"
FWDIR="$fdir"
MLXUP="\$FWDIR/mlxup"
URLS=(${MLXUP_URLS[*]})
LOG=/var/log/router-monitor/router-monitor.log
ONLINE=""; CHECK=0
for a in "\$@"; do case \$a in --online) ONLINE=--online ;; --check) CHECK=1 ;; *) echo "nieznana opcja: \$a"; exit 2 ;; esac; done
[[ \$EUID -eq 0 ]] || { echo "Uruchom jako root."; exit 1; }
if [[ ! -x \$MLXUP ]]; then
  for u in "\${URLS[@]}"; do curl -fsSL -o "\$MLXUP" "\$u" && chmod 755 "\$MLXUP" && break; done
fi
[[ -x \$MLXUP ]] || { echo "Brak mlxup i nie udało się go pobrać."; exit 1; }
psid=\$(mstflint -d "\$BDF" q 2>/dev/null | sed -n 's/^PSID: *//p')
echo "Karta \$BDF, PSID \${psid:-?}"
if [[ \$psid == DEL* ]]; then echo "To karta z firmware Della — zaktualizuj ją pakietem z dell.com/support."; exit 1; fi
"\$MLXUP" -d "\$BDF" \$ONLINE --query | tee "\$FWDIR/query-\$(date +%F-%H%M).txt"
((CHECK)) && exit 0
echo
echo "UWAGA: zapis firmware trwa kilka minut. Nie wyłączaj serwera w trakcie."
echo "Router działa dalej na starym firmware; nowy zadziała po restarcie (krótka przerwa w ruchu)."
read -rp "Wpisz TAK, aby zaktualizować: " ans
[[ \$ans == TAK ]] || { echo "Przerwano."; exit 0; }
bk="\$FWDIR/backup-\${psid}-\$(date +%F-%H%M).bin"
mstflint -d "\$BDF" ri "\$bk" >/dev/null 2>&1 && echo "Kopia obecnego firmware: \$bk"
if "\$MLXUP" -d "\$BDF" \$ONLINE -u -y; then
  new=\$(mstflint -d "\$BDF" q 2>/dev/null | sed -n 's/^FW Version: *//p')
  msg="%SYS-5-NIC_FW_UPDATED: firmware karty \$BDF zapisany (\${new:-?}), aktywny po restarcie serwera"
  echo "\$msg"
  printf '%s %s\n' "\$(date '+%F %T')" "\$msg" >>"\$LOG"
  /opt/router/bin/router-notify queue "\$msg" >/dev/null 2>&1 || true
  echo "Zaplanuj restart serwera: systemctl reboot"
else
  msg="%SYS-3-NIC_FW_FAIL: aktualizacja firmware karty \$BDF nie powiodła się"
  echo "\$msg"; printf '%s %s\n' "\$(date '+%F %T')" "\$msg" >>"\$LOG"
  /opt/router/bin/router-notify queue "\$msg" >/dev/null 2>&1 || true
  exit 1
fi
EOF
}

prog_router_alert() {
  cat <<'EOF'
#!/bin/sh
# router-alert <usługa> <SERVICE_RESULT> <EXIT_CODE> <EXIT_STATUS>
# Wywoływany przez systemd (ExecStopPost / OnFailure). Normalne zatrzymanie = cisza.
unit="$1"; result="${2:-unknown}"; code="${3:-}"; status="${4:-}"
[ "$result" = "success" ] && exit 0
if [ "$result" = "limit" ]; then
  msg="%SYS-1-SERVICE_DOWN: $unit nie wstaje po wielu próbach restartu — wymagana interwencja"
else
  msg="%SYS-2-SERVICE_FAIL: $unit zakończył się nieoczekiwanie (result=$result code=$code status=$status) — automatyczny restart"
fi
logger -t router-alert -p local0.crit "$msg"
mkdir -p /var/log/router-monitor
printf '%s %s\n' "$(date '+%F %T')" "$msg" >>/var/log/router-monitor/router-monitor.log
/opt/router/bin/router-notify queue "$msg" >/dev/null 2>&1 || true
EOF
}

prog_router_ifaces() {
  cat <<'RIFEOF'
#!/usr/bin/env python3
"""router-ifaces — interfejsy VPP (porty, VLAN-y, loopbacki) z pliku /etc/router/ifaces.conf

  router-ifaces              pokaż interfejsy: stan w VPP, adresy, opisy (jak "show interfaces description")
  router-ifaces diff         pokaż, co zmieni się w VPP po zastosowaniu ifaces.conf (niczego nie zmienia)
  router-ifaces apply        zastosuj ifaces.conf: dodaje / usuwa / zmienia tylko różnice (pyta; -y bez pytania)
  router-ifaces check        porównaj VPP z ostatnio zastosowaną konfiguracją (wykrywanie rozjazdu)
  router-ifaces render       wypisz pełną konfigurację jako polecenia vppctl
  router-ifaces boot         (systemd) po starcie VPP odtwórz konfigurację
  router-ifaces snmp         odtwórz plik opisów dla SNMP (/etc/router/snmp-ifaces.yaml) bez dotykania VPP

Plik ifaces.conf jest jedynym źródłem prawdy: adres usunięty z pliku znika z VPP,
VLAN usunięty z pliku jest kasowany, zmiana opisu trafia do SNMP (ifAlias) i Linuksa.
Obiektów utworzonych ręcznie (vppctl), których nigdy nie było w pliku, skrypt nie rusza.
"""
import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time

ROOT = os.environ.get("ROUTER_IFACES_ROOT", "")      # tylko do testów
CONF = ROOT + "/etc/router/ifaces.conf"
LASTGOOD = ROOT + "/var/lib/router/ifaces.last-good.conf"
STATE = ROOT + "/var/lib/router/ifaces.state.json"
SNMP_YAML = ROOT + "/etc/router/snmp-ifaces.yaml"
ENVF = ROOT + "/etc/router/router.env"
LOGDIR = ROOT + "/var/log/router-monitor"
LOG = LOGDIR + "/router-ifaces.log"
MONLOG = LOGDIR + "/router-monitor.log"
LOCK = ROOT + "/run/router-ifaces.lock"
NOTIFY = ROOT + "/opt/router/bin/router-notify"
NETNS = "dataplane"
VPPCTL = os.environ.get("ROUTER_IFACES_VPPCTL", "vppctl")
IPCMD = os.environ.get("ROUTER_IFACES_IP", "ip")
SYSTEMD = os.environ.get("ROUTER_IFACES_SYSTEMD", "1") == "1"

ERR_RE = re.compile(r"unknown input|error|fail|invalid|conflict|not found|already|does not exist|not supported",
                    re.I)
TTY = sys.stdout.isatty()


def color(s, c):
    return "\033[%sm%s\033[0m" % (c, s) if TTY else s


# --------------------------------------------------------------------------- logi
def now():
    return time.strftime("%F %T")


def log(msg):
    try:
        os.makedirs(LOGDIR, exist_ok=True)
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (now(), msg))
    except OSError:
        pass


def event(sev, mnem, text, mail=True):
    """Zdarzenie w stylu Cisco: log router-monitor + syslog + (opcjonalnie) e-mail."""
    line = "%%IFACE-%d-%s: %s" % (sev, mnem, text)
    log(line)
    try:
        os.makedirs(LOGDIR, exist_ok=True)
        with open(MONLOG, "a") as f:
            f.write("%s %s\n" % (now(), line))
    except OSError:
        pass
    prio = {1: "alert", 2: "crit", 3: "err", 4: "warning", 5: "notice"}.get(sev, "info")
    subprocess.run(["logger", "-t", "router-ifaces", "-p", "local0." + prio, line],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if mail and os.access(NOTIFY, os.X_OK):
        subprocess.run([NOTIFY, "queue", line], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return line


# --------------------------------------------------------------------------- plik ifaces.conf
class Entry:
    def __init__(self, name, kind, lineno=0, parent=None, vlan=None, implicit=False):
        self.name, self.kind, self.lineno = name, kind, lineno
        self.parent, self.vlan, self.implicit = parent, vlan, implicit
        self.v4, self.v6, self.desc = [], [], ""

    @property
    def addrs(self):
        return set(self.v4) | set(self.v6)

    def order(self):
        k = {"phy": 0, "loop": 1, "vlan": 2}[self.kind]
        return (k, self.parent or self.name, self.vlan or 0, natkey(self.name))


def natkey(s):
    return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", s)]


def addr_key(a):
    return (a.version, a.ip, a.network.prefixlen)


def known_phys():
    """Porty fizyczne: z VPP (jeśli działa), inaczej z /etc/router/router.env (hu0..huN)."""
    try:
        st = read_vpp()
        phys = {n for n in st.ifaces if "." not in n and n != "local0"
                and not n.startswith(("loop", "tap", "tun", "lcp"))}
        if phys:
            return phys
    except VppError:
        pass
    try:
        with open(ENVF) as f:
            m = re.search(r'^INST_NIC_PCI="([^"]*)"', f.read(), re.M)
        if m and m.group(1).split():
            return {"hu%d" % i for i in range(len(m.group(1).split()))}
    except OSError:
        pass
    return None


def parse_conf(text, phys=None):
    """Zwraca (dict nazwa->Entry, błędy, ostrzeżenia). Błąd = nic nie zostanie zastosowane."""
    ents, errs, warns = {}, [], []
    for no, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        t = line.split(None, 4)
        where = "linia %d" % no
        if len(t) < 4:
            errs.append("%s: za mało kolumn (interfejs vlan ipv4 ipv6 [opis]): %s" % (where, line))
            continue
        ifc, vlan, c4, c6 = t[:4]
        rest = t[4] if len(t) > 4 else ""
        if re.match(r"^mtu=", rest, re.I):
            errs.append("%s: MTU nie ustawia się w ifaces.conf — wszystkie interfejsy mają standardowe "
                        "MTU Ethernet 1500 (usuń '%s')" % (where, rest.split()[0]))
            continue
        desc = rest.strip()
        if desc in ("-", '""', "''"):
            desc = ""
        if len(desc) > 200:
            errs.append("%s: opis dłuższy niż 200 znaków" % where)
        lm = re.match(r"^loop(\d{1,4})$", ifc)
        if lm:
            if vlan != "-":
                errs.append("%s: loopback %s nie może mieć VLAN-u (wpisz -)" % (where, ifc))
                continue
            e = Entry(ifc, "loop", no)
        else:
            if not re.match(r"^[A-Za-z][A-Za-z0-9/_-]*$", ifc):
                errs.append("%s: niepoprawna nazwa interfejsu '%s'" % (where, ifc))
                continue
            if phys is not None and ifc not in phys:
                errs.append("%s: port '%s' nie istnieje w VPP (dostępne: %s)"
                            % (where, ifc, ", ".join(sorted(phys, key=natkey)) or "brak"))
                continue
            if vlan == "-":
                e = Entry(ifc, "phy", no)
            else:
                if not vlan.isdigit() or not 1 <= int(vlan) <= 4094:
                    errs.append("%s: VLAN '%s' poza zakresem 1-4094" % (where, vlan))
                    continue
                v = int(vlan)
                e = Entry("%s.%d" % (ifc, v), "vlan", no, parent=ifc, vlan=v)
        if len(e.name) > 15:
            errs.append("%s: nazwa %s ma ponad 15 znaków (limit nazw w Linuksie)" % (where, e.name))
            continue
        if e.name in ents and not ents[e.name].implicit:
            errs.append("%s: %s zdefiniowany ponownie (pierwszy raz w linii %d)"
                        % (where, e.name, ents[e.name].lineno))
            continue
        e.desc = desc
        for col, ver, lst in ((c4, 4, e.v4), (c6, 6, e.v6)):
            if col == "-":
                continue
            for a in col.split(","):
                a = a.strip()
                if not a:
                    continue
                try:
                    ia = ipaddress.ip_interface(a)
                except ValueError:
                    errs.append("%s: niepoprawny adres '%s'" % (where, a))
                    continue
                if "/" not in a:
                    errs.append("%s: adres %s bez maski (np. %s/%d)" % (where, a, a, 32 if ver == 4 else 128))
                    continue
                if ia.version != ver:
                    errs.append("%s: adres %s w kolumnie IPv%d" % (where, a, ver))
                    continue
                if ia.ip.is_multicast or ia.ip.is_unspecified or ia.ip.is_loopback or \
                        (ver == 6 and ia.ip.is_link_local):
                    errs.append("%s: adres %s nie może być przypisany do interfejsu" % (where, a))
                    continue
                edge = (ia.network.network_address, ia.network.broadcast_address)
                if ver == 4 and ia.network.prefixlen <= 30 and ia.ip in edge:
                    errs.append("%s: %s to adres sieci lub rozgłoszeniowy podsieci %s" % (where, a, ia.network))
                    continue
                if ia in lst:
                    warns.append("%s: adres %s podany dwa razy" % (where, a))
                    continue
                lst.append(ia)
        ents[e.name] = e
        if e.kind == "vlan" and e.parent not in ents:
            ents[e.parent] = Entry(e.parent, "phy", 0, implicit=True)
    # kontrola krzyżowa adresów: VPP nie pozwala na te same / nakładające się podsieci na różnych interfejsach
    seen = []
    for e in ents.values():
        for a in sorted(e.addrs, key=addr_key):
            for (n2, a2) in seen:
                if a.version != a2.version:
                    continue
                if a.ip == a2.ip:
                    errs.append("adres %s użyty na %s i %s" % (a.ip, n2, e.name))
                elif n2 != e.name and a.network.overlaps(a2.network):
                    errs.append("podsieci nakładają się: %s (%s) i %s (%s) — VPP tego nie przyjmie"
                                % (a, e.name, a2, n2))
            seen.append((e.name, a))
    return ents, errs, warns


def load_conf(path, phys=None):
    try:
        with open(path) as f:
            text = f.read()
    except OSError as ex:
        return None, ["nie można odczytać %s: %s" % (path, ex)], [], ""
    ents, errs, warns = parse_conf(text, phys)
    return ents, errs, warns, text


# --------------------------------------------------------------------------- VPP
class VppError(Exception):
    pass


class Actual:
    def __init__(self):
        self.ifaces = {}   # nazwa -> {"up": bool, "mtu": int|None}
        self.addrs = {}    # nazwa -> set(ip_interface)
        self.lcp = {}      # nazwa VPP -> nazwa w Linuksie (netns dataplane)
        self.alias = {}    # nazwa w Linuksie -> ifalias
        self.laddrs = {}   # nazwa w Linuksie -> set(ip_interface) (adresy globalne)


def cli(cmd, timeout=15):
    try:
        r = subprocess.run([VPPCTL, cmd], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as ex:
        raise VppError("vppctl: %s" % ex)
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0 or "connect" in out.lower() and "fail" in out.lower():
        raise VppError("vppctl '%s': %s" % (cmd, out.strip() or "kod %d" % r.returncode))
    return out


def read_vpp(with_alias=False):
    st = Actual()
    for line in cli("show interface").splitlines():
        if not line.strip() or line[0].isspace():
            continue
        t = line.split()
        if len(t) >= 4 and t[1].isdigit():
            m = t[3].split("/")[0]
            st.ifaces[t[0]] = {"up": t[2] == "up", "mtu": int(m) if m.isdigit() else None}
    if not st.ifaces:
        raise VppError("VPP nie zwrócił listy interfejsów")
    cur = None
    for line in cli("show interface address").splitlines():
        if not line.strip():
            continue
        if not line[0].isspace():
            m = re.match(r"^(\S+)\s+\(", line)
            cur = m.group(1) if m else None
            if cur:
                st.addrs.setdefault(cur, set())
            continue
        t = line.split()
        if cur and len(t) >= 2 and t[0] == "L3":
            try:
                a = ipaddress.ip_interface(t[1])
            except ValueError:
                continue
            if a.version == 6 and a.ip.is_link_local:
                continue
            st.addrs[cur].add(a)
    try:
        for line in cli("show lcp").splitlines():
            t = line.split()
            # itf-pair: [0] hu0 tap4096 hu0 41 type tap netns dataplane
            if len(t) >= 5 and t[0] == "itf-pair:":
                st.lcp[t[2]] = t[4]
    except VppError:
        pass
    if with_alias:
        st.alias, st.laddrs = read_linux()
    return st


def read_linux():
    """Opisy i adresy interfejsów linux-cp w netns dataplane (to, co widzi BIRD)."""
    alias, addrs = {}, {}
    try:
        r = subprocess.run([IPCMD, "-n", NETNS, "-j", "link", "show"], capture_output=True, text=True, timeout=10)
        alias = {x["ifname"]: x.get("ifalias", "") for x in json.loads(r.stdout or "[]")}
        r = subprocess.run([IPCMD, "-n", NETNS, "-j", "addr", "show"], capture_output=True, text=True, timeout=10)
        for x in json.loads(r.stdout or "[]"):
            s = addrs.setdefault(x["ifname"], set())
            for a in x.get("addr_info", []):
                if a.get("family") in ("inet", "inet6") and a.get("scope") == "global":
                    try:
                        s.add(ipaddress.ip_interface("%s/%s" % (a["local"], a["prefixlen"])))
                    except (KeyError, ValueError):
                        pass
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return alias, addrs


def wait_vpp(phys_needed, timeout):
    """Czeka, aż VPP odpowie i pokaże porty."""
    end = time.time() + timeout
    last = "brak odpowiedzi"
    while time.time() < end:
        try:
            st = read_vpp()
            missing = [p for p in phys_needed if p not in st.ifaces]
            if not missing:
                return True
            last = "brak portów: " + ", ".join(missing)
        except VppError as ex:
            last = str(ex)
        time.sleep(2)
    print("VPP niegotowy po %d s: %s" % (timeout, last), file=sys.stderr)
    return False


# --------------------------------------------------------------------------- plan zmian
class Cmd:
    def __init__(self, op, kind, args, why=""):
        self.op, self.kind, self.args, self.why = op, kind, args, why   # op: + - ~

    def text(self):
        if self.kind == "vpp":
            return self.args
        return "ip " + " ".join(shlex.quote(a) for a in self.args)

    def __eq__(self, o):
        return (self.op, self.kind, self.text()) == (o.op, o.kind, o.text())


def plan(desired, act, managed, aliases=True):
    """Lista poleceń, które doprowadzą VPP do stanu z ifaces.conf."""
    cmds = []
    D = desired
    ents = sorted(D.values(), key=Entry.order)
    # 1. adresy do usunięcia (najpierw, żeby adres mógł przejść na inny interfejs)
    for e in ents:
        if e.implicit or e.name not in act.ifaces:
            continue
        for a in sorted(act.addrs.get(e.name, set()) - e.addrs, key=addr_key):
            cmds.append(Cmd("-", "vpp", "set interface ip address del %s %s" % (e.name, a),
                            "adres usunięty z ifaces.conf"))
    # 2. obiekty usunięte z pliku (tylko te, które wcześniej utworzył ten skrypt)
    for name in sorted(set(managed) - set(D), key=natkey):
        kind = managed[name]
        if name not in act.ifaces:
            continue
        for a in sorted(act.addrs.get(name, set()), key=addr_key):
            cmds.append(Cmd("-", "vpp", "set interface ip address del %s %s" % (name, a), "usunięty z ifaces.conf"))
        if kind in ("vlan", "loop"):
            if name in act.lcp:
                cmds.append(Cmd("-", "vpp", "lcp delete %s" % name, "usunięty z ifaces.conf"))
            if kind == "vlan":
                cmds.append(Cmd("-", "vpp", "delete sub-interface %s" % name, "VLAN usunięty z ifaces.conf"))
            else:
                cmds.append(Cmd("-", "vpp", "delete loopback interface intfc %s" % name,
                                "loopback usunięty z ifaces.conf"))
    # 3. porty, loopbacki, VLAN-y
    for e in ents:
        new = e.name not in act.ifaces
        cur = act.ifaces.get(e.name, {})
        if e.kind == "phy":
            if new:
                continue      # nie powinno się zdarzyć (walidacja)
            if e.name not in act.lcp:
                cmds.append(Cmd("+", "vpp", "lcp create %s host-if %s" % (e.name, e.name), "port widoczny w Linuksie"))
            if not cur.get("up"):
                cmds.append(Cmd("+", "vpp", "set interface state %s up" % e.name))
        elif e.kind == "loop":
            if new:
                cmds.append(Cmd("+", "vpp", "create loopback interface instance %s" % e.name[4:], "nowy loopback"))
            if new or not cur.get("up"):
                cmds.append(Cmd("+", "vpp", "set interface state %s up" % e.name))
            if new or e.name not in act.lcp:
                cmds.append(Cmd("+", "vpp", "lcp create %s host-if %s" % (e.name, e.name)))
        else:
            if new:
                cmds.append(Cmd("+", "vpp", "create sub-interfaces %s %d dot1q %d exact-match"
                                % (e.parent, e.vlan, e.vlan), "nowy VLAN %d" % e.vlan))
            if new or not cur.get("up"):
                cmds.append(Cmd("+", "vpp", "set interface state %s up" % e.name))
            # nowy VLAN dostaje parę w Linuksie automatycznie (lcp-auto-subint); brak → utwórz
            if not new and e.name not in act.lcp and e.parent in act.lcp:
                cmds.append(Cmd("+", "vpp", "lcp create %s host-if %s" % (e.name, e.name)))
        # 4. adresy do dodania
        if not e.implicit:
            have = set() if new else act.addrs.get(e.name, set())
            for a in sorted(e.addrs - have, key=addr_key):
                cmds.append(Cmd("+", "vpp", "set interface ip address %s %s" % (e.name, a)))
    # 5. Linux (netns dataplane): adresy i opisy — tylko dla istniejących par linux-cp.
    #    Adresy synchronizuje lcp-sync; tu tylko kontrola i dopięcie, gdy synchronizacja zawiodła
    #    (dopiero gdy VPP ma już właściwe adresy, żeby nie dublować pracy lcp-sync).
    if aliases:
        vpp_pending = {c.args.split()[-2] for c in cmds
                       if c.kind == "vpp" and c.args.startswith("set interface ip address")}
        for e in ents:
            if e.implicit or e.name not in act.lcp or e.name not in act.ifaces:
                continue
            host = act.lcp[e.name]
            if host not in act.alias:
                continue
            if e.name not in vpp_pending and act.addrs.get(e.name, set()) == e.addrs:
                lx = act.laddrs.get(host, set())
                for a in sorted(lx - e.addrs, key=addr_key):
                    cmds.append(Cmd("-", "ip", ["-n", NETNS, "addr", "del", str(a), "dev", host],
                                    "adres tylko w Linuksie (brak synchronizacji)"))
                for a in sorted(e.addrs - lx, key=addr_key):
                    cmds.append(Cmd("+", "ip", ["-n", NETNS, "addr", "add", str(a), "dev", host],
                                    "brak adresu w Linuksie (BIRD go nie widzi)"))
            if act.alias.get(host, "") != e.desc:
                cmds.append(Cmd("~", "ip", ["-n", NETNS, "link", "set", "dev", host, "alias", e.desc], "opis"))
    return cmds


def show_cmds(cmds, prefix="  "):
    for c in cmds:
        col = {"+": "32", "-": "31", "~": "33"}[c.op]
        why = color("   # " + c.why, "2") if c.why else ""
        print(prefix + color("%s %s" % (c.op, c.text()), col) + why)


def run_cmd(c):
    if c.kind == "vpp":
        try:
            out = cli(c.args).strip()
        except VppError as ex:
            return False, str(ex)
        ok = not (out and ERR_RE.search(out))
        return ok, out
    try:
        r = subprocess.run([IPCMD] + c.args, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as ex:
        return False, str(ex)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


# --------------------------------------------------------------------------- stan, SNMP
def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(st):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f, indent=1, sort_keys=True)
    os.replace(tmp, STATE)


def q(s):
    return json.dumps(s, ensure_ascii=False)


def render_snmp_yaml(desired):
    """Plik w formacie vppcfg dla vpp-snmp-agent (-c): opis -> ifAlias w SNMP."""
    out = ["# Wygenerowane przez router-ifaces z /etc/router/ifaces.conf — nie edytuj ręcznie.",
           "# vpp-snmp-agent bierze stąd ifAlias (opis portu w LibreNMS / Cacti)."]
    phys = sorted((e for e in desired.values() if e.kind == "phy"), key=lambda e: natkey(e.name))
    loops = sorted((e for e in desired.values() if e.kind == "loop"), key=lambda e: natkey(e.name))
    out.append("interfaces:" if phys else "interfaces: {}")
    for p in phys:
        out.append("  %s:" % p.name)
        if p.desc:
            out.append("    description: %s" % q(p.desc))
        subs = sorted((e for e in desired.values() if e.kind == "vlan" and e.parent == p.name), key=lambda e: e.vlan)
        if subs:
            out.append("    sub-interfaces:")
            for s in subs:
                out.append("      %d:" % s.vlan)
                out.append("        description: %s" % q(s.desc or s.name))
        if not p.desc and not subs:
            out[-1] += " {}"
    out.append("loopbacks:" if loops else "loopbacks: {}")
    for lp in loops:
        out.append("  %s:" % lp.name)
        out.append("    description: %s" % q(lp.desc or lp.name))
    return "\n".join(out) + "\n"


def write_if_changed(path, text, mode=0o644):
    try:
        with open(path) as f:
            if f.read() == text:
                return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    return True


def restart_snmp_agent():
    if SYSTEMD:
        subprocess.run(["systemctl", "try-restart", "vpp-snmp-agent.service"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def lock():
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    fd = open(LOCK, "w")
    end = time.time() + 120
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.time() > end:
                sys.exit("inna instancja router-ifaces działa zbyt długo (%s)" % LOCK)
            time.sleep(1)


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()[:16]


# --------------------------------------------------------------------------- polecenia
def print_problems(errs, warns):
    for w in warns:
        print(color("  UWAGA: " + w, "33"))
    for e in errs:
        print(color("  BŁĄD:  " + e, "31"))


def get_desired(path, quiet=False):
    phys = known_phys()
    ents, errs, warns, text = load_conf(path, phys)
    if not quiet or errs:
        print_problems(errs, warns)
    return ents, errs, text


def converge(desired, managed, verbose=True, max_pass=4):
    """Stosuje różnice aż do zgodności. Zwraca (wykonane, nieudane, pozostałe)."""
    done, failed, prev = [], [], None
    for _ in range(max_pass):
        act = read_vpp(with_alias=True)
        cmds = plan(desired, act, managed)
        if not cmds or (prev is not None and cmds == prev):
            break
        for c in cmds:
            ok, out = run_cmd(c)
            mark = "OK " if ok else "BŁĄD"
            log("%s %s%s" % (mark, c.text(), (" -> " + out.replace("\n", " | ")) if out else ""))
            if verbose:
                print("  %s %s%s" % (color(mark, "32" if ok else "31"), c.text(),
                                     color("  (" + out.replace("\n", " ") + ")", "2") if out else ""))
            (done if ok else failed).append((c, out))
        prev = cmds
    left = plan(desired, read_vpp(with_alias=True), managed)
    return done, failed, left


def pl(n, one, few, many):
    if n == 1:
        return "%d %s" % (n, one)
    return "%d %s" % (n, few if n % 10 in (2, 3, 4) and n % 100 not in (12, 13, 14) else many)


def summarize(cmds, limit=8):
    """Opis zmian po ludzku (do logu i maila)."""
    groups = [("utworzono", []), ("usunięto", []), ("dodano adresy", []), ("usunięto adresy", []),
              ("MTU", []), ("opisy", []), ("inne", [])]
    g = dict(groups)
    for c in cmds:
        t = c.text().split() if c.kind == "vpp" else []
        if c.kind == "ip" and c.args[2] == "addr":
            g["dodano adresy" if c.args[3] == "add" else "usunięto adresy"].append("%s %s (Linux)" % (c.args[6], c.args[4]))
        elif c.kind == "ip":
            g["opisy"].append(c.args[5])
        elif t[:2] == ["create", "sub-interfaces"]:
            g["utworzono"].append("%s.%s" % (t[2], t[3]))
        elif t[:2] == ["create", "loopback"]:
            g["utworzono"].append("loop" + t[-1])
        elif t[:2] == ["delete", "sub-interface"] or t[:3] == ["delete", "loopback", "interface"]:
            g["usunięto"].append(t[-1])
        elif t[:5] == ["set", "interface", "ip", "address", "del"]:
            g["usunięto adresy"].append("%s %s" % (t[5], t[6]))
        elif t[:4] == ["set", "interface", "ip", "address"]:
            g["dodano adresy"].append("%s %s" % (t[4], t[5]))
        elif t[:3] == ["set", "interface", "mtu"]:
            g["MTU"].append("%s %s" % (t[-1], t[-2]))
        elif t[:3] == ["set", "interface", "state"] or t[:1] == ["lcp"]:
            continue
        else:
            g["inne"].append(c.text())
    parts = []
    for name, items in groups:
        if items:
            more = " … (+%d)" % (len(items) - limit) if len(items) > limit else ""
            parts.append("%s: %s%s" % (name, ", ".join(items[:limit]), more))
    return "; ".join(parts) or "porządkowanie (stan portów, linux-cp)"


def do_apply(args, boot=False):
    fd = lock()
    state = load_state()
    managed = state.get("managed", {})
    source, used_fallback = CONF, False
    if boot:
        envphys = known_phys_env()
        if not wait_vpp(envphys or [], args.timeout):
            event(2, "APPLY_FAIL", "VPP nie odpowiada po %d s — interfejsy nie zostały skonfigurowane" % args.timeout)
            return 3
    desired, errs, text = get_desired(CONF, quiet=boot)
    if errs or desired is None:
        if boot and os.path.exists(LASTGOOD):
            event(2, "CONFIG_ERROR", "błędy w %s (%s) — używam ostatniej poprawnej konfiguracji"
                  % (CONF, errs[0] if errs else "?"))
            desired, errs, text = get_desired(LASTGOOD, quiet=True)
            source, used_fallback = LASTGOOD, True
        if errs or desired is None:
            if boot:
                event(2, "CONFIG_ERROR", "błędy w konfiguracji interfejsów: %s" % "; ".join(errs[:3]))
            print(color("Nic nie zmieniono — popraw %s i uruchom ponownie." % source, "31"))
            return 2
    try:
        act = read_vpp(with_alias=True)
    except VppError as ex:
        print(color("VPP nie odpowiada: %s" % ex, "31"))
        return 3
    cmds = plan(desired, act, managed)
    yaml_text = render_snmp_yaml(desired)
    if not cmds and not boot:
        print("Brak zmian — VPP jest zgodny z %s." % source)
    if cmds and not boot:
        print("Zmiany do wprowadzenia (%s → VPP):" % source)
        show_cmds(cmds)
        if any(c.op == "-" for c in cmds):
            print(color("  Uwaga: usunięcie adresu zrywa sesje BGP, które z niego korzystają.", "33"))
        if sys.stdin.isatty() and not args.yes:
            try:
                ans = input("Zastosować? [t/N] ").strip().lower()
            except EOFError:
                ans = ""
            if ans not in ("t", "tak", "y", "yes"):
                print("Przerwano — nic nie zmieniono.")
                return 1
    if cmds:
        log("=== %s: %d zmian (%s) ===" % ("boot" if boot else "apply", len(cmds), source))
        done, _failed, left = converge(desired, managed, verbose=not boot)
    else:
        done, left = [], []
    # stan: co jest zarządzane przez skrypt (do późniejszego kasowania)
    new_managed = {e.name: e.kind for e in desired.values() if not e.implicit}
    if left:
        for n, k in managed.items():
            new_managed.setdefault(n, k)    # nieudane usunięcie — spróbujemy następnym razem
    state.update({"managed": new_managed, "applied": now(), "conf_sha": sha(text), "source": source})
    save_state(state)
    if not left and not used_fallback:
        os.makedirs(os.path.dirname(LASTGOOD), exist_ok=True)
        write_if_changed(LASTGOOD, text, 0o644)
    if write_if_changed(SNMP_YAML, yaml_text):
        restart_snmp_agent()
        log("zaktualizowano %s, restart vpp-snmp-agent" % SNMP_YAML)
    if left:
        print(color("\nNie udało się doprowadzić VPP do zgodności — pozostałe różnice:", "31"))
        show_cmds(left)
        print("Szczegóły: %s" % LOG)
        event(3, "APPLY_FAIL", "nie udało się zastosować (%s): %s — szczegóły %s"
              % (pl(len(left), "polecenie", "polecenia", "poleceń"), summarize(left), LOG))
        return 4
    if boot:
        n = len([c for c, _ in done if c.kind == "vpp"])
        event(6, "RESTORED", "konfiguracja interfejsów odtworzona po starcie VPP (%d poleceń, %d interfejsów, źródło %s)"
              % (n, len([e for e in desired.values() if not e.implicit]), source), mail=False)
        state["drift"] = ""
        save_state(state)
    elif done:
        event(5, "CONFIG_APPLIED", "%s" % summarize([c for c, _ in done]))
        if state.get("drift"):
            event(5, "DRIFT_END", "VPP znów zgodny z ifaces.conf")
        state["drift"], state["pending_logged"] = "", False
        save_state(state)
        print(color("Zastosowano: %s. VPP zgodny z %s." % (pl(len(done), "zmiana", "zmiany", "zmian"), source), "32"))
    del fd
    return 0


def known_phys_env():
    try:
        with open(ENVF) as f:
            m = re.search(r'^INST_NIC_PCI="([^"]*)"', f.read(), re.M)
        return ["hu%d" % i for i in range(len(m.group(1).split()))] if m else []
    except OSError:
        return []


def do_diff(args):
    desired, errs, _ = get_desired(CONF)
    if errs or desired is None:
        print(color("Plik zawiera błędy — apply niczego nie zmieni, dopóki ich nie poprawisz.", "31"))
        return 2
    try:
        act = read_vpp(with_alias=True)
    except VppError as ex:
        print(color("VPP nie odpowiada: %s" % ex, "31"))
        return 3
    cmds = plan(desired, act, load_state().get("managed", {}))
    if not cmds:
        print("Brak różnic — VPP jest zgodny z %s." % CONF)
        return 0
    print("Po 'router-ifaces apply' zostanie wykonane:")
    show_cmds(cmds)
    if any(c.args.startswith("create sub-interfaces") for c in cmds if c.kind == "vpp"):
        print(color("  (nowe VLAN-y dostaną interfejs w Linuksie automatycznie, potem opis)", "2"))
    unmanaged(act, desired)
    return 1


def unmanaged(act, desired):
    managed = load_state().get("managed", {})
    extra = [n for n in act.ifaces if ("." in n or n.startswith("loop")) and n not in desired and n not in managed]
    if extra:
        print(color("  Poza ifaces.conf (utworzone ręcznie, skrypt ich nie rusza): %s"
                    % ", ".join(sorted(extra, key=natkey)), "33"))


def do_check(args):
    """Rozjazd: VPP vs OSTATNIO ZASTOSOWANA konfiguracja (edycja pliku bez apply to nie rozjazd)."""
    state = load_state()
    src = LASTGOOD if os.path.exists(LASTGOOD) else CONF
    desired, errs, _ = get_desired(src, quiet=args.log)
    if errs or desired is None:
        return 2
    if args.log and vpp_young():
        return 0
    if args.log:
        fd = open(LOCK, "a") if os.path.isdir(os.path.dirname(LOCK)) else None
        try:
            if fd:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0          # trwa apply/boot — sprawdzimy następnym razem
    try:
        act = read_vpp(with_alias=True)
    except VppError as ex:
        if not args.log:
            print("VPP nie odpowiada: %s" % ex)
        return 3
    cmds = plan(desired, act, state.get("managed", {}))
    pending = False
    try:
        with open(CONF) as f:
            pending = sha(f.read()) != state.get("conf_sha")
    except OSError:
        pass
    if args.log:
        key = sha("\n".join(c.text() for c in cmds)) if cmds else ""
        if cmds and key != state.get("drift"):
            event(4, "DRIFT", "VPP różni się od ifaces.conf (%s do naprawy): %s — napraw: router-ifaces apply"
                  % (pl(len(cmds), "polecenie", "polecenia", "poleceń"), summarize(cmds, 4)))
        elif not cmds and state.get("drift"):
            event(5, "DRIFT_END", "VPP znów zgodny z ifaces.conf")
        if pending and not state.get("pending_logged"):
            event(6, "PENDING", "%s zmieniony, ale nie zastosowany (router-ifaces diff / apply)" % CONF, mail=False)
        state["drift"], state["pending_logged"] = key, pending
        save_state(state)
        return 1 if cmds else 0
    if cmds:
        print(color("ROZJAZD: VPP różni się od ostatnio zastosowanej konfiguracji (%s):" % src, "33"))
        show_cmds(cmds)
        print("Naprawa: router-ifaces apply")
    else:
        print(color("OK: VPP zgodny z ostatnio zastosowaną konfiguracją.", "32"))
    if pending:
        print(color("Plik %s zmieniono po ostatnim apply — zobacz: router-ifaces diff" % CONF, "33"))
    return 1 if cmds else 0


def vpp_young(sec=180):
    """VPP wystartował niedawno — konfiguracja może się jeszcze odtwarzać."""
    if not SYSTEMD:
        return False
    try:
        r = subprocess.run(["systemctl", "show", "-p", "ActiveEnterTimestampMonotonic", "--value", "vpp.service"],
                           capture_output=True, text=True, timeout=5)
        t = int(r.stdout.strip() or 0) / 1e6
        return t == 0 or time.monotonic() - t < sec
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


def do_render(args):
    desired, errs, _ = get_desired(CONF)
    if errs or desired is None:
        return 2
    empty = Actual()
    for e in desired.values():
        if e.kind == "phy":
            empty.ifaces[e.name] = {"up": False, "mtu": None}
    print("comment { router-ifaces: pełna konfiguracja z %s }" % CONF)
    for c in plan(desired, empty, {}, aliases=False):
        print(c.text())
    for e in sorted(desired.values(), key=Entry.order):
        if e.kind == "vlan":
            print("comment { %s: para linux-cp powstaje automatycznie (lcp-auto-subint) }" % e.name)
    return 0


def do_snmp(args):
    desired, errs, _ = get_desired(CONF)
    if (errs or desired is None) and os.path.exists(LASTGOOD):
        desired, errs, _ = get_desired(LASTGOOD, quiet=True)
    if errs or desired is None:
        return 2
    if write_if_changed(SNMP_YAML, render_snmp_yaml(desired)):
        restart_snmp_agent()
        print("zapisano %s" % SNMP_YAML)
    return 0


def do_show(args):
    desired, errs, _ = get_desired(CONF, quiet=True)
    desired = desired or {}
    try:
        act = read_vpp(with_alias=True)
    except VppError as ex:
        act = None
        print(color("VPP nie odpowiada (%s) — pokazuję tylko plik." % ex, "33"))
    rows, diff = [], False
    names = set(desired)
    if act:
        names |= {n for n in act.ifaces if n != "local0" and not n.startswith(("tap", "tun"))}
    for n in sorted(names, key=lambda n: (n.startswith("loop"), natkey(n))):
        e = desired.get(n)
        vlan = str(e.vlan) if e and e.vlan else (n.split(".", 1)[1] if "." in n else "-")
        if act and n in act.ifaces:
            cur = act.ifaces[n]
            stt = "up" if cur["up"] else "down"
            mtu = str(cur["mtu"] or "-")
            have = act.addrs.get(n, set())
            lnx = act.lcp.get(n, "-")
        else:
            stt, mtu, have, lnx = ("BRAK" if act else "?"), "-", set(), "-"
        mark = ""
        if e and not e.implicit and act:
            if n not in act.ifaces or have != e.addrs or n not in act.lcp:
                mark = "*"
        elif not e and act and n in act.ifaces and ("." in n or n.startswith("loop")):
            mark = "?"
        if mark:
            diff = True
        a4 = ",".join(str(a) for a in sorted(have, key=addr_key) if a.version == 4) or "-"
        a6 = ",".join(str(a) for a in sorted(have, key=addr_key) if a.version == 6) or "-"
        if not act and e:
            a4 = ",".join(str(a) for a in e.v4) or "-"
            a6 = ",".join(str(a) for a in e.v6) or "-"
        desc = e.desc if e else ("(poza ifaces.conf)" if mark == "?" else "")
        rows.append((n + mark, vlan, stt, mtu, lnx, a4, a6, desc))
    hdr = ("Interfejs", "VLAN", "Stan", "MTU", "Linux", "IPv4", "IPv6", "Opis")
    w = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(7)]
    fmt = "  ".join("%%-%ds" % x for x in w) + "  %s"
    print(color(fmt % hdr, "1"))
    for r in rows:
        print(fmt % r)
    if diff:
        print("\n* różni się od ifaces.conf (router-ifaces diff)   ? utworzony ręcznie, poza ifaces.conf")
    if errs:
        print(color("\nifaces.conf zawiera błędy (%d) — router-ifaces diff pokaże szczegóły." % len(errs), "31"))
    return 0


def main():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    ap = argparse.ArgumentParser(prog="router-ifaces", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", nargs="?", default="show", choices=["show", "diff", "apply", "check", "render", "boot", "snmp"])
    ap.add_argument("-y", "--yes", action="store_true", help="apply bez pytania o potwierdzenie")
    ap.add_argument("--log", action="store_true", help="check: tryb cichy, wynik do logu (timer systemd)")
    ap.add_argument("--timeout", type=int, default=180, help="boot: ile sekund czekać na VPP")
    args = ap.parse_args()
    if os.geteuid() != 0 and not ROOT:
        sys.exit("Uruchom jako root.")
    fn = {"show": do_show, "diff": do_diff, "check": do_check, "render": do_render, "snmp": do_snmp,
          "apply": lambda a: do_apply(a), "boot": lambda a: do_apply(a, boot=True)}[args.cmd]
    sys.exit(fn(args))


if __name__ == "__main__":
    main()
RIFEOF
}

prog_mdadm_alert() {
  cat <<'EOF'
#!/bin/sh
# Wywoływany przez mdadm --monitor:  mdadm-alert <zdarzenie> <macierz> [dysk]
ev="$1"; md="$2"; dev="${3:-}"
case "$ev" in
  Fail|FailSpare|DegradedArray|DeviceDisappeared|SparesMissing) sev=1; prio=local0.crit ;;
  Rebuild*|SpareActive|NewArray|MoveSpare) sev=5; prio=local0.notice ;;
  TestMessage) sev=6; prio=local0.info ;;
  *) sev=4; prio=local0.warning ;;
esac
name=$(basename "$md")
state=$(grep -A1 "^$name " /proc/mdstat 2>/dev/null | grep -o '\[[U_]*\]' | tail -n1)
msg="%MD-$sev-$(echo "$ev" | tr '[:lower:]' '[:upper:]'): $md ${dev:+dysk $dev }${state:+stan $state}"
logger -t mdadm-alert -p "$prio" "$msg"
mkdir -p /var/log/router-monitor
printf '%s %s\n' "$(date '+%F %T')" "$msg" >>/var/log/router-monitor/router-monitor.log
[ "$sev" -le 5 ] && /opt/router/bin/router-notify queue "$msg" >/dev/null 2>&1
exit 0
EOF
}

prog_smartd_alert() {
  cat <<'EOF'
#!/bin/sh
# Wywoływany przez smartd (-M exec). smartd ustawia SMARTD_DEVICE, SMARTD_FAILTYPE, SMARTD_MESSAGE.
t=$(echo "${SMARTD_FAILTYPE:-ALERT}" | tr '[:lower:]' '[:upper:]')
sev=2; [ "$t" = "EMAILTEST" ] && sev=6
msg="%SMART-$sev-$t: ${SMARTD_DEVICE:-?} ${SMARTD_MESSAGE:-}"
logger -t smartd-alert -p local0.crit "$msg"
mkdir -p /var/log/router-monitor
printf '%s %s\n' "$(date '+%F %T')" "$msg" >>/var/log/router-monitor/router-monitor.log
[ "$sev" -le 5 ] && /opt/router/bin/router-notify queue "$msg" >/dev/null 2>&1
exit 0
EOF
}

prog_router_monitor() {
  cat <<'ROUTER_MONITOR_PY'
#!/usr/bin/python3
# router-monitor — monitor obciążenia routera VPP w czasie rzeczywistym.
#
# Co sekundę czyta segment statystyk VPP i zapisuje do logu zdarzenia
# w stylu syslog Cisco (%FAC-SEV-MNEMONIC), np. przy krótkich DDoS-ach:
#   %VPP-4-LOAD_HIGH     obciążenie workera (średni rozmiar wektora) ponad próg
#   %VPP-2-RX_MISS       karta gubi pakiety, bo VPP nie nadąża (rx-miss / rx-no-buf)
#   %VPP-3-NIC_DISCARD   karta odrzuca pakiety sprzętowo (limit karty / PCIe)
#   %VPP-4-PUNT_HIGH     dużo ruchu do samego routera (atak na control plane)
#   %VPP-1-HANG          VPP przestał odpowiadać (opcjonalny automatyczny restart)
#   %SYS-4-CPU_HIGH      przeciążony rdzeń systemowy (BIRD, SNMP itd.)
#   %MD-1-DEGRADED       zdegradowana macierz mdadm
#   %VPP-6-STATS         co minutę szczyty z ostatniej minuty (historia)
# Po ustąpieniu zdarzenia: *_NORMAL z czasem trwania i wartością szczytową.
#
# Logi: syslog/journal (tag router-monitor, facility local0)
#       oraz /var/log/router-monitor/router-monitor.log
# Bieżący stan: /run/router-monitor/state.json
# Progi: /etc/router/router-monitor.conf
# E-mail: zgłoszenia, eskalacje i zakończenia zdarzeń trafiają do kolejki router-notify
#         (/var/spool/router-notify); przypomnienia "trwa Ns" nie. Co faktycznie idzie mailem,
#         decyduje MAIL_SEND w /etc/router/notify.conf (router-notify categories).
import itertools
import json
import logging
import logging.handlers
import os
import re
import subprocess
import sys
import time

CONF = "/etc/router/router-monitor.conf"
CFG = {
    "INTERVAL": 1.0,        # s, okres próbkowania
    "VEC_WARN": 64.0,       # średni rozmiar wektora workera (1 = luz, 256 = nasycenie)
    "VEC_CRIT": 160.0,
    "RXMISS_PPS": 1.0,      # pkt/s zgubione przez kartę (rx-miss + rx-no-buf) => alarm
    "NIC_DISCARD_PPS": 1.0, # pkt/s odrzucone sprzętowo (xstats *discard*/*out_of_buffer*)
    "PUNT_PPS": 20000.0,    # pkt/s do control plane
    "HK_CPU_PCT": 90.0,     # % zajętości rdzenia systemowego
    "HK_CPU_SECONDS": 5,    # przez ile sekund z rzędu
    "REPEAT_EVERY": 10,     # s, przypomnienie o trwającym zdarzeniu
    "SUMMARY_EVERY": 60,    # s, linia %VPP-6-STATS (0 = wyłączone)
    "XSTATS_EVERY": 10,     # s, odczyt liczników sprzętowych karty (vppctl)
    "MD_EVERY": 10,         # s, kontrola /proc/mdstat
    "HANG_SECONDS": 30,     # s bez heartbeat VPP => %VPP-1-HANG
    "HANG_RESTART": 1,      # 1 = po HANG zrestartuj VPP
    "LOGFILE": "/var/log/router-monitor/router-monitor.log",
    "STATEFILE": "/run/router-monitor/state.json",
    "ENVFILE": "/etc/router/router.env",
}
SEV_LEVEL = {1: logging.CRITICAL, 2: logging.CRITICAL, 3: logging.ERROR,
             4: logging.WARNING, 5: logging.INFO, 6: logging.INFO}


def load_conf():
    try:
        with open(CONF) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if "=" not in line:
                    continue
                k, v = (x.strip() for x in line.split("=", 1))
                if k in CFG:
                    CFG[k] = type(CFG[k])(v) if not isinstance(CFG[k], str) else v
    except FileNotFoundError:
        pass


def setup_log():
    log = logging.getLogger("router-monitor")
    log.setLevel(logging.INFO)
    try:
        sh = logging.handlers.SysLogHandler(address="/dev/log",
                                            facility=logging.handlers.SysLogHandler.LOG_LOCAL0)
        sh.ident = "router-monitor: "
        log.addHandler(sh)
    except OSError:
        pass
    os.makedirs(os.path.dirname(CFG["LOGFILE"]), exist_ok=True)
    fh = logging.handlers.WatchedFileHandler(CFG["LOGFILE"])
    fh.setFormatter(logging.Formatter("%(asctime)s %(message)s", "%Y-%m-%d %H:%M:%S"))
    log.addHandler(fh)
    if sys.stdout.isatty():
        log.addHandler(logging.StreamHandler(sys.stdout))
    return log


LOG = None
logging.raiseExceptions = False  # brak /dev/log nie może zatrzymać monitora


SPOOL = "/var/spool/router-notify"
NOMAIL = {"START"}
_seq = itertools.count()


def queue_mail(line, sev):
    """Zdarzenie do kolejki powiadomień e-mail (wysyła router-notify.service)."""
    try:
        os.makedirs(SPOOL, mode=0o700, exist_ok=True)
        name = "%d-%d-%d.json" % (time.time_ns(), os.getpid(), next(_seq))
        tmp = os.path.join(SPOOL, "." + name)
        with open(tmp, "w") as f:
            json.dump({"time": time.strftime("%Y-%m-%d %H:%M:%S"), "sev": sev, "line": line}, f)
        os.replace(tmp, os.path.join(SPOOL, name))
    except OSError:
        pass


def emit(fac, sev, mnem, msg, mail=True):
    line = "%%%s-%d-%s: %s" % (fac, sev, mnem, msg)
    LOG.log(SEV_LEVEL.get(sev, logging.INFO), "%s", line)
    if mail and mnem not in NOMAIL:
        queue_mail(line, sev)


def fmt_num(x):
    if x >= 1e9:
        return "%.2fG" % (x / 1e9)
    if x >= 1e6:
        return "%.2fM" % (x / 1e6)
    if x >= 1e3:
        return "%.1fk" % (x / 1e3)
    return "%.0f" % x


class Alarm:
    """Zdarzenie z histerezą: zgłoszenie, eskalacja, przypomnienia, koniec ze szczytem i czasem trwania."""

    def __init__(self, fac, sev, mnem, clear_mnem):
        self.fac, self.sev, self.mnem, self.clear_mnem = fac, sev, mnem, clear_mnem
        self.active = False
        self.since = self.last = 0.0
        self.peak = 0.0
        self.peak_txt = ""
        self.cur_sev, self.cur_mnem = sev, mnem

    def update(self, now, active, value, text, sev=None, mnem=None):
        sev = self.sev if sev is None else sev
        mnem = self.mnem if mnem is None else mnem
        if active:
            if not self.active:
                self.active, self.since, self.last = True, now, now
                self.peak, self.peak_txt = value, text
                self.cur_sev, self.cur_mnem = sev, mnem
                emit(self.fac, sev, mnem, text)
                return
            if value >= self.peak:
                self.peak, self.peak_txt = value, text
            if sev < self.cur_sev:  # eskalacja (niższy numer = poważniej)
                self.cur_sev, self.cur_mnem, self.last = sev, mnem, now
                emit(self.fac, sev, mnem, "%s (eskalacja po %ds)" % (text, int(now - self.since)))
            elif now - self.last >= CFG["REPEAT_EVERY"]:
                self.last = now
                emit(self.fac, self.cur_sev, self.cur_mnem,
                     "%s (trwa %ds)" % (text, int(now - self.since)), mail=False)
        elif self.active:
            self.active = False
            emit(self.fac, 5, self.clear_mnem,
                 "koniec po %ds, szczyt: %s" % (int(now - self.since), self.peak_txt))
            self.peak, self.peak_txt = 0.0, ""
            self.cur_sev, self.cur_mnem = self.sev, self.mnem


# ----------------------------------------------------------------- parsery
MD_HDR = re.compile(r"^(md\d+)\s*:\s*(\S+)\s+(\S+)?")
MD_STAT = re.compile(r"\[(\d+)/(\d+)\]\s*\[([U_]+)\]")
MD_PROG = re.compile(r"(recovery|resync|reshape|check)\s*=\s*([\d.]+)%.*?finish=([\d.]+min)?")


def parse_mdstat(text):
    """Zwraca {md: {'state': 'UU', 'degraded': bool, 'progress': '...' }}."""
    res, cur = {}, None
    for line in text.splitlines():
        m = MD_HDR.match(line)
        if m:
            cur = m.group(1)
            res[cur] = {"state": "", "degraded": False, "progress": "",
                        "faulty": "(F)" in line, "status": m.group(2)}
            continue
        if cur is None:
            continue
        m = MD_STAT.search(line)
        if m:
            res[cur]["state"] = m.group(3)
            res[cur]["degraded"] = "_" in m.group(3) or m.group(1) != m.group(2)
        m = MD_PROG.search(line)
        if m:
            res[cur]["progress"] = "%s %s%%%s" % (m.group(1), m.group(2),
                                                  (" (koniec za %s)" % m.group(3)) if m.group(3) else "")
    for v in res.values():
        v["degraded"] = v["degraded"] or v["faulty"]
    return res


HW_IF = re.compile(r"^(\S+)\s+\d+\s+(up|down)\b")
HW_X = re.compile(r"^\s+([A-Za-z0-9_\[\]]*(?:discard|out_of_buffer)[A-Za-z0-9_\[\]]*)\s+(\d+)\s*$")


def parse_hw_xstats(text):
    """Z 'vppctl show hardware-interfaces' wyciąga liczniki *discard*/*out_of_buffer* per port."""
    res, cur = {}, None
    for line in text.splitlines():
        m = HW_IF.match(line)
        if m:
            cur = m.group(1)
            res.setdefault(cur, 0)
            continue
        if cur:
            m = HW_X.match(line)
            if m and not m.group(1).startswith("tx_"):
                res[cur] += int(m.group(2))
    return res


def read_proc_stat():
    out = {}
    with open("/proc/stat") as f:
        for line in f:
            if line.startswith("cpu") and line[3:4].isdigit():
                p = line.split()
                vals = list(map(int, p[1:]))
                idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
                out[int(p[0][3:])] = (sum(vals), idle)
    return out


def cpulist(text):
    res = []
    for part in text.strip().split(","):
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-")
            res.extend(range(int(a), int(b) + 1))
        else:
            res.append(int(part))
    return res


def worker_cores():
    try:
        with open(CFG["ENVFILE"]) as f:
            for line in f:
                if line.startswith("INST_WORKERS="):
                    return [int(x) for x in line.split("=", 1)[1].strip().strip('"').split(",") if x]
    except (OSError, ValueError):
        pass
    return []


def phys_if(name):
    return not (name.startswith(("local", "tap", "loop", "lcp")) or "." in name or name == "")


# ------------------------------------------------------------------ główna pętla
def main():
    global LOG
    load_conf()
    LOG = setup_log()
    try:
        from vpp_papi.vpp_stats import VPPStats
    except ImportError:
        emit("SYS", 3, "NO_VPP_PAPI", "brak modułu vpp_papi (paczka python3-vpp-api)")
        sys.exit(1)

    emit("SYS", 5, "START", "router-monitor uruchomiony (progi: wektor %.0f/%.0f, punt %s pkt/s)"
         % (CFG["VEC_WARN"], CFG["VEC_CRIT"], fmt_num(CFG["PUNT_PPS"])))
    wcores = worker_cores()
    try:
        with open("/sys/devices/system/cpu/isolated") as f:
            isolated = set(cpulist(f.read()))
    except OSError:
        isolated = set()

    a_load = Alarm("VPP", 4, "LOAD_HIGH", "LOAD_NORMAL")
    a_miss = Alarm("VPP", 2, "RX_MISS", "RX_MISS_END")
    a_disc = Alarm("VPP", 3, "NIC_DISCARD", "NIC_DISCARD_END")
    a_punt = Alarm("VPP", 4, "PUNT_HIGH", "PUNT_NORMAL")
    a_down = Alarm("VPP", 2, "DOWN", "UP")
    a_hk = Alarm("SYS", 4, "CPU_HIGH", "CPU_NORMAL")
    md_known = {}

    stats = None
    prev = None
    prev_t = 0.0
    hb_last, hb_t = None, time.time()
    last_restart = 0.0
    hk_prev = read_proc_stat()
    hk_over = 0
    xs_prev, xs_t = None, 0.0
    md_t = 0.0
    sum_t = time.time()
    win = {"vec": 0.0, "vec_w": "", "pps": 0.0, "bps": 0.0, "miss": 0, "punt": 0.0, "hk": 0.0}

    while True:
        t0 = time.time()
        state = {"time": int(t0)}

        # ---------------------------------------------------------- VPP
        try:
            if stats is None:
                stats = VPPStats(socketname="/run/vpp/stats.sock", timeout=2)
                stats.connect()
                prev = None
            hb = stats["/sys/heartbeat"]
            names = list(stats["/if/names"])
            vec = stats["/sys/vector_rate_per_worker"]
            loops = stats["/sys/loops_per_worker"]
            rx = stats["/if/rx"]
            tx = stats["/if/tx"]
            miss = stats["/if/rx-miss"]
            nobuf = stats["/if/rx-no-buf"]
            punt = stats["/if/punt"]
            a_down.update(t0, False, 0, "")

            vrow = list(vec[0]) if len(vec) and isinstance(vec[0], (list, tuple)) else list(vec)
            lrow = list(loops[0]) if len(loops) and isinstance(loops[0], (list, tuple)) else list(loops)
            cur = {}
            for i, n in enumerate(names):
                if not n:
                    continue
                cur[n] = (rx[:, i].sum_packets(), rx[:, i].sum_octets(),
                          tx[:, i].sum_packets(), tx[:, i].sum_octets(),
                          miss[:, i].sum() + nobuf[:, i].sum(), punt[:, i].sum())

            # heartbeat / zawieszenie
            if hb != hb_last:
                hb_last, hb_t = hb, t0
            elif t0 - hb_t >= CFG["HANG_SECONDS"]:
                emit("VPP", 1, "HANG", "brak heartbeat VPP od %ds" % int(t0 - hb_t))
                if CFG["HANG_RESTART"] and t0 - last_restart > 300:
                    emit("VPP", 1, "HANG_RESTART", "restartuję VPP (systemctl restart vpp)")
                    subprocess.run(["systemctl", "restart", "vpp"], check=False)
                    last_restart = t0
                hb_t = t0
                stats = None

            # obciążenie workerów
            workers = [(i, v) for i, v in enumerate(vrow) if i > 0] or [(0, v) for v in vrow[:1]]
            if workers:
                wi, wv = max(workers, key=lambda x: x[1])
                core = wcores[wi - 1] if 0 < wi <= len(wcores) else "?"
                lp = lrow[wi] if wi < len(lrow) else 0
                txt = "worker %d (cpu %s) wektor %.0f/256, pętle %s/s, workery>%.0f: %d/%d" % (
                    wi, core, wv, fmt_num(lp), CFG["VEC_WARN"],
                    sum(1 for _, v in workers if v >= CFG["VEC_WARN"]), len(workers))
                state["vector_max"], state["vector_worker"] = wv, wi
                state["vector_per_worker"] = [v for _, v in workers]
                crit = wv >= CFG["VEC_CRIT"]
                a_load.update(t0, wv >= CFG["VEC_WARN"], wv, txt,
                              sev=2 if crit else 4, mnem="LOAD_CRITICAL" if crit else "LOAD_HIGH")
                if wv > win["vec"]:
                    win["vec"], win["vec_w"] = wv, "worker %d" % wi

            # ruch, rx-miss, punt
            if prev is not None and t0 > prev_t:
                dt = t0 - prev_t
                tot_pps = tot_bps = tot_tpps = tot_miss = tot_punt = 0.0
                ifs = {}
                miss_txt = []
                for n, c in cur.items():
                    p = prev.get(n)
                    if p is None:
                        continue
                    d = [max(0, a - b) / dt for a, b in zip(c, p)]
                    if phys_if(n):
                        tot_pps += d[0]
                        tot_bps += d[1] * 8
                        tot_tpps += d[2]
                        tot_miss += d[4]
                        ifs[n] = {"rx_pps": d[0], "rx_bps": d[1] * 8, "tx_pps": d[2],
                                  "tx_bps": d[3] * 8, "rx_miss_pps": d[4]}
                        if d[4] >= CFG["RXMISS_PPS"]:
                            miss_txt.append("%s %s pkt/s" % (n, fmt_num(d[4])))
                    tot_punt += d[5]
                state["interfaces"] = ifs
                state["rx_pps"], state["rx_bps"] = tot_pps, tot_bps
                state["rx_miss_pps"], state["punt_pps"] = tot_miss, tot_punt
                traffic = "rx %s pps / %sb/s" % (fmt_num(tot_pps), fmt_num(tot_bps))
                a_miss.update(t0, tot_miss >= CFG["RXMISS_PPS"], tot_miss,
                              "utrata pakietów na wejściu: %s (VPP nie nadąża lub brak buforów); %s"
                              % (", ".join(miss_txt) or fmt_num(tot_miss), traffic))
                a_punt.update(t0, tot_punt >= CFG["PUNT_PPS"], tot_punt,
                              "ruch do control plane %s pkt/s; %s" % (fmt_num(tot_punt), traffic))
                win["pps"] = max(win["pps"], tot_pps)
                win["bps"] = max(win["bps"], tot_bps)
                win["miss"] += int(tot_miss * dt)
                win["punt"] = max(win["punt"], tot_punt)
            prev, prev_t = cur, t0
        except Exception as e:  # VPP nie działa / restart / zmiana segmentu
            if not a_down.active:
                a_down.update(t0, True, 0, "brak dostępu do statystyk VPP: %s" % e)
            stats, prev = None, None

        # ---------------------------------------------------------- liczniki sprzętowe karty
        if CFG["XSTATS_EVERY"] > 0 and t0 - xs_t >= CFG["XSTATS_EVERY"] and not a_down.active:
            try:
                out = subprocess.run(["vppctl", "show", "hardware-interfaces"], capture_output=True,
                                     text=True, timeout=5).stdout
                xs = parse_hw_xstats(out)
                if xs_prev is not None:
                    dt = t0 - xs_t
                    rates = {k: max(0, v - xs_prev.get(k, v)) / dt for k, v in xs.items()}
                    tot = sum(rates.values())
                    state["nic_discard_pps"] = tot
                    a_disc.update(t0, tot >= CFG["NIC_DISCARD_PPS"], tot,
                                  "karta odrzuca pakiety sprzętowo: %s (limit karty/PCIe lub przepełnienie)"
                                  % ", ".join("%s %s pkt/s" % (k, fmt_num(v)) for k, v in rates.items() if v > 0))
                xs_prev, xs_t = xs, t0
            except (OSError, subprocess.SubprocessError):
                xs_t = t0

        # ---------------------------------------------------------- rdzenie systemowe
        hk_now = read_proc_stat()
        hk_max, hk_core = 0.0, None
        for c, (tot, idle) in hk_now.items():
            if c in isolated or c not in hk_prev:
                continue
            dtot, didle = tot - hk_prev[c][0], idle - hk_prev[c][1]
            if dtot > 0:
                busy = 100.0 * (dtot - didle) / dtot
                if busy > hk_max:
                    hk_max, hk_core = busy, c
        hk_prev = hk_now
        hk_over = hk_over + 1 if hk_max >= CFG["HK_CPU_PCT"] else 0
        state["hk_cpu_max"] = hk_max
        win["hk"] = max(win["hk"], hk_max)
        a_hk.update(t0, hk_over >= CFG["HK_CPU_SECONDS"], hk_max,
                    "rdzeń systemowy cpu %s zajęty %.0f%% (BIRD/SNMP/system)" % (hk_core, hk_max))

        # ---------------------------------------------------------- RAID
        if t0 - md_t >= CFG["MD_EVERY"]:
            md_t = t0
            try:
                with open("/proc/mdstat") as f:
                    md = parse_mdstat(f.read())
            except OSError:
                md = {}
            state["md"] = md
            for name, v in md.items():
                old = md_known.get(name)
                if v["degraded"] and (old is None or not old["degraded"]):
                    emit("MD", 1, "DEGRADED", "%s zdegradowana [%s] %s" % (name, v["state"], v["progress"]))
                elif not v["degraded"] and old is not None and old["degraded"]:
                    emit("MD", 5, "RECOVERED", "%s sprawna [%s]" % (name, v["state"]))
                if v["progress"] and (old is None or old["progress"] != v["progress"]) and int(t0) % 60 < CFG["MD_EVERY"]:
                    emit("MD", 5, "SYNC", "%s %s" % (name, v["progress"]))
                md_known[name] = v

        # ---------------------------------------------------------- podsumowanie minutowe
        if CFG["SUMMARY_EVERY"] > 0 and t0 - sum_t >= CFG["SUMMARY_EVERY"]:
            emit("VPP", 6, "STATS", "szczyty %ds: wektor %.0f (%s), rx %s pps / %sb/s, rx-miss %d pkt, punt %s pps, cpu sys %.0f%%"
                 % (int(t0 - sum_t), win["vec"], win["vec_w"] or "-", fmt_num(win["pps"]), fmt_num(win["bps"]),
                    win["miss"], fmt_num(win["punt"]), win["hk"]))
            sum_t = t0
            win = {"vec": 0.0, "vec_w": "", "pps": 0.0, "bps": 0.0, "miss": 0, "punt": 0.0, "hk": 0.0}

        # ---------------------------------------------------------- stan bieżący
        try:
            os.makedirs(os.path.dirname(CFG["STATEFILE"]), exist_ok=True)
            tmp = CFG["STATEFILE"] + ".tmp"
            with open(tmp, "w") as f:
                json.dump(state, f)
            os.replace(tmp, CFG["STATEFILE"])
        except OSError:
            pass

        time.sleep(max(0.05, CFG["INTERVAL"] - (time.time() - t0)))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
ROUTER_MONITOR_PY
}

prog_router_notify() {
  cat <<'ROUTER_NOTIFY_PY'
#!/usr/bin/python3
# router-notify — powiadomienia e-mail o alarmach routera.
#
#   router-notify queue "%VPP-2-RX_MISS: opis"   dodaj zdarzenie do kolejki (wołają skrypty alarmów)
#   router-notify run                            demon: zbiera kolejkę i wysyła maile (router-notify.service)
#   router-notify test                           wyślij od razu mail testowy i pokaż wynik
#   router-notify categories                     lista kategorii zdarzeń do wyboru w MAIL_SEND
#
# Konfiguracja: /etc/router/notify.conf (SMTP, odbiorcy, progi). Kolejka: /var/spool/router-notify/
# Zasady wysyłki:
#   * wysyłane są tylko zdarzenia z kategorii wymienionych w MAIL_SEND (router-notify categories)
#     i o poziomie 1..MAIL_MAX_SEV (1 = najpoważniejsze); MAIL_SEND_CLEAR=no wyłącza maile o zakończeniu
#   * konfiguracja jest wczytywana ponownie co 5 s — zmiany działają bez restartu
#   * pierwsze zdarzenie po okresie ciszy idzie od razu; kolejne w ciągu MAIL_MIN_INTERVAL s
#     są zbierane w jeden mail (np. cały krótki DDoS = 1-2 maile, a nie dziesiątki)
#   * najwyżej MAIL_MAX_PER_HOUR maili na godzinę; nadmiar trafia do następnego maila zbiorczo
#   * przy błędzie SMTP zdarzenia zostają w kolejce, ponowna próba z rosnącą przerwą (do 10 min)
import itertools
import json
import os
import re
import smtplib
import socket
import ssl
import sys
import time
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

CONF = "/etc/router/notify.conf"
SPOOL = "/var/spool/router-notify"
LOGFILE = "/var/log/router-monitor/router-monitor.log"
CFG = {
    "ALERT_EMAILS": "", "SMTP_HOST": "", "SMTP_PORT": "587", "SMTP_SECURITY": "starttls",
    "SMTP_USER": "", "SMTP_PASS": "", "SMTP_FROM": "",
    "MAIL_MAX_SEV": "5", "MAIL_MIN_INTERVAL": "60", "MAIL_MAX_PER_HOUR": "30",
    "MAIL_SEND": "CRASH SERVICES BOOT RAID DISKS NIC_FW VPP_STATE VPP_DROPS VPP_LOAD VPP_PUNT SYS_CPU IFACES FIREWALL OTHER",
    "MAIL_SEND_CLEAR": "yes",
}
# kategorie zdarzeń: (nazwa, opis, wzorzec na "OBSZAR-ZDARZENIE")
CATEGORIES = [
    ("CRASH", "kernel panic, nieczysty restart serwera", r"^SYS-(KERNEL_PANIC|UNCLEAN_REBOOT)$"),
    ("SERVICES", "awaria i automatyczny restart VPP, BIRD, usług", r"^SYS-SERVICE_"),
    ("BOOT", "wynik kontroli po starcie (BOOT_OK / BOOT_PROBLEM)", r"^SYS-BOOT_"),
    ("RAID", "mdadm: awaria dysku, degradacja, odbudowa macierzy", r"^MD-"),
    ("DISKS", "smartd: zdrowie dysków (S.M.A.R.T.)", r"^SMART-"),
    ("NIC_FW", "aktualizacja firmware karty", r"^SYS-NIC_FW_"),
    ("VPP_STATE", "VPP niedostępny, zawieszony, wznowiony", r"^VPP-(DOWN|UP|HANG|HANG_RESTART)$"),
    ("VPP_DROPS", "utrata pakietów: rx-miss, odrzucenia na karcie", r"^VPP-(RX_MISS|NIC_DISCARD)"),
    ("VPP_LOAD", "przeciążenie workerów VPP (LOAD_HIGH / LOAD_CRITICAL)", r"^VPP-LOAD_"),
    ("VPP_PUNT", "duży ruch do samego routera (atak na control plane)", r"^VPP-PUNT_"),
    ("SYS_CPU", "przeciążenie rdzeni systemowych (BIRD, SNMP)", r"^SYS-CPU_"),
    ("IFACES", "interfejsy: zmiany z ifaces.conf, rozjazd VPP, błędy pliku", r"^IFACE-"),
    ("FIREWALL", "firewall i router-guard: zmiany, rozjazd VPP, blokady, naruszenia", r"^(FW|GUARD)-"),
    ("STATS", "minutowe podsumowanie szczytów (dużo maili!)", r"^VPP-STATS$"),
    ("MAIL", "test wysyłki", r"^SYS-MAIL_"),
    ("OTHER", "pozostałe zdarzenia", r".*"),
]
CLEAR_RE = re.compile(r"(_NORMAL|_END|RECOVERED)$|^VPP-UP$")
SEV_RE = re.compile(r"%([A-Z0-9_]+)-(\d)-([A-Z0-9_]+)")
SEV_LABEL = {1: "KRYTYCZNE", 2: "KRYTYCZNE", 3: "BŁĄD", 4: "OSTRZEŻENIE", 5: "INFO", 6: "INFO"}
_seq = itertools.count()


def load_conf():
    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                    v = v[1:-1]
                CFG[k.strip()] = v
    except FileNotFoundError:
        pass


def category(line):
    m = SEV_RE.search(line)
    key = "%s-%s" % (m.group(1), m.group(3)) if m else ""
    for name, _desc, pat in CATEGORIES:
        if re.search(pat, key):
            return name, key
    return "OTHER", key


def wanted(e):
    """Czy zdarzenie ma iść mailem (kategoria, poziom, zakończenia)."""
    cat, key = category(e.get("line", ""))
    send = CFG["MAIL_SEND"].upper().replace(",", " ").split()
    if "ALL" not in send and cat not in send:
        return False
    if CFG["MAIL_SEND_CLEAR"].lower() in ("no", "nie", "0", "false") and CLEAR_RE.search(key):
        return False
    if cat == "STATS":
        return True
    return e.get("sev", 9) <= int(CFG["MAIL_MAX_SEV"] or 5)


def log(line):
    try:
        os.makedirs(os.path.dirname(LOGFILE), exist_ok=True)
        with open(LOGFILE, "a") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), line))
    except OSError:
        pass


def queue(line):
    m = SEV_RE.search(line)
    sev = int(m.group(2)) if m else 4
    os.makedirs(SPOOL, mode=0o700, exist_ok=True)
    name = "%d-%d-%d.json" % (time.time_ns(), os.getpid(), next(_seq))
    tmp = os.path.join(SPOOL, "." + name)
    with open(tmp, "w") as f:
        json.dump({"time": time.strftime("%Y-%m-%d %H:%M:%S"), "sev": sev, "line": line}, f)
    os.replace(tmp, os.path.join(SPOOL, name))


def host():
    return socket.getfqdn() or socket.gethostname()


def uptime():
    try:
        with open("/proc/uptime") as f:
            s = int(float(f.read().split()[0]))
        return "%dd %02dh %02dm" % (s // 86400, s % 86400 // 3600, s % 3600 // 60)
    except OSError:
        return "?"


def recipients():
    return [a.strip() for a in re.split(r"[,; ]+", CFG["ALERT_EMAILS"]) if a.strip()]


def send(subject, body):
    to = recipients()
    if not to or not CFG["SMTP_HOST"]:
        raise RuntimeError("brak ALERT_EMAILS lub SMTP_HOST w %s" % CONF)
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = CFG["SMTP_FROM"] or CFG["SMTP_USER"] or "router@" + host()
    msg["To"] = ", ".join(to)
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain=host())
    msg.set_content(body)
    port = int(CFG["SMTP_PORT"] or 587)
    sec = CFG["SMTP_SECURITY"].lower()
    ctx = ssl.create_default_context()
    if sec == "ssl":
        srv = smtplib.SMTP_SSL(CFG["SMTP_HOST"], port, timeout=30, context=ctx)
    else:
        srv = smtplib.SMTP(CFG["SMTP_HOST"], port, timeout=30)
    try:
        srv.ehlo()
        if sec == "starttls":
            srv.starttls(context=ctx)
            srv.ehlo()
        if CFG["SMTP_USER"]:
            srv.login(CFG["SMTP_USER"], CFG["SMTP_PASS"])
        srv.send_message(msg)
    finally:
        try:
            srv.quit()
        except Exception:
            pass


def body_for(events, extra=""):
    h = host()
    lines = ["Router: %s   (uptime %s)" % (h, uptime()), ""]
    lines += ["%s  %s" % (e["time"], e["line"]) for e in events]
    if extra:
        lines += ["", extra]
    lines += ["",
              "Stan routera:    router-check",
              "Alarmy na żywo:  tail -f /var/log/router-monitor/router-monitor.log",
              "Opis komunikatów: /opt/router/README.md (rozdział 5)"]
    return "\n".join(lines) + "\n"


def subject_for(events, extra_count=0):
    worst = min(e["sev"] for e in events)
    first = min((e for e in events if e["sev"] == worst), key=lambda e: e["time"])
    m = SEV_RE.search(first["line"])
    mn = "%%%s-%s-%s" % m.groups() if m else first["line"][:60]
    more = len(events) - 1 + extra_count
    return "[%s] %s: %s%s" % (host().split(".")[0], SEV_LABEL.get(worst, "INFO"), mn,
                              (" (+%d)" % more) if more > 0 else "")


def run():
    load_conf()
    os.makedirs(SPOOL, mode=0o700, exist_ok=True)
    sent_times = []
    last_sent = 0.0
    backoff, next_try = 60, 0.0
    if not recipients() or not CFG["SMTP_HOST"]:
        log("%SYS-4-MAIL_DISABLED: powiadomienia e-mail wyłączone (brak ALERT_EMAILS/SMTP_HOST w /etc/router/notify.conf)")
    while True:
        load_conf()
        min_int = int(CFG["MAIL_MIN_INTERVAL"] or 60)
        max_hour = int(CFG["MAIL_MAX_PER_HOUR"] or 30)
        now = time.time()
        files = sorted(f for f in os.listdir(SPOOL) if f.endswith(".json") and not f.startswith("."))
        events, keep = [], []
        for f in files:
            p = os.path.join(SPOOL, f)
            try:
                with open(p) as fh:
                    e = json.load(fh)
            except (OSError, ValueError):
                os.unlink(p)
                continue
            if not wanted(e) or not recipients() or not CFG["SMTP_HOST"]:
                os.unlink(p)
                continue
            events.append(e)
            keep.append(p)
        sent_times = [t for t in sent_times if now - t < 3600]
        if events and now >= next_try and now - last_sent >= min_int and len(sent_times) < max_hour:
            shown, rest = events[:200], len(events) - 200
            extra = ("... oraz %d kolejnych zdarzeń (pełna lista w %s)" % (rest, LOGFILE)) if rest > 0 else ""
            try:
                send(subject_for(shown, max(0, rest)), body_for(shown, extra))
                for p in keep:
                    try:
                        os.unlink(p)
                    except OSError:
                        pass
                last_sent = now
                sent_times.append(now)
                backoff = 60
                log("%%SYS-6-MAIL_SENT: wysłano %d zdarzeń do %s" % (len(events), ", ".join(recipients())))
                if len(sent_times) == max_hour:
                    log("%%SYS-4-MAIL_LIMIT: osiągnięto limit %d maili/h — kolejne zdarzenia pójdą zbiorczo" % max_hour)
            except Exception as ex:  # SMTP niedostępny, zły login itp.
                log("%%SYS-3-MAIL_FAIL: nie wysłano %d zdarzeń: %s — ponowna próba za %ds" % (len(events), ex, backoff))
                next_try = now + backoff
                backoff = min(backoff * 2, 600)
        time.sleep(5)


def test():
    load_conf()
    line = "%%SYS-5-MAIL_TEST: test powiadomień z routera %s" % host()
    ev = [{"time": time.strftime("%Y-%m-%d %H:%M:%S"), "sev": 5, "line": line}]
    try:
        send("[%s] TEST powiadomień routera" % host().split(".")[0],
             body_for(ev, "Jeśli czytasz tę wiadomość, powiadomienia e-mail działają."))
    except Exception as ex:
        print("BŁĄD wysyłki: %s" % ex)
        log("%%SYS-3-MAIL_FAIL: test nieudany: %s" % ex)
        return 1
    print("Wysłano mail testowy do: %s" % ", ".join(recipients()))
    log("%%SYS-6-MAIL_SENT: mail testowy do %s" % ", ".join(recipients()))
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "queue" and len(sys.argv) > 2:
        queue(" ".join(sys.argv[2:]))
    elif cmd == "run":
        try:
            run()
        except KeyboardInterrupt:
            pass
    elif cmd == "test":
        sys.exit(test())
    elif cmd == "categories":
        load_conf()
        send = CFG["MAIL_SEND"].upper().replace(",", " ").split()
        print("Kategorie zdarzeń (MAIL_SEND w %s):" % CONF)
        for name, desc, _p in CATEGORIES:
            print("  [%s] %-10s %s" % ("x" if ("ALL" in send or name in send) else " ", name, desc))
        print("Zakończenia zdarzeń (MAIL_SEND_CLEAR): %s, maks. poziom (MAIL_MAX_SEV): %s"
              % (CFG["MAIL_SEND_CLEAR"], CFG["MAIL_MAX_SEV"]))
    else:
        print("użycie: router-notify queue \"%FAC-SEV-MNEM: opis\" | run | test | categories")
        sys.exit(2)
ROUTER_NOTIFY_PY
}

prog_router_bootcheck() {
  sed "s/@@BIRDUNIT@@/$(bird_unit)/" <<'EOF'
#!/bin/bash
# router-bootcheck — uruchamiany raz po starcie systemu (router-bootcheck.service).
#   * wykrywa, że poprzedni start nie zakończył się normalnym wyłączeniem
#     (kernel panic, watchdog, zanik zasilania) i czy zachował się zapis paniki (pstore),
#   * czeka do 3 minut, aż usługi routera wstaną, sprawdza porty VPP i BIRD,
#   * wynik: /var/log/router-monitor/router-monitor.log, syslog (local0) i e-mail.
# Przy zamykaniu systemu (ExecStop) wołany z --shutdown: zapisuje znacznik czystego wyłączenia.
STATE=/var/lib/router
LOG=/var/log/router-monitor/router-monitor.log
UNITS="netns-dataplane vpp router-ifaces @@BIRDUNIT@@ snmpd-dataplane vpp-snmp-agent hsflowd router-monitor router-notify"
mkdir -p "$STATE" /var/log/router-monitor
report() {
  logger -t router-bootcheck -p "$1" "$2"
  printf '%s %s\n' "$(date '+%F %T')" "$2" >>"$LOG"
  /opt/router/bin/router-notify queue "$2" >/dev/null 2>&1 || true
}
if [[ ${1:-} == --shutdown ]]; then date '+%F %T' >"$STATE/clean-shutdown"; exit 0; fi

if [[ -f $STATE/booted-before && ! -f $STATE/clean-shutdown ]]; then
  panic=$(find /var/lib/systemd/pstore -type f -newer "$STATE/booted-before" 2>/dev/null | head -n1)
  if [[ -n $panic ]]; then
    first=$(grep -m1 -E 'Kernel panic|BUG:|Oops|watchdog' "$panic" 2>/dev/null | cut -c1-160)
    report local0.crit "%SYS-1-KERNEL_PANIC: poprzedni start zakończył się awarią kernela, system wstał automatycznie; zapis: $panic; ${first:-brak opisu}"
  else
    report local0.crit "%SYS-1-UNCLEAN_REBOOT: poprzedni start nie zakończył się normalnym wyłączeniem (kernel panic, watchdog albo zasilanie); system wstał automatycznie"
  fi
fi
rm -f "$STATE/clean-shutdown"
touch "$STATE/booted-before"

deadline=$((SECONDS + 180))
while :; do
  bad=""
  for u in $UNITS; do systemctl is-active --quiet "$u" || bad="$bad $u"; done
  [[ -z $bad || $SECONDS -ge $deadline ]] && break
  sleep 5
done
ports=$(vppctl show interface 2>/dev/null | awk '$1 ~ /^hu[0-9]+$/ {print $1"="$3}' | xargs)
vver=$(vppctl show version 2>/dev/null | awk '{print $2}')
bird=$(birdc show status 2>/dev/null | grep -c 'Daemon is up and running')
hp=$(awk '/HugePages_Total/{print $2}' /proc/meminfo)
iso=$(cat /sys/devices/system/cpu/isolated 2>/dev/null)
[[ -n $vver ]] || bad="$bad vpp-cli"
[[ $bird -ge 1 ]] || bad="$bad bird-cli"
[[ -n $iso ]] || bad="$bad isolcpus"
if [[ -z $bad ]]; then
  report local0.notice "%SYS-5-BOOT_OK: router gotowy po ${SECONDS}s: VPP $vver, porty: ${ports:-brak}, BIRD działa, hugepages $hp, izolowane CPU $iso"
else
  report local0.crit "%SYS-2-BOOT_PROBLEM: po ${SECONDS}s nie działa:$bad (porty: ${ports:-brak}) — uruchom router-check"
fi
EOF
}

prog_router_fw() {
  cat <<'ROUTER_FW_PY'
#!/usr/bin/env python3
"""router-fw — firewall tranzytu na VPP (acl-plugin) z pliku /etc/router/firewall.conf

  router-fw show                       strefy, reguły i stan w VPP
  router-fw diff                       co zmieni się w VPP po zastosowaniu firewall.conf (niczego nie zmienia)
  router-fw check                      kontrola pliku i porównanie VPP z ostatnio zastosowaną konfiguracją
  router-fw apply [-y] [--confirm N]   zastosuj różnicowo, na żywo; --confirm: cofnij po N s, jeśli nie wpiszesz "confirm"
  router-fw confirm                    potwierdź zmianę z "apply --confirm"
  router-fw block IP [czas]            blokada doraźna (czas: 30m, 2h, 1d; bez czasu = bezterminowo)
  router-fw unblock IP                 zdejmij blokadę;  router-fw blocks = lista blokad
  router-fw counters [-w]              liczniki trafień reguł (pakiety, bajty, pkt/s);  counters clear = zerowanie
  router-fw boot                       (systemd) po starcie VPP odtwórz reguły
  router-fw expire                     (systemd, timer) zdejmij wygasłe blokady

Plik firewall.conf jest jedynym źródłem prawdy dla stref i reguł. Reguły działają tylko na ruch
przechodzący przez VPP (acl-plugin, tryb bezstanowy). Ruchu do samego routera nie filtruje —
to zadanie netfiltera w netns dataplane.
"""
import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import signal
import subprocess
import sys
import time

ROOT = os.environ.get("ROUTER_FW_ROOT", "")      # tylko do testów
CONF = ROOT + "/etc/router/firewall.conf"
LASTGOOD = ROOT + "/var/lib/router/fw.last-good.conf"
PREV = ROOT + "/var/lib/router/fw.prev.conf"
REJECTED = ROOT + "/var/lib/router/fw.rejected.conf"
STATE = ROOT + "/var/lib/router/fw.state.json"
BLOCKS = ROOT + "/var/lib/router/fw-blocks.json"
PENDING = ROOT + "/var/lib/router/fw.pending.json"
LOGDIR = ROOT + "/var/log/router-monitor"
LOG = LOGDIR + "/router-fw.log"
MONLOG = LOGDIR + "/router-monitor.log"
LOCK = ROOT + "/run/router-fw.lock"
NOTIFY = ROOT + "/opt/router/bin/router-notify"
SELF = "/opt/router/bin/router-fw"
VPPCTL = os.environ.get("ROUTER_FW_VPPCTL", "vppctl")
SYSTEMD_RUN = os.environ.get("ROUTER_FW_SYSTEMD_RUN", "systemd-run")
SYSTEMD = os.environ.get("ROUTER_FW_SYSTEMD", "1") == "1"
STATS_JSON = os.environ.get("ROUTER_FW_STATS_JSON", "")      # tylko testy: liczniki z pliku zamiast z VPP
TAG_PREFIX = "rfw"
MAX_CMD = int(os.environ.get("ROUTER_FW_MAX_CMD", "120000"))       # limit jednego argumentu execve to 128 KB — dłuższej listy ACL nie da się wgrać przez vppctl

ERR_RE = re.compile(r"unknown input|error|fail|invalid|conflict|not found|already|does not exist|not supported|in use",
                    re.I)
TTY = sys.stdout.isatty()
COMMANDS = {}


def command(name):
    def deco(fn):
        COMMANDS[name] = fn
        return fn
    return deco


def run_quiet(cmd):
    """Uruchamia polecenie bez wyjścia; zwraca kod (127, gdy programu nie ma)."""
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode
    except OSError:
        return 127


def color(s, c):
    return "\033[%sm%s\033[0m" % (c, s) if TTY else s


# --------------------------------------------------------------------------- logi
def now():
    return time.strftime("%F %T")


def log(msg):
    try:
        os.makedirs(LOGDIR, exist_ok=True)
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (now(), msg))
    except OSError:
        pass


def event(sev, mnem, text, mail=True):
    """Zdarzenie w stylu Cisco: log router-monitor + syslog + (opcjonalnie) e-mail."""
    line = "%%FW-%d-%s: %s" % (sev, mnem, text)
    log(line)
    try:
        os.makedirs(LOGDIR, exist_ok=True)
        with open(MONLOG, "a") as f:
            f.write("%s %s\n" % (now(), line))
    except OSError:
        pass
    prio = {1: "alert", 2: "crit", 3: "err", 4: "warning", 5: "notice"}.get(sev, "info")
    subprocess.run(["logger", "-t", "router-fw", "-p", "local0." + prio, line],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if mail and os.access(NOTIFY, os.X_OK):
        subprocess.run([NOTIFY, "queue", line], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return line


# --------------------------------------------------------------------------- plik firewall.conf
IDENT = re.compile(r"^[A-Za-z0-9_-]{1,24}$")
IFNAME = re.compile(r"^[A-Za-z0-9_.-]{1,40}$")
PROTOS = {"any": None, "tcp": 6, "udp": 17, "icmp": 1, "icmp6": 58}
ANY = {4: ipaddress.ip_network("0.0.0.0/0"), 6: ipaddress.ip_network("::/0")}
DIRECTION_RE = re.compile(r"^(?:([A-Za-z0-9_-]+)->|->([A-Za-z0-9_-]+))$")


class Rule:
    def __init__(self, lineno, direction, action, proto, src, sport, dst, dport, desc, raw):
        self.lineno, self.direction, self.action, self.proto = lineno, direction, action, proto
        self.src, self.sport, self.dst, self.dport = src, sport, dst, dport
        self.desc, self.raw = desc, raw


class Conf:
    def __init__(self):
        self.zones = {}                  # interfejs -> strefa
        self.lists = {}                  # nazwa -> [ip_network]
        self.rules = []                  # [Rule] w kolejności z pliku
        self.settings = {"counters": "on"}


def parse_ports(tok):
    if tok == "any":
        return None
    out = []
    for part in tok.split(","):
        m = re.fullmatch(r"(\d+)(?:-(\d+))?", part)
        if not m:
            raise ValueError("zły port '%s'" % part)
        lo, hi = int(m.group(1)), int(m.group(2) or m.group(1))
        if not 0 <= lo <= hi <= 65535:
            raise ValueError("zły zakres portów '%s'" % part)
        out.append((lo, hi))
    return out


def parse_addrs(tok, lists):
    if tok == "any":
        return None
    out = []
    for part in tok.split(","):
        if part.startswith("@"):
            if part[1:] not in lists:
                raise ValueError("nieznana lista '%s' (lista musi być zdefiniowana wyżej)" % part)
            out.extend(lists[part[1:]])
        else:
            try:
                out.append(ipaddress.ip_network(part, strict=False))
            except ValueError:
                raise ValueError("zły adres '%s'" % part)
    if not out:
        raise ValueError("lista adresów '%s' jest pusta" % tok)
    return out


def read_list_file(path):
    try:
        with open(ROOT + path) as f:
            lines = f.read().splitlines()
    except OSError as ex:
        raise ValueError("nie można czytać %s: %s" % (path, ex))
    out = []
    for raw in lines:
        s = re.split(r"\s#|^#", raw.strip(), maxsplit=1)[0].strip()
        if not s:
            continue
        try:
            out.append(ipaddress.ip_network(s, strict=False))
        except ValueError:
            raise ValueError("%s: zły adres '%s'" % (path, s))
    return out


def parse_rule(t, comment):
    """Kolumny reguły -> (kierunek, akcja, proto, src, sport, dst, dport, opis); ValueError przy błędzie."""
    if len(t) < 7:
        raise ValueError("za mało kolumn (kierunek akcja proto src sport dst dport [opis]): %s" % " ".join(t))
    m = DIRECTION_RE.match(t[0])
    if not m:
        raise ValueError("zły kierunek '%s' (np. internet-> albo ->internet)" % t[0])
    direction = (m.group(1), "in") if m.group(1) else (m.group(2), "out")
    if t[1] not in ("permit", "deny"):
        raise ValueError("akcja musi być permit albo deny, jest '%s'" % t[1])
    if t[2] not in PROTOS:
        raise ValueError("nieznany protokół '%s' (tcp, udp, icmp, icmp6, any)" % t[2])
    return direction, t[1], PROTOS[t[2]], t[3], t[4], t[5], t[6], (t[7] if len(t) == 8 else comment.strip())


def parse_conf(text):
    """Zwraca (Conf, błędy). Błąd w pliku = nic nie zostanie zastosowane."""
    conf, errs = Conf(), []
    for no, raw in enumerate(text.splitlines(), 1):
        parts = re.split(r"\s#", raw.strip(), maxsplit=1)
        body, comment = parts[0].strip(), (parts[1] if len(parts) > 1 else "")
        if not body or body.startswith("#"):
            continue
        t = body.split(None, 7)
        try:
            kw = t[0]
            if kw == "zone":
                if len(t) != 3:
                    raise ValueError("składnia: zone INTERFEJS STREFA")
                if not IFNAME.match(t[1]) or not IDENT.match(t[2]):
                    raise ValueError("zła nazwa interfejsu lub strefy (litery, cyfry, _ - ; strefa do 24 znaków)")
                if t[1] in conf.zones:
                    raise ValueError("interfejs %s ma już strefę %s" % (t[1], conf.zones[t[1]]))
                conf.zones[t[1]] = t[2]
            elif kw == "list":
                if len(t) < 3 or not IDENT.match(t[1]):
                    raise ValueError("składnia: list NAZWA adres... | include /ścieżka")
                items, k, nets = body.split()[2:], 0, []
                while k < len(items):
                    if items[k] == "include":
                        if k + 1 >= len(items):
                            raise ValueError("include wymaga ścieżki")
                        nets.extend(read_list_file(items[k + 1]))
                        k += 2
                    else:
                        nets.extend(parse_addrs(items[k], conf.lists))
                        k += 1
                conf.lists[t[1]] = nets
            elif kw == "set":
                if len(t) != 3 or t[1] != "counters" or t[2] not in ("on", "off"):
                    raise ValueError("znane ustawienie: set counters on|off")
                conf.settings["counters"] = t[2]
            else:
                direction, action, proto, src, sport, dst, dport, desc = parse_rule(t, comment)
                r = Rule(no, direction, action, proto, parse_addrs(src, conf.lists), parse_ports(sport),
                         parse_addrs(dst, conf.lists), parse_ports(dport), desc, " ".join(t[:7]))
                if proto not in (6, 17) and (r.sport or r.dport):
                    raise ValueError("porty można podać tylko dla tcp i udp")
                if not flatten(r):
                    raise ValueError("reguła nic nie obejmuje (src, dst i protokół z różnych rodzin adresów)")
                conf.rules.append(r)
        except ValueError as ex:
            errs.append("linia %d: %s" % (no, ex))
    zones = set(conf.zones.values())
    for r in conf.rules:
        if r.direction[0] not in zones:
            errs.append("linia %d: strefa '%s' nie ma żadnego interfejsu (zone ...)" % (r.lineno, r.direction[0]))
    return conf, errs

# --------------------------------------------------------------------------- reguła -> reguły ACL VPP
class Flat:
    """Jedna reguła ACL VPP (jedna rodzina adresów, jeden zakres portów)."""
    def __init__(self, action, src, dst, proto, sport, dport, parent):
        self.action, self.src, self.dst, self.proto = action, src, dst, proto
        self.sport, self.dport, self.parent = sport, dport, parent    # parent: nr linii | "block" | "default"

    def text(self):
        s = "%s src %s dst %s" % (self.action, self.src, self.dst)
        if self.proto is not None:
            s += " proto %d" % self.proto
        for name, pr in (("sport", self.sport), ("dport", self.dport)):
            if pr is not None:
                s += " %s %s" % (name, str(pr[0]) if pr[0] == pr[1] else "%d-%d" % pr)
        return s


def flatten(rule):
    """Reguła -> lista Flat: iloczyn adresów, portów i rodzin adresów (IPv4 / IPv6)."""
    fams = {1: {4}, 58: {6}}.get(rule.proto, {4, 6})
    out = []
    for s in rule.src or [None]:
        for d in rule.dst or [None]:
            f = set(fams)
            if s is not None:
                f &= {s.version}
            if d is not None:
                f &= {d.version}
            for v in sorted(f):
                for sp in rule.sport or [None]:
                    for dp in rule.dport or [None]:
                        out.append(Flat(rule.action, s or ANY[v], d or ANY[v], rule.proto, sp, dp, rule.lineno))
    return out

# --------------------------------------------------------------------------- kompilacja reguł do ACL VPP
class Group:
    """Jedna lista ACL w VPP: strefa + kierunek (in = wejście na interfejsach strefy, out = wyjście)."""
    def __init__(self, zone, direction, ifaces, flat):
        self.zone, self.dir, self.ifaces, self.flat = zone, direction, ifaces, flat
        self.key = "%s:%s" % (zone, direction)
        self.texts = [f.text() for f in flat]
        self.sha = hashlib.sha256("\n".join(self.texts).encode()).hexdigest()[:8]
        self.tag = "%s:%s:%s" % (TAG_PREFIX, self.key, self.sha)     # sha w tagu = wykrywanie zmiany treści

    def acl_command(self, index=None):
        return "set acl-plugin acl%s %s tag %s" % ("" if index is None else " index %d" % index,
                                                    ", ".join(self.texts), self.tag)


def build_groups(conf, blocks=()):
    """Conf + blokady doraźne -> {klucz: Group}. Blokady wchodzą na początek listy internet:in."""
    groups = {}
    for zone in sorted(set(conf.zones.values())):
        for d in ("in", "out"):
            flat = []
            if zone == "internet" and d == "in":
                for b in blocks:
                    net = ipaddress.ip_network(b["net"])
                    flat.append(Flat("deny", net, ANY[net.version], None, None, None, "block"))
            for r in conf.rules:
                if r.direction == (zone, d):
                    flat.extend(flatten(r))
            if not flat:
                continue
            flat.append(Flat("permit", ANY[4], ANY[4], None, None, None, "default"))
            flat.append(Flat("permit", ANY[6], ANY[6], None, None, None, "default"))
            ifaces = sorted(i for i, z in conf.zones.items() if z == zone)
            g = Group(zone, d, ifaces, flat)
            groups[g.key] = g
    return groups


# --------------------------------------------------------------------------- analiza reguł (check)
CRITICAL = [("tcp", 6, 179, "BGP"), ("udp", 17, 3784, "BFD"), ("udp", 17, 4784, "BFD")]


def _covers_nets(a, b):
    """Czy zbiór adresów a (None = dowolny) obejmuje cały zbiór b."""
    if a is None:
        return True
    if b is None:
        return False
    return all(any(x.version == y.version and x.subnet_of(y) for y in a) for x in b)


def _covers_ports(a, b):
    if a is None:
        return True
    if b is None:
        return False
    return all(any(y[0] <= x[0] and x[1] <= y[1] for y in a) for x in b)


def _hits(ports, n):
    return ports is not None and any(lo <= n <= hi for lo, hi in ports)


def analyze(conf):
    """Ostrzeżenia: reguły zacienione oraz deny, które mogą zerwać BGP/BFD z sąsiadami."""
    warns, seen = [], {}
    for r in conf.rules:
        for p in seen.get(r.direction, []):
            if ((p.proto is None or p.proto == r.proto) and _covers_nets(p.src, r.src)
                    and _covers_nets(p.dst, r.dst) and _covers_ports(p.sport, r.sport)
                    and _covers_ports(p.dport, r.dport)):
                warns.append("linia %d jest zacieniona przez linię %d (nigdy nie zadziała)" % (r.lineno, p.lineno))
                break
        seen.setdefault(r.direction, []).append(r)
        if r.action != "deny":
            continue
        blanket = r.src is None and r.dst is None and r.sport is None and r.dport is None
        for name, proto, port, what in CRITICAL:
            explicit = _hits(r.dport, port) or _hits(r.sport, port)
            if r.proto in (None, proto) and (explicit or (blanket and r.proto == proto)):
                warns.append("linia %d: deny obejmuje %s (%s/%d) — może zerwać sesje z sąsiadami"
                             % (r.lineno, what, name, port))
        if r.proto is None and r.src is None and r.dst is None and r.sport is None and r.dport is None:
            warns.append("linia %d: deny dla całego ruchu — zablokuje także BGP i BFD" % r.lineno)
    return warns

# --------------------------------------------------------------------------- VPP: odczyt stanu i zmiany
class VppError(Exception):
    pass


class Actual:
    def __init__(self):
        self.ifaces = {}     # nazwa -> sw_if_index
        self.acls = {}       # klucz "strefa:kier" -> (indeks, tag): nasze ACL (o tagu rfw:...)
        self.extra = []      # [(indeks, tag)]: duplikaty naszych ACL (po przerwanym apply)
        self.binds = {}      # (nazwa interfejsu, "in"|"out") -> [indeksy ACL]


def cli(cmd, timeout=15):
    try:
        r = subprocess.run([VPPCTL, cmd], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as ex:
        raise VppError("vppctl: %s" % ex)
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0 or "connect" in out.lower() and "fail" in out.lower():
        raise VppError("vppctl '%s': %s" % (cmd[:80], out.strip() or "kod %d" % r.returncode))
    return out


# Formaty wyjścia VPP, na których opiera się parser (do potwierdzenia w labie: docs/router-fw-lab-checklist.md):
#   show acl-plugin acl        ->  "acl-index 3 count 12 tag {rfw:internet:in:1a2b3c4d}"  + wiersze reguł
#   show acl-plugin interface  ->  "sw_if_index 5:" / "  input acl(s): 3 4" / "  output acl(s): 6"
ACL_RE = re.compile(r"acl-index\s+(\d+)\s+count\s+\d+\s+tag\s+\{([^}]*)\}")
SWIF_RE = re.compile(r"^\s*sw_if_index\s+(\d+)")
BIND_RE = re.compile(r"^\s*(input|output)\s+acl\(s\):\s*([\d\s,]*)")


def read_vpp():
    act = Actual()
    for line in cli("show interface").splitlines():
        m = re.match(r"^(\S+)\s+(\d+)\s", line)
        if m:
            act.ifaces[m.group(1)] = int(m.group(2))
    found = []
    for m in ACL_RE.finditer(cli("show acl-plugin acl")):
        if m.group(2).startswith(TAG_PREFIX + ":"):
            found.append((int(m.group(1)), m.group(2)))
    for idx, tag in sorted(found):
        key = tag[len(TAG_PREFIX) + 1:].rsplit(":", 1)[0]
        if key in act.acls:
            act.extra.append(act.acls[key])
        act.acls[key] = (idx, tag)
    by_idx = {v: k for k, v in act.ifaces.items()}
    cur = None
    for line in cli("show acl-plugin interface").splitlines():
        m = SWIF_RE.match(line)
        if m:
            cur = by_idx.get(int(m.group(1)))
            continue
        m = BIND_RE.match(line)
        if m and cur:
            ids = [int(x) for x in re.findall(r"\d+", m.group(2))]
            if ids:
                act.binds[(cur, "in" if m.group(1) == "input" else "out")] = ids
    return act


def wait_vpp(timeout):
    end = time.time() + timeout
    while True:
        try:
            cli("show version", timeout=5)
            return True
        except VppError:
            if time.time() > end:
                return False
            time.sleep(2)


class Step:
    """Jeden krok doprowadzenia VPP do stanu docelowego: create | replace | bind | unbind | delete."""
    def __init__(self, op, key, group=None, index=None, iface=None, direction=None):
        self.op, self.key, self.group, self.index = op, key, group, index
        self.iface, self.dir = iface, direction

    def command(self, idx_map):
        if self.op == "create":
            return self.group.acl_command()
        if self.op == "replace":
            return self.group.acl_command(self.index)
        idx = self.index if self.index is not None else idx_map[self.key]
        if self.op in ("bind", "unbind"):
            return "set acl-plugin interface %s %s acl %d%s" % (
                self.iface, "input" if self.dir == "in" else "output", idx, " del" if self.op == "unbind" else "")
        return "delete acl-plugin acl index %d" % idx

    def human(self):
        way = {"in": "wejście", "out": "wyjście"}.get(self.dir or (self.group.dir if self.group else ""), "")
        if self.op == "create":
            return "+ ACL %s (%d reguł)" % (self.key, len(self.group.flat))
        if self.op == "replace":
            return "~ ACL %s: nowa treść (%d reguł)" % (self.key, len(self.group.flat))
        if self.op == "bind":
            return "+ %s: %s na %s" % (self.key, way, self.iface)
        if self.op == "unbind":
            return "- %s: %s na %s" % (self.key, way, self.iface)
        return "- ACL %s" % self.key


def plan(groups, act):
    """Różnice VPP -> stan docelowy: lista Step (create/replace, bind, unbind, delete). Cudzych ACL nie rusza."""
    defs, binds, unbinds, deletes = [], [], [], []
    for key, g in sorted(groups.items()):
        cur = act.acls.get(key)
        if cur is None:
            defs.append(Step("create", key, group=g))
        elif cur[1] != g.tag:
            defs.append(Step("replace", key, group=g, index=cur[0]))
    managed = {idx: key for key, (idx, _t) in act.acls.items()}
    managed.update({idx: tag[len(TAG_PREFIX) + 1:].rsplit(":", 1)[0] for idx, tag in act.extra})
    want = {}
    for g in groups.values():
        for ifn in g.ifaces:
            if ifn in act.ifaces:
                want[(ifn, g.dir)] = g.key
    for (ifn, d), lst in sorted(act.binds.items()):
        for idx in lst:
            key = managed.get(idx)
            if key is None:
                continue
            if not (want.get((ifn, d)) == key and act.acls.get(key, (None,))[0] == idx):
                unbinds.append(Step("unbind", key, index=idx, iface=ifn, direction=d))
    for (ifn, d), key in sorted(want.items()):
        idx = act.acls.get(key, (None,))[0]
        if idx is None or idx not in act.binds.get((ifn, d), []):
            binds.append(Step("bind", key, index=idx, iface=ifn, direction=d))
    for idx, key in sorted(managed.items()):
        if key not in groups or act.acls.get(key, (None,))[0] != idx:
            deletes.append(Step("delete", key, index=idx))
    return defs + binds + unbinds + deletes


def run_steps(steps):
    """Wykonuje kroki po kolei; przy pierwszym błędzie staje. Zwraca (wykonane, nieudany_krok|None, tekst błędu)."""
    idx_map, done = {}, []
    for st in steps:
        try:
            cmd = st.command(idx_map)
        except KeyError:
            return done, st, "brak indeksu ACL %s" % st.key
        log("vppctl: %s" % cmd)
        try:
            out = cli(cmd)
        except VppError as ex:
            log("BŁĄD: %s" % ex)
            return done, st, str(ex)
        if ERR_RE.search(out):
            log("BŁĄD: %s" % out.strip())
            return done, st, out.strip()
        if st.op == "create":
            act = read_vpp()
            if st.key not in act.acls:
                return done, st, "ACL %s nie pojawił się w VPP" % st.key
            idx_map[st.key] = act.acls[st.key][0]
        done.append(st)
    return done, None, ""


def enable_counters(on):
    """Włącza (API acl_stats_intf_counters_enable) liczniki per reguła w segmencie statystyk VPP."""
    if STATS_JSON or os.environ.get("ROUTER_FW_NO_PAPI"):
        return True
    try:
        import glob
        from vpp_papi import VPPApiClient
        vpp = VPPApiClient(apifiles=glob.glob("/usr/share/vpp/api/**/*.api.json", recursive=True),
                           server_address="/run/vpp/api.sock")
        vpp.connect("router-fw")
        try:
            vpp.api.acl_stats_intf_counters_enable(enable=1 if on else 0)
        finally:
            vpp.disconnect()
        return True
    except Exception as ex:     # noqa: BLE001 — brak vpp_papi / pliku API / gniazda nie może blokować apply
        log("liczniki ACL: nie udało się %s (%s)" % ("włączyć" if on else "wyłączyć", ex))
        return False

# --------------------------------------------------------------------------- stan, blokady, blokada współbieżności
def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def lock():
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    fd = open(LOCK, "w")
    end = time.time() + 120
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.time() > end:
                sys.exit("inna instancja router-fw działa zbyt długo (%s)" % LOCK)
            time.sleep(1)


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def pl(n, one, few, many):
    if n == 1:
        return "%d %s" % (n, one)
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return "%d %s" % (n, few)
    return "%d %s" % (n, many)


def load_blocks(include_expired=False):
    """Blokady doraźne: aktywne (wygasłe pomija; usuwa je dopiero 'expire') albo wszystkie wpisy z pliku."""
    t = time.time()
    return [b for b in load_json(BLOCKS, []) if include_expired or not b.get("expires") or b["expires"] > t]


def freeze(text, conf):
    """Treść pliku z rozwiniętymi listami (include): to zapisujemy jako last-good, żeby cofnięcie, boot i check
    nie zależały od plików list, które operator mógł już zmienić. Numery linii zostają bez zmian."""
    out = []
    for raw in text.splitlines():
        t = raw.split()
        if len(t) >= 3 and t[0] == "list" and t[1] in conf.lists:
            out.append("list %s %s" % (t[1], " ".join(str(n) for n in conf.lists[t[1]])))
        else:
            out.append(raw)
    return "\n".join(out) + "\n"


def get_desired(path):
    try:
        with open(path) as f:
            text = f.read()
    except OSError as ex:
        return None, ["nie można czytać %s: %s" % (path, ex)], ""
    conf, errs = parse_conf(text)
    return (None if errs else conf), errs, text


def summarize(steps, limit=6):
    s = "; ".join(st.human() for st in steps[:limit])
    return s + ("; … (+%d)" % (len(steps) - limit) if len(steps) > limit else "")


def show_steps(steps, prefix="  "):
    for st in steps:
        c = "32" if st.human().startswith("+") else "31" if st.human().startswith("-") else "33"
        print(prefix + color(st.human(), c))


# --------------------------------------------------------------------------- apply / boot / diff
def prepare(args, boot, source, lenient):
    """Tylko odczyt: (kontekst, 0) albo (None, kod wyjścia). Wołane przed pytaniem i jeszcze raz pod blokadą."""
    path, fallback = source or CONF, False
    conf, errs, text = get_desired(path)
    if conf is None and boot and os.path.exists(LASTGOOD):
        event(2, "CONFIG_ERROR", "błędy w %s (%s) — używam ostatniej poprawnej konfiguracji" % (path, errs[0]))
        path, fallback = LASTGOOD, True
        conf, errs, text = get_desired(LASTGOOD)
    if conf is None:
        if boot:
            event(2, "CONFIG_ERROR", "błędy w firewall.conf: %s" % "; ".join(errs[:3]))
        for e in errs:
            print(color("  " + e, "31"))
        print(color("Nic nie zmieniono — popraw %s i uruchom ponownie." % path, "31"))
        return None, 2
    blocks = load_blocks()
    if blocks and "internet" not in conf.zones.values():
        msg = "są blokady doraźne, ale w pliku nie ma żadnego interfejsu ze strefą 'internet'"
        if not boot:
            print(color("  " + msg, "31"))
            return None, 2
        event(4, "BLOCKS_IGNORED", msg)
        blocks = []
    if boot and not wait_vpp(args.timeout):
        event(2, "APPLY_FAIL", "VPP nie odpowiada po %d s — reguły nie zostały wgrane" % args.timeout)
        return None, 3
    try:
        act = read_vpp()
    except VppError as ex:
        print(color("VPP nie odpowiada: %s" % ex, "31"))
        return None, 3
    groups = build_groups(conf, blocks)
    big = sorted(g.key for g in groups.values() if len(g.acl_command()) > MAX_CMD)
    if big:
        print(color("  lista ACL %s jest za długa dla jednego polecenia vppctl (limit ok. %d KB) — skróć listy"
                    % (", ".join(big), MAX_CMD // 1000), "31"))
        return None, 2
    missing = sorted({i for g in groups.values() for i in g.ifaces if i not in act.ifaces})
    if missing and not (boot or lenient):
        print(color("  interfejsy spoza VPP: %s (sprawdź zone ... w firewall.conf i router-ifaces)" % ", ".join(missing), "31"))
        return None, 2
    if missing:
        event(4, "IFACE_MISSING", "brak interfejsów w VPP: %s — reguły na nich zostaną wgrane po ich utworzeniu "
              "(router-fw apply)" % ", ".join(missing), mail=False)
    return {"conf": conf, "text": text, "path": path, "fallback": fallback, "groups": groups,
            "steps": plan(groups, act)}, 0


def report_plan(ctx):
    for w in analyze(ctx["conf"]):
        print(color("  UWAGA: " + w, "33"))
    if not ctx["steps"]:
        print("Brak zmian — VPP jest zgodny z %s." % ctx["path"])
    else:
        print("Zmiany do wprowadzenia (%s → VPP):" % ctx["path"])
        show_steps(ctx["steps"])


def do_apply(args, boot=False, source=None, lenient=False):
    shown = None
    if not boot and sys.stdin.isatty() and not args.yes:
        # pytanie zadajemy BEZ blokady (operator może je zostawić otwarte); pod blokadą plan liczymy jeszcze raz
        ctx, rc = prepare(args, boot, source, lenient)
        if ctx is None:
            return rc
        report_plan(ctx)
        if not ctx["steps"]:
            return 0
        try:
            ans = input("Zastosować? [t/N] ").strip().lower()
        except EOFError:
            ans = ""
        if ans not in ("t", "tak", "y", "yes"):
            print("Przerwano — nic nie zmieniono.")
            return 1
        shown = [s.human() for s in ctx["steps"]]
    fd = lock()
    state = load_json(STATE, {})
    ctx, rc = prepare(args, boot, source, lenient)
    if ctx is None:
        return rc
    conf, text, path, groups, steps = ctx["conf"], ctx["text"], ctx["path"], ctx["groups"], ctx["steps"]
    if shown is not None and [s.human() for s in steps] != shown:
        print(color("Stan VPP lub pliku zmienił się w trakcie pytania — nic nie zmieniono, uruchom apply ponownie.", "33"))
        return 1
    if not boot and shown is None:
        report_plan(ctx)
    if args.confirm and steps and not boot and not arm_rollback(args.confirm):
        return 4
    done, failed, err = run_steps(steps)
    enable_counters(conf.settings["counters"] == "on")
    frozen = freeze(text, conf)
    keep = {g.tag for g in groups.values()}
    state.update({"applied": now(), "conf_sha": sha(frozen), "source": path,
                  "baseline": {t: v for t, v in state.get("baseline", {}).items() if t in keep}})
    if failed is None and not ctx["fallback"]:
        os.makedirs(os.path.dirname(LASTGOOD), exist_ok=True)
        with open(LASTGOOD, "w") as f:
            f.write(frozen)
    if failed is not None:
        save_json(STATE, state)
        print(color("\nNie udało się doprowadzić VPP do zgodności: %s\n  krok: %s\nSzczegóły: %s"
                    % (err, failed.human(), LOG), "31"))
        event(3, "APPLY_FAIL", "nie udało się zastosować (%s): %s — szczegóły %s" % (failed.human(), err[:120], LOG))
        return 4
    if boot:
        event(6, "RESTORED", "reguły firewalla odtworzone po starcie VPP (%s, %d list ACL, źródło %s)"
              % (pl(len(done), "krok", "kroki", "kroków"), len(groups), path), mail=False)
        state["drift"] = ""
    elif done:
        event(5, "APPLIED", summarize(done))
        if state.get("drift"):
            event(5, "DRIFT_END", "VPP znów zgodny z firewall.conf")
        state["drift"] = ""
        print(color("Zastosowano: %s. VPP zgodny z %s." % (pl(len(done), "zmiana", "zmiany", "zmian"), path), "32"))
    save_json(STATE, state)
    del fd
    return 0


@command("apply")
def cmd_apply(args):
    if os.path.exists(PENDING):
        print(color("Poprzednia zmiana czeka na potwierdzenie — wykonaj: router-fw confirm (zostaje) "
                    "albo router-fw rollback (cofnij).", "33"))
        return 1
    return do_apply(args)


@command("boot")
def cmd_boot(args):
    settle_pending("po starcie VPP")          # niepotwierdzona zmiana (apply --confirm) nie przeżywa restartu
    return do_apply(args, boot=True)


@command("diff")
def cmd_diff(args):
    conf, errs, _text = get_desired(CONF)
    if conf is None:
        for e in errs:
            print(color("  " + e, "31"))
        return 2
    try:
        act = read_vpp()
    except VppError as ex:
        print(color("VPP nie odpowiada: %s" % ex, "31"))
        return 3
    steps = plan(build_groups(conf, load_blocks()), act)
    if not steps:
        print("Brak różnic — VPP jest zgodny z %s." % CONF)
        return 0
    print("Po 'router-fw apply' w VPP zmieni się:")
    show_steps(steps)
    return 1


# --------------------------------------------------------------------------- check / show
@command("check")
def cmd_check(args):
    """Kontrola pliku firewall.conf + porównanie VPP z ostatnio zastosowaną konfiguracją (rozjazd)."""
    quiet, rc = args.log, 0
    conf, errs, text = get_desired(CONF)
    if conf is None:
        for e in errs:
            print(color("  " + e, "31"))
        if quiet:
            event(2, "CONFIG_ERROR", "błędy w firewall.conf: %s" % "; ".join(errs[:3]), mail=False)
        rc = 2
    else:
        for w in analyze(conf):
            print(color("  UWAGA: " + w, "33"))
        if not quiet:
            print("firewall.conf: %d stref(y), %s, %s — składnia OK." % (
                len(set(conf.zones.values())), pl(len(conf.rules), "reguła", "reguły", "reguł"),
                pl(len(conf.lists), "lista", "listy", "list")))
    state = load_json(STATE, {})
    if not os.path.exists(LASTGOOD):
        if not quiet:
            print("Firewall nie był jeszcze stosowany (router-fw apply).")
        return rc
    applied, aerrs, _t = get_desired(LASTGOOD)
    if applied is None:
        print(color("  ostatnia zastosowana konfiguracja jest uszkodzona: %s" % aerrs[0], "31"))
        return 2
    try:
        act = read_vpp()
    except VppError as ex:
        print(color("VPP nie odpowiada: %s" % ex, "31"))
        return 3
    steps = plan(build_groups(applied, load_blocks(include_expired=True)), act)
    if steps:
        print(color("Rozjazd: VPP różni się od ostatnio zastosowanej konfiguracji:", "31"))
        show_steps(steps)
        if quiet and not state.get("drift"):
            state["drift"] = summarize(steps)
            save_json(STATE, state)
            event(4, "DRIFT", "VPP różni się od firewall.conf: %s" % state["drift"])
        rc = rc or 1
    else:
        if not quiet:
            print("VPP jest zgodny z ostatnio zastosowaną konfiguracją.")
        if state.get("drift"):
            state["drift"] = ""
            save_json(STATE, state)
            event(5, "DRIFT_END", "VPP znów zgodny z firewall.conf")
    if conf is not None and state.get("conf_sha") and sha(freeze(text, conf)) != state["conf_sha"] and not quiet:
        print("Plik firewall.conf zmieniono po ostatnim apply — zobacz: router-fw diff")
    return rc


@command("show")
def cmd_show(args):
    conf, errs, _text = get_desired(CONF)
    if conf is None:
        for e in errs:
            print(color("  " + e, "31"))
        return 2
    try:
        act = read_vpp()
    except VppError:
        act = None
    groups = build_groups(conf, load_blocks())
    print(color("Strefy:", "1"))
    for z in sorted(set(conf.zones.values())):
        print("  %-12s %s" % (z, " ".join(sorted(i for i, zz in conf.zones.items() if zz == z))))
    print(color("\nListy ACL:", "1"))
    for key, g in sorted(groups.items()):
        cur = act.acls.get(key) if act else None
        state = ("ACL %d w VPP" % cur[0] if cur else "brak w VPP") if act else "VPP nie odpowiada"
        bound = [i for i in g.ifaces if act and cur and cur[0] in act.binds.get((i, g.dir), [])]
        print("  %-14s %3d reguł  %-16s przypięta do: %s" % (key, len(g.flat), state, " ".join(bound) or "—"))
    print(color("\nReguły:", "1"))
    for r in conf.rules:
        print("  %4d  %s%s" % (r.lineno, r.raw, ("   # " + r.desc) if r.desc else ""))
    blocks = load_blocks()
    if blocks:
        print(color("\nBlokady doraźne: %d (router-fw blocks)" % len(blocks), "1"))
    return 0

# --------------------------------------------------------------------------- apply --confirm / confirm / rollback
def arm_rollback(sec):
    """Zapamiętuje poprzednią konfigurację i uzbraja jednorazowy timer cofnięcia (systemd-run).
    Zwraca False (i nic nie zostaje zmienione), gdy timera nie da się uzbroić."""
    prev = ""
    if os.path.exists(LASTGOOD):
        with open(LASTGOOD) as f:
            prev = f.read()
    os.makedirs(os.path.dirname(PREV), exist_ok=True)
    with open(PREV, "w") as f:
        f.write(prev)
    save_json(PENDING, {"deadline": int(time.time()) + sec, "prev": PREV})
    log("apply --confirm %d: cofnięcie do %s, jeśli nie będzie 'router-fw confirm'" % (sec, PREV))
    if SYSTEMD:
        for unit in ("router-fw-rollback.timer", "router-fw-rollback.service"):
            run_quiet(["systemctl", "stop", unit])
        run_quiet(["systemctl", "reset-failed", "router-fw-rollback.service"])
        rc = run_quiet([SYSTEMD_RUN, "--unit=router-fw-rollback", "--on-active=%ds" % sec,
                        "--description=router-fw: automatyczne cofnięcie niepotwierdzonej zmiany", SELF, "rollback"])
        if rc != 0:
            os.remove(PENDING)
            log("systemd-run zwrócił %d — timer cofnięcia nie został uzbrojony" % rc)
            print(color("Nie udało się uzbroić timera cofnięcia (systemd-run, kod %d) — nic nie zmieniono." % rc, "31"))
            return False
    print(color("  Masz %d s na potwierdzenie: router-fw confirm (inaczej zmiana zostanie cofnięta)." % sec, "33"))
    return True


def settle_pending(why):
    """Odrzuca niepotwierdzoną zmianę: firewall.conf wraca do poprzedniej zastosowanej wersji,
    a odrzucona zostaje w fw.rejected.conf. Zwraca True, gdy była zmiana do odrzucenia."""
    fd = lock()
    pend = load_json(PENDING, None)
    if not pend:
        return False
    prev = ""
    try:
        with open(pend["prev"]) as f:
            prev = f.read()
    except OSError:
        pass
    try:
        with open(CONF) as f:
            rejected = f.read()
        os.makedirs(os.path.dirname(REJECTED), exist_ok=True)
        with open(REJECTED, "w") as f:
            f.write(rejected)
    except OSError:
        pass
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    with open(CONF, "w") as f:
        f.write(prev or "# firewall.conf — poprzednia zastosowana wersja była pusta; odrzucona zmiana: %s\n" % REJECTED)
    os.remove(PENDING)
    if SYSTEMD:
        run_quiet(["systemctl", "stop", "router-fw-rollback.timer"])
    fd.close()
    event(4, "ROLLBACK", "%s: zmiana nie została potwierdzona — firewall.conf wrócił do poprzedniej wersji, "
          "odrzucona zapisana w %s" % (why, REJECTED))
    return True


@command("confirm")
def cmd_confirm(args):
    fd = lock()
    if not os.path.exists(PENDING):
        print("Brak zmiany oczekującej na potwierdzenie.")
        return 0
    os.remove(PENDING)
    if SYSTEMD:
        run_quiet(["systemctl", "stop", "router-fw-rollback.timer"])
    fd.close()
    event(5, "CONFIRMED", "zmiana firewalla potwierdzona", mail=False)
    print("Potwierdzono — zmiana zostaje.")
    return 0


@command("rollback")
def cmd_rollback(args):
    """(timer systemd) cofa niepotwierdzoną zmianę do konfiguracji sprzed 'apply --confirm'."""
    if not settle_pending("timer"):
        return 0
    rc = do_apply(argparse.Namespace(yes=True, confirm=0, timeout=args.timeout), lenient=True)
    if rc != 0:
        event(2, "ROLLBACK_FAIL", "poprzednia konfiguracja firewalla nie została wgrana do VPP (kod %d) — "
              "sprawdź: router-fw check" % rc)
    return rc


# --------------------------------------------------------------------------- blokady doraźne
def parse_duration(s):
    m = re.fullmatch(r"(\d+)([smhd]?)", s)
    if not m:
        raise ValueError("zły czas '%s' (np. 30m, 2h, 1d)" % s)
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]


def fmt_left(expires):
    if not expires:
        return "bezterminowo"
    left = max(0, int(expires - time.time()))
    return "%dd %02dh %02dm" % (left // 86400, left % 86400 // 3600, left % 3600 // 60) if left >= 86400 else \
        "%dh %02dm" % (left // 3600, left % 3600 // 60) if left >= 3600 else "%dm %02ds" % (left // 60, left % 60)


def apply_blocks():
    """Wdraża blokady na podstawie OSTATNIO ZASTOSOWANEJ konfiguracji (nie niezatwierdzonej edycji pliku);
    przy niedostępnym VPP blokada zostanie wgrana przy starcie VPP."""
    src = LASTGOOD if os.path.exists(LASTGOOD) else None
    rc = do_apply(argparse.Namespace(yes=True, confirm=0, timeout=0), source=src, lenient=True)
    if rc == 3:
        print(color("VPP nie odpowiada — zmiana zapisana, zostanie wgrana przy starcie VPP.", "33"))
    return rc


def modify_blocks(add=(), remove=()):
    """Dopisuje i usuwa wpisy pliku blokad pod blokadą (równoległe wywołania nie gubią wpisów), wdraża je,
    a gdy wdrożenie zostało odrzucone, cofa tylko własną zmianę. Zwraca (kod, usunięte wpisy)."""
    nets = {a["net"] for a in add}
    fd = lock()
    cur = load_json(BLOCKS, [])
    removed = [b for b in cur if b in remove or b["net"] in nets]
    save_json(BLOCKS, [b for b in cur if b not in removed] + list(add))
    fd.close()
    rc = apply_blocks()
    if rc not in (0, 3):
        fd = lock()
        cur = [b for b in load_json(BLOCKS, []) if b not in add]
        have = {b["net"] for b in cur}
        save_json(BLOCKS, cur + [b for b in removed if b["net"] not in have])
        fd.close()
        print(color("Zmiana blokad nie została wdrożona (kod %d) — plik blokad przywrócony." % rc, "31"))
    return rc, removed


@command("block")
def cmd_block(args):
    if not args.rest or len(args.rest) > 2:
        print("użycie: router-fw block IP|prefiks [czas]   (czas: 30m, 2h, 1d; bez czasu = bezterminowo)")
        return 2
    try:
        net = ipaddress.ip_network(args.rest[0], strict=False)
        secs = parse_duration(args.rest[1]) if len(args.rest) == 2 else 0
    except ValueError as ex:
        print(color(str(ex), "31"))
        return 2
    entry = {"net": str(net), "added": int(time.time()), "expires": int(time.time()) + secs if secs else 0,
             "by": os.environ.get("SUDO_USER") or os.environ.get("USER") or "root"}
    rc, _removed = modify_blocks(add=[entry])
    if rc in (0, 3):
        print("Zablokowano %s (%s)." % (net, fmt_left(entry["expires"])))
        event(5, "BLOCK", "blokada %s (%s)" % (net, fmt_left(entry["expires"])))
    return rc


@command("unblock")
def cmd_unblock(args):
    if len(args.rest) != 1:
        print("użycie: router-fw unblock IP|prefiks")
        return 2
    try:
        net = str(ipaddress.ip_network(args.rest[0], strict=False))
    except ValueError as ex:
        print(color(str(ex), "31"))
        return 2
    found = [b for b in load_json(BLOCKS, []) if b["net"] == net]
    if not found:
        print("Nie ma blokady %s." % net)
        return 1
    rc, _removed = modify_blocks(remove=found)
    if rc in (0, 3):
        event(5, "UNBLOCK", "zdjęto blokadę %s" % net)
    return rc


@command("blocks")
def cmd_blocks(args):
    blocks = load_blocks()
    if not blocks:
        print("Brak blokad doraźnych.")
        return 0
    print("%-40s %-14s %s" % ("Adres", "Do końca", "Dodał"))
    for b in sorted(blocks, key=lambda x: x["net"]):
        print("%-40s %-14s %s  (%s)" % (b["net"], fmt_left(b["expires"]), b.get("by", "?"),
                                        time.strftime("%F %T", time.localtime(b["added"]))))
    return 0


@command("expire")
def cmd_expire(args):
    """(timer) usuwa wygasłe blokady z pliku i z VPP."""
    t = time.time()
    gone = [b for b in load_json(BLOCKS, []) if b.get("expires") and b["expires"] <= t]
    if not gone:
        return 0
    rc, removed = modify_blocks(remove=gone)
    if rc in (0, 3):
        event(5, "BLOCK_EXPIRED", "wygasły blokady: %s" % ", ".join(b["net"] for b in removed))
    return rc


# --------------------------------------------------------------------------- liczniki trafień (jak "show access-lists")
def read_counters(index, n):
    """Liczniki reguł jednego ACL: lista n krotek (pakiety, bajty). Źródło: /acl/<indeks>/matches."""
    if STATS_JSON:
        data = load_json(STATS_JSON, {}).get(str(index), [])
        return [tuple(data[i]) if i < len(data) else (0, 0) for i in range(n)]
    from vpp_papi.vpp_stats import VPPStats
    stats = VPPStats(socketname="/run/vpp/stats.sock", timeout=2)
    stats.connect()
    try:
        c = stats["/acl/%d/matches" % index]
        return [(int(c[:, i].sum_packets()), int(c[:, i].sum_octets())) for i in range(n)]
    finally:
        try:
            stats.disconnect()
        except Exception:      # noqa: BLE001
            pass


def dir_label(zone, d):
    return "%s->" % zone if d == "in" else "->%s" % zone


def fmt_num(n):
    return "{:,}".format(int(n)).replace(",", " ")


def fmt_bytes(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1000 or unit == "GB":
            return "%d B" % n if unit == "B" else "%.1f %s" % (n, unit)
        n /= 1000.0
    return "%.1f GB" % n


def raw_counters(groups, act):
    """{klucz: (Group, indeks|None, [(pakiety, bajty) na każdą regułę ACL])} — bez punktu odniesienia."""
    out = {}
    for key, g in groups.items():
        idx = act.acls.get(key, (None,))[0]
        out[key] = (g, idx, read_counters(idx, len(g.flat)) if idx is not None else [(0, 0)] * len(g.flat))
    return out


def counter_rows(raw, conf, state):
    """Zlicza liczniki ACL do wierszy 'jedna reguła z pliku = jeden wiersz', odejmując punkt odniesienia."""
    by_line = {r.lineno: r for r in conf.rules}
    snap = []
    for key in sorted(raw):
        g, idx, vals = raw[key]
        base = state.get("baseline", {}).get(g.tag) or [(0, 0)] * len(vals)
        rows = []
        for f, (p, b), (bp, bb) in zip(g.flat, vals, base):
            if p < bp or b < bb:
                bp, bb = 0, 0          # VPP wyzerował liczniki (restart, zmiana ACL) — punkt odniesienia jest nieaktualny
            label = f.parent if isinstance(f.parent, str) else str(f.parent)
            if rows and rows[-1]["parent"] == f.parent:
                rows[-1]["pkts"] += p - bp
                rows[-1]["bytes"] += b - bb
                continue
            if isinstance(f.parent, int):
                r = by_line.get(f.parent)
                text = (r.raw.split(None, 1)[1] if r else "?") + (("   # " + r.desc) if r and r.desc else "")
            else:
                label = "blokada" if f.parent == "block" else "domyślna"
                text = "deny src %s" % f.src if f.parent == "block" else "permit any"
            rows.append({"parent": f.parent, "label": label, "text": text, "pkts": p - bp, "bytes": b - bb})
        snap.append({"group": g, "index": idx, "rows": rows})
    return snap


def print_counters(snap, prev=None, dt=1.0):
    old = {s["group"].key: s["rows"] for s in (prev or [])}
    for s in snap:
        g = s["group"]
        print(color("%s  (%s: %s)  %s" % (dir_label(g.zone, g.dir), "wejście" if g.dir == "in" else "wyjście",
                                          " ".join(g.ifaces), "ACL %d" % s["index"] if s["index"] is not None
                                          else "brak w VPP"), "1"))
        print("  %-9s %-60s %18s %12s %10s" % ("reguła", "opis", "pakiety", "bajty", "pkt/s"))
        for i, r in enumerate(s["rows"]):
            rate = ""
            prows = old.get(g.key)
            if prows and i < len(prows) and prows[i]["parent"] == r["parent"] and dt > 0:
                rate = fmt_num(max(0, r["pkts"] - prows[i]["pkts"]) / dt)
            print("  %-9s %-60s %18s %12s %10s" % (r["label"], r["text"][:60], fmt_num(r["pkts"]),
                                                   fmt_bytes(r["bytes"]), rate))


def counters_snapshot():
    """(snapshot, błąd): liczniki list ACL wgranych na podstawie ostatnio zastosowanej konfiguracji."""
    conf, errs, _t = get_desired(LASTGOOD)
    if conf is None:
        return None, "firewall nie był jeszcze stosowany (router-fw apply)" if not os.path.exists(LASTGOOD) else errs[0]
    try:
        act = read_vpp()
    except VppError as ex:
        return None, "VPP nie odpowiada: %s" % ex
    groups = build_groups(conf, load_blocks(include_expired=True))
    return (conf, groups, act), ""


@command("counters")
def cmd_counters(args):
    ctx, err = counters_snapshot()
    if ctx is None:
        print(color(err, "31"))
        return 3
    conf, groups, act = ctx
    state = load_json(STATE, {})
    if conf.settings["counters"] == "off":
        print("Liczniki są wyłączone (set counters off w firewall.conf).")
        return 0
    stale = sorted(k for k, g in groups.items() if k in act.acls and act.acls[k][1] != g.tag)
    for k in stale:
        print(color("  lista %s: treść ACL w VPP różni się od zastosowanej konfiguracji — liczniki pominięte "
                    "(router-fw check / apply)" % k, "33"))
    groups = {k: g for k, g in groups.items() if k not in stale}
    try:
        if args.rest == ["clear"]:
            state["baseline"] = {g.tag: [list(v) for v in vals] for g, _i, vals in raw_counters(groups, act).values()}
            save_json(STATE, state)
            print("Liczniki wyzerowane (punkt odniesienia po stronie router-fw).")
            return 0
        if args.rest:
            print("użycie: router-fw counters [-w] | router-fw counters clear")
            return 2
        prev, t0 = counter_rows(raw_counters(groups, act), conf, state), time.time()
        while True:
            time.sleep(1)
            snap = counter_rows(raw_counters(groups, act), conf, state)
            dt = time.time() - t0
            if args.watch and TTY:
                sys.stdout.write("\033[H\033[J")
            print_counters(snap, prev, dt)
            if not args.watch:
                return 0
            prev, t0 = snap, time.time()
    except KeyboardInterrupt:
        return 0
    except VppError as ex:
        print(color("VPP nie odpowiada: %s" % ex, "31"))
        return 3
    except Exception as ex:     # noqa: BLE001 — brak vpp_papi, segmentu statystyk albo wyłączone liczniki w VPP
        print(color("nie można odczytać liczników (%s: %s) — czy w pliku jest 'set counters on' i wykonano router-fw apply?"
                    % (type(ex).__name__, ex), "31"))
        return 3

# --- KONIEC MODUŁÓW (nowe funkcje wstawiaj powyżej tej linii) ---

def main():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    ap = argparse.ArgumentParser(prog="router-fw", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", nargs="?", default="show")
    ap.add_argument("rest", nargs="*")
    ap.add_argument("-y", "--yes", action="store_true", help="apply bez pytania o potwierdzenie")
    ap.add_argument("--confirm", type=int, default=0, metavar="SEK", help="apply: cofnij zmianę po SEK s bez 'confirm'")
    ap.add_argument("-w", "--watch", action="store_true", help="counters: odświeżanie co 1 s")
    ap.add_argument("--log", action="store_true", help="check: tryb cichy, wynik do logu (timer systemd)")
    ap.add_argument("--timeout", type=int, default=180, help="boot: ile sekund czekać na VPP")
    args = ap.parse_args()
    if os.geteuid() != 0 and not ROOT:
        sys.exit("Uruchom jako root.")
    fn = COMMANDS.get(args.cmd)
    if fn is None:
        sys.exit("nieznane polecenie: %s (dostępne: %s)" % (args.cmd, ", ".join(sorted(COMMANDS)) or "brak"))
    sys.exit(fn(args))


if __name__ == "__main__":
    main()
ROUTER_FW_PY
}

prog_router_guard() {
  cat <<'ROUTER_GUARD_PY'
#!/usr/bin/env python3
"""router-guard — filtr odbić (SYN-ACK, RST, UDP z portów amplifikacji) w VPP, włączany na żądanie

  router-guard on <prefiks|IP|grupa>[,...] [--monitor|--enforce] [--for 2h]   włącz ochronę wskazanych prefiksów
  router-guard off [prefiks|IP|grupa]      wyłącz wskazane (bez argumentu: wszystko, węzły schodzą ze ścieżki pakietów)
  router-guard enforce | monitor           zmień tryb: enforce odrzuca, monitor tylko liczy
  router-guard status                      co jest chronione, tryb, liczniki, zapełnienie tablic
  router-guard check [--log]               kontrola pliku i zgodności VPP ze stanem; alarmy (--log: timer systemd)
  router-guard boot                        (systemd) po starcie VPP odtwórz ochronę
  router-guard expire                      (systemd, timer) wyłącz po upływie --for oraz przejdź na enforce po rozgrzewce

Tryb monitor liczy, co zostałoby odrzucone, i niczego nie blokuje. "on --enforce" włącza najpierw monitor na czas
rozgrzewki (warmup), żeby tablica zdążyła nauczyć się wychodzących SYN, i dopiero potem enforce.
Konfiguracja: /etc/router/synack-guard.conf. Moduł VPP: vppctl show synack-guard.
"""
import argparse
import fcntl
import ipaddress
import json
import os
import re
import signal
import subprocess
import sys
import time

ROOT = os.environ.get("ROUTER_GUARD_ROOT", "")      # tylko do testów
CONF = ROOT + "/etc/router/synack-guard.conf"
STATE = ROOT + "/var/lib/router/guard.state.json"
LOGDIR = ROOT + "/var/log/router-monitor"
LOG = LOGDIR + "/router-guard.log"
MONLOG = LOGDIR + "/router-monitor.log"
LOCK = ROOT + "/run/router-guard.lock"
NOTIFY = ROOT + "/opt/router/bin/router-notify"
SELF = "/opt/router/bin/router-guard"
VPPCTL = os.environ.get("ROUTER_GUARD_VPPCTL", "vppctl")
SYSTEMD = os.environ.get("ROUTER_GUARD_SYSTEMD", "1") == "1"
SYSTEMD_RUN = os.environ.get("ROUTER_GUARD_SYSTEMD_RUN", "systemd-run")

ERR_RE = re.compile(r"unknown input|error|fail|invalid|conflict|not found|already|does not exist|not supported|cannot|too many",
                    re.I)
IDENT = re.compile(r"^[A-Za-z0-9_-]{1,24}$")
IFNAME = re.compile(r"^[A-Za-z0-9_.-]{1,40}$")
DEFAULT_PORTS = [19, 53, 111, 123, 137, 161, 389, 1900, 3702, 5353, 11211]
TTY = sys.stdout.isatty()


def color(s, c):
    return "\033[%sm%s\033[0m" % (c, s) if TTY else s


# --------------------------------------------------------------------------- logi
def now():
    return int(time.time())


def stamp():
    return time.strftime("%F %T")


def log(msg):
    try:
        os.makedirs(LOGDIR, exist_ok=True)
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (stamp(), msg))
    except OSError:
        pass


def event(sev, mnem, text, mail=True):
    """Zdarzenie w stylu Cisco: log router-monitor + syslog + (opcjonalnie) e-mail."""
    line = "%%GUARD-%d-%s: %s" % (sev, mnem, text)
    log(line)
    try:
        os.makedirs(LOGDIR, exist_ok=True)
        with open(MONLOG, "a") as f:
            f.write("%s %s\n" % (stamp(), line))
    except OSError:
        pass
    prio = {1: "alert", 2: "crit", 3: "err", 4: "warning", 5: "notice"}.get(sev, "info")
    subprocess.run(["logger", "-t", "router-guard", "-p", "local0." + prio, line],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if mail and os.access(NOTIFY, os.X_OK):
        subprocess.run([NOTIFY, "queue", line], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return line


def run_quiet(cmd):
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode
    except OSError:
        return 127


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def lock():
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    fd = open(LOCK, "w")
    end = time.time() + 120
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.time() > end:
                sys.exit("inna instancja router-guard działa zbyt długo (%s)" % LOCK)
            time.sleep(1)


def fmt_num(n):
    return "{:,}".format(int(n)).replace(",", " ")


def parse_duration(s):
    m = re.fullmatch(r"(\d+)([smhd]?)", s)
    if not m:
        raise ValueError("zły czas '%s' (np. 30m, 2h, 1d)" % s)
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]


def fmt_left(ts):
    left = max(0, int(ts - time.time()))
    if left >= 86400:
        return "%dd %02dh %02dm" % (left // 86400, left % 86400 // 3600, left % 3600 // 60)
    if left >= 3600:
        return "%dh %02dm" % (left // 3600, left % 3600 // 60)
    return "%dm %02ds" % (left // 60, left % 60)


# --------------------------------------------------------------------------- plik synack-guard.conf
class Conf:
    def __init__(self):
        self.in_if, self.out_if, self.groups = [], [], {}
        self.ttl, self.udp_ttl, self.warmup, self.max_on, self.alarm_pps = 60, 30, 60, 6 * 3600, 10000
        self.tcp_rst, self.udp, self.udp_frags, self.check_isn = "pass", "on", "pass", "on"
        self.udp_ports = list(DEFAULT_PORTS)
        self.table_v4, self.table_v6 = 4000000, 1000000
        self.default_mode = "monitor"


def parse_nets(tokens):
    out = []
    for tok in tokens:
        try:
            out.append(ipaddress.ip_network(tok, strict=False))
        except ValueError:
            raise ValueError("zły adres '%s'" % tok)
    return out


def parse_conf(text):
    """Zwraca (Conf, błędy). Błąd = ochrona nie zostanie włączona."""
    c, errs = Conf(), []
    ints = {"ttl": "ttl", "udp-ttl": "udp_ttl", "warmup": "warmup", "alarm-pps": "alarm_pps",
            "table-v4": "table_v4", "table-v6": "table_v6"}
    choices = {"tcp-rst": ("tcp_rst", ("pass", "handshake")), "udp": ("udp", ("on", "off")),
               "udp-frags": ("udp_frags", ("pass", "drop")), "check-isn": ("check_isn", ("on", "off")),
               "default-mode": ("default_mode", ("monitor", "enforce"))}
    for no, raw in enumerate(text.splitlines(), 1):
        body = re.split(r"\s#", raw.strip(), maxsplit=1)[0].strip()
        if not body or body.startswith("#"):
            continue
        t = body.split()
        try:
            k, args = t[0], t[1:]
            if k in ("in-if", "out-if"):
                if not args or not all(IFNAME.match(a) for a in args):
                    raise ValueError("%s wymaga nazw interfejsów" % k)
                dest = c.in_if if k == "in-if" else c.out_if
                dest.extend(a for a in args if a not in dest)
            elif k == "group":
                if len(args) < 2 or not IDENT.match(args[0]):
                    raise ValueError("składnia: group NAZWA prefiks...")
                c.groups[args[0]] = parse_nets(args[1:])
            elif k in ints:
                if len(args) != 1 or not args[0].isdigit():
                    raise ValueError("%s wymaga liczby" % k)
                setattr(c, ints[k], int(args[0]))
            elif k == "max-on":
                if len(args) != 1:
                    raise ValueError("max-on wymaga czasu (np. 6h)")
                c.max_on = parse_duration(args[0])
            elif k in choices:
                attr, allowed = choices[k]
                if len(args) != 1 or args[0] not in allowed:
                    raise ValueError("%s: %s" % (k, " | ".join(allowed)))
                setattr(c, attr, args[0])
            elif k == "udp-ports":
                ports = []
                for a in args:
                    if not a.isdigit() or not 0 <= int(a) <= 65535:
                        raise ValueError("zły port '%s'" % a)
                    ports.append(int(a))
                if not ports:
                    raise ValueError("udp-ports wymaga listy portów")
                c.udp_ports = ports
            else:
                raise ValueError("nieznane słowo '%s'" % k)
        except ValueError as ex:
            errs.append("linia %d: %s" % (no, ex))
    if not c.in_if:
        errs.append("brak in-if (interfejsy uplinków, np. in-if hu0.100 hu0.200)")
    if not c.out_if:
        errs.append("brak out-if (interfejs strony klientów, np. out-if hu0.300)")
    both = sorted(set(c.in_if) & set(c.out_if))
    if both:
        errs.append("wspólny interfejs w in-if i out-if: %s" % ", ".join(both))
    return c, errs


def load_conf():
    try:
        with open(CONF) as f:
            text = f.read()
    except OSError as ex:
        return None, ["nie można czytać %s: %s" % (CONF, ex)]
    c, errs = parse_conf(text)
    return (None if errs else c), errs


def resolve_targets(conf, tokens):
    """Grupy, prefiksy i adresy (po przecinku lub spacjach) -> posortowana lista prefiksów."""
    out = set()
    for tok in ",".join(tokens).split(","):
        tok = tok.strip()
        if not tok:
            continue
        if tok in conf.groups:
            out.update(str(n) for n in conf.groups[tok])
        else:
            try:
                out.add(str(ipaddress.ip_network(tok, strict=False)))
            except ValueError:
                raise ValueError("'%s' to nie grupa z pliku, prefiks ani adres IP" % tok)
    return sorted(out, key=lambda p: (ipaddress.ip_network(p).version, ipaddress.ip_network(p)))


# --------------------------------------------------------------------------- VPP
class VppError(Exception):
    pass


class GuardMissing(Exception):
    pass


class VState:
    def __init__(self):
        self.mode, self.ifaces, self.prefixes = "off", {}, set()
        self.used4 = self.size4 = self.used6 = self.size6 = 0
        self.names = set()


def cli(cmd, timeout=15):
    try:
        r = subprocess.run([VPPCTL, cmd], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as ex:
        raise VppError("vppctl: %s" % ex)
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0 or "connect" in out.lower() and "fail" in out.lower():
        raise VppError("vppctl '%s': %s" % (cmd[:80], out.strip() or "kod %d" % r.returncode))
    return out


def read_vpp():
    out = cli("show synack-guard")
    if "unknown input" in out:
        raise GuardMissing()
    v = VState()
    for line in out.splitlines():
        m = re.match(r"^(mode|interface|prefix|table-v4|table-v6):\s*(.*)$", line.strip())
        if not m:
            continue
        key, val = m.groups()
        if key == "mode":
            v.mode = val.strip()
        elif key == "interface":
            parts = val.split()
            if len(parts) == 2:
                v.ifaces[parts[0]] = parts[1]
        elif key == "prefix":
            v.prefixes.add(val.strip())
        else:
            mm = re.match(r"(\d+)/(\d+)", val)
            if mm:
                setattr(v, "used4" if key == "table-v4" else "used6", int(mm.group(1)))
                setattr(v, "size4" if key == "table-v4" else "size6", int(mm.group(2)))
    for line in cli("show interface").splitlines():
        m = re.match(r"^(\S+)\s+(\d+)\s", line)
        if m:
            v.names.add(m.group(1))
    return v


def read_errors():
    """Liczniki węzłów synack-guard z 'show errors': {powód: suma po węzłach}."""
    tot = {}
    for line in cli("show errors").splitlines():
        m = re.match(r"^\s*(\d+)\s+(synack-guard-\S+)\s+(.+?)\s+(error|warn|info|debug)\s*$", line)
        if m:
            tot[m.group(3)] = tot.get(m.group(3), 0) + int(m.group(1))
    return tot


def counters_summary(tot):
    return {"checked": tot.get("Checked", 0),
            "passed": tot.get("Passed", 0),
            "violations": sum(v for k, v in tot.items() if k.startswith("Violation")),
            "dropped": tot.get("Dropped", 0),
            "recorded": tot.get("SYN recorded", 0) + tot.get("UDP recorded", 0),
            "insert_failed": tot.get("Insert failed", 0)}


def wait_vpp(timeout):
    end = time.time() + timeout
    while True:
        try:
            cli("show version", timeout=5)
            return True
        except VppError:
            if time.time() > end:
                return False
            time.sleep(2)


def config_cmd(conf, with_tables):
    s = ("synack-guard config ttl %d udp-ttl %d check-isn %s tcp-rst %s udp %s udp-frags %s udp-ports %s"
         % (conf.ttl, conf.udp_ttl, conf.check_isn, conf.tcp_rst, conf.udp, conf.udp_frags,
            ",".join(str(p) for p in conf.udp_ports)))
    if with_tables:
        s += " table-v4 %d table-v6 %d" % (conf.table_v4, conf.table_v6)
    return s


def sync_cmds(conf, prefixes, mode, v, with_config=True):
    """Polecenia, które doprowadzą VPP do stanu: interfejsy z pliku, podane prefiksy, tryb."""
    cmds = []
    if with_config:
        cmds.append(config_cmd(conf, with_tables=v.mode == "off"))
    want = {i: "in" for i in conf.in_if}
    want.update({i: "out" for i in conf.out_if})
    for i, d in sorted(want.items()):
        if v.ifaces.get(i) != d and i in v.names:
            cmds.append("synack-guard interface %s %s" % (i, d))
    for i in sorted(v.ifaces):
        if i not in want:
            cmds.append("synack-guard interface %s %s disable" % (i, v.ifaces[i]))
    for p in sorted(set(prefixes) - v.prefixes):
        cmds.append("synack-guard prefix %s" % p)
    for p in sorted(v.prefixes - set(prefixes)):
        cmds.append("synack-guard prefix %s del" % p)
    if v.mode != mode:
        cmds.append("synack-guard mode %s" % mode)
    return cmds


def off_cmds(v):
    cmds = ["synack-guard mode off"] if v.mode != "off" else []
    cmds += ["synack-guard interface %s %s disable" % (i, d) for i, d in sorted(v.ifaces.items())]
    cmds += ["synack-guard prefix %s del" % p for p in sorted(v.prefixes)]
    return cmds


def run_cmds(cmds):
    """Wykonuje polecenia po kolei; przy pierwszym błędzie staje. Zwraca tekst błędu albo ''."""
    for c in cmds:
        log("vppctl: %s" % c)
        try:
            out = cli(c)
        except VppError as ex:
            log("BŁĄD: %s" % ex)
            return str(ex)
        if ERR_RE.search(out):
            log("BŁĄD: %s" % out.strip())
            return "%s: %s" % (c, out.strip())
    return ""


def schedule_tick(at):
    """Jednorazowy timer systemd, który w zadanej chwili wywoła 'router-guard expire' (przejście na enforce)."""
    if not SYSTEMD or not at:
        return
    for unit in ("router-guard-tick.timer", "router-guard-tick.service"):
        run_quiet(["systemctl", "stop", unit])
    run_quiet(["systemctl", "reset-failed", "router-guard-tick.service"])
    sec = max(1, int(at - time.time()) + 1)
    rc = run_quiet([SYSTEMD_RUN, "--unit=router-guard-tick", "--on-active=%ds" % sec,
                    "--description=router-guard: przejście na enforce po rozgrzewce", SELF, "expire"])
    if rc != 0:
        log("systemd-run zwrócił %d — przejście na enforce wykona minutowy router-guard-expire.timer" % rc)


def load_state():
    s = load_json(STATE, {})
    s.setdefault("active", False)
    s.setdefault("mode", "off")
    s.setdefault("target_mode", "monitor")
    s.setdefault("prefixes", [])
    s.setdefault("expires", 0)
    s.setdefault("enforce_at", 0)
    s.setdefault("snapshot", {})
    return s


def state_prefixes(st):
    return [p["net"] for p in st["prefixes"]] if st["active"] else []


def missing_ifaces(conf, v):
    return sorted(i for i in conf.in_if + conf.out_if if i not in v.names)


def need_conf():
    conf, errs = load_conf()
    if conf is None:
        for e in errs:
            print(color("  " + e, "31"))
        print(color("Nic nie zmieniono — popraw %s." % CONF, "31"))
    return conf


def open_vpp():
    """(VState, kod) — kod 0 albo 3 z komunikatem."""
    try:
        return read_vpp(), 0
    except GuardMissing:
        print(color("Wtyczka synack_guard nie jest załadowana w VPP — przebuduj VPP: install-router.sh --from 10 "
                    "(patrz docs/synack-guard-lab-checklist.md).", "31"))
    except VppError as ex:
        print(color("VPP nie odpowiada: %s" % ex, "31"))
    return None, 3


# --------------------------------------------------------------------------- polecenia
def cmd_on(args):
    if not args.rest or (args.monitor and args.enforce):
        print("użycie: router-guard on <prefiks|IP|grupa>[,...] [--monitor|--enforce] [--for 2h]")
        return 2
    conf = need_conf()
    if conf is None:
        return 2
    try:
        targets = resolve_targets(conf, args.rest)
        secs = parse_duration(args.for_) if args.for_ else 0
    except ValueError as ex:
        print(color(str(ex), "31"))
        return 2
    if not targets:
        print("użycie: router-guard on <prefiks|IP|grupa>[,...]")
        return 2
    fd = lock()
    v, rc = open_vpp()
    if v is None:
        return rc
    miss = missing_ifaces(conf, v)
    if miss:
        print(color("  interfejsy spoza VPP: %s (sprawdź %s i router-ifaces)" % (", ".join(miss), CONF), "31"))
        return 2
    st = load_state()
    old = set(state_prefixes(st))
    prefixes = old | set(targets)
    fresh = not st["active"] or bool(set(targets) - old)
    target = "enforce" if args.enforce else "monitor" if args.monitor else (st["target_mode"] if st["active"] else conf.default_mode)
    t = now()
    if target == "enforce" and (fresh or st["mode"] == "monitor" and st["enforce_at"]):
        if conf.warmup > 0:
            mode, enforce_at = "monitor", t + conf.warmup
        else:
            mode, enforce_at = "enforce", 0
    else:
        mode, enforce_at = target, 0
    expires = t + min(secs or conf.max_on, conf.max_on)
    err = run_cmds(sync_cmds(conf, prefixes, mode, v))
    if err:
        event(3, "APPLY_FAIL", "nie udało się włączyć ochrony: %s" % err[:150])
        print(color("Nie udało się: %s" % err, "31"))
        return 4
    since = {p["net"]: p["added"] for p in st["prefixes"]} if st["active"] else {}
    if st.get("drift"):
        event(5, "DRIFT_END", "VPP znów zgodny ze stanem router-guard (naprawione przez 'on')")
    st.update({"active": True, "mode": mode, "target_mode": target, "enforce_at": enforce_at, "expires": expires,
               "prefixes": [{"net": p, "added": since.get(p, t)} for p in sorted(prefixes)], "applied": t, "drift": ""})
    save_json(STATE, st)
    schedule_tick(enforce_at)
    note = "; enforce za %d s (rozgrzewka)" % conf.warmup if enforce_at else ""
    event(5, "ON", "ochrona włączona: %s, tryb %s%s, wyłączenie za %s" % (", ".join(sorted(prefixes)), mode, note,
                                                                       fmt_left(expires)))
    print(color("Ochrona włączona (tryb %s%s). Wyłączy się za %s." % (mode, note, fmt_left(expires)), "32"))
    del fd
    return 0


def full_off(why, mail=True):
    """Wyłącza ochronę w VPP i w stanie. Zwraca kod."""
    v, rc = open_vpp()
    if v is None:
        return rc
    err = run_cmds(off_cmds(v))
    if err:
        event(3, "APPLY_FAIL", "nie udało się wyłączyć ochrony: %s" % err[:150])
        print(color("Nie udało się: %s" % err, "31"))
        return 4
    st = load_state()
    was = st["active"]
    st.update({"active": False, "mode": "off", "prefixes": [], "expires": 0, "enforce_at": 0, "drift": ""})
    save_json(STATE, st)
    if SYSTEMD:
        run_quiet(["systemctl", "stop", "router-guard-tick.timer"])
    if was:
        event(5, why[0], why[1], mail=mail)
    return 0


def cmd_off(args):
    fd = lock()
    st = load_state()
    if args.rest:
        conf = need_conf()
        if conf is None:
            return 2
        try:
            targets = resolve_targets(conf, args.rest)
        except ValueError as ex:
            print(color(str(ex), "31"))
            return 2
        left = sorted(set(state_prefixes(st)) - set(targets))
        if left:
            v, rc = open_vpp()
            if v is None:
                return rc
            err = run_cmds(sync_cmds(conf, left, v.mode, v, with_config=False))
            if err:
                print(color("Nie udało się: %s" % err, "31"))
                return 4
            by = {p["net"]: p["added"] for p in st["prefixes"]}
            st["prefixes"] = [{"net": p, "added": by.get(p, now())} for p in left]
            save_json(STATE, st)
            event(5, "OFF", "zdjęto ochronę: %s; nadal chronione: %s" % (", ".join(targets), ", ".join(left)))
            print("Zdjęto ochronę wskazanych prefiksów; nadal chronione: %s." % ", ".join(left))
            return 0
    if not st["active"]:
        v, rc = open_vpp()
        if v is not None and (v.mode != "off" or v.ifaces or v.prefixes):
            print(color("Stan zapisany jako wyłączony, ale VPP ma włączone elementy — czyszczę.", "33"))
            return full_off(("OFF", "ręczne czyszczenie"))
        print("Ochrona jest wyłączona.")
        return rc
    rc = full_off(("OFF", "ochrona wyłączona ręcznie"))
    if rc == 0:
        print(color("Ochrona wyłączona; węzły zdjęte ze ścieżki pakietów.", "32"))
    del fd
    return rc


def set_mode(mode):
    fd = lock()
    st = load_state()
    if not st["active"]:
        print(color("Ochrona nie jest włączona (router-guard on <prefiks>).", "31"))
        return 2
    v, rc = open_vpp()
    if v is None:
        return rc
    err = run_cmds(["synack-guard mode %s" % mode] if v.mode != mode else [])
    if err:
        print(color("Nie udało się: %s" % err, "31"))
        return 4
    st.update({"mode": mode, "target_mode": mode, "enforce_at": 0})
    save_json(STATE, st)
    if SYSTEMD:
        run_quiet(["systemctl", "stop", "router-guard-tick.timer"])
    event(5, "MODE", "tryb %s" % mode)
    print(color("Tryb: %s." % mode, "32"))
    del fd
    return 0


def cmd_enforce(args):
    return set_mode("enforce")


def cmd_monitor(args):
    return set_mode("monitor")


def cmd_status(args):
    st = load_state()
    v, rc = open_vpp()
    if v is None:
        return rc
    if not st["active"]:
        print("Ochrona wyłączona.")
        if v.mode != "off":
            print(color("  UWAGA: VPP ma tryb %s mimo wyłączonego stanu — router-guard off" % v.mode, "33"))
        return 0
    print(color("Ochrona WŁĄCZONA — tryb %s" % st["mode"], "1"))
    if st["target_mode"] != st["mode"]:
        print("  docelowo: %s za %s (rozgrzewka)" % (st["target_mode"], fmt_left(st["enforce_at"])))
    print("  wyłączy się za: %s" % fmt_left(st["expires"]))
    print("  prefiksy: %s" % ", ".join(p["net"] for p in st["prefixes"]))
    print("  uplinki (in): %s   klienci (out): %s" % (" ".join(sorted(i for i, d in v.ifaces.items() if d == "in")),
                                                     " ".join(sorted(i for i, d in v.ifaces.items() if d == "out"))))
    print("  tablica IPv4: %s / %s   IPv6: %s / %s" % (fmt_num(v.used4), fmt_num(v.size4), fmt_num(v.used6), fmt_num(v.size6)))
    cur = counters_summary(read_errors())
    snap = st.get("snapshot") or {}
    dt = max(1, now() - snap.get("ts", now())) if snap else 0
    for key, label in (("checked", "sprawdzone odpowiedzi"), ("passed", "przepuszczone (jest wpis)"),
                       ("violations", "naruszenia (brak wpisu / zły ISN)"), ("dropped", "odrzucone (enforce)"),
                       ("recorded", "zapisane wpisy (SYN, UDP)"), ("insert_failed", "błędy zapisu do tablicy")):
        rate = ""
        if snap and dt and key in snap.get("vals", {}):
            rate = "   ~%s/s" % fmt_num(max(0, cur[key] - snap["vals"][key]) / dt)
        print("  %-38s %16s%s" % (label, fmt_num(cur[key]), rate))
    return 0


def cmd_check(args):
    quiet = args.log
    conf, errs = load_conf()
    if conf is None:
        for e in errs:
            print(color("  " + e, "31"))
        if quiet:
            event(2, "CONFIG_ERROR", "błędy w synack-guard.conf: %s" % "; ".join(errs[:3]), mail=False)
        return 2
    st = load_state()
    if not st["active"]:
        if not quiet:
            print("synack-guard.conf: składnia OK. Ochrona wyłączona.")
        return 0
    v, rc = open_vpp()
    if v is None:
        return rc
    cmds = sync_cmds(conf, state_prefixes(st), st["mode"], v, with_config=False)
    out = 0
    if cmds:
        print(color("Rozjazd: VPP różni się od zapisanego stanu:", "31"))
        for c in cmds:
            print("  " + c)
        if quiet and not st.get("drift"):
            st["drift"] = "; ".join(cmds[:4])
            event(4, "DRIFT", "VPP różni się od stanu router-guard: %s" % st["drift"])
        out = 1
    else:
        if not quiet:
            print("VPP jest zgodny ze stanem (tryb %s)." % st["mode"])
        if st.get("drift"):
            st["drift"] = ""
            event(5, "DRIFT_END", "VPP znów zgodny ze stanem router-guard")
    if quiet:
        t = now()
        cur = counters_summary(read_errors())
        snap = st.get("snapshot") or {}
        if snap.get("vals") and t > snap.get("ts", t):
            dt = t - snap["ts"]
            rate = max(0, cur["violations"] - snap["vals"].get("violations", 0)) / dt
            if rate > conf.alarm_pps and t - st.get("alarm_ts", 0) > 600:
                st["alarm_ts"] = t
                event(4, "VIOLATIONS", "%s pkt/s odpowiedzi bez wpisu (tryb %s, %s)" % (
                    fmt_num(rate), st["mode"], "odrzucane" if st["mode"] == "enforce" else "tylko liczone"))
        full = max(v.used4 / v.size4 if v.size4 else 0, v.used6 / v.size6 if v.size6 else 0)
        if full >= 0.9 and t - st.get("full_ts", 0) > 600:
            st["full_ts"] = t
            if st["mode"] == "enforce":
                err = run_cmds(["synack-guard mode monitor"])
                if not err:
                    st.update({"mode": "monitor", "target_mode": "monitor", "enforce_at": 0})
            event(2, "TABLE_FULL", "tablica stanów zapełniona w %d%% — %s" % (
                int(full * 100), "przełączono na monitor" if st["mode"] == "monitor" else "sprawdź rozmiary tablic"))
        st["snapshot"] = {"ts": t, "vals": cur}
    save_json(STATE, st)
    return out


def cmd_boot(args):
    fd = lock()
    st = load_state()
    if not st["active"]:
        return 0
    if st["expires"] and st["expires"] <= now():
        st.update({"active": False, "mode": "off", "prefixes": [], "expires": 0, "enforce_at": 0})
        save_json(STATE, st)
        event(5, "EXPIRED", "po restarcie: czas ochrony już minął — pozostaje wyłączona", mail=False)
        return 0
    conf, errs = load_conf()
    if conf is None:
        event(2, "CONFIG_ERROR", "błędy w synack-guard.conf: %s — ochrona nie została odtworzona" % "; ".join(errs[:3]))
        return 2
    if not wait_vpp(args.timeout):
        event(2, "APPLY_FAIL", "VPP nie odpowiada po %d s — ochrona nie została odtworzona" % args.timeout)
        return 3
    v, rc = open_vpp()
    if v is None:
        event(2, "APPLY_FAIL", "wtyczka synack_guard niedostępna po starcie VPP — ochrona nie została odtworzona")
        return rc
    t = now()
    target = st["target_mode"]
    if target == "enforce" and conf.warmup > 0:
        mode, enforce_at = "monitor", t + conf.warmup
    else:
        mode, enforce_at = target, 0
    err = run_cmds(sync_cmds(conf, state_prefixes(st), mode, v))
    if err:
        event(3, "APPLY_FAIL", "nie udało się odtworzyć ochrony: %s" % err[:150])
        return 4
    st.update({"mode": mode, "enforce_at": enforce_at, "drift": "", "snapshot": {}})
    save_json(STATE, st)
    schedule_tick(enforce_at)
    event(6, "RESTORED", "ochrona odtworzona po starcie VPP (%d prefiksów, tryb %s%s)" % (
        len(st["prefixes"]), mode, ", enforce za %d s" % conf.warmup if enforce_at else ""), mail=False)
    del fd
    return 0


def cmd_expire(args):
    fd = lock()
    st = load_state()
    if not st["active"]:
        return 0
    t = now()
    if st["expires"] and st["expires"] <= t:
        return full_off(("EXPIRED", "minął czas ochrony — wyłączona"))
    if st["enforce_at"] and st["enforce_at"] <= t and st["mode"] == "monitor" and st["target_mode"] == "enforce":
        v, rc = open_vpp()
        if v is None:
            return rc
        err = run_cmds(["synack-guard mode enforce"] if v.mode != "enforce" else [])
        if err:
            event(3, "APPLY_FAIL", "nie udało się przejść na enforce: %s" % err[:150])
            return 4
        st.update({"mode": "enforce", "enforce_at": 0})
        save_json(STATE, st)
        event(5, "MODE", "tryb enforce po rozgrzewce")
    del fd
    return 0


COMMANDS = {"on": cmd_on, "off": cmd_off, "enforce": cmd_enforce, "monitor": cmd_monitor, "status": cmd_status,
            "check": cmd_check, "boot": cmd_boot, "expire": cmd_expire}


def main():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    ap = argparse.ArgumentParser(prog="router-guard", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", nargs="?", default="status")
    ap.add_argument("rest", nargs="*")
    ap.add_argument("--monitor", action="store_true", help="on: zostaw tryb monitor (liczy, nie blokuje)")
    ap.add_argument("--enforce", action="store_true", help="on: po rozgrzewce przejdź na enforce")
    ap.add_argument("--for", dest="for_", default="", metavar="CZAS", help="on: automatyczne wyłączenie po CZAS (30m, 2h, 1d)")
    ap.add_argument("--log", action="store_true", help="check: tryb cichy, wynik do logu (timer systemd)")
    ap.add_argument("--timeout", type=int, default=180, help="boot: ile sekund czekać na VPP")
    args = ap.parse_args()
    if os.geteuid() != 0 and not ROOT:
        sys.exit("Uruchom jako root.")
    fn = COMMANDS.get(args.cmd)
    if fn is None:
        sys.exit("nieznane polecenie: %s (dostępne: %s)" % (args.cmd, ", ".join(sorted(COMMANDS))))
    sys.exit(fn(args))


if __name__ == "__main__":
    main()
ROUTER_GUARD_PY
}

prog_router_check() { printf '#!/bin/sh\nexec /opt/router/install-router.sh --check "$@"\n'; }

# wersja skryptu zapisana na routerze (/etc/router/version): write_version install|upgrade
write_version() {
  local inst upg
  inst=$(sed -n 's/^INSTALLED_AT=//p' "$VERSION_FILE" 2>/dev/null || true)
  upg=$(sed -n 's/^UPGRADED_AT=//p' "$VERSION_FILE" 2>/dev/null || true)
  [[ $1 == upgrade ]] && upg=$(now)
  mkdir -p "$(dirname "$VERSION_FILE")"
  {
    echo "SCRIPT_VERSION=$SCRIPT_VERSION"
    echo "INSTALLED_AT=${inst:-$(now)}"
    [[ -n $upg ]] && echo "UPGRADED_AT=$upg"
    true
  } >"$VERSION_FILE"
}

# =============================================================================
# TRYB --check
# =============================================================================
do_check() {
  SNMP_COMMUNITY=$(grep -sh '^SNMP_COMMUNITY=' /etc/router/router.env "$ENV_FILE" | head -n1 | cut -d= -f2 || true)
  printf '\n%s== Wersja ==%s\n' "$c_hdr" "$c_off"
  if [[ -f $VERSION_FILE ]]; then
    printf '  skrypt na routerze: %s (zainstalowany %s%s)\n' "$(sed -n 's/^SCRIPT_VERSION=//p' "$VERSION_FILE")" \
      "$(sed -n 's/^INSTALLED_AT=//p' "$VERSION_FILE")" "$(sed -n 's/^UPGRADED_AT=\(.*\)$/, ostatnia aktualizacja programów \1/p' "$VERSION_FILE")"
  else warn "brak $VERSION_FILE (instalacja sprzed wersjonowania — uruchom: install-router upgrade_script)"; fi
  printf '\n%s== Kernel i pamięć ==%s\n' "$c_hdr" "$c_off"
  if grep -q isolcpus /proc/cmdline; then ok "cmdline: $(grep -o 'isolcpus=[^ ]*' /proc/cmdline)"; else warn "brak isolcpus w /proc/cmdline — zrób restart"; fi
  for n in /sys/devices/system/node/node*; do
    printf '  %s: hugepages 2M total=%s free=%s\n' "$(basename "$n")" \
      "$(cat "$n/hugepages/hugepages-2048kB/nr_hugepages")" "$(cat "$n/hugepages/hugepages-2048kB/free_hugepages")"
  done
  if lsmod | grep -qw mlx5_ib; then ok "moduł mlx5_ib załadowany"; else warn "brak modułu mlx5_ib"; fi
  if lsmod | grep -qw ib_uverbs; then ok "moduł ib_uverbs załadowany"; else warn "brak modułu ib_uverbs"; fi

  printf '\n%s== Karta ==%s\n' "$c_hdr" "$c_off"
  local p d fw
  for p in "${NIC_PCI[@]}"; do
    d=$(netdev_of "$p"); fw=""
    [[ -n $d ]] && fw=$(ethtool -i "$d" 2>/dev/null | awk '/firmware-version/{print $2}' || true)
    printf '  %s  netdev=%s  numa=%s  firmware=%s\n' "$p" "${d:-?}" "$(cat "/sys/bus/pci/devices/$p/numa_node")" "${fw:-?}"
  done

  printf '\n%s== Usługi ==%s\n' "$c_hdr" "$c_off"
  local u
  for u in router.target netns-dataplane vpp router-ifaces router-fw router-guard "$(bird_unit)" snmpd-dataplane vpp-snmp-agent hsflowd router-monitor router-notify router-bootcheck mdmonitor smartd; do
    if systemctl is-active --quiet "$u"; then ok "$u: active"; else warn "$u: $(systemctl is-active "$u" 2>/dev/null || true)"; fi
  done

  printf '\n%s== VPP ==%s\n' "$c_hdr" "$c_off"
  vppctl show version || true
  vppctl show threads || true
  vppctl show interface || true
  vppctl show plugins 2>/dev/null | grep -E 'linux_cp|linux_nl|sflow|dpdk' || true
  vppctl show sflow || true

  printf '\n%s== Interfejsy (/etc/router/ifaces.conf) ==%s\n' "$c_hdr" "$c_off"
  /opt/router/bin/router-ifaces show 2>&1 || true
  /opt/router/bin/router-ifaces check 2>&1 || true
  local badmtu
  badmtu=$(vppctl show interface 2>/dev/null | awk -v want="$PORT_MTU" \
    '$1 ~ /^hu[0-9]+(\.[0-9]+)?$/ { split($4, m, "/"); if (m[1] != want) print $1 "=" m[1] }' | xargs)
  if [[ -z $badmtu ]]; then ok "MTU $PORT_MTU (standard Ethernet) na portach i VLAN-ach"
  else warn "MTU inne niż $PORT_MTU: $badmtu"; fi

  printf '\n%s== Firewall (/etc/router/firewall.conf) ==%s\n' "$c_hdr" "$c_off"
  if [[ -x /opt/router/bin/router-fw ]]; then /opt/router/bin/router-fw check 2>&1 || true
  else warn "brak router-fw — uruchom: install-router --from 22"; fi
  printf '\n%s== Ochrona przed odbiciami (router-guard) ==%s\n' "$c_hdr" "$c_off"
  if [[ -x /opt/router/bin/router-guard ]]; then /opt/router/bin/router-guard status 2>&1 || true
  else warn "brak router-guard — uruchom: install-router --from 23"; fi
  printf '\n%s== BIRD ==%s\n' "$c_hdr" "$c_off"
  birdc show status || true
  birdc show protocols || true

  printf '\n%s== SNMP (netns dataplane) ==%s\n' "$c_hdr" "$c_off"
  if [[ -n ${SNMP_COMMUNITY:-} ]]; then
    ip netns exec dataplane snmpwalk -v2c -c "$SNMP_COMMUNITY" -On 127.0.0.1 1.3.6.1.2.1.31.1.1.1.1 2>&1 | head -20 || true
  else warn "brak community w $ENV_FILE"; fi
  printf '\n%s== RAID ==%s\n' "$c_hdr" "$c_off"
  cat /proc/mdstat 2>/dev/null || true

  printf '\n%s== router-monitor (ostatnie zdarzenia) ==%s\n' "$c_hdr" "$c_off"
  tail -n 15 /var/log/router-monitor/router-monitor.log 2>/dev/null || warn "brak logu router-monitor"
  printf '\n  ostatnia kontrola po starcie: %s\n' "$(grep -h 'BOOT_' /var/log/router-monitor/router-monitor.log 2>/dev/null | tail -n1)"
  printf '\n%s== Historia /etc (etckeeper) ==%s\n' "$c_hdr" "$c_off"
  git -C /etc log --oneline -n 5 2>/dev/null || true
  printf '\n%s== Odporność ==%s\n' "$c_hdr" "$c_off"
  printf '  kernel.panic=%s panic_on_oops=%s  watchdog: %s  RuntimeWatchdog: %s\n' "$(sysctl -n kernel.panic)" "$(sysctl -n kernel.panic_on_oops)" "$(ls /dev/watchdog0 2>/dev/null || echo brak)" "$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null)"
  /opt/router/bin/router-notify categories 2>/dev/null | sed 's/^/  /' || true
  printf '  kolejka e-mail: %s zdarzeń   audyt sprzętu: /etc/router/hardware-audit.md\n' "$(find /var/spool/router-notify -name '*.json' 2>/dev/null | wc -l)"
  printf '\nDokumentacja: /opt/router/README.md   Raport instalacji: %s\n' "$MANIFEST"
}

if [[ $MODE == check ]]; then do_check; exit 0; fi

# =============================================================================
# TRYB upgrade_script — podmienia same programy routera nowszą treścią z tego pliku.
# Nie dotyka: VPP, BIRD, pakietów, GRUB-a, jednostek systemd ani konfiguracji
# (router.env, ifaces.conf, notify.conf, bird.conf, startup.conf...). Sesje BGP się nie przerywają.
# =============================================================================
# nazwa | plik docelowy | tryb | funkcja generująca treść | usługa do restartu po zmianie
UPGRADE_PROGRAMS=(
  "router-monitor|/opt/router/bin/router-monitor|755|prog_router_monitor|router-monitor.service"
  "router-notify|/opt/router/bin/router-notify|755|prog_router_notify|router-notify.service"
  "router-ifaces|/opt/router/bin/router-ifaces|755|prog_router_ifaces|"
  "router-fw|/opt/router/bin/router-fw|755|prog_router_fw|"
  "router-guard|/opt/router/bin/router-guard|755|prog_router_guard|"
  "router-alert|/opt/router/bin/router-alert|755|prog_router_alert|"
  "router-bootcheck|/opt/router/bin/router-bootcheck|755|prog_router_bootcheck|"
  "mdadm-alert|/opt/router/bin/mdadm-alert|755|prog_mdadm_alert|"
  "smartd-alert|/opt/router/bin/smartd-alert|755|prog_smartd_alert|"
  "router-fw-update|/opt/router/bin/router-fw-update|755|prog_router_fw_update|"
  "router-check|/usr/local/sbin/router-check|755|prog_router_check|"
)

upgrade_syntax_ok() {   # upgrade_syntax_ok <plik> — składnia wg shebangu
  case $(head -n1 "$1") in
    *python*) python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$1" ;;
    *bash*)   bash -n "$1" ;;
    *)        sh -n "$1" ;;
  esac
}

do_upgrade() {
  local old_ver="" tmp ts bdir entry name path mode fn unit self
  local -a names=() todo=() restart=() paths=() modes=() units=()
  [[ -d /opt/router/bin ]] || die "Brak /opt/router/bin — router nie jest zainstalowany. Uruchom pełną instalację: $0"
  [[ -f $VERSION_FILE ]] && old_ver=$(sed -n 's/^SCRIPT_VERSION=//p' "$VERSION_FILE")
  printf '\n%s[%s] upgrade_script: wersja na routerze: %s → ten skrypt: %s%s%s\n' "$c_hdr" "$(now)" \
    "${old_ver:-brak (instalacja sprzed wersjonowania)}" "$SCRIPT_VERSION" "$( ((DRY_RUN)) && echo '  [--dry-run: nic nie zostanie zapisane]')" "$c_off"
  if [[ -n $old_ver && $old_ver != "$SCRIPT_VERSION" && $(printf '%s\n%s\n' "$old_ver" "$SCRIPT_VERSION" | sort -V | head -n1) == "$SCRIPT_VERSION" ]]; then
    warn "ten skrypt ($SCRIPT_VERSION) jest STARSZY niż zainstalowany na routerze ($old_ver)"
    if ((!DRY_RUN && !ASSUME_YES)); then
      local ans=""; read -rp "  Wgrać mimo to (obniżenie wersji)? [t/N] " ans || true
      [[ $ans == [tTyY]* ]] || die "Przerwano."
    fi
  fi

  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  CUR_STAGE="upgrade_script $SCRIPT_VERSION"
  # 1. wygeneruj i sprawdź składnię WSZYSTKICH programów, zanim cokolwiek zostanie zapisane
  for entry in "${UPGRADE_PROGRAMS[@]}"; do
    IFS='|' read -r name path mode fn unit <<<"$entry"
    "$fn" >"$tmp/$name" || die "nie udało się wygenerować $name"
    upgrade_syntax_ok "$tmp/$name" || die "błąd składni w nowej wersji $name — upgrade przerwany, nic nie zmieniono"
    names+=("$name"); paths+=("$path"); modes+=("$mode"); units+=("$unit")
  done
  # kopia samego skryptu w /opt/router (stąd działają router-check i install-router)
  self=$(readlink -f "$0")
  if [[ $self != /opt/router/install-router.sh ]]; then
    bash -n "$self" || die "błąd składni w $self"
    cp "$self" "$tmp/install-router.sh"
    names+=(install-router.sh); paths+=(/opt/router/install-router.sh); modes+=(755); units+=("")
  fi

  # 2. porównanie z tym, co jest na routerze
  local i state
  for i in "${!names[@]}"; do
    name=${names[$i]} path=${paths[$i]} mode=${modes[$i]}
    if [[ ! -e $path ]]; then state="NOWY"
    elif ! cmp -s "$tmp/$name" "$path" || [[ $(stat -c %a "$path") != "$mode" ]]; then state="ZMIENIONY"
    else state=""; fi
    if [[ -z $state ]]; then printf '  %sbez zmian%s   %s\n' "$c_dim" "$c_off" "$path"; continue; fi
    printf '  %s%s%s  %s\n' "$c_warn" "$state" "$c_off" "$path"
    todo+=("$i")
    if ((DRY_RUN)) && [[ $state == ZMIENIONY ]]; then
      diff -u --label "na routerze: $path" --label "nowa wersja" "$path" "$tmp/$name" | head -n 60 | sed 's/^/      /' || true
    fi
  done
  if ((${#todo[@]} == 0)); then
    ok "programy routera są aktualne — nic do podmiany"
    if ((!DRY_RUN)) && [[ $old_ver != "$SCRIPT_VERSION" ]]; then write_version upgrade; say "zapisano wersję $SCRIPT_VERSION w $VERSION_FILE"; fi
    return 0
  fi
  if ((DRY_RUN)); then ok "dry-run: do podmiany ${#todo[@]} plik(ów); nic nie zapisano"; return 0; fi

  # 3. kopia starych wersji i atomowa podmiana (mv w obrębie katalogu)
  ts=$(date +%Y%m%d-%H%M%S); bdir=$BACKUP_DIR/upgrade-$ts
  local changed=()
  for i in "${todo[@]}"; do
    name=${names[$i]} path=${paths[$i]} mode=${modes[$i]}
    if [[ -e $path ]]; then
      mkdir -p "$bdir$(dirname "$path")"; cp -a "$path" "$bdir$path"
    else
      man_add file "$path" "dodany przez upgrade_script $SCRIPT_VERSION"
    fi
    mkdir -p "$(dirname "$path")"
    install -m "$mode" "$tmp/$name" "$path.upgrade-new" && mv -f "$path.upgrade-new" "$path"
    changed+=("$name")
    [[ -n ${units[$i]} ]] && restart+=("${units[$i]}")
  done
  ln -sfn /opt/router/bin/router-ifaces /usr/local/sbin/router-ifaces
  ln -sfn /opt/router/bin/router-notify /usr/local/sbin/router-notify
  ln -sfn /opt/router/bin/router-fw-update /usr/local/sbin/router-fw-update
  ln -sfn /opt/router/install-router.sh /usr/local/sbin/install-router
  ok "podmieniono: ${changed[*]}   (poprzednie wersje: $bdir)"

  # 4. restart tylko usług, których program się zmienił (nigdy VPP ani BIRD)
  for unit in "${restart[@]}"; do
    if systemctl is-active --quiet "$unit"; then
      systemctl restart "$unit"; sleep 2
      if systemctl is-active --quiet "$unit"; then ok "$unit zrestartowany"; else warn "$unit nie wstał po restarcie — journalctl -u $unit"; fi
    else say "$unit nie działa — nie restartuję (stan: $(systemctl is-active "$unit" 2>/dev/null || true))"; fi
  done
  if [[ " ${changed[*]} " == *" router-ifaces "* ]] && vppctl show version >/dev/null 2>&1; then
    /opt/router/bin/router-ifaces check >/dev/null 2>&1 && ok "router-ifaces check: zgodne z ifaces.conf" \
      || warn "router-ifaces check zgłasza rozjazd/błąd — sprawdź: router-ifaces check"
  fi

  # 5. wersja, dziennik, historia
  write_version upgrade
  local msg="%SYS-5-SCRIPTS_UPGRADED: programy routera zaktualizowane ${old_ver:-?} → $SCRIPT_VERSION (zmienione: ${changed[*]})"
  logger -t install-router -p local0.notice "$msg" || true
  mkdir -p /var/log/router-monitor
  printf '%s %s\n' "$(now)" "$msg" >>/var/log/router-monitor/router-monitor.log
  if [[ -d /etc/.git ]] && command -v etckeeper >/dev/null; then
    etckeeper commit "install-router.sh: upgrade_script ${old_ver:-?} → $SCRIPT_VERSION (${changed[*]})" >/dev/null 2>&1 || true
  fi
  ok "gotowe — wersja na routerze: $SCRIPT_VERSION. Cofnięcie: skopiuj pliki z $bdir"
}

if [[ $MODE == upgrade ]]; then do_upgrade; exit 0; fi

printf '%s[%s] install-router.sh — start. Dane robocze i logi: %s%s\n' "$c_hdr" "$(now)" "$DATA_DIR" "$c_off"

# =============================================================================
# ETAP 01 — kontrola wstępna (zawsze wykonywany: wylicza parametry dla reszty)
# =============================================================================
CUR_STAGE="01 Kontrola wstępna"
printf '\n%s[%s] ETAP 01/%s  Kontrola wstępna i pełny audyt sprzętu/BIOS (zawsze wykonywany)%s\n' "$c_hdr" "$(now)" "$TOTAL_STAGES" "$c_off"
# shellcheck disable=SC1091
. /etc/os-release
[[ ${VERSION_ID:-} == 13 ]] || die "Wymagany Debian 13 (trixie), wykryto: ${PRETTY_NAME:-?}"
ok "$PRETTY_NAME, kernel $(uname -r)"

NUMA=""
for p in "${NIC_PCI[@]}"; do
  [[ -d /sys/bus/pci/devices/$p ]] || die "Brak urządzenia PCI $p (sprawdź: lspci -D | grep -i mellanox)"
  [[ $(cat "/sys/bus/pci/devices/$p/vendor") == 0x15b3 ]] || die "$p to nie jest karta Mellanox"
  drv=$(basename "$(readlink -f "/sys/bus/pci/devices/$p/driver" 2>/dev/null || echo brak)")
  [[ $drv == mlx5_core ]] || die "$p ma sterownik '$drv', oczekiwano mlx5_core"
  n=$(cat "/sys/bus/pci/devices/$p/numa_node"); ((n < 0)) && n=0
  [[ -z $NUMA || $NUMA == "$n" ]] || die "Porty są na różnych węzłach NUMA ($NUMA i $n)"
  NUMA=$n
  d=$(netdev_of "$p")
  if [[ -n $d ]] && ip -o addr show dev "$d" | grep -q 'inet '; then
    warn "$d ($p) ma adres IP w Linuksie — usuń go z /etc/network/interfaces, ten port przejmuje VPP"
  fi
  ok "$p  netdev=${d:-?}  NUMA=$n  $(lspci -s "$p" -vv 2>/dev/null | grep -o 'LnkSta: Speed [^,]*, Width x[0-9]*' || true)"
done

# =============================================================================
# AUDYT SPRZĘTU, BIOS, PAMIĘCI I PROCESORÓW + automatyczny dobór parametrów VPP
# =============================================================================
AUDIT=()          # "STATUS|obszar|wynik|komentarz"  (STATUS: OK, AUTO, WARN, INFO, ## = nagłówek)
REC=()            # "priorytet|gdzie|co|jak"          (1 = wymagane, 2 = zalecane, 3 = opcjonalne)
EXTRA_CMDLINE=()
audit() {
  AUDIT+=("$1|$2|$3|$4")
  case $1 in
    OK)   printf '  %s[OK]%s    %-26s %s\n' "$c_ok" "$c_off" "$2" "$3" ;;
    INFO) printf '  %s[INFO]%s  %-26s %s\n' "$c_dim" "$c_off" "$2" "$3" ;;
    AUTO) printf '  %s[AUTO]%s  %-26s %s → %s\n' "$c_ok" "$c_off" "$2" "$3" "$4" ;;
    *)    printf '  %s[UWAGA]%s %-26s %s — %s\n' "$c_warn" "$c_off" "$2" "$3" "$4" ;;
  esac
}
sect() { AUDIT+=("##|$1||"); printf '\n  %s── %s ──%s\n' "$c_hdr" "$1" "$c_off"; }
rec() { REC+=("$1|$2|$3|$4"); }
BIOSPATH="BIOS (F2 → System BIOS)"

# --- narzędzia potrzebne do audytu (brakujące doinstalowane z apt)
need=()
for t in lspci:pciutils ethtool:ethtool dmidecode:dmidecode jq:jq curl:curl ipmitool:ipmitool mstflint:mstflint smartctl:smartmontools; do
  command -v "${t%%:*}" >/dev/null || need+=("${t#*:}")
done
if ((${#need[@]})); then
  say "doinstalowuję narzędzia audytu: ${need[*]}"
  { apt-get update -qq && apt-get install -y -qq "${need[@]}"; } >/dev/null 2>&1 || warn "nie wszystkie narzędzia się zainstalowały — audyt może być niepełny"
fi
modprobe ipmi_si 2>/dev/null || true
modprobe ipmi_devintf 2>/dev/null || true

# ------------------------------------------------------------- serwer i firmware
sect "Serwer i firmware"
audit INFO "Model" "$(dmidecode -s system-manufacturer 2>/dev/null) $(dmidecode -s system-product-name 2>/dev/null)" ""
audit INFO "BIOS" "$(dmidecode -s bios-version 2>/dev/null) ($(dmidecode -s bios-release-date 2>/dev/null))" "najnowszy BIOS dla modelu: support Della"
rec 3 "iDRAC / Lifecycle Controller" "Zaktualizuj BIOS i iDRAC do najnowszych wersji dla R630" "iDRAC → Maintenance → System Update (albo pliki .EXE/.BIN z dell.com/support)"
idrac_fw=$(ipmitool mc info 2>/dev/null | sed -n 's/^Firmware Revision *: *//p')
[[ -n $idrac_fw ]] && audit INFO "iDRAC (BMC)" "firmware $idrac_fw" ""
if [[ -d /sys/firmware/efi ]]; then
  BOOTMODE=UEFI; audit OK "Tryb startu" "UEFI" "log kernel panic przetrwa restart (pstore)"
else
  BOOTMODE=BIOS; audit WARN "Tryb startu" "BIOS (legacy)" "log paniki nie przetrwa restartu (samo wykrycie awarii działa)"
  rec 3 "$BIOSPATH → Boot Settings" "Boot Mode = UEFI — tylko przy ponownej instalacji systemu" "zmiana na działającym systemie uniemożliwi start; przy reinstalacji wybierz UEFI"
fi

# ------------------------------------------------------------- ustawienia BIOS (iDRAC Redfish)
sect "Ustawienia BIOS"
declare -A BIOSA=()
if [[ -n $IDRAC_HOST ]]; then
  bios_json=$(curl -sk --max-time 20 -u "$IDRAC_USER:$IDRAC_PASS" \
    "https://$IDRAC_HOST/redfish/v1/Systems/System.Embedded.1/Bios" 2>/dev/null || true)
  if jq -e '.Attributes' >/dev/null 2>&1 <<<"$bios_json"; then
    while IFS='=' read -r k v; do BIOSA[$k]=$v; done < <(jq -r '.Attributes | to_entries[] | "\(.key)=\(.value)"' <<<"$bios_json")
    jq . <<<"$bios_json" >"$DATA_DIR/bios-attributes.json" 2>/dev/null || true
    audit OK "Odczyt z iDRAC" "$IDRAC_HOST (Redfish), ${#BIOSA[@]} ustawień" "pełna lista: $DATA_DIR/bios-attributes.json"
  else
    audit WARN "Odczyt z iDRAC" "nie udało się ($IDRAC_HOST)" "sprawdź adres/login iDRAC i czy iDRAC ma firmware ≥ 2.40 (Redfish)"
  fi
fi
declare -A BIOS_WHY=(
  [SysProfile]="Profil Performance: pełne taktowanie, turbo, bez głębokich C-states."
  [LogicalProc]="Worker VPP potrzebuje całego rdzenia fizycznego; HT nie dodaje przepustowości VPP, a zwiększa wahania opóźnień."
  [NodeInterleave]="Bez NUMA VPP nie trzyma pamięci przy procesorze karty — duży spadek wydajności."
  [ProcTurboMode]="Wyższe taktowanie workerów VPP."
  [MemOpMode]="Pełna przepustowość pamięci (bez mirroringu/spare)."
)
bios_check() {  # bios_check <atrybut> <oczekiwana> <prio> <ścieżka BIOS> <opis> [dopuszczalne...]
  local key=$1 want=$2 prio=$3 path=$4 desc=$5; shift 5
  local have=${BIOSA[$key]:-}
  [[ -n $have ]] || return 0
  local okv
  for okv in "$want" "$@"; do [[ $have == "$okv" ]] && { audit OK "$desc" "$have" ""; return 0; }; done
  audit WARN "$desc" "$have" "zalecane: $want"
  rec "$prio" "$BIOSPATH → $path" "$desc = $want (teraz: $have)" "${BIOS_WHY[$key]:+${BIOS_WHY[$key]} }Zmień w BIOS albo w iDRAC → Configuration → BIOS Settings, potem restart."
}
if ((${#BIOSA[@]})); then
  bios_check SysProfile     PerfOptimized 2 "System Profile Settings" "System Profile"
  bios_check LogicalProc    Disabled      2 "Processor Settings"      "Logical Processor (HT)"
  bios_check NodeInterleave Disabled      1 "Memory Settings"         "Node Interleaving"
  bios_check ProcTurboMode  Enabled       2 "System Profile Settings" "Turbo Boost"
  bios_check ProcCStates    Disabled      3 "System Profile Settings" "C-States"
  bios_check ProcC1E        Disabled      3 "System Profile Settings" "C1E"
  bios_check ProcPwrPerf    MaxPerf       3 "System Profile Settings" "CPU Power Management"
  bios_check MemFrequency   MaxPerf       3 "System Profile Settings" "Memory Frequency"
  bios_check UncoreFrequency MaxUFS       3 "System Profile Settings" "Uncore Frequency"
  bios_check MemOpMode      OptimizerMode 2 "Memory Settings"         "Memory Operating Mode"
  bios_check SnoopMode      OpportunisticSnoopBroadcast 3 "Memory Settings" "Snoop Mode" HomeSnoop EarlySnoop
  bios_check ProcX2Apic     Enabled       3 "Processor Settings"      "x2APIC Mode"
else
  audit INFO "Odczyt BIOS" "wnioskowany z Linuksa" "dokładny odczyt: ustaw IDRAC_HOST/IDRAC_USER/IDRAC_PASS na górze skryptu"
  rec 3 "install-router.sh (ustawienia)" "Podaj IDRAC_HOST/IDRAC_USER/IDRAC_PASS, żeby audyt czytał BIOS bezpośrednio z iDRAC" "./install-router.sh --audit"
fi

# ------------------------------------------------------------- procesory
sect "Procesory"
CPU_MODEL=$(LC_ALL=C lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -n1)
SOCKETS=$(LC_ALL=C lscpu | sed -n 's/^Socket(s):[[:space:]]*//p' | head -n1)
CPU_MAX=$(LC_ALL=C lscpu | sed -n 's/^CPU max MHz:[[:space:]]*//p' | head -n1 | cut -d. -f1)
NUMA_NODES=$(find /sys/devices/system/node -maxdepth 1 -name 'node[0-9]*' | wc -l)
audit INFO "Model" "${SOCKETS:-?} × $CPU_MODEL${CPU_MAX:+ (turbo do ${CPU_MAX} MHz)}" ""
ucode=$(grep -m1 '^microcode' /proc/cpuinfo | awk '{print $3}')
if dpkg -s intel-microcode >/dev/null 2>&1 || ! grep -q GenuineIntel /proc/cpuinfo; then
  audit OK "Mikrokod" "${ucode:-?} (pakiet zainstalowany)" ""
else
  audit WARN "Mikrokod" "${ucode:-?}, brak pakietu intel-microcode" "poprawki stabilności i bezpieczeństwa CPU"
  rec 2 "system" "Zainstaluj mikrokod Intela" "dodaj 'non-free-firmware' w /etc/apt/sources.list, potem: apt install intel-microcode, restart"
fi
flags=$(grep -m1 '^flags' /proc/cpuinfo)
simd="SSE4.2"; [[ $flags == *" avx2 "* ]] && simd="AVX2"; [[ $flags == *" avx512f "* ]] && simd="AVX-512"
audit OK "Instrukcje SIMD" "$simd" "VPP sam wybierze najszybszy wariant kodu"

read -ra NODE_CPUS <<<"$(expand_cpulist "$(cat "/sys/devices/system/node/node$NUMA/cpulist")")"
PHYS=(); HT=0
for c in "${NODE_CPUS[@]}"; do
  read -ra sibs <<<"$(expand_cpulist "$(cat "/sys/devices/system/cpu/cpu$c/topology/thread_siblings_list")")"
  ((${#sibs[@]} > 1)) && HT=1
  [[ ${sibs[0]} == "$c" ]] && PHYS+=("$c")
done
audit INFO "Rdzenie" "węzłów NUMA: $NUMA_NODES, karta na węźle $NUMA, rdzeni fizycznych na nim: ${#PHYS[@]}" ""
smt_ctl=$(cat /sys/devices/system/cpu/smt/control 2>/dev/null || echo "")
if ((HT == 0)) && [[ $smt_ctl == off || $smt_ctl == forceoff ]]; then
  audit WARN "Hyper-Threading" "włączony w BIOS, wyłączony przez kernel (nosmt)" "lepiej wyłączyć w BIOS"
  ((AUTO_NOSMT)) && EXTRA_CMDLINE+=(nosmt)
  [[ -n ${BIOSA[LogicalProc]:-} ]] || rec 3 "$BIOSPATH → Processor Settings" "Logical Processor = Disabled" "kernel już nie używa HT (nosmt); wyłączenie w BIOS porządkuje numerację CPU."
elif ((HT)); then
  audit WARN "Hyper-Threading" "WŁĄCZONY" "dla tego routera zalecane WYŁĄCZENIE"
  [[ -n ${BIOSA[LogicalProc]:-} ]] || rec 2 "$BIOSPATH → Processor Settings" "Logical Processor = Disabled (wyłącz Hyper-Threading)" \
    "worker VPP potrzebuje całego rdzenia fizycznego: drugi wątek dzieli z nim cache i jednostki wykonawcze, nie dodaje przepustowości VPP, a zwiększa wahania opóźnień. Na tym serwerze rdzeni fizycznych jest dość."
  if ((AUTO_NOSMT)); then
    EXTRA_CMDLINE+=(nosmt)
    audit AUTO "Hyper-Threading (system)" "włączony w BIOS" "dodaję 'nosmt' do kernela, dopóki nie wyłączysz HT w BIOS"
  fi
else
  audit OK "Hyper-Threading" "wyłączony" "tak ma być dla routera VPP"
fi
if (( ${SOCKETS:-1} > 1 && NUMA_NODES < 2 )); then
  audit WARN "NUMA" "2 procesory, 1 węzeł NUMA" "włączone Node Interleaving"
  rec 1 "$BIOSPATH → Memory Settings" "Node Interleaving = Disabled" "bez tego VPP nie może trzymać pamięci przy procesorze karty — duży spadek wydajności"
elif (( NUMA_NODES > ${SOCKETS:-1} )); then
  audit WARN "NUMA" "$NUMA_NODES węzłów na ${SOCKETS} procesory" "Snoop Mode = Cluster on Die dzieli procesor na pół"
  rec 3 "$BIOSPATH → Memory Settings" "Snoop Mode = Opportunistic Snoop Broadcast (zamiast Cluster on Die)" "mniej rdzeni na węźle karty = mniej workerów VPP"
else
  audit OK "NUMA" "węzłów: $NUMA_NODES, interleaving wyłączony" ""
fi
gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo brak)
drv=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo brak)
if [[ $gov == brak ]]; then
  audit OK "Taktowanie" "sterowane przez BIOS" "tak jest przy System Profile = Performance"
elif [[ $gov == performance ]]; then
  audit OK "Taktowanie" "$drv / performance" ""
else
  audit AUTO "Taktowanie" "$drv / $gov" "ustawię governor 'performance' (teraz i przy każdym starcie)"
  ((${#BIOSA[@]})) || rec 2 "$BIOSPATH → System Profile Settings" "System Profile = Performance" "pełna częstotliwość, turbo, bez głębokich C-states; system ma teraz oszczędzanie energii ($gov)"
fi
if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo && $(cat /sys/devices/system/cpu/intel_pstate/no_turbo) == 1 ]]; then
  audit AUTO "Turbo Boost" "wyłączony w systemie" "włączę (no_turbo=0)"
fi
states=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name 2>/dev/null | xargs || true)
if grep -qE 'C3|C6|C7|C8|C10' <<<"$states"; then
  if ((AUTO_CSTATE)); then
    EXTRA_CMDLINE+=(intel_idle.max_cstate=1 processor.max_cstate=1)
    audit AUTO "C-states" "głębokie stany aktywne ($states)" "ograniczam do C1 w kernelu"
  else
    audit WARN "C-states" "głębokie stany aktywne ($states)" "opóźnienia przy wybudzaniu rdzeni"
  fi
  ((${#BIOSA[@]})) || rec 2 "$BIOSPATH → System Profile Settings" "System Profile = Performance (wyłącza C-states i C1E)" "skrypt ogranicza C-states w kernelu, ale właściwe miejsce to BIOS"
else
  audit OK "C-states" "${states:-wyłączone w BIOS}" ""
fi

# ------------------------------------------------------------- pamięć RAM
sect "Pamięć RAM"
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
NODE_MEM_MB=$(awk '/MemTotal/{print int($4/1024)}' "/sys/devices/system/node/node$NUMA/meminfo")
audit INFO "Razem" "$((MEM_MB / 1024)) GB, na węźle karty $((NODE_MEM_MB / 1024)) GB" ""
dimm_rows=$(dmidecode -t 17 2>/dev/null | awk -F': ' '
  /^Memory Device/ {if (sz!="") print loc"|"sz"|"typ"|"spd"|"cfg"|"rk"|"man; sz=""; loc=""; typ=""; spd=""; cfg=""; rk=""; man=""}
  /^\tSize: [0-9]/ {sz=$2} /^\tLocator: / {loc=$2} /^\tType: / {typ=$2}
  /^\tSpeed: / {spd=$2} /^\tConfigured (Memory|Clock) Speed: / {cfg=$2}
  /^\tRank: / {rk=$2} /^\tManufacturer: / {man=$2}
  END {if (sz!="") print loc"|"sz"|"typ"|"spd"|"cfg"|"rk"|"man}')
if [[ -n $dimm_rows ]]; then
  while IFS='|' read -r loc sz typ spd cfg rk man; do
    audit INFO "Moduł $loc" "$sz $typ, $cfg (moduł: $spd), rank $rk, $man" ""
  done <<<"$dimm_rows"
  sizes=$(cut -d'|' -f2 <<<"$dimm_rows" | sort -u | wc -l)
  ((sizes > 1)) && { audit WARN "Rozmiary modułów" "mieszane" "moduły różnej pojemności obniżają przeplot kanałów"; rec 3 "sprzęt" "Używaj modułów tej samej pojemności" "jednakowe moduły na wszystkich kanałach"; }
  slow=$(awk -F'|' '{gsub(/[^0-9]/,"",$4); gsub(/[^0-9]/,"",$5); if ($4!="" && $5!="" && $5+0 < $4+0) n++} END{print n+0}' <<<"$dimm_rows")
  ((slow > 0)) && { audit WARN "Taktowanie RAM" "$slow modułów pracuje wolniej niż mogą" "ustawienie BIOS albo limit procesora"; rec 3 "$BIOSPATH → System Profile Settings" "Memory Frequency = Maximum Performance" "jeśli nadal wolniej — to limit procesora/obsady kanałów"; }
  for bank in $(cut -d'|' -f1 <<<"$dimm_rows" | awk '{print $NF}' | grep -oE '^[A-Z]' | sort -u); do
    n=$(cut -d'|' -f1 <<<"$dimm_rows" | awk '{print $NF}' | grep -c "^$bank")
    if ((n < 4)); then
      audit WARN "Kanały procesora $bank" "$n moduły" "nie wszystkie 4 kanały obsadzone"
      rec 2 "sprzęt" "Obsadź sloty ${bank}1–${bank}4 (po jednym module na kanał)" "pełna przepustowość pamięci dla VPP"
    else
      audit OK "Kanały procesora $bank" "$n moduły (wszystkie kanały)" ""
    fi
  done
fi
ce=0; ue=0
for mc in /sys/devices/system/edac/mc/mc*; do
  [[ -f $mc/ce_count ]] || continue
  ce=$((ce + $(cat "$mc/ce_count"))); ue=$((ue + $(cat "$mc/ue_count")))
done
if ((ue > 0)); then
  audit WARN "Błędy pamięci (EDAC)" "nienaprawialne: $ue, naprawialne: $ce" "uszkodzony moduł"
  rec 1 "sprzęt" "Wymień uszkodzony moduł RAM" "iDRAC → Logs → System Event Log wskaże slot"
elif ((ce > 0)); then
  audit WARN "Błędy pamięci (EDAC)" "naprawialne: $ce" "moduł zaczyna się psuć"
  rec 2 "sprzęt" "Sprawdź moduły RAM (rosnące błędy naprawialne)" "iDRAC → Logs → System Event Log"
else
  audit OK "Błędy pamięci (EDAC)" "brak" ""
fi

# ------------------------------------------------------------- karta sieciowa
sect "Karta sieciowa"
NIC_DEV=$(cat "/sys/bus/pci/devices/${NIC_PCI[0]}/device")
case $NIC_DEV in
  0x1013) NIC_MODEL="ConnectX-4";        NIC_CAP=12 ;;
  0x1015) NIC_MODEL="ConnectX-4 Lx";     NIC_CAP=8 ;;
  0x1017) NIC_MODEL="ConnectX-5";        NIC_CAP=16 ;;
  0x1019) NIC_MODEL="ConnectX-5 Ex";     NIC_CAP=18 ;;
  0x101b|0x101d|0x101f) NIC_MODEL="ConnectX-6"; NIC_CAP=20 ;;
  0x1021) NIC_MODEL="ConnectX-7";        NIC_CAP=24 ;;
  *)      NIC_MODEL="Mellanox $NIC_DEV"; NIC_CAP=12 ;;
esac
NIC_PN=$(lspci -s "${NIC_PCI[0]}" -vv 2>/dev/null | sed -n 's/.*\[PN\] Part number: *//p' | head -n1)
NIC_PSID=$(mstflint -d "${NIC_PCI[0]}" q 2>/dev/null | sed -n 's/^PSID: *//p' | head -n1)
NIC_FW=$(mstflint -d "${NIC_PCI[0]}" q 2>/dev/null | sed -n 's/^FW Version: *//p' | head -n1)
if [[ -z $NIC_FW ]]; then d=$(netdev_of "${NIC_PCI[0]}"); [[ -n $d ]] && NIC_FW=$(ethtool -i "$d" 2>/dev/null | awk '/firmware-version/{print $2}'); fi
audit INFO "Model" "$NIC_MODEL ${NIC_PN:+($NIC_PN)}, PSID ${NIC_PSID:-?}" ""
for p in "${NIC_PCI[@]}"; do
  lnk=$(lspci -s "$p" -vv 2>/dev/null)
  cap_w=$(grep -o 'LnkCap:.*Width x[0-9]*' <<<"$lnk" | grep -o 'x[0-9]*$' || true)
  sta_w=$(grep -o 'LnkSta:.*Width x[0-9]*' <<<"$lnk" | grep -o 'x[0-9]*$' || true)
  sta_s=$(grep -o 'LnkSta: Speed [0-9.]*GT/s' <<<"$lnk" | grep -o '[0-9.]*GT' || true)
  if [[ -n $sta_w && $sta_w != "$cap_w" ]]; then
    audit WARN "PCIe $p" "$sta_w zamiast $cap_w" "karta w wolniejszym slocie"
    rec 1 "sprzęt" "Przełóż kartę do slotu x16 (R630: slot 1 low-profile → CPU2)" "w slocie x8 karta 100G zrobi najwyżej ~50 Gb/s"
  else
    audit OK "PCIe $p" "${sta_s:-?}/s ${sta_w:-?}" ""
  fi
done
if [[ $NIC_PSID == DEL* ]]; then
  audit WARN "Firmware" "${NIC_FW:-?} (karta z firmware Della)" "aktualizacja tylko pakietem Della"
  rec 2 "dell.com/support" "Zaktualizuj firmware karty pakietem Della dla PSID $NIC_PSID" "narzędzie NVIDIA mlxup nie obsługuje kart z PSID Della"
elif [[ $NIC_DEV == 0x1013 && -n $NIC_FW && $(printf '%s\n%s\n' "$NIC_FW" "12.28.0" | sort -V | head -n1) != "12.28.0" ]]; then
  audit WARN "Firmware" "$NIC_FW" "stary firmware"
  rec 2 "system (po instalacji)" "Zaktualizuj firmware karty" "skrypt pobierze firmware i przygotuje polecenie: router-fw-update (uruchamiasz ręcznie, wymaga restartu)"
else
  audit OK "Firmware" "${NIC_FW:-?}" ""
fi

# ------------------------------------------------------------- dyski, RAID
sect "Dyski i RAID"
while read -r name size rota model; do
  [[ -n $name ]] || continue
  h=$(smartctl -H "/dev/$name" 2>/dev/null | sed -n 's/.*overall-health self-assessment test result: //p; s/^SMART Health Status: //p' | head -n1)
  audit INFO "Dysk $name" "$size $([[ $rota == 1 ]] && echo HDD || echo SSD) $model, SMART: ${h:-niedostępny}" ""
  [[ -n $h && $h != PASSED && $h != OK ]] && rec 1 "sprzęt" "Wymień dysk /dev/$name (SMART: $h)" "przy RAID: mdadm --manage /dev/mdX --fail/--remove/--add"
done < <(lsblk -dno NAME,SIZE,ROTA,MODEL 2>/dev/null | grep -vE '^(loop|sr|ram)')
if grep -q '^md' /proc/mdstat 2>/dev/null; then
  while read -r line; do
    md=$(awk '{print $1}' <<<"$line"); lvl=$(awk '{print $4}' <<<"$line")
    st=$(grep -A1 "^$md " /proc/mdstat | grep -o '\[[U_]*\]' | tail -n1)
    if [[ $st == *_* ]]; then audit WARN "RAID $md" "$lvl $st" "macierz zdegradowana"; rec 1 "sprzęt" "Napraw macierz $md" "cat /proc/mdstat; mdadm --detail /dev/$md"
    else audit OK "RAID $md" "$lvl $st" ""; fi
  done < <(grep '^md' /proc/mdstat)
else
  audit WARN "RAID" "brak macierzy mdadm" "awaria dysku = awaria routera"
  rec 2 "system" "System na RAID1 (mdadm) z dwóch dysków" "przy reinstalacji Debiana: partycjonowanie ręczne → RAID"
fi
if [[ -n $(lspci 2>/dev/null | grep -i 'RAID bus controller' || true) ]]; then
  audit INFO "Kontroler RAID" "$(lspci | grep -i 'RAID bus controller' | head -n1 | cut -d: -f3- | xargs)" "dla mdadm i smartd kontroler powinien być w trybie HBA"
fi

# ------------------------------------------------------------- zasilanie i temperatury (IPMI)
sect "Zasilanie i środowisko (iDRAC/IPMI)"
if ipmitool sdr type "Power Supply" >/dev/null 2>&1; then
  psu=$(ipmitool sdr type "Power Supply" 2>/dev/null | grep -i 'status' || true)
  npsu=$(grep -ci 'presence detected' <<<"$psu" || true)
  nbad=$(grep -ciE 'failure|lost|absent' <<<"$psu" || true)
  if ((npsu >= 2 && nbad == 0)); then audit OK "Zasilacze" "$npsu sprawne" "podłącz do dwóch niezależnych linii/UPS"
  else
    audit WARN "Zasilacze" "obecne: $npsu, problemy: $nbad" "brak redundancji zasilania"
    rec 1 "sprzęt" "Dwa sprawne zasilacze, każdy na innej linii zasilania" "iDRAC → Overview → Power Supplies"
  fi
  tmax=$(ipmitool sdr type Temperature 2>/dev/null | grep -oE '[0-9]+ degrees' | awk '{print $1}' | sort -n | tail -n1)
  [[ -n $tmax ]] && audit INFO "Temperatura" "najwyższa: ${tmax} °C" ""
else
  audit INFO "IPMI" "niedostępne z systemu" "zasilacze i temperatury sprawdź w iDRAC"
fi

# ------------------------------------------------------------- system
sect "System"
kv=$(uname -r | cut -d. -f1-2)
if [[ $(printf '%s\n6.1\n' "$kv" | sort -V | head -n1) == 6.1 ]]; then audit OK "Kernel" "$(uname -r)" ""
else audit WARN "Kernel" "$(uname -r)" "zalecany ≥ 6.1"; rec 2 "system" "Kernel ≥ 6.1 (Debian 13 ma 6.12)" "apt install linux-image-amd64"; fi
wd=$(find /dev -maxdepth 1 -name 'watchdog*' 2>/dev/null | sort | xargs || true)
audit INFO "Watchdog sprzętowy" "${wd:-jeszcze nieaktywny}" "skrypt załaduje sterownik i włączy go w systemd"

# ------------------------------------------------------------- dobór parametrów VPP
sect "Dobór parametrów VPP"
avail_w=$(( ${#PHYS[@]} - 2 ))   # 1 rdzeń dla systemu na węźle karty + 1 rdzeń główny VPP
((avail_w >= 1)) || die "Węzeł NUMA $NUMA ma za mało rdzeni fizycznych (${#PHYS[@]})"
if [[ $VPP_WORKERS == auto ]]; then
  VPP_WORKERS=$(( NIC_CAP < avail_w ? NIC_CAP : avail_w ))
  audit AUTO "Workery VPP" "$NIC_MODEL, wolnych rdzeni: $avail_w" "$VPP_WORKERS (powyżej $NIC_CAP karta i tak nie nadąży)"
else
  ((VPP_WORKERS <= avail_w)) || die "VPP_WORKERS=$VPP_WORKERS, a na węźle $NUMA jest tylko $avail_w wolnych rdzeni"
  audit OK "Workery VPP" "$VPP_WORKERS (ustawione ręcznie)" ""
fi
MAIN_CORE=${PHYS[1]}
WORKERS=("${PHYS[@]:2:VPP_WORKERS}")
WORKERS_CSV=$(join_by , "${WORKERS[@]}")
ISOL=("$MAIN_CORE" "${WORKERS[@]}")
if ((HT)); then
  for c in "$MAIN_CORE" "${WORKERS[@]}"; do
    read -ra sibs <<<"$(expand_cpulist "$(cat "/sys/devices/system/cpu/cpu$c/topology/thread_siblings_list")")"
    for s in "${sibs[@]:1}"; do ISOL+=("$s"); done
  done
fi
ISOL_CSV=$(join_by , "${ISOL[@]}")
audit AUTO "Rdzenie" "węzeł $NUMA" "main $MAIN_CORE, workery $WORKERS_CSV, izolowane $ISOL_CSV"
if [[ $HUGEPAGES_2M == auto ]]; then
  HUGEPAGES_2M=$(( MEM_MB / 4 / 2 ))
  ((HUGEPAGES_2M > 8192)) && HUGEPAGES_2M=8192
  ((HUGEPAGES_2M < 2048)) && HUGEPAGES_2M=2048
fi
HP_NODE_MB=$(( HUGEPAGES_2M * 2 / NUMA_NODES ))
if ((HP_NODE_MB >= 6144)); then MAIN_HEAP=4G; BUFFERS=262144; else MAIN_HEAP=2G; BUFFERS=131072; fi
audit AUTO "Pamięć VPP" "RAM $((MEM_MB / 1024)) GB" "hugepages $HUGEPAGES_2M × 2 MB, sterta $MAIN_HEAP, bufory $BUFFERS"
((NODE_MEM_MB >= 16384)) || { audit WARN "Pamięć węzła karty" "$((NODE_MEM_MB / 1024)) GB" "mało na pełne tablice BGP"; rec 2 "sprzęt" "Dołóż RAM na procesorze karty (≥ 16 GB)" "VPP + pełne tablice BGP"; }
EXTRA_CMDLINE+=("panic=$PANIC_REBOOT_SEC" "oops=panic")
audit AUTO "Kernel panic" "restart po panic" "panic=$PANIC_REBOOT_SEC oops=panic w linii kernela + sysctl kernel.panic"

# ------------------------------------------------------------- raport audytu i zalecenia
audit_md() {
  local l st ob wy dz
  echo "# Audyt serwera — $(now), $(hostname)"
  echo
  for l in "${AUDIT[@]}"; do
    IFS='|' read -r st ob wy dz <<<"$l"
    if [[ $st == "##" ]]; then printf '\n### %s\n\n| Stan | Obszar | Wynik | Komentarz |\n|---|---|---|---|\n' "$ob"
    else printf '| %s | %s | %s | %s |\n' "$st" "$ob" "$wy" "${dz:--}"; fi
  done
  echo
  echo "### Zalecenia"
  echo
  if ((${#REC[@]} == 0)); then echo "Brak — konfiguracja sprzętu zgodna z zaleceniami."; return; fi
  local n=0 pr gd co jak lab
  for pr in 1 2 3; do
    for l in "${REC[@]}"; do
      IFS='|' read -r p gd co jak <<<"$l"
      [[ $p == "$pr" ]] || continue
      n=$((n + 1)); lab=$([[ $pr == 1 ]] && echo WYMAGANE || { [[ $pr == 2 ]] && echo ZALECANE || echo OPCJONALNE; })
      printf '%d. **[%s] %s**  \n   Gdzie: %s  \n   %s\n\n' "$n" "$lab" "$co" "$gd" "$jak"
    done
  done
}
audit_md >"$DATA_DIR/audit.md"
printf '\n  %s── ZALECENIA ──%s\n' "$c_hdr" "$c_off"
if ((${#REC[@]} == 0)); then ok "brak — sprzęt i BIOS zgodne z zaleceniami"
else
  n=0
  for pr in 1 2 3; do
    for l in "${REC[@]}"; do
      IFS='|' read -r p gd co jak <<<"$l"
      [[ $p == "$pr" ]] || continue
      n=$((n + 1))
      case $pr in 1) col=$c_err; lab=WYMAGANE ;; 2) col=$c_warn; lab=ZALECANE ;; *) col=$c_dim; lab=OPCJONALNE ;; esac
      printf '  %2d. %s[%s]%s %s\n      gdzie: %s\n      %s\n' "$n" "$col" "$lab" "$c_off" "$co" "$gd" "$jak"
    done
  done
fi
ok "pełny raport audytu: $DATA_DIR/audit.md"

# --- po audycie: tryb --audit kończy tutaj; przy nowej instalacji pytanie o kontynuację
if [[ $MODE == audit ]]; then
  printf '\n%sTryb --audit: niczego nie zmieniono. Pełny raport: %s%s\n' "$c_hdr" "$DATA_DIR/audit.md" "$c_off"
  exit 0
fi
INTERACTIVE=0
[[ -t 0 && $ASSUME_YES == 0 ]] && INTERACTIVE=1
if ((INTERACTIVE)) && ! compgen -G "$STATE_DIR/*.done" >/dev/null; then
  printf '\n'
  read -rp "Kontynuować instalację z tymi ustawieniami? (zalecenia BIOS możesz wprowadzić później) [T/n] " ans
  [[ -z $ans || $ans =~ ^[TtYy] ]] || { echo "Przerwano. Po zmianach w BIOS uruchom skrypt ponownie."; exit 0; }
fi

# --- powiadomienia e-mail: zewnętrzny serwer SMTP (pytanie, jeśli nie ustawiono w skrypcie)
if [[ -z $ALERT_EMAILS && ! -f /etc/router/notify.conf ]] && ((INTERACTIVE)); then
  printf '\n  %s── Powiadomienia e-mail (Twój zewnętrzny serwer SMTP) ──%s\n' "$c_hdr" "$c_off"
  read -rp "  Skonfigurować teraz? [T/n] " ans
  if [[ -z $ans || $ans =~ ^[TtYy] ]]; then
    read -rp "  Odbiorcy alarmów (po przecinku): " ALERT_EMAILS
    if [[ -n $ALERT_EMAILS ]]; then
      until [[ -n $SMTP_HOST ]]; do read -rp "  Serwer SMTP (np. smtp.firma.pl): " SMTP_HOST; done
      read -rp "  Szyfrowanie starttls / ssl / none [starttls]: " ans; SMTP_SECURITY=${ans:-starttls}
      case $SMTP_SECURITY in ssl) def=465 ;; none) def=25 ;; *) SMTP_SECURITY=starttls; def=587 ;; esac
      read -rp "  Port [$def]: " ans; SMTP_PORT=${ans:-$def}
      read -rp "  Login SMTP: " SMTP_USER
      read -rsp "  Hasło SMTP (nie jest wyświetlane): " SMTP_PASS; echo
      read -rp "  Adres nadawcy [$SMTP_USER]: " ans; SMTP_FROM=${ans:-$SMTP_USER}
      printf '\n  Co wysyłać mailem? Dostępne kategorie:\n'
      printf '    %-10s %s\n' CRASH "kernel panic, nieczysty restart" SERVICES "awaria/restart VPP, BIRD" \
        BOOT "wynik kontroli po starcie" RAID "mdadm: dyski, degradacja, odbudowa" DISKS "smartd: zdrowie dysków" \
        NIC_FW "aktualizacja firmware karty" VPP_STATE "VPP niedostępny/zawieszony" VPP_DROPS "utrata pakietów (rx-miss, karta)" \
        VPP_LOAD "przeciążenie workerów VPP" VPP_PUNT "atak na control plane" SYS_CPU "przeciążenie rdzeni systemowych" \
        IFACES "interfejsy: zmiany, rozjazd, błędy ifaces.conf" FIREWALL "firewall: zmiany reguł, rozjazd, blokady" \
        STATS "minutowe statystyki (dużo maili)" OTHER "pozostałe" ALL "wszystko"
      read -rp "  Kategorie [$MAIL_SEND]: " ans; MAIL_SEND=${ans:-$MAIL_SEND}
      read -rp "  Wysyłać też zakończenia zdarzeń (np. LOAD_NORMAL z czasem trwania)? [T/n] " ans
      [[ -z $ans || $ans =~ ^[TtYy] ]] && MAIL_SEND_CLEAR=yes || MAIL_SEND_CLEAR=no
      write_notify_conf
      ok "zapisano /etc/router/notify.conf (mail testowy zostanie wysłany w etapie powiadomień)"
    fi
  fi
fi

if [[ -z $ROUTER_ID ]]; then
  ROUTER_ID=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)
  [[ -n $ROUTER_ID ]] || die "Nie umiem ustalić ROUTER_ID — ustaw go w skrypcie"
fi
[[ -n $SNMP_COMMUNITY ]] || SNMP_COMMUNITY=$(grep -s '^SNMP_COMMUNITY=' "$ENV_FILE" | cut -d= -f2 || true)
[[ -n $SNMP_COMMUNITY ]] || SNMP_COMMUNITY=$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')
ok "router id $ROUTER_ID"

avail=$(df --output=avail -BG "$DATA_DIR" | tail -1 | tr -dc 0-9)
if [[ ! -f $STATE_DIR/10.done ]]; then
  ((avail >= 25)) || die "Za mało miejsca w $DATA_DIR: ${avail} GB (kompilacja VPP potrzebuje ≥ 25 GB)"
fi
ok "wolne miejsce w $DATA_DIR: ${avail} GB"

timeout 10 getent hosts github.com >/dev/null || die "Brak DNS/internetu (github.com) — skrypt pobiera źródła i paczki"
ok "internet dostępny"

cat >"$ENV_FILE" <<EOF
INST_NIC_PCI="${NIC_PCI[*]}"
INST_NUMA=$NUMA
INST_MAIN_CORE=$MAIN_CORE
INST_WORKERS=$WORKERS_CSV
INST_NIC_MODEL="$NIC_MODEL"
INST_NIC_PSID="$NIC_PSID"
INST_BOOTMODE=$BOOTMODE
INST_NIC_FW="$NIC_FW"
INST_HUGEPAGES=$HUGEPAGES_2M
INST_MAIN_HEAP=$MAIN_HEAP
INST_EXTRA_CMDLINE="${EXTRA_CMDLINE[*]}"
INST_ROUTER_ID=$ROUTER_ID
SNMP_COMMUNITY=$SNMP_COMMUNITY
EOF
chmod 600 "$ENV_FILE"
mkdir -p /etc/router && install -m 600 "$ENV_FILE" /etc/router/router.env
install -m 644 "$DATA_DIR/audit.md" /etc/router/hardware-audit.md
ok "parametry zapisane w $ENV_FILE i /etc/router/router.env"

# =============================================================================
# ETAPY
# =============================================================================
st_packages() {
  say "apt-get update"
  apt-get update
  local pk=(sudo git ca-certificates curl wget gnupg build-essential pkg-config python3 python3-yaml
            ethtool numactl pciutils rdma-core ibverbs-utils irqbalance snmpd snmp tcpdump iproute2
            libpcap-dev uuid-dev etckeeper jq mdadm smartmontools systemd-coredump ipmitool)
  say "instaluję: ${pk[*]}"
  apt-get install "${APT_OPTS[@]}" "${pk[@]}"
  man_add pkg "${pk[*]}" "paczki Debiana (apt)"
  if apt-get install "${APT_OPTS[@]}" mstflint; then man_add pkg mstflint "narzędzie do firmware Mellanox"
  else warn "mstflint niedostępny — firmware zaktualizujesz ręcznie"; fi
  ok "pakiety bazowe zainstalowane"
}

st_firmware() {
  local fdir=$DATA_DIR/firmware p
  mkdir -p "$fdir"
  man_add dir "$fdir" "firmware karty: mlxup (z obrazami firmware), kopie zapasowe, wyniki zapytań"
  say "pobieram mlxup (narzędzie NVIDIA z obrazami firmware)"
  local u ok_dl=0
  for u in "${MLXUP_URLS[@]}"; do
    if curl -fsSL --max-time 300 -o "$fdir/mlxup.new" "$u"; then mv -f "$fdir/mlxup.new" "$fdir/mlxup"; chmod 755 "$fdir/mlxup"; ok_dl=1; say "pobrano: $u"; break; fi
  done
  ((ok_dl)) || { rm -f "$fdir/mlxup.new"; warn "nie pobrano mlxup — router-fw-update spróbuje ponownie przy uruchomieniu"; }
  local bdf=${NIC_PCI[0]#0000:}
  say "kopia zapasowa obecnego firmware (mstflint ri)"
  if mstflint -d "$bdf" ri "$fdir/backup-${NIC_PSID:-psid}-${NIC_FW:-fw}.bin" >/dev/null 2>&1; then
    ok "kopia: $fdir/backup-${NIC_PSID:-psid}-${NIC_FW:-fw}.bin"
  else
    warn "nie udało się odczytać obrazu firmware (mstflint ri) — aktualizacja i tak jest możliwa"
  fi
  if [[ -x $fdir/mlxup ]]; then
    "$fdir/mlxup" -d "$bdf" --query >"$fdir/query-offline.txt" 2>&1 || true
    timeout 120 "$fdir/mlxup" -d "$bdf" --online --query >"$fdir/query-online.txt" 2>&1 || true
    local cur off onl
    cur=$(awk '$1=="FW"{print $2; exit}' "$fdir/query-offline.txt")
    off=$(awk '$1=="FW"{print $3; exit}' "$fdir/query-offline.txt")
    onl=$(awk '$1=="FW"{print $3; exit}' "$fdir/query-online.txt")
    ok "firmware: obecny ${cur:-${NIC_FW:-?}}, w pobranym mlxup ${off:-?}, najnowszy online ${onl:-?}"
  fi
  [[ $NIC_PSID == DEL* ]] && warn "karta z PSID Della ($NIC_PSID) — mlxup jej nie zaktualizuje; użyj pakietu z dell.com/support"

  prog_router_fw_update | put_file /opt/router/bin/router-fw-update "aktualizacja firmware karty (uruchamiana RĘCZNIE, wymaga restartu)" 755
  ln -sfn /opt/router/bin/router-fw-update /usr/local/sbin/router-fw-update
  man_add file /usr/local/sbin/router-fw-update "polecenie router-fw-update (ręczna aktualizacja firmware karty)"
  ok "aktualizacja firmware: router-fw-update (ręcznie, w oknie serwisowym)"
}

st_kernel() {
  put_file /etc/modules-load.d/mlx5-dpdk.conf "moduły mlx5/RDMA ładowane przy starcie (wymagane przez DPDK mlx5)" <<'EOF'
mlx5_core
mlx5_ib
ib_uverbs
EOF
  say "modprobe mlx5_ib ib_uverbs"
  modprobe mlx5_ib
  modprobe ib_uverbs
  put_file /etc/sysctl.d/81-vpp-router.conf "hugepages dla VPP, bufory netlink dla linux-nl" <<EOF
# install-router.sh: hugepages dla VPP i bufor netlink dla linux-nl (pełna tablica BGP)
vm.nr_hugepages = $HUGEPAGES_2M
vm.max_map_count = $((HUGEPAGES_2M * 2 + 4096))
kernel.shmmax = $((HUGEPAGES_2M * 2 * 1024 * 1024))
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
EOF
  put_file /etc/sysctl.d/82-router-neigh.conf "duże tablice ARP/ND (LAN IX); stosowane też w netns dataplane" <<'EOF'
# install-router.sh: duże tablice ARP/ND (LAN IX, wielu sąsiadów)
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384
net.ipv6.neigh.default.gc_thresh1 = 4096
net.ipv6.neigh.default.gc_thresh2 = 8192
net.ipv6.neigh.default.gc_thresh3 = 16384
EOF
  say "sysctl --system"
  sysctl --system >/dev/null
  ok "hugepages teraz: $(awk '/HugePages_Total/{print $2}' /proc/meminfo) × 2 MB (pełna pula po restarcie)"
}

st_isolation() {
  put_file /etc/default/grub.d/90-vpp.cfg "parametry kernela: izolacja rdzeni VPP" <<EOF
# install-router.sh: rdzenie VPP (main + workery) wyłączone z harmonogramu systemu
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT isolcpus=$ISOL_CSV rcu_nocbs=$ISOL_CSV ${EXTRA_CMDLINE[*]}"
EOF
  if command -v update-grub >/dev/null; then
    say "update-grub"
    update-grub
    man_add file /boot/grub/grub.cfg "wygenerowany ponownie przez update-grub (isolcpus=$ISOL_CSV)"
    ok "GRUB: isolcpus=$ISOL_CSV ${EXTRA_CMDLINE[*]} (działa po restarcie)"
  else
    warn "Brak update-grub — dodaj ręcznie do linii kernela: isolcpus=$ISOL_CSV rcu_nocbs=$ISOL_CSV"
  fi
  local cfg
  cfg=$(grep -v -e '^IRQBALANCE_BANNED_CPULIST=' -e '^# install-router.sh: przerwania' /etc/default/irqbalance 2>/dev/null || true)
  {
    [[ -n $cfg ]] && printf '%s\n' "$cfg"
    echo "# install-router.sh: przerwania nie trafiają na rdzenie VPP"
    echo "IRQBALANCE_BANNED_CPULIST=$ISOL_CSV"
  } | put_file /etc/default/irqbalance "irqbalance: wykluczone rdzenie VPP"
  systemctl restart irqbalance || warn "restart irqbalance nie powiódł się"
  {
    echo "# install-router.sh: taktowanie CPU (stosowane przy każdym starcie przez systemd-tmpfiles)"
    [[ -e /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]] && echo "w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - performance"
    [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]] && echo "w /sys/devices/system/cpu/intel_pstate/no_turbo - - - - 0"
    true
  } | put_file /etc/tmpfiles.d/router-cpu.conf "taktowanie CPU: governor performance, turbo włączone"
  systemd-tmpfiles --create /etc/tmpfiles.d/router-cpu.conf || warn "nie ustawiono governora (sterowanie przez BIOS?)"
  ok "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'BIOS')"
  man_add service irqbalance.service "rozdział przerwań z pominięciem rdzeni VPP"
}

st_netns() {
  put_file /etc/systemd/system/netns-dataplane.service "netns 'dataplane' (linux-cp, BIRD, SNMP)" <<'EOF'
[Unit]
Description=Dataplane network namespace (VPP linux-cp, BIRD, SNMP)
Documentation=file:/opt/router/README.md
After=systemd-sysctl.service network-pre.target
Before=network.target network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
PrivateNetwork=yes
ExecStart=-/usr/sbin/ip netns delete dataplane
ExecStart=-/usr/bin/mkdir -p /etc/netns/dataplane
ExecStart=-/usr/bin/touch /etc/netns/dataplane/resolv.conf
ExecStart=-/usr/sbin/ip netns add dataplane
ExecStart=-/usr/bin/umount /var/run/netns/dataplane
ExecStart=-/usr/bin/mount --bind /proc/self/ns/net /var/run/netns/dataplane
ExecStart=-/usr/sbin/ip netns exec dataplane /usr/lib/systemd/systemd-sysctl
ExecStop=-/usr/sbin/ip netns delete dataplane

[Install]
WantedBy=multi-user.target
WantedBy=network-online.target
EOF
  systemctl daemon-reload
  say "systemctl enable --now netns-dataplane"
  systemctl enable --now netns-dataplane.service
  ip netns list | grep -q dataplane || { echo "netns dataplane nie powstał"; return 1; }
  man_add service netns-dataplane.service "tworzy netns dataplane przy starcie"
  man_add dir /etc/netns/dataplane "pliki specyficzne dla netns (resolv.conf)"
  ok "netns dataplane istnieje"
}

st_vpp_config() {
  local dpdk_devs="" idx=0 p i
  IFNAMES=()
  for p in "${NIC_PCI[@]}"; do
    IFNAMES+=("hu$idx")
    dpdk_devs+="  dev $p { name hu$idx num-rx-queues $VPP_WORKERS num-rx-desc 4096 num-tx-desc 4096 }"$'\n'
    idx=$((idx + 1))
  done
  mkdir -p /var/log/vpp
  put_file /etc/vpp/startup.conf "główna konfiguracja VPP (rdzenie, pamięć, porty DPDK, linux-cp)" <<EOF
# install-router.sh — VPP na R630, karta Mellanox na NUMA $NUMA
unix {
  nodaemon
  log /var/log/vpp/vpp.log
  full-coredump
  cli-listen /run/vpp/cli.sock
  gid vpp
  exec /etc/vpp/bootstrap.vpp
}

api-trace { on }
api-segment { gid vpp }
socksvr { default }

memory {
  main-heap-size $MAIN_HEAP
  main-heap-page-size default-hugepage
}

cpu {
  main-core $MAIN_CORE
  corelist-workers $WORKERS_CSV
}

buffers {
  buffers-per-numa $BUFFERS
  default data-size 2048
  page-size default-hugepage
}

statseg {
  size 1G
  page-size default-hugepage
  per-node-counters off
  update-interval 1
}

dpdk {
${dpdk_devs}}

plugins {
  plugin default { enable }
  plugin linux_cp_plugin.so { enable }
  plugin linux_nl_plugin.so { enable }
  plugin sflow_plugin.so { enable }
}

linux-cp {
  default netns dataplane
  lcp-sync
  lcp-auto-subint
}

linux-nl {
  nl-rx-buffer-size 134217728
}

logging {
  default-log-level info
  default-syslog-log-level notice
}
EOF
  {
    for i in "${IFNAMES[@]}"; do echo "set interface mtu $PORT_MTU $i"; done
    for i in "${IFNAMES[@]}"; do echo "set interface state $i up"; done
    echo "sflow sampling-rate $SFLOW_SAMPLING"
    echo "sflow polling-interval 20"
    echo "sflow header-bytes 128"
    for i in "${IFNAMES[@]}"; do echo "sflow enable-disable $i"; done
  } | put_file /etc/vpp/bootstrap.vpp "polecenia VPP wykonywane po starcie (MTU $PORT_MTU, porty up, sFlow)"
  put_file /etc/systemd/system/vpp.service.d/10-dataplane.conf "VPP startuje po netns dataplane" <<'EOF'
[Unit]
Requires=netns-dataplane.service
After=netns-dataplane.service
EOF
  prog_router_alert | put_file /opt/router/bin/router-alert "alarm do logu, gdy usługa (VPP/BIRD) padnie" 755
  put_file /etc/systemd/system/router-alert@.service "alarm: usługa padła na stałe (limit restartów)" <<'EOF'
[Unit]
Description=Alarm: %i nie wstaje
Documentation=file:/opt/router/README.md

[Service]
Type=oneshot
ExecStart=/opt/router/bin/router-alert %i limit - -
EOF
  put_file /etc/systemd/system/vpp.service.d/20-restart.conf "automatyczny restart VPP po awarii (max 5 razy / 10 min) + alarm" <<'EOF'
[Unit]
StartLimitIntervalSec=600
StartLimitBurst=5
OnFailure=router-alert@%n.service

[Service]
Restart=always
RestartSec=5
ExecStopPost=/opt/router/bin/router-alert %n $SERVICE_RESULT $EXIT_CODE $EXIT_STATUS
EOF
  systemctl daemon-reload
  man_add dir /var/log/vpp "logi VPP (vpp.log)"
  ok "porty VPP: ${IFNAMES[*]} = ${NIC_PCI[*]}"
}

# Źródła wtyczki VPP synack-guard (moduł C): kopiowane do drzewa VPP przed kompilacją (st_vpp_build)
emit_guard_plugin() {   # emit_guard_plugin <katalog>
  local d=$1
  mkdir -p "$d"
  cat >"$d/synack_guard_core.h" <<'GUARD_CORE_H'
/*
 * synack_guard_core.h — logika filtra odbić niezależna od VPP (testowana na hoście: tests/guard_core_test.c).
 *
 * Polityka (tryb zrównoważony): SYN przechodzi; odrzucamy tylko „odpowiedź bez pytania”:
 *   SYN-ACK, opcjonalnie RST oraz UDP ze źródłowych portów amplifikacji, jeśli sieć chroniona nie wysłała wcześniej
 *   pasującego SYN (albo pakietu UDP do takiego portu).
 * Moduł VPP włącza ten plik po zdefiniowaniu GC_ALLOC / GC_FREE (clib_mem_*); na hoście to calloc / free.
 */
#ifndef SYNACK_GUARD_CORE_H
#define SYNACK_GUARD_CORE_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef GC_ALLOC
#define GC_ALLOC(n) calloc (1, (n))
#define GC_FREE(p)  free (p)
#endif

#define GC_TCP_FLAG_FIN 0x01
#define GC_TCP_FLAG_SYN 0x02
#define GC_TCP_FLAG_RST 0x04
#define GC_TCP_FLAG_ACK 0x10

typedef enum
{
  GC_NONE = 0,
  GC_TCP_SYN,    /* SYN, bez ACK i RST */
  GC_TCP_SYNACK, /* SYN + ACK, bez RST */
  GC_TCP_RST,    /* RST (z ACK lub bez), bez SYN */
  GC_UDP,
} gc_class_t;

typedef struct
{
  gc_class_t cls;
  uint8_t is_v6;
  uint8_t frag;  /* niepierwszy fragment: brak nagłówka L4 */
  uint8_t proto; /* numer protokołu L4 (także dla fragmentów) */
  uint8_t flags; /* flagi TCP */
  uint8_t src[16], dst[16]; /* IPv4: pierwsze 4 bajty, kolejność sieciowa */
  uint16_t sport, dport;    /* kolejność hosta */
  uint32_t seq, ack;        /* kolejność hosta */
} gc_pkt_t;

static inline uint16_t
gc_be16 (const uint8_t *p)
{
  return (uint16_t) (p[0] << 8 | p[1]);
}

static inline uint32_t
gc_be32 (const uint8_t *p)
{
  return (uint32_t) p[0] << 24 | (uint32_t) p[1] << 16 | (uint32_t) p[2] << 8 | p[3];
}

static inline uint64_t
gc_be64 (const uint8_t *p)
{
  return (uint64_t) gc_be32 (p) << 32 | gc_be32 (p + 4);
}

/* Klasyfikacja po nagłówkach L3/L4. Nic nie czyta poza `len` bajtów; fragmenty i nagłówki rozszerzeń → GC_NONE. */
static inline gc_class_t
gc_classify_l4 (gc_pkt_t *p, const uint8_t *l4, uint32_t avail)
{
  if (p->proto == 6)
    {
      if (avail < 14)
        return GC_NONE;
      p->sport = gc_be16 (l4);
      p->dport = gc_be16 (l4 + 2);
      p->seq = gc_be32 (l4 + 4);
      p->ack = gc_be32 (l4 + 8);
      p->flags = l4[13];
      uint8_t f = p->flags;
      if ((f & GC_TCP_FLAG_RST) && !(f & GC_TCP_FLAG_SYN))
        return GC_TCP_RST;
      if (f & GC_TCP_FLAG_RST)
        return GC_NONE; /* SYN+RST to śmieć */
      if ((f & GC_TCP_FLAG_SYN) && (f & GC_TCP_FLAG_ACK))
        return GC_TCP_SYNACK;
      if (f & GC_TCP_FLAG_SYN)
        return GC_TCP_SYN;
      return GC_NONE;
    }
  if (p->proto == 17)
    {
      if (avail < 8)
        return GC_NONE;
      p->sport = gc_be16 (l4);
      p->dport = gc_be16 (l4 + 2);
      return GC_UDP;
    }
  return GC_NONE;
}

static inline gc_class_t
gc_classify_v4 (const uint8_t *ip, uint32_t len, gc_pkt_t *p)
{
  memset (p, 0, sizeof *p);
  if (len < 20 || (ip[0] >> 4) != 4)
    return p->cls = GC_NONE;
  uint32_t ihl = (uint32_t) (ip[0] & 0x0f) * 4;
  if (ihl < 20 || len < ihl)
    return p->cls = GC_NONE;
  p->proto = ip[9];
  if (gc_be16 (ip + 6) & 0x1fff) /* offset fragmentu != 0 */
    {
      p->frag = 1;
      return p->cls = GC_NONE;
    }
  memcpy (p->src, ip + 12, 4);
  memcpy (p->dst, ip + 16, 4);
  return p->cls = gc_classify_l4 (p, ip + ihl, len - ihl);
}

static inline gc_class_t
gc_classify_v6 (const uint8_t *ip, uint32_t len, gc_pkt_t *p)
{
  memset (p, 0, sizeof *p);
  p->is_v6 = 1;
  if (len < 40 || (ip[0] >> 4) != 6)
    return p->cls = GC_NONE;
  p->proto = ip[6];
  if (p->proto != 6 && p->proto != 17) /* nagłówki rozszerzeń (także fragmentu) przechodzą bez sprawdzania */
    return p->cls = GC_NONE;
  memcpy (p->src, ip + 8, 16);
  memcpy (p->dst, ip + 24, 16);
  return p->cls = gc_classify_l4 (p, ip + 40, len - 40);
}

/* ------------------------------------------------------------------------------------------- konfiguracja */
typedef struct
{
  uint8_t enforce;        /* 0 = monitor, 1 = enforce */
  uint8_t rst_handshake;  /* RST wymaga wpisu */
  uint8_t check_isn;      /* ack == ISN + 1 */
  uint8_t udp_enabled;    /* filtr UDP z portów amplifikacji */
  uint8_t udp_frags_drop; /* niepierwsze fragmenty UDP do chronionych prefiksów */
  uint32_t ttl, udp_ttl;  /* sekundy */
  uint8_t udp_ports[8192]; /* mapa bitowa portów amplifikacji */
} gc_cfg_t;

static inline void
gc_port_set (gc_cfg_t *c, uint16_t port)
{
  c->udp_ports[port >> 3] |= (uint8_t) (1u << (port & 7));
}

static inline int
gc_port_test (const gc_cfg_t *c, uint16_t port)
{
  return (c->udp_ports[port >> 3] >> (port & 7)) & 1;
}

static inline void
gc_ports_clear (gc_cfg_t *c)
{
  memset (c->udp_ports, 0, sizeof c->udp_ports);
}

static inline void
gc_cfg_init (gc_cfg_t *c)
{
  static const uint16_t def[] = { 19, 53, 111, 123, 137, 161, 389, 1900, 3702, 5353, 11211 };
  memset (c, 0, sizeof *c);
  c->check_isn = 1;
  c->udp_enabled = 1;
  c->ttl = 60;
  c->udp_ttl = 30;
  for (size_t i = 0; i < sizeof def / sizeof def[0]; i++)
    gc_port_set (c, def[i]);
}

/* ------------------------------------------------------------------------------------------- decyzje */
typedef enum
{
  GC_OUT_IGNORE = 0,
  GC_OUT_RECORD_TCP,
  GC_OUT_RECORD_UDP,
} gc_out_t;

/* Pakiet wychodzący z chronionego prefiksu: czy zapisać wpis. */
static inline gc_out_t
gc_out_action (const gc_pkt_t *p, const gc_cfg_t *c)
{
  if (p->cls == GC_TCP_SYN)
    return GC_OUT_RECORD_TCP;
  if (p->cls == GC_UDP && c->udp_enabled && gc_port_test (c, p->dport))
    return GC_OUT_RECORD_UDP;
  return GC_OUT_IGNORE;
}

typedef enum
{
  GC_V_IGNORE = 0, /* pakiet nie podlega sprawdzaniu */
  GC_V_PASS,       /* sprawdzony, jest wpis */
  GC_V_NO_FLOW,    /* brak wpisu albo wpis przeterminowany */
  GC_V_BAD_ISN,    /* wpis jest, ale numer potwierdzenia się nie zgadza */
  GC_V_FRAG_DROP,  /* niepierwszy fragment UDP przy udp-frags drop */
} gc_verdict_t;

/* Pakiet przychodzący do chronionego prefiksu: czy trzeba szukać wpisu w tablicy. */
static inline int
gc_in_need_lookup (const gc_pkt_t *p, const gc_cfg_t *c)
{
  switch (p->cls)
    {
    case GC_TCP_SYNACK:
      return 1;
    case GC_TCP_RST:
      return c->rst_handshake;
    case GC_UDP:
      return c->udp_enabled && gc_port_test (c, p->sport);
    default:
      return 0;
    }
}

static inline uint64_t
gc_val_pack (uint32_t isn, uint32_t ts)
{
  return (uint64_t) isn << 32 | ts;
}

static inline uint32_t
gc_val_isn (uint64_t v)
{
  return (uint32_t) (v >> 32);
}

static inline uint32_t
gc_val_ts (uint64_t v)
{
  return (uint32_t) v;
}

static inline gc_verdict_t
gc_in_verdict (const gc_pkt_t *p, const gc_cfg_t *c, int found, uint64_t val, uint32_t now)
{
  if (p->frag && p->proto == 17 && c->udp_enabled && c->udp_frags_drop)
    return GC_V_FRAG_DROP;
  if (!gc_in_need_lookup (p, c))
    return GC_V_IGNORE;
  if (!found)
    return GC_V_NO_FLOW;
  uint32_t ts = gc_val_ts (val);
  uint32_t age = now >= ts ? now - ts : 0;
  if (age > (p->cls == GC_UDP ? c->udp_ttl : c->ttl))
    return GC_V_NO_FLOW;
  if (p->cls != GC_UDP && c->check_isn && (p->flags & GC_TCP_FLAG_ACK) && p->ack != gc_val_isn (val) + 1)
    return GC_V_BAD_ISN;
  return GC_V_PASS;
}

static inline int
gc_should_drop (const gc_cfg_t *c, gc_verdict_t v)
{
  return c->enforce && (v == GC_V_NO_FLOW || v == GC_V_BAD_ISN || v == GC_V_FRAG_DROP);
}

/* ------------------------------------------------------------------------------------------- klucze tablicy stanów */
typedef struct
{
  uint64_t k[2];
} gc_key4_t; /* klient, serwer, port klienta, port serwera, protokół */

typedef struct
{
  uint64_t k[6];
} gc_key6_t;

static inline uint64_t
gc_key_ports (uint16_t cport, uint16_t sport, uint8_t proto)
{
  return (uint64_t) cport | (uint64_t) sport << 16 | (uint64_t) proto << 32;
}

/* pakiet wychodzący od klienta (SYN albo UDP do portu amplifikacji) */
static inline void
gc_key4_out (gc_key4_t *k, const gc_pkt_t *p)
{
  k->k[0] = (uint64_t) gc_be32 (p->src) | (uint64_t) gc_be32 (p->dst) << 32;
  k->k[1] = gc_key_ports (p->sport, p->dport, p->proto);
}

/* pakiet przychodzący do klienta (odpowiedź serwera) */
static inline void
gc_key4_in (gc_key4_t *k, const gc_pkt_t *p)
{
  k->k[0] = (uint64_t) gc_be32 (p->dst) | (uint64_t) gc_be32 (p->src) << 32;
  k->k[1] = gc_key_ports (p->dport, p->sport, p->proto);
}

static inline void
gc_key6_out (gc_key6_t *k, const gc_pkt_t *p)
{
  memset (k, 0, sizeof *k);
  memcpy (&k->k[0], p->src, 16);
  memcpy (&k->k[2], p->dst, 16);
  k->k[4] = gc_key_ports (p->sport, p->dport, p->proto);
}

static inline void
gc_key6_in (gc_key6_t *k, const gc_pkt_t *p)
{
  memset (k, 0, sizeof *k);
  memcpy (&k->k[0], p->dst, 16);
  memcpy (&k->k[2], p->src, 16);
  k->k[4] = gc_key_ports (p->dport, p->sport, p->proto);
}

/* ------------------------------------------------------------------------------------------- zbiory prefiksów */
#define GC_MAX_LENS 8

typedef struct
{
  uint32_t nlens;
  uint8_t lens[GC_MAX_LENS]; /* malejąco */
  uint32_t cap[GC_MAX_LENS]; /* potęgi dwójki */
  uint64_t *tab[GC_MAX_LENS]; /* (1<<32) | zamaskowany adres; 0 = puste */
} gc_pset4_t;

static inline uint32_t
gc_mask4 (uint8_t len)
{
  return len == 0 ? 0 : ~0u << (32 - len);
}

static inline uint32_t
gc_pow2_at_least (uint32_t n)
{
  uint32_t c = 8;
  while (c < n)
    c <<= 1;
  return c;
}

static inline uint32_t
gc_hash4 (uint32_t key)
{
  return (key * 2654435761u) >> 7;
}

static inline void
gc_pset4_free (gc_pset4_t *s)
{
  for (uint32_t i = 0; i < s->nlens; i++)
    if (s->tab[i])
      GC_FREE (s->tab[i]);
  memset (s, 0, sizeof *s);
}

/* addr: kolejność hosta. Zwraca 0, -1 (więcej niż GC_MAX_LENS różnych długości) albo -2 (brak pamięci). */
static inline int
gc_pset4_build (gc_pset4_t *s, const uint32_t *addr, const uint8_t *len, size_t n)
{
  memset (s, 0, sizeof *s);
  for (size_t i = 0; i < n; i++)
    {
      uint32_t j;
      for (j = 0; j < s->nlens; j++)
        if (s->lens[j] == len[i])
          break;
      if (j == s->nlens)
        {
          if (s->nlens == GC_MAX_LENS)
            return -1;
          s->lens[s->nlens++] = len[i];
        }
    }
  for (uint32_t a = 0; a < s->nlens; a++) /* sortowanie malejące (kilka elementów) */
    for (uint32_t b = a + 1; b < s->nlens; b++)
      if (s->lens[b] > s->lens[a])
        {
          uint8_t t = s->lens[a];
          s->lens[a] = s->lens[b];
          s->lens[b] = t;
        }
  for (uint32_t j = 0; j < s->nlens; j++)
    {
      uint32_t cnt = 0;
      for (size_t i = 0; i < n; i++)
        cnt += len[i] == s->lens[j];
      s->cap[j] = gc_pow2_at_least (cnt * 2);
      s->tab[j] = (uint64_t *) GC_ALLOC (s->cap[j] * sizeof (uint64_t));
      if (!s->tab[j])
        {
          gc_pset4_free (s);
          return -2;
        }
      for (size_t i = 0; i < n; i++)
        {
          if (len[i] != s->lens[j])
            continue;
          uint32_t key = addr[i] & gc_mask4 (len[i]);
          uint32_t h = gc_hash4 (key) & (s->cap[j] - 1);
          while (s->tab[j][h] && s->tab[j][h] != ((1ull << 32) | key))
            h = (h + 1) & (s->cap[j] - 1);
          s->tab[j][h] = (1ull << 32) | key;
        }
    }
  return 0;
}

static inline int
gc_pset4_lookup (const gc_pset4_t *s, uint32_t addr)
{
  for (uint32_t j = 0; j < s->nlens; j++)
    {
      uint32_t key = addr & gc_mask4 (s->lens[j]);
      uint32_t h = gc_hash4 (key) & (s->cap[j] - 1);
      while (s->tab[j][h])
        {
          if (s->tab[j][h] == ((1ull << 32) | key))
            return 1;
          h = (h + 1) & (s->cap[j] - 1);
        }
    }
  return 0;
}

typedef struct
{
  uint64_t hi, lo;
  uint64_t used;
} gc_e6_t;

typedef struct
{
  uint32_t nlens;
  uint8_t lens[GC_MAX_LENS];
  uint32_t cap[GC_MAX_LENS];
  gc_e6_t *tab[GC_MAX_LENS];
} gc_pset6_t;

static inline void
gc_mask6 (uint8_t len, uint64_t *mh, uint64_t *ml)
{
  if (len >= 128)
    *mh = *ml = ~0ull;
  else if (len >= 64)
    {
      *mh = ~0ull;
      *ml = len == 64 ? 0 : ~0ull << (128 - len);
    }
  else
    {
      *mh = len == 0 ? 0 : ~0ull << (64 - len);
      *ml = 0;
    }
}

static inline uint32_t
gc_hash6 (uint64_t hi, uint64_t lo)
{
  return (uint32_t) ((hi * 0x9E3779B97F4A7C15ull ^ lo * 0xC2B2AE3D27D4EB4Full) >> 32);
}

static inline void
gc_pset6_free (gc_pset6_t *s)
{
  for (uint32_t i = 0; i < s->nlens; i++)
    if (s->tab[i])
      GC_FREE (s->tab[i]);
  memset (s, 0, sizeof *s);
}

static inline int
gc_pset6_build (gc_pset6_t *s, const uint64_t *hi, const uint64_t *lo, const uint8_t *len, size_t n)
{
  memset (s, 0, sizeof *s);
  for (size_t i = 0; i < n; i++)
    {
      uint32_t j;
      for (j = 0; j < s->nlens; j++)
        if (s->lens[j] == len[i])
          break;
      if (j == s->nlens)
        {
          if (s->nlens == GC_MAX_LENS)
            return -1;
          s->lens[s->nlens++] = len[i];
        }
    }
  for (uint32_t a = 0; a < s->nlens; a++)
    for (uint32_t b = a + 1; b < s->nlens; b++)
      if (s->lens[b] > s->lens[a])
        {
          uint8_t t = s->lens[a];
          s->lens[a] = s->lens[b];
          s->lens[b] = t;
        }
  for (uint32_t j = 0; j < s->nlens; j++)
    {
      uint32_t cnt = 0;
      for (size_t i = 0; i < n; i++)
        cnt += len[i] == s->lens[j];
      s->cap[j] = gc_pow2_at_least (cnt * 2);
      s->tab[j] = (gc_e6_t *) GC_ALLOC (s->cap[j] * sizeof (gc_e6_t));
      if (!s->tab[j])
        {
          gc_pset6_free (s);
          return -2;
        }
      uint64_t mh, ml;
      gc_mask6 (s->lens[j], &mh, &ml);
      for (size_t i = 0; i < n; i++)
        {
          if (len[i] != s->lens[j])
            continue;
          uint64_t kh = hi[i] & mh, kl = lo[i] & ml;
          uint32_t h = gc_hash6 (kh, kl) & (s->cap[j] - 1);
          while (s->tab[j][h].used && !(s->tab[j][h].hi == kh && s->tab[j][h].lo == kl))
            h = (h + 1) & (s->cap[j] - 1);
          s->tab[j][h].hi = kh;
          s->tab[j][h].lo = kl;
          s->tab[j][h].used = 1;
        }
    }
  return 0;
}

static inline int
gc_pset6_lookup (const gc_pset6_t *s, uint64_t hi, uint64_t lo)
{
  for (uint32_t j = 0; j < s->nlens; j++)
    {
      uint64_t mh, ml;
      gc_mask6 (s->lens[j], &mh, &ml);
      uint64_t kh = hi & mh, kl = lo & ml;
      uint32_t h = gc_hash6 (kh, kl) & (s->cap[j] - 1);
      while (s->tab[j][h].used)
        {
          if (s->tab[j][h].hi == kh && s->tab[j][h].lo == kl)
            return 1;
          h = (h + 1) & (s->cap[j] - 1);
        }
    }
  return 0;
}

#endif /* SYNACK_GUARD_CORE_H */
GUARD_CORE_H
  cat >"$d/synack_guard.c" <<'GUARD_PLUGIN_C'
/*
 * synack_guard.c — wtyczka VPP: filtr odbić (SYN-ACK, RST, UDP z portów amplifikacji) dla chronionych prefiksów.
 *
 * Węzły na łuku ip4-unicast / ip6-unicast, włączane tylko na wskazanych interfejsach:
 *   synack-guard-out-ip{4,6}  (strona klientów): zapisuje SYN i UDP do portów amplifikacji do wspólnej tablicy stanów,
 *   synack-guard-in-ip{4,6}   (uplinki): sprawdza SYN-ACK / RST / UDP z portów amplifikacji względem tablicy.
 * Logika decyzji jest w synack_guard_core.h (testowana na hoście). Sterowanie: vppctl (patrz "synack-guard ...").
 *
 * UWAGA: ten plik nie był kompilowany na maszynie deweloperskiej (brak VPP). Wymaga weryfikacji na buildzie
 * VPP 26.06 (patrz docs/synack-guard-lab-checklist.md); miejsca zależne od wersji API są oznaczone "WERSJA:".
 */
#include <vlib/vlib.h>
#include <vnet/vnet.h>
#include <vnet/feature/feature.h>
#include <vnet/ip/ip.h>
#include <vnet/plugin/plugin.h>
#include <vpp/app/version.h>

#include <vppinfra/bihash_16_8.h>
#include <vppinfra/bihash_template.h>
#include <vppinfra/bihash_template.c>
#include <vppinfra/bihash_48_8.h>
#include <vppinfra/bihash_template.h>
#include <vppinfra/bihash_template.c>

static inline void *
sg_zalloc (uword n)
{
  void *p = clib_mem_alloc (n);
  if (p)
    clib_memset (p, 0, n);
  return p;
}

#define GC_ALLOC(n) sg_zalloc ((n))
#define GC_FREE(p)  clib_mem_free ((p))
#include "synack_guard_core.h"

/* WERSJA: w razie zmiany nazwy w VPP 26.06 popraw tylko to makro. */
#define SG_FEATURE_NEXT(nextp, b) vnet_feature_next_u16 ((nextp), (b))

typedef enum
{
  SG_MODE_OFF = 0,
  SG_MODE_MONITOR = 1,
  SG_MODE_ENFORCE = 2,
} sg_mode_t;

typedef struct
{
  u32 sw_if_index;
  u8 is_out;
} sg_if_t;

typedef struct
{
  ip46_address_t addr;
  u8 len;
  u8 is_v6;
} sg_prefix_t;

typedef struct
{
  sg_mode_t mode;
  gc_cfg_t cfg;
  u8 tables_ready;
  u32 table_v4, table_v6; /* docelowa liczba wpisów */
  clib_bihash_16_8_t flows4;
  clib_bihash_48_8_t flows6;
  gc_pset4_t *pset4; /* wskaźniki podmieniane w barierze */
  gc_pset6_t *pset6;
  sg_if_t *ifs;
  sg_prefix_t *prefixes;
  vlib_main_t *vlib_main;
  vnet_main_t *vnet_main;
} sg_main_t;

static sg_main_t sg_main;

#define foreach_sg_error                                                                                      \
  _ (SYN_RECORDED, "SYN recorded")                                                                            \
  _ (UDP_RECORDED, "UDP recorded")                                                                            \
  _ (CHECKED, "Checked")                                                                                      \
  _ (PASSED, "Passed")                                                                                        \
  _ (VIOL_NO_FLOW, "Violation no flow")                                                                       \
  _ (VIOL_BAD_ISN, "Violation bad isn")                                                                       \
  _ (VIOL_UDP_FRAG, "Violation udp fragment")                                                                 \
  _ (DROPPED, "Dropped")                                                                                      \
  _ (INSERT_FAILED, "Insert failed")

typedef enum
{
#define _(sym, str) SG_ERROR_##sym,
  foreach_sg_error
#undef _
    SG_N_ERROR,
} sg_error_t;

static char *sg_error_strings[] = {
#define _(sym, str) str,
  foreach_sg_error
#undef _
};

typedef enum
{
  SG_NEXT_DROP,
  SG_N_NEXT,
} sg_next_t;

/* ------------------------------------------------------------------------------------------- tablice stanów */
static int
sg_is_stale4 (clib_bihash_kv_16_8_t *kv, void *arg)
{
  u32 now = *(u32 *) arg;
  u32 ts = gc_val_ts (kv->value);
  u8 proto = (kv->key[1] >> 32) & 0xff;
  u32 ttl = proto == 17 ? sg_main.cfg.udp_ttl : sg_main.cfg.ttl;
  return now >= ts && now - ts > ttl;
}

static int
sg_is_stale6 (clib_bihash_kv_48_8_t *kv, void *arg)
{
  u32 now = *(u32 *) arg;
  u32 ts = gc_val_ts (kv->value);
  u8 proto = (kv->key[4] >> 32) & 0xff;
  u32 ttl = proto == 17 ? sg_main.cfg.udp_ttl : sg_main.cfg.ttl;
  return now >= ts && now - ts > ttl;
}

static void
sg_tables_init (sg_main_t *sm)
{
  if (sm->tables_ready)
    return;
  /* ok. 4 wpisy na stronę koszyka; pamięć z zapasem 1.5x */
  clib_bihash_init_16_8 (&sm->flows4, "synack-guard-v4", clib_max (sm->table_v4 / 4, 1024),
                         (uword) sm->table_v4 * sizeof (clib_bihash_kv_16_8_t) * 3 / 2);
  clib_bihash_init_48_8 (&sm->flows6, "synack-guard-v6", clib_max (sm->table_v6 / 4, 1024),
                         (uword) sm->table_v6 * sizeof (clib_bihash_kv_48_8_t) * 3 / 2);
  sm->tables_ready = 1;
}

static void
sg_tables_free (sg_main_t *sm)
{
  if (!sm->tables_ready)
    return;
  clib_bihash_free_16_8 (&sm->flows4);
  clib_bihash_free_48_8 (&sm->flows6);
  sm->tables_ready = 0;
}

/* ------------------------------------------------------------------------------------------- prefiksy */
static void
sg_rebuild_prefixes (vlib_main_t *vm)
{
  sg_main_t *sm = &sg_main;
  u32 n4 = 0, n6 = 0;
  sg_prefix_t *p;
  vec_foreach (p, sm->prefixes) p->is_v6 ? n6++ : n4++;
  uint32_t *a4 = n4 ? clib_mem_alloc (n4 * sizeof (uint32_t)) : 0;
  uint8_t *l4 = n4 ? clib_mem_alloc (n4) : 0;
  uint64_t *h6 = n6 ? clib_mem_alloc (n6 * sizeof (uint64_t)) : 0;
  uint64_t *l6 = n6 ? clib_mem_alloc (n6 * sizeof (uint64_t)) : 0;
  uint8_t *ln6 = n6 ? clib_mem_alloc (n6) : 0;
  u32 i4 = 0, i6 = 0;
  vec_foreach (p, sm->prefixes)
    {
      if (p->is_v6)
        {
          h6[i6] = clib_net_to_host_u64 (p->addr.ip6.as_u64[0]);
          l6[i6] = clib_net_to_host_u64 (p->addr.ip6.as_u64[1]);
          ln6[i6++] = p->len;
        }
      else
        {
          a4[i4] = clib_net_to_host_u32 (p->addr.ip4.as_u32);
          l4[i4++] = p->len;
        }
    }
  gc_pset4_t *new4 = sg_zalloc (sizeof (*new4));
  gc_pset6_t *new6 = sg_zalloc (sizeof (*new6));
  if (gc_pset4_build (new4, a4, l4, n4) || gc_pset6_build (new6, h6, l6, ln6, n6))
    {
      clib_warning ("synack-guard: nie udało się zbudować zbiorów prefiksów (za dużo różnych długości?)");
      gc_pset4_free (new4);
      gc_pset6_free (new6);
      clib_mem_free (new4);
      clib_mem_free (new6);
      goto done;
    }
  vlib_worker_thread_barrier_sync (vm);
  gc_pset4_t *old4 = sm->pset4;
  gc_pset6_t *old6 = sm->pset6;
  sm->pset4 = new4;
  sm->pset6 = new6;
  vlib_worker_thread_barrier_release (vm);
  if (old4)
    {
      gc_pset4_free (old4);
      clib_mem_free (old4);
    }
  if (old6)
    {
      gc_pset6_free (old6);
      clib_mem_free (old6);
    }
done:
  if (a4)
    clib_mem_free (a4);
  if (l4)
    clib_mem_free (l4);
  if (h6)
    clib_mem_free (h6);
  if (l6)
    clib_mem_free (l6);
  if (ln6)
    clib_mem_free (ln6);
}

/* ------------------------------------------------------------------------------------------- węzły */
always_inline uword
sg_node_inline (vlib_main_t *vm, vlib_node_runtime_t *node, vlib_frame_t *frame, int is_out, int is_ip6)
{
  sg_main_t *sm = &sg_main;
  u32 *from = vlib_frame_vector_args (frame);
  u32 n_left = frame->n_vectors;
  vlib_buffer_t *bufs[VLIB_FRAME_SIZE], **b = bufs;
  u16 nexts[VLIB_FRAME_SIZE];
  gc_pkt_t pk[VLIB_FRAME_SIZE];
  u8 need[VLIB_FRAME_SIZE];
  u64 hashes[VLIB_FRAME_SIZE];
  gc_key4_t keys4[VLIB_FRAME_SIZE];
  gc_key6_t keys6[VLIB_FRAME_SIZE];
  u32 n = n_left, i;
  u32 c_syn = 0, c_udp = 0, c_checked = 0, c_pass = 0, c_nf = 0, c_isn = 0, c_frag = 0, c_drop = 0, c_fail = 0;

  vlib_get_buffers (vm, from, bufs, n);

  if (PREDICT_FALSE (sm->mode == SG_MODE_OFF || !sm->tables_ready))
    {
      for (i = 0; i < n; i++)
        SG_FEATURE_NEXT (&nexts[i], bufs[i]);
      vlib_buffer_enqueue_to_next (vm, node, from, nexts, n);
      return n;
    }

  u32 now = (u32) vlib_time_now (vm);
  gc_pset4_t *ps4 = sm->pset4;
  gc_pset6_t *ps6 = sm->pset6;
  const gc_cfg_t *cfg = &sm->cfg;

  /* przejście 1: klasyfikacja, test prefiksu, (out) zapis wpisu, (in) policzenie skrótu i prefetch koszyka */
  for (i = 0; i < n; i++)
    {
      if (i + 4 < n)
        {
          vlib_prefetch_buffer_header (b[4], LOAD);
          CLIB_PREFETCH (vlib_buffer_get_current (b[4]), 64, LOAD);
        }
      vlib_buffer_t *b0 = b[0];
      b++;
      const u8 *ip = vlib_buffer_get_current (b0);
      gc_pkt_t *p = &pk[i];
      need[i] = 0;
      SG_FEATURE_NEXT (&nexts[i], b0);
      if (is_ip6)
        gc_classify_v6 (ip, b0->current_length, p);
      else
        gc_classify_v4 (ip, b0->current_length, p);

      if (is_out)
        {
          gc_out_t act = gc_out_action (p, cfg);
          if (act == GC_OUT_IGNORE)
            continue;
          int hit = is_ip6 ? (ps6 && gc_pset6_lookup (ps6, gc_be64 (p->src), gc_be64 (p->src + 8))) :
                             (ps4 && gc_pset4_lookup (ps4, gc_be32 (p->src)));
          if (!hit)
            continue;
          u64 val = gc_val_pack (act == GC_OUT_RECORD_TCP ? p->seq : 0, now);
          int rv;
          if (is_ip6)
            {
              clib_bihash_kv_48_8_t kv;
              gc_key6_t k;
              gc_key6_out (&k, p);
              clib_memcpy_fast (kv.key, k.k, sizeof kv.key);
              kv.value = val;
              rv = clib_bihash_add_or_overwrite_stale_48_8 (&sm->flows6, &kv, sg_is_stale6, &now);
            }
          else
            {
              clib_bihash_kv_16_8_t kv;
              gc_key4_t k;
              gc_key4_out (&k, p);
              kv.key[0] = k.k[0];
              kv.key[1] = k.k[1];
              kv.value = val;
              rv = clib_bihash_add_or_overwrite_stale_16_8 (&sm->flows4, &kv, sg_is_stale4, &now);
            }
          if (rv)
            c_fail++;
          else if (act == GC_OUT_RECORD_TCP)
            c_syn++;
          else
            c_udp++;
          continue;
        }

      /* kierunek przychodzący (uplinki) */
      int frag_udp = p->frag && p->proto == 17 && cfg->udp_enabled && cfg->udp_frags_drop;
      if (!frag_udp && !gc_in_need_lookup (p, cfg))
        continue;
      int hit = is_ip6 ? (ps6 && gc_pset6_lookup (ps6, gc_be64 (p->dst), gc_be64 (p->dst + 8))) :
                         (ps4 && gc_pset4_lookup (ps4, gc_be32 (p->dst)));
      if (!hit)
        continue;
      need[i] = 1;
      if (frag_udp)
        {
          need[i] = 2; /* decyzja bez tablicy */
          continue;
        }
      if (is_ip6)
        {
          gc_key6_in (&keys6[i], p);
          clib_bihash_kv_48_8_t kv;
          clib_memcpy_fast (kv.key, keys6[i].k, sizeof kv.key);
          hashes[i] = clib_bihash_hash_48_8 (&kv);
          clib_bihash_prefetch_bucket_48_8 (&sm->flows6, hashes[i]);
        }
      else
        {
          gc_key4_in (&keys4[i], p);
          clib_bihash_kv_16_8_t kv;
          kv.key[0] = keys4[i].k[0];
          kv.key[1] = keys4[i].k[1];
          hashes[i] = clib_bihash_hash_16_8 (&kv);
          clib_bihash_prefetch_bucket_16_8 (&sm->flows4, hashes[i]);
        }
    }

  /* przejście 2 (tylko uplinki): wyszukanie wpisów i werdykt */
  if (!is_out)
    {
      for (i = 0; i < n; i++)
        {
          if (!need[i])
            continue;
          gc_verdict_t v;
          if (need[i] == 2)
            v = GC_V_FRAG_DROP;
          else
            {
              int found;
              u64 val = 0;
              if (is_ip6)
                {
                  clib_bihash_kv_48_8_t kv, res;
                  clib_memcpy_fast (kv.key, keys6[i].k, sizeof kv.key);
                  found = clib_bihash_search_inline_2_with_hash_48_8 (&sm->flows6, hashes[i], &kv, &res) == 0;
                  val = found ? res.value : 0;
                }
              else
                {
                  clib_bihash_kv_16_8_t kv, res;
                  kv.key[0] = keys4[i].k[0];
                  kv.key[1] = keys4[i].k[1];
                  found = clib_bihash_search_inline_2_with_hash_16_8 (&sm->flows4, hashes[i], &kv, &res) == 0;
                  val = found ? res.value : 0;
                }
              v = gc_in_verdict (&pk[i], cfg, found, val, now);
            }
          c_checked++;
          switch (v)
            {
            case GC_V_PASS:
              c_pass++;
              break;
            case GC_V_NO_FLOW:
              c_nf++;
              break;
            case GC_V_BAD_ISN:
              c_isn++;
              break;
            case GC_V_FRAG_DROP:
              c_frag++;
              break;
            default:
              break;
            }
          if (gc_should_drop (cfg, v))
            {
              nexts[i] = SG_NEXT_DROP;
              bufs[i]->error = node->errors[SG_ERROR_DROPPED];
              c_drop++;
            }
        }
    }

  vlib_buffer_enqueue_to_next (vm, node, from, nexts, n);

#define _inc(sym, cnt)                                                                                        \
  if (cnt)                                                                                                    \
    vlib_node_increment_counter (vm, node->node_index, SG_ERROR_##sym, cnt);
  _inc (SYN_RECORDED, c_syn) _inc (UDP_RECORDED, c_udp) _inc (CHECKED, c_checked) _inc (PASSED, c_pass)
  _inc (VIOL_NO_FLOW, c_nf) _inc (VIOL_BAD_ISN, c_isn) _inc (VIOL_UDP_FRAG, c_frag) _inc (DROPPED, c_drop)
  _inc (INSERT_FAILED, c_fail)
#undef _inc
  return n;
}

VLIB_NODE_FN (sg_in_ip4_node) (vlib_main_t *vm, vlib_node_runtime_t *node, vlib_frame_t *frame)
{
  return sg_node_inline (vm, node, frame, 0, 0);
}

VLIB_NODE_FN (sg_out_ip4_node) (vlib_main_t *vm, vlib_node_runtime_t *node, vlib_frame_t *frame)
{
  return sg_node_inline (vm, node, frame, 1, 0);
}

VLIB_NODE_FN (sg_in_ip6_node) (vlib_main_t *vm, vlib_node_runtime_t *node, vlib_frame_t *frame)
{
  return sg_node_inline (vm, node, frame, 0, 1);
}

VLIB_NODE_FN (sg_out_ip6_node) (vlib_main_t *vm, vlib_node_runtime_t *node, vlib_frame_t *frame)
{
  return sg_node_inline (vm, node, frame, 1, 1);
}

#define SG_REGISTER_NODE(sym, nm)                                                                             \
  VLIB_REGISTER_NODE (sym) = {                                                                                \
    .name = nm,                                                                                               \
    .vector_size = sizeof (u32),                                                                              \
    .type = VLIB_NODE_TYPE_INTERNAL,                                                                          \
    .n_errors = SG_N_ERROR,                                                                                   \
    .error_strings = sg_error_strings,                                                                        \
    .n_next_nodes = SG_N_NEXT,                                                                                \
    .next_nodes = { [SG_NEXT_DROP] = "error-drop" },                                                          \
  }

SG_REGISTER_NODE (sg_in_ip4_node, "synack-guard-in-ip4");
SG_REGISTER_NODE (sg_out_ip4_node, "synack-guard-out-ip4");
SG_REGISTER_NODE (sg_in_ip6_node, "synack-guard-in-ip6");
SG_REGISTER_NODE (sg_out_ip6_node, "synack-guard-out-ip6");

VNET_FEATURE_INIT (sg_in_ip4_feat, static) = {
  .arc_name = "ip4-unicast",
  .node_name = "synack-guard-in-ip4",
  .runs_before = VNET_FEATURES ("ip4-lookup"),
};
VNET_FEATURE_INIT (sg_out_ip4_feat, static) = {
  .arc_name = "ip4-unicast",
  .node_name = "synack-guard-out-ip4",
  .runs_before = VNET_FEATURES ("ip4-lookup"),
};
VNET_FEATURE_INIT (sg_in_ip6_feat, static) = {
  .arc_name = "ip6-unicast",
  .node_name = "synack-guard-in-ip6",
  .runs_before = VNET_FEATURES ("ip6-lookup"),
};
VNET_FEATURE_INIT (sg_out_ip6_feat, static) = {
  .arc_name = "ip6-unicast",
  .node_name = "synack-guard-out-ip6",
  .runs_before = VNET_FEATURES ("ip6-lookup"),
};

/* ------------------------------------------------------------------------------------------- CLI */
static int
sg_set_interface (vlib_main_t *vm, u32 sw_if_index, int is_out, int enable)
{
  sg_main_t *sm = &sg_main;
  sg_if_t *e;
  /* zdejmij poprzednie przypięcie (także w drugą stronę), żeby jeden interfejs miał jedną rolę */
  vec_foreach (e, sm->ifs)
    {
      if (e->sw_if_index != sw_if_index)
        continue;
      vnet_feature_enable_disable ("ip4-unicast", e->is_out ? "synack-guard-out-ip4" : "synack-guard-in-ip4",
                                   sw_if_index, 0, 0, 0);
      vnet_feature_enable_disable ("ip6-unicast", e->is_out ? "synack-guard-out-ip6" : "synack-guard-in-ip6",
                                   sw_if_index, 0, 0, 0);
      vec_del1 (sm->ifs, e - sm->ifs);
      break;
    }
  if (!enable)
    return 0;
  vnet_feature_enable_disable ("ip4-unicast", is_out ? "synack-guard-out-ip4" : "synack-guard-in-ip4", sw_if_index, 1,
                               0, 0);
  vnet_feature_enable_disable ("ip6-unicast", is_out ? "synack-guard-out-ip6" : "synack-guard-in-ip6", sw_if_index, 1,
                               0, 0);
  sg_if_t ne = { .sw_if_index = sw_if_index, .is_out = is_out };
  vec_add1 (sm->ifs, ne);
  return 0;
}

static clib_error_t *
sg_interface_command_fn (vlib_main_t *vm, unformat_input_t *input, vlib_cli_command_t *cmd)
{
  sg_main_t *sm = &sg_main;
  u32 sw_if_index = ~0;
  int is_out = -1, disable = 0;
  while (unformat_check_input (input) != UNFORMAT_END_OF_INPUT)
    {
      if (unformat (input, "%U", unformat_vnet_sw_interface, sm->vnet_main, &sw_if_index))
        ;
      else if (unformat (input, "in"))
        is_out = 0;
      else if (unformat (input, "out"))
        is_out = 1;
      else if (unformat (input, "disable"))
        disable = 1;
      else
        return clib_error_return (0, "unknown input `%U'", format_unformat_error, input);
    }
  if (sw_if_index == ~0 || is_out < 0)
    return clib_error_return (0, "usage: synack-guard interface <if> in|out [disable]");
  sg_set_interface (vm, sw_if_index, is_out, !disable);
  return 0;
}

static clib_error_t *
sg_prefix_command_fn (vlib_main_t *vm, unformat_input_t *input, vlib_cli_command_t *cmd)
{
  sg_main_t *sm = &sg_main;
  ip46_address_t addr;
  u32 len = ~0;
  int del = 0, have = 0;
  while (unformat_check_input (input) != UNFORMAT_END_OF_INPUT)
    {
      if (unformat (input, "%U/%d", unformat_ip46_address, &addr, IP46_TYPE_ANY, &len))
        have = 1;
      else if (unformat (input, "del"))
        del = 1;
      else
        return clib_error_return (0, "unknown input `%U'", format_unformat_error, input);
    }
  if (!have)
    return clib_error_return (0, "usage: synack-guard prefix <addr>/<len> [del]");
  int is_v6 = !ip46_address_is_ip4 (&addr);
  if (len > (is_v6 ? 128 : 32))
    return clib_error_return (0, "invalid prefix length");
  /* adres zamaskowany do długości, żeby porównania były jednoznaczne */
  if (is_v6)
    {
      ip6_address_t mask;
      ip6_preflen_to_mask (len, &mask);
      ip6_address_mask (&addr.ip6, &mask);
    }
  else
    {
      ip4_address_t mask;
      ip4_preflen_to_mask (len, &mask);
      addr.ip4.as_u32 &= mask.as_u32;
    }
  sg_prefix_t *p;
  int idx = -1;
  vec_foreach (p, sm->prefixes)
    {
      if (p->is_v6 == is_v6 && p->len == len && !memcmp (&p->addr, &addr, sizeof addr))
        idx = p - sm->prefixes;
    }
  if (del)
    {
      if (idx < 0)
        return clib_error_return (0, "prefix not found");
      vec_del1 (sm->prefixes, idx);
    }
  else if (idx < 0)
    {
      sg_prefix_t np = { .addr = addr, .len = len, .is_v6 = is_v6 };
      vec_add1 (sm->prefixes, np);
    }
  sg_rebuild_prefixes (vm);
  return 0;
}

static clib_error_t *
sg_mode_command_fn (vlib_main_t *vm, unformat_input_t *input, vlib_cli_command_t *cmd)
{
  sg_main_t *sm = &sg_main;
  sg_mode_t mode;
  if (unformat (input, "off"))
    mode = SG_MODE_OFF;
  else if (unformat (input, "monitor"))
    mode = SG_MODE_MONITOR;
  else if (unformat (input, "enforce"))
    mode = SG_MODE_ENFORCE;
  else
    return clib_error_return (0, "usage: synack-guard mode off|monitor|enforce");
  if (mode != SG_MODE_OFF)
    sg_tables_init (sm);
  vlib_worker_thread_barrier_sync (vm);
  sm->mode = mode;
  sm->cfg.enforce = mode == SG_MODE_ENFORCE;
  vlib_worker_thread_barrier_release (vm);
  return 0;
}

static clib_error_t *
sg_config_command_fn (vlib_main_t *vm, unformat_input_t *input, vlib_cli_command_t *cmd)
{
  sg_main_t *sm = &sg_main;
  gc_cfg_t nc = sm->cfg;
  u32 v4 = sm->table_v4, v6 = sm->table_v6, x;
  int tables_changed = 0;
  u8 *word = 0;
  while (unformat_check_input (input) != UNFORMAT_END_OF_INPUT)
    {
      if (unformat (input, "ttl %u", &x))
        nc.ttl = x;
      else if (unformat (input, "udp-ttl %u", &x))
        nc.udp_ttl = x;
      else if (unformat (input, "check-isn %s", &word))
        nc.check_isn = !strcmp ((char *) word, "on");
      else if (unformat (input, "tcp-rst %s", &word))
        nc.rst_handshake = !strcmp ((char *) word, "handshake");
      else if (unformat (input, "udp-frags %s", &word))
        nc.udp_frags_drop = !strcmp ((char *) word, "drop");
      else if (unformat (input, "udp-ports"))
        {
          gc_ports_clear (&nc);
          while (unformat (input, "%u", &x))
            {
              if (x > 65535)
                return clib_error_return (0, "invalid port");
              gc_port_set (&nc, x);
              unformat (input, ",");
            }
        }
      else if (unformat (input, "udp %s", &word))
        nc.udp_enabled = !strcmp ((char *) word, "on");
      else if (unformat (input, "table-v4 %u", &x))
        {
          v4 = x;
          tables_changed = 1;
        }
      else if (unformat (input, "table-v6 %u", &x))
        {
          v6 = x;
          tables_changed = 1;
        }
      else
        {
          vec_free (word);
          return clib_error_return (0, "unknown input `%U'", format_unformat_error, input);
        }
      vec_free (word);
    }
  if (tables_changed && sm->mode != SG_MODE_OFF)
    return clib_error_return (0, "table sizes can be changed only when mode is off");
  vlib_worker_thread_barrier_sync (vm);
  sm->cfg = nc;
  sm->cfg.enforce = sm->mode == SG_MODE_ENFORCE;
  vlib_worker_thread_barrier_release (vm);
  if (tables_changed && (v4 != sm->table_v4 || v6 != sm->table_v6))
    {
      sg_tables_free (sm);
      sm->table_v4 = v4;
      sm->table_v6 = v6;
    }
  return 0;
}

static clib_error_t *
sg_show_command_fn (vlib_main_t *vm, unformat_input_t *input, vlib_cli_command_t *cmd)
{
  sg_main_t *sm = &sg_main;
  const gc_cfg_t *c = &sm->cfg;
  static const char *names[] = { "off", "monitor", "enforce" };
  vlib_cli_output (vm, "mode: %s", names[sm->mode]);
  u8 *ports = 0;
  for (u32 p = 0; p < 65536; p++)
    if (gc_port_test (c, p))
      ports = format (ports, "%s%u", vec_len (ports) ? "," : "", p);
  vlib_cli_output (vm, "config: ttl %u udp-ttl %u check-isn %s tcp-rst %s udp %s udp-frags %s udp-ports %v", c->ttl,
                   c->udp_ttl, c->check_isn ? "on" : "off", c->rst_handshake ? "handshake" : "pass",
                   c->udp_enabled ? "on" : "off", c->udp_frags_drop ? "drop" : "pass", ports);
  vec_free (ports);
  sg_if_t *e;
  vec_foreach (e, sm->ifs)
    vlib_cli_output (vm, "interface: %U %s", format_vnet_sw_if_index_name, sm->vnet_main, e->sw_if_index,
                     e->is_out ? "out" : "in");
  sg_prefix_t *p;
  vec_foreach (p, sm->prefixes)
    {
      if (p->is_v6)
        vlib_cli_output (vm, "prefix: %U/%u", format_ip6_address, &p->addr.ip6, p->len);
      else
        vlib_cli_output (vm, "prefix: %U/%u", format_ip4_address, &p->addr.ip4, p->len);
    }
  /* WERSJA: clib_bihash_elts_* przechodzi po koszykach (koszt rzędu ms) — używane tylko przy "show". */
  vlib_cli_output (vm, "table-v4: %llu/%u", sm->tables_ready ? (u64) clib_bihash_elts_16_8 (&sm->flows4) : 0,
                   sm->table_v4);
  vlib_cli_output (vm, "table-v6: %llu/%u", sm->tables_ready ? (u64) clib_bihash_elts_48_8 (&sm->flows6) : 0,
                   sm->table_v6);
  return 0;
}

VLIB_CLI_COMMAND (sg_interface_command, static) = {
  .path = "synack-guard interface",
  .short_help = "synack-guard interface <interface> in|out [disable]",
  .function = sg_interface_command_fn,
};
VLIB_CLI_COMMAND (sg_prefix_command, static) = {
  .path = "synack-guard prefix",
  .short_help = "synack-guard prefix <addr>/<len> [del]",
  .function = sg_prefix_command_fn,
};
VLIB_CLI_COMMAND (sg_mode_command, static) = {
  .path = "synack-guard mode",
  .short_help = "synack-guard mode off|monitor|enforce",
  .function = sg_mode_command_fn,
};
VLIB_CLI_COMMAND (sg_config_command, static) = {
  .path = "synack-guard config",
  .short_help = "synack-guard config [ttl <s>] [udp-ttl <s>] [check-isn on|off] [tcp-rst pass|handshake] [udp on|off] "
                "[udp-frags pass|drop] [udp-ports <p,p,...>] [table-v4 <n>] [table-v6 <n>]",
  .function = sg_config_command_fn,
};
VLIB_CLI_COMMAND (sg_show_command, static) = {
  .path = "show synack-guard",
  .short_help = "show synack-guard",
  .function = sg_show_command_fn,
};

static clib_error_t *
sg_init (vlib_main_t *vm)
{
  sg_main_t *sm = &sg_main;
  sm->vlib_main = vm;
  sm->vnet_main = vnet_get_main ();
  gc_cfg_init (&sm->cfg);
  sm->mode = SG_MODE_OFF;
  sm->table_v4 = 4000000;
  sm->table_v6 = 1000000;
  return 0;
}

VLIB_INIT_FUNCTION (sg_init);

VLIB_PLUGIN_REGISTER () = {
  .version = VPP_BUILD_VER,
  .description = "synack-guard: filtr odbić SYN-ACK / RST / UDP dla chronionych prefiksów",
};
GUARD_PLUGIN_C
  cat >"$d/CMakeLists.txt" <<'GUARD_CMAKE'
# synack-guard — wtyczka VPP (budowana razem z VPP: install-router.sh kopiuje ten katalog do src/plugins/)
add_vpp_plugin(synack_guard
  SOURCES
  synack_guard.c
)
GUARD_CMAKE
}

st_vpp_build() {
  local vdir=$SRC_DIR/vpp
  if [[ -d $vdir/.git ]]; then
    say "aktualizuję źródła VPP w $vdir"
    git -C "$vdir" fetch --tags --force
  else
    say "pobieram źródła VPP do $vdir"
    git clone https://github.com/FDio/vpp.git "$vdir"
  fi
  git -C "$vdir" checkout -f "$VPP_VERSION"
  say "wtyczka synack-guard → $vdir/src/plugins/synack_guard (kompilowana razem z VPP)"
  emit_guard_plugin "$vdir/src/plugins/synack_guard"
  man_add dir "$vdir/src/plugins/synack_guard" "źródła wtyczki VPP synack-guard (filtr odbić SYN-ACK/RST/UDP)"
  man_add dir "$vdir" "źródła VPP $VPP_VERSION (kompilacja)"
  cd "$vdir"
  say "make install-dep (zależności kompilacji z apt)"
  make UNATTENDED=y install-dep
  say "make install-ext-deps (DPDK, rdma-core, ipsec-mb — kompilacja)"
  make UNATTENDED=y install-ext-deps
  man_add pkg vpp-ext-deps "biblioteki zewnętrzne VPP (zbudowane w $vdir/build/external)"
  say "make pkg-deb (kompilacja VPP, to trwa najdłużej)"
  make UNATTENDED=y pkg-deb
  rm -f "$DEB_DIR"/vpp*.deb "$DEB_DIR"/libvppinfra*.deb "$DEB_DIR"/python3-vpp-api*.deb
  cp -f "$vdir"/build-root/*.deb "$DEB_DIR/"
  ls -1 "$DEB_DIR"/*.deb | sed 's/^/    /'
  man_add dir "$DEB_DIR" "zbudowane paczki .deb (VPP, hsflowd)"
  ok "VPP zbudowany, paczki w $DEB_DIR"
}

st_vpp_install() {
  local debs=()
  mapfile -t debs < <(find "$DEB_DIR" -maxdepth 1 \( -name 'vpp*.deb' -o -name 'libvppinfra*.deb' -o -name 'python3-vpp-api*.deb' \) \
    ! -name '*-dbg_*' ! -name '*-dev_*' ! -name '*-devtools_*' | sort)
  ((${#debs[@]})) || { echo "Brak paczek VPP w $DEB_DIR — powtórz etap 10 (--from 10)"; return 1; }
  say "instaluję: $(printf '%s ' "${debs[@]##*/}")"
  apt-get install "${APT_OPTS[@]}" "${debs[@]}"
  local d
  for d in "${debs[@]}"; do man_add pkg "$(dpkg-deb -f "$d" Package) $(dpkg-deb -f "$d" Version)" "zbudowane z VPP"; done
  systemctl enable vpp
  say "systemctl restart vpp"
  systemctl restart vpp || warn "VPP nie wystartował — sprawdź po restarcie: journalctl -u vpp"
  man_add service vpp.service "VPP (dataplane)"
  local _
  for _ in $(seq 1 30); do vppctl show version >/dev/null 2>&1 && break; sleep 2; done
  if vppctl show version >/dev/null 2>&1; then
    ok "$(vppctl show version)"
    vppctl show interface | grep -E '^hu' || warn "VPP nie widzi portów hu* — sprawdź /var/log/vpp/vpp.log"
  else
    warn "VPP jeszcze nie odpowiada (zwykle brak pełnej puli hugepages przed restartem) — sprawdź po restarcie: $0 --check"
  fi
}

st_bird() {
  say "repozytorium CZ.NIC dla BIRD 3"
  wget -qO /usr/share/keyrings/cznic-labs-pkg.gpg https://pkg.labs.nic.cz/gpg
  man_add file /usr/share/keyrings/cznic-labs-pkg.gpg "klucz repozytorium CZ.NIC"
  echo "deb [signed-by=/usr/share/keyrings/cznic-labs-pkg.gpg] https://pkg.labs.nic.cz/bird3 trixie main" \
    | put_file /etc/apt/sources.list.d/cznic-labs-bird3.list "repozytorium apt BIRD 3 (CZ.NIC)"
  apt-get update
  apt-get install "${APT_OPTS[@]}" bird3
  man_add pkg "bird3 $(dpkg-query -W -f='${Version}' bird3)" "BIRD 3 z repo CZ.NIC"
  local unit; unit=$(bird_unit)
  mkdir -p /etc/bird/conf.d
  put_file /etc/bird/bird.conf "konfiguracja bazowa BIRD (BGP doda drugi skrypt w conf.d/)" 640 <<EOF
# install-router.sh — konfiguracja bazowa; sesje BGP doda drugi skrypt w /etc/bird/conf.d/
log syslog all;
router id $ROUTER_ID;

protocol device {
}

protocol kernel kernel4 {
  ipv4 {
    import none;
    export none;
  };
}

protocol kernel kernel6 {
  ipv6 {
    import none;
    export none;
  };
}

include "/etc/bird/conf.d/*.conf";
EOF
  echo "# Pliki .conf w tym katalogu dołącza /etc/bird/bird.conf" \
    | put_file /etc/bird/conf.d/00-readme.conf "katalog na konfigurację BGP (drugi skrypt)" 640
  chown -R root:bird /etc/bird
  chmod 750 /etc/bird /etc/bird/conf.d
  say "bird -p (kontrola składni)"
  bird -p -c /etc/bird/bird.conf
  put_file "/etc/systemd/system/$unit.service.d/10-dataplane.conf" "BIRD uruchamiany w netns dataplane" <<'EOF'
[Unit]
Requires=netns-dataplane.service
After=netns-dataplane.service vpp.service
Wants=vpp.service

[Service]
NetworkNamespacePath=/var/run/netns/dataplane
EOF
  put_file "/etc/systemd/system/$unit.service.d/20-restart.conf" "BIRD: restart razem z VPP, automatyczny restart po awarii + alarm" <<'EOF'
[Unit]
BindsTo=vpp.service
StartLimitIntervalSec=600
StartLimitBurst=5
OnFailure=router-alert@%n.service

[Service]
Restart=on-failure
RestartSec=5
ExecStopPost=/opt/router/bin/router-alert %n $SERVICE_RESULT $EXIT_CODE $EXIT_STATUS
EOF
  printf '[Unit]\nWants=%s.service\n' "$unit" \
    | put_file /etc/systemd/system/vpp.service.d/30-bird.conf "start VPP podnosi też BIRD (po restarcie VPP sesje BGP wstają same)"
  systemctl daemon-reload
  systemctl enable "$unit"
  systemctl restart "$unit" || warn "BIRD nie wystartował — journalctl -u $unit"
  man_add service "$unit.service" "BIRD 3 w netns dataplane"
  sleep 2
  if birdc show status >/dev/null 2>&1; then ok "BIRD działa: $(birdc show status | head -1)"
  else warn "BIRD nie odpowiada — journalctl -u $unit"; fi
}

st_ifaces() {
  local bu i n=${#NIC_PCI[@]}
  bu=$(bird_unit)
  mkdir -p /var/lib/router /var/log/router-monitor
  prog_router_ifaces | put_file /opt/router/bin/router-ifaces "interfejsy VPP z /etc/router/ifaces.conf (VLAN-y, adresy, loopbacki, opisy)" 755
  ln -sfn /opt/router/bin/router-ifaces /usr/local/sbin/router-ifaces
  man_add file /usr/local/sbin/router-ifaces "polecenie router-ifaces (show / diff / apply / check)"

  if [[ -e /etc/router/ifaces.conf ]]; then
    say "/etc/router/ifaces.conf już istnieje — zostawiam bez zmian"
    man_add file /etc/router/ifaces.conf "interfejsy routera (istniejący plik zachowany)"
  else
    {
      cat <<'EOF'
# /etc/router/ifaces.conf — interfejsy routera: porty, VLAN-y, adresy, loopbacki, opisy
#
# Po edycji:   router-ifaces diff     (podgląd zmian)
#              router-ifaces apply    (zastosuj — wykonuje tylko różnice)
# Ten plik jest też konfiguracją startową: po każdym starcie VPP zostanie odtworzony.
# Plik jest jedynym źródłem prawdy: adres lub VLAN usunięty stąd znika z VPP.
#
# Kolumny (oddzielone spacjami):
#   interfejs  port VPP (hu0, hu1) albo loopback (loop0, loop1, ...)
#   vlan       1-4094 (802.1Q), "-" = sam port / loopback
#   ipv4       adres/maska, kilka po przecinku, "-" = brak
#   ipv6       adres/maska, kilka po przecinku, "-" = brak
#   opis       reszta linii (SNMP ifAlias → opis portu w LibreNMS/Cacti)
#
# MTU: wszystkie porty i VLAN-y mają standardowe MTU Ethernet 1500 (ustawiane przy starcie VPP).
#
# Prefiksy opisów Transit: / Peering: / Core: / Cust: LibreNMS grupuje w menu portów.
#
# interfejs  vlan  ipv4               ipv6                     opis
EOF
      printf '%-12s %-5s %-18s %-24s %s\n' hu0 - - - "Port 100G: trunk VLAN do switcha"
      for ((i = 1; i < n; i++)); do
        printf '#%-11s %-5s %-18s %-24s %s\n' "hu$i" - - - "Port $((i + 1)) (nieużywany)"
      done
      cat <<'EOF'
#
# Przykłady (usuń # i wpisz swoje adresy):
#hu0         100   192.0.2.2/30       2001:db8:100::2/64       Transit: EPIX AS62081
#hu0         200   198.51.100.2/30    2001:db8:200::2/64       Transit: Upstream-2 10G
#hu0         300   10.255.0.1/30      -                        Core: ASR1001-X BNG
#loop0       -     203.0.113.1/32     2001:db8::1/128          Loopback: router-id, BGP, SNMP
EOF
    } | put_file /etc/router/ifaces.conf "interfejsy routera: porty, VLAN-y, adresy IPv4/IPv6, loopbacki, opisy" 644
  fi

  put_file /etc/systemd/system/router-ifaces.service "odtworzenie interfejsów z ifaces.conf po każdym starcie VPP" <<'EOF'
[Unit]
Description=Router: interfejsy VPP z /etc/router/ifaces.conf (VLAN-y, adresy, loopbacki)
Documentation=file:/opt/router/README.md
BindsTo=vpp.service
After=vpp.service netns-dataplane.service
OnFailure=router-alert@%n.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/router/bin/router-ifaces boot
TimeoutStartSec=300
EOF
  printf '[Unit]\nWants=router-ifaces.service\n' \
    | put_file /etc/systemd/system/vpp.service.d/40-ifaces.conf "start VPP (także automatyczny restart) odtwarza interfejsy"
  printf '[Unit]\nAfter=router-ifaces.service\n' \
    | put_file "/etc/systemd/system/$bu.service.d/30-ifaces.conf" "BIRD startuje po odtworzeniu interfejsów"
  put_file /etc/systemd/system/router-ifaces-check.service "kontrola zgodności VPP z ifaces.conf (rozjazd → alarm)" <<'EOF'
[Unit]
Description=Router: kontrola zgodności interfejsów VPP z ifaces.conf
Documentation=file:/opt/router/README.md
After=router-ifaces.service

[Service]
Type=oneshot
ExecStart=/opt/router/bin/router-ifaces check --log
SuccessExitStatus=1 2 3
EOF
  put_file /etc/systemd/system/router-ifaces-check.timer "co 5 minut: kontrola zgodności interfejsów" <<'EOF'
[Unit]
Description=Router: co 5 minut kontrola zgodności interfejsów VPP z ifaces.conf
Documentation=file:/opt/router/README.md

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now router-ifaces-check.timer >/dev/null 2>&1 || warn "nie włączono router-ifaces-check.timer"
  man_add service router-ifaces.service "odtwarza interfejsy po starcie VPP (przed BIRD)"
  man_add service router-ifaces-check.timer "co 5 min: rozjazd VPP vs ifaces.conf → %IFACE-4-DRIFT"
  man_add dir /var/lib/router "stan router-ifaces (ifaces.state.json, ifaces.last-good.conf)"
  man_add file /var/log/router-monitor/router-ifaces.log "log router-ifaces: każde polecenie vppctl z wynikiem"

  say "router-ifaces: kontrola pliku i zastosowanie"
  if vppctl show version >/dev/null 2>&1; then
    /opt/router/bin/router-ifaces apply -y || warn "router-ifaces apply zakończył się błędem — zobacz /var/log/router-monitor/router-ifaces.log"
    /opt/router/bin/router-ifaces show || true
  else
    warn "VPP nie odpowiada — interfejsy zostaną skonfigurowane przy starcie VPP (router-ifaces.service)"
  fi
  /opt/router/bin/router-ifaces snmp || warn "ifaces.conf zawiera błędy (wyżej) — popraw i uruchom: router-ifaces apply"
  man_add file /etc/router/snmp-ifaces.yaml "opisy interfejsów dla vpp-snmp-agent (ifAlias), generowany przez router-ifaces"
  ok "interfejsy: /etc/router/ifaces.conf → router-ifaces apply (odtwarzane po każdym starcie VPP)"
}

st_snmp() {
  put_file /etc/snmp/snmpd.conf "snmpd (netns dataplane), community i AgentX dla vpp-snmp-agent" 600 <<EOF
# install-router.sh — snmpd w netns dataplane, liczniki interfejsów dostarcza vpp-snmp-agent
agentaddress udp:161,udp6:161
rocommunity $SNMP_COMMUNITY 127.0.0.1
rocommunity $SNMP_COMMUNITY $SNMP_ALLOW
sysName $(hostname -f 2>/dev/null || hostname)
sysLocation R630 BGP router
sysContact noc
master agentx
agentXSocket tcp:localhost:705
# LibreNMS: aplikacja mdadm (stan macierzy RAID)
extend mdadm /etc/snmp/extend/mdadm
EOF
  local ldir=$SRC_DIR/librenms-agent
  mkdir -p "$ldir"
  say "pobieram skrypt mdadm dla LibreNMS do $ldir"
  curl -fsSL -o "$ldir/mdadm" https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/mdadm
  man_add dir "$ldir" "skrypty LibreNMS (snmp extend)"
  put_file /etc/snmp/extend/mdadm "SNMP extend: stan RAID dla LibreNMS (aplikacja mdadm)" 755 <"$ldir/mdadm"
  put_file /etc/systemd/system/snmpd-dataplane.service "snmpd uruchamiany w netns dataplane" <<'EOF'
[Unit]
Description=Net-SNMP agent in dataplane netns
Documentation=file:/opt/router/README.md
Requires=netns-dataplane.service
After=netns-dataplane.service

[Service]
Type=simple
NetworkNamespacePath=/var/run/netns/dataplane
ExecStart=/usr/sbin/snmpd -LOw -u Debian-snmp -g vpp -I -smux,mteTrigger,mteTriggerConf -f -p /run/snmpd-dataplane.pid
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  local sdir=$SRC_DIR/vpp-snmp-agent
  if [[ -d $sdir/.git ]]; then git -C "$sdir" pull --ff-only || warn "nie zaktualizowano vpp-snmp-agent"
  else say "pobieram vpp-snmp-agent do $sdir"; git clone https://git.ipng.ch/ipng/vpp-snmp-agent.git "$sdir"; fi
  man_add dir "$sdir" "źródła vpp-snmp-agent"
  say "instaluję vpp-snmp-agent do /opt/router/vpp-snmp-agent"
  mkdir -p /opt/router
  rm -rf /opt/router/vpp-snmp-agent
  cp -a "$sdir" /opt/router/vpp-snmp-agent
  rm -rf /opt/router/vpp-snmp-agent/.git
  man_add dir /opt/router/vpp-snmp-agent "vpp-snmp-agent (AgentX: liczniki interfejsów z VPP do SNMP)"
  put_file /etc/systemd/system/vpp-snmp-agent.service "vpp-snmp-agent w netns dataplane" <<'EOF'
[Unit]
Description=SNMP AgentX for VPP dataplane statistics
Documentation=file:/opt/router/README.md
Requires=netns-dataplane.service
After=netns-dataplane.service vpp.service snmpd-dataplane.service
Wants=snmpd-dataplane.service

[Service]
Type=simple
NetworkNamespacePath=/var/run/netns/dataplane
WorkingDirectory=/opt/router/vpp-snmp-agent
ExecStart=/usr/bin/python3 /opt/router/vpp-snmp-agent/vpp-snmp-agent.py -a localhost:705 -c /etc/router/snmp-ifaces.yaml
Group=vpp
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl disable --now snmpd.service 2>/dev/null || true
  man_add other "snmpd.service" "domyślny snmpd wyłączony (zastąpiony przez snmpd-dataplane)"
  systemctl enable --now snmpd-dataplane.service || warn "snmpd-dataplane nie wystartował"
  systemctl enable --now vpp-snmp-agent.service || warn "vpp-snmp-agent nie wystartował (sprawdź po restarcie)"
  man_add service snmpd-dataplane.service "snmpd w netns dataplane (UDP 161)"
  man_add service vpp-snmp-agent.service "AgentX z licznikami VPP"
  ok "SNMP gotowe (community w $ENV_FILE)"
}

st_sflow() {
  local hdir=$SRC_DIR/host-sflow
  if [[ -d $hdir/.git ]]; then git -C "$hdir" pull --ff-only || warn "nie zaktualizowano host-sflow"
  else say "pobieram host-sflow do $hdir"; git clone https://github.com/sflow/host-sflow.git "$hdir"; fi
  man_add dir "$hdir" "źródła hsflowd"
  cd "$hdir"
  make clean >/dev/null 2>&1 || true
  rm -f hsflowd_*.deb
  say "make deb FEATURES=VPP"
  make deb FEATURES="VPP"
  rm -f "$DEB_DIR"/hsflowd_*.deb
  cp -f "$hdir"/hsflowd_*.deb "$DEB_DIR/"
  apt-get install "${APT_OPTS[@]}" "$DEB_DIR"/hsflowd_*.deb
  man_add pkg "hsflowd $(dpkg-query -W -f='${Version}' hsflowd)" "zbudowany z host-sflow (moduł VPP)"
  {
    echo "# install-router.sh — próbki z VPP (psample 3/4) wysyłane jako sFlow"
    echo "sflow {"
    if [[ -n $SFLOW_COLLECTOR ]]; then echo "  collector { ip=$SFLOW_COLLECTOR udpport=6343 }"
    else echo "  # collector { ip=192.0.2.10 udpport=6343 }"; fi
    echo "  psample { group=3 egress=on }"
    echo "  vpp { osIndex=off }"
    echo "}"
  } | put_file /etc/hsflowd.conf "hsflowd: kolektor sFlow, źródło próbek z VPP"
  systemctl enable hsflowd
  systemctl restart hsflowd || warn "hsflowd nie wystartował — journalctl -u hsflowd"
  man_add service hsflowd.service "eksport sFlow (próbki z VPP)"
  [[ -n $SFLOW_COLLECTOR ]] || warn "SFLOW_COLLECTOR puste — hsflowd działa, ale nikomu nie wysyła (uzupełnij /etc/hsflowd.conf)"
  ok "sFlow gotowe"
}

st_etckeeper() {
  if [[ ! -d /etc/.git ]]; then
    say "etckeeper init"
    etckeeper init
  fi
  etckeeper commit "install-router.sh: stan przed instalacją routera" >/dev/null 2>&1 || true
  man_add dir /etc/.git "etckeeper: historia zmian /etc (git log -C /etc, tylko root)"
  ok "etckeeper aktywny: $(git -C /etc log --oneline | wc -l) commitów w historii /etc"
}

st_raid() {
  prog_mdadm_alert | put_file /opt/router/bin/mdadm-alert "zdarzenia mdadm do logu (styl %MD-SEV-ZDARZENIE)" 755
  local conf=/etc/mdadm/mdadm.conf cur
  cur=$(grep -v -e '^PROGRAM' -e '^# install-router.sh: PROGRAM' "$conf" 2>/dev/null || true)
  {
    [[ -n $cur ]] && printf '%s\n' "$cur"
    echo "# install-router.sh: PROGRAM wywoływany przy każdym zdarzeniu RAID"
    echo "PROGRAM /opt/router/bin/mdadm-alert"
  } | put_file "$conf" "mdadm: alarmy RAID przez /opt/router/bin/mdadm-alert"
  if grep -q '^md' /proc/mdstat 2>/dev/null; then
    ok "macierze: $(grep -c '^md' /proc/mdstat) — $(grep '^md' /proc/mdstat | awk '{print $1"("$4")"}' | xargs)"
  else
    warn "nie widzę macierzy mdadm w /proc/mdstat — monitoring ruszy, gdy się pojawią"
  fi
  local u
  for u in mdmonitor mdadm; do
    if systemctl list-unit-files "$u.service" --no-legend 2>/dev/null | grep -q "^$u.service"; then
      systemctl enable "$u.service" 2>/dev/null || true
      systemctl restart "$u.service" || warn "restart $u nie powiódł się"
      man_add service "$u.service" "mdadm --monitor: zdarzenia RAID → mdadm-alert"
      break
    fi
  done
  say "test alarmu RAID (mdadm --test)"
  mdadm --monitor --scan --oneshot --test --program=/opt/router/bin/mdadm-alert >/dev/null 2>&1 || true
  prog_smartd_alert | put_file /opt/router/bin/smartd-alert "alarm z smartd (zdrowie dysków) do logu i e-mail" 755
  if [[ -f /etc/smartd.conf ]]; then
    local sc
    sc=$(sed -e '/^DEVICESCAN/d' -e '/^# install-router.sh: smartd/d' /etc/smartd.conf)
    {
      printf '%s\n' "$sc"
      echo "# install-router.sh: smartd — wszystkie dyski, alarmy przez /opt/router/bin/smartd-alert"
      echo "DEVICESCAN -d removable -n standby -m root -M exec /opt/router/bin/smartd-alert"
    } | put_file /etc/smartd.conf "smartd: alarmy przez smartd-alert"
  fi
  for u in smartd smartmontools; do
    if systemctl list-unit-files "$u.service" --no-legend 2>/dev/null | grep -q "^$u.service"; then
      systemctl enable --now "$u.service" || warn "smartd nie wystartował"
      man_add service "$u.service" "smartd: kontrola zdrowia dysków (S.M.A.R.T.) do sysloga"
      break
    fi
  done
  warn "jeśli dyski stoją za kontrolerem PERC w trybie RAID (nie HBA), smartd wymaga '-d megaraid,N' w /etc/smartd.conf"
  ok "monitoring RAID i dysków aktywny"
}

st_monitor() {
  prog_router_monitor | put_file /opt/router/bin/router-monitor "router-monitor: obciążenie VPP, rx-miss, CPU, RAID w czasie rzeczywistym" 755
  put_file /etc/router/router-monitor.conf "progi router-monitor (zmiana: edytuj i systemctl restart router-monitor)" <<EOF
# router-monitor — progi alarmów. Po zmianie: systemctl restart router-monitor
INTERVAL=1
# średni rozmiar wektora workera VPP: 1 = luz, 256 = pełne nasycenie
VEC_WARN=64
VEC_CRIT=160
# pakiety/s zgubione przez kartę, bo VPP nie nadąża (rx-miss + rx-no-buf)
RXMISS_PPS=1
# pakiety/s odrzucone sprzętowo przez kartę (liczniki *discard*)
NIC_DISCARD_PPS=1
# pakiety/s do samego routera (control plane)
PUNT_PPS=20000
# rdzenie systemowe (poza VPP): % zajętości przez ile sekund
HK_CPU_PCT=90
HK_CPU_SECONDS=5
# przypomnienie o trwającym zdarzeniu co N s; minutowe podsumowanie szczytów
REPEAT_EVERY=10
SUMMARY_EVERY=60
XSTATS_EVERY=10
MD_EVERY=10
# zawieszenie VPP: brak heartbeat przez N s; 1 = restart VPP
HANG_SECONDS=30
HANG_RESTART=$VPP_HANG_RESTART
EOF
  put_file /etc/systemd/system/router-monitor.service "usługa router-monitor" <<'EOF'
[Unit]
Description=Router monitor (obciążenie VPP, rx-miss, CPU, RAID)
Documentation=file:/opt/router/README.md
After=vpp.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/router/bin/router-monitor
Restart=always
RestartSec=5
Nice=-5

[Install]
WantedBy=multi-user.target
EOF
  put_file /etc/logrotate.d/router-monitor "rotacja logów router-monitor (60 dni)" <<'EOF'
/var/log/router-monitor/*.log {
  daily
  rotate 60
  compress
  delaycompress
  missingok
  notifempty
  create 0640 root adm
}
EOF
  mkdir -p /var/log/router-monitor
  man_add dir /var/log/router-monitor "logi zdarzeń: router-monitor, router-alert, mdadm-alert"
  python3 -m py_compile /opt/router/bin/router-monitor
  rm -rf /opt/router/bin/__pycache__
  systemctl daemon-reload
  systemctl enable router-monitor.service
  systemctl restart router-monitor.service || warn "router-monitor nie wystartował — journalctl -u router-monitor"
  man_add service router-monitor.service "logowanie przeciążeń w czasie rzeczywistym"
  sleep 3
  tail -n 5 /var/log/router-monitor/router-monitor.log 2>/dev/null || true
  ok "router-monitor działa — log: /var/log/router-monitor/router-monitor.log"
}

st_resilience() {
  put_file /etc/sysctl.d/83-router-panic.conf "restart po kernel panic / oops / zawieszeniu kernela" <<EOF
# install-router.sh: router ma sam wstać po awarii kernela
# panic -> restart po N s; oops i zawieszenia kernela traktowane jak panic
kernel.panic = $PANIC_REBOOT_SEC
kernel.panic_on_oops = 1
kernel.softlockup_panic = 1
kernel.hardlockup_panic = 1
EOF
  sysctl -q -p /etc/sysctl.d/83-router-panic.conf || warn "część ustawień panic nie została przyjęta przez kernel"
  ok "kernel.panic=$(sysctl -n kernel.panic) panic_on_oops=$(sysctl -n kernel.panic_on_oops)"

  local wdmod="" m
  if [[ ! -e /dev/watchdog0 ]]; then
    for m in iTCO_wdt ipmi_watchdog; do
      [[ $m == ipmi_watchdog ]] && { modprobe ipmi_si 2>/dev/null || true; }
      if modprobe "$m" 2>/dev/null; then
        sleep 1
        [[ -e /dev/watchdog0 ]] && { wdmod=$m; break; }
      fi
    done
  fi
  [[ -n $wdmod ]] && echo "$wdmod" | put_file /etc/modules-load.d/router-watchdog.conf "sterownik watchdoga sprzętowego ($wdmod)"
  if [[ -e /dev/watchdog0 ]]; then
    put_file /etc/systemd/system.conf.d/90-router-watchdog.conf "systemd: watchdog sprzętowy — restart przy całkowitym zawieszeniu" <<EOF
# install-router.sh: systemd odświeża watchdog sprzętowy; przy zawieszeniu systemu płyta restartuje serwer
[Manager]
RuntimeWatchdogSec=$WATCHDOG_SEC
RebootWatchdogSec=10min
EOF
    systemctl daemon-reexec
    ok "watchdog sprzętowy: $(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null || echo watchdog0), timeout ${WATCHDOG_SEC}s"
  else
    warn "brak watchdoga sprzętowego — przy całkowitym zawieszeniu zostaje iDRAC (Automated System Recovery w BIOS/iDRAC)"
  fi

  say "trwały journal (logi poprzedniego startu po awarii)"
  mkdir -p /var/log/journal
  systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
  systemctl restart systemd-journald || true
  man_add dir /var/log/journal "trwały journal (journalctl -b -1 po restarcie)"
  systemctl enable systemd-pstore.service >/dev/null 2>&1 || true
  man_add service systemd-pstore.service "zapis logu kernel panic z UEFI pstore do /var/lib/systemd/pstore"
  mkdir -p /var/lib/router
  man_add dir /var/lib/router "znaczniki czystego wyłączenia (wykrywanie awarii)"
  ok "restart po awarii kernela skonfigurowany"
}

st_notify() {
  local conf=/etc/router/notify.conf
  mkdir -p /etc/router
  if [[ -z $ALERT_EMAILS && -f $conf ]]; then
    say "zostawiam istniejący $conf (odbiorcy: $(sed -n 's/^ALERT_EMAILS="\(.*\)"$/\1/p' "$conf"))"
  else
    write_notify_conf
    say "zapisano $conf"
  fi
  man_add file "$conf" "SMTP, odbiorcy i kategorie alarmów (hasło — tylko root, poza etckeeper)"
  prog_router_notify | put_file /opt/router/bin/router-notify "wysyłka alarmów e-mailem (kolejka /var/spool/router-notify)" 755
  python3 -m py_compile /opt/router/bin/router-notify && rm -rf /opt/router/bin/__pycache__
  mkdir -p /var/spool/router-notify && chmod 700 /var/spool/router-notify
  man_add dir /var/spool/router-notify "kolejka alarmów do wysłania"
  put_file /etc/systemd/system/router-notify.service "usługa wysyłki alarmów e-mailem" <<'EOF'
[Unit]
Description=Router: powiadomienia e-mail o alarmach
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/router/bin/router-notify run
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable router-notify.service
  systemctl restart router-notify.service || warn "router-notify nie wystartował"
  man_add service router-notify.service "wysyłka alarmów e-mailem"
  ln -sfn /opt/router/bin/router-notify /usr/local/sbin/router-notify
  man_add file /usr/local/sbin/router-notify "polecenie router-notify (test: router-notify test)"
  if grep -q '^ALERT_EMAILS="[^"]' "$conf" && grep -q '^SMTP_HOST="[^"]' "$conf"; then
    say "wysyłam mail testowy"
    if /opt/router/bin/router-notify test; then ok "mail testowy wysłany — sprawdź skrzynkę"
    else warn "mail testowy nie wyszedł — popraw $conf i uruchom: router-notify test"; fi
  else
    warn "powiadomienia e-mail nieskonfigurowane — uzupełnij $conf (albo ALERT_EMAILS/SMTP_* w skrypcie) i: systemctl restart router-notify"
  fi
}

st_services() {
  local bu; bu=$(bird_unit)
  prog_router_bootcheck | put_file /opt/router/bin/router-bootcheck "kontrola po starcie: nieczysty restart, kernel panic, stan usług" 755

  put_file /etc/systemd/system/router-bootcheck.service "kontrola po starcie (wynik w logu router-monitor)" <<'EOF'
[Unit]
Description=Router: kontrola po starcie (nieczysty restart, kernel panic, usługi)
Documentation=file:/opt/router/README.md
After=router.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/router/bin/router-bootcheck
ExecStop=/opt/router/bin/router-bootcheck --shutdown
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

  local units=(netns-dataplane.service vpp.service router-ifaces.service "$bu.service" snmpd-dataplane.service
               vpp-snmp-agent.service hsflowd.service router-monitor.service router-notify.service)
  {
    echo "[Unit]"
    echo "Description=Router BGP: VPP + BIRD + SNMP + sFlow + monitoring"
    echo "Documentation=file:/opt/router/README.md"
    echo "Wants=${units[*]}"
    echo "After=${units[*]}"
    echo
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } | put_file /etc/systemd/system/router.target "grupa wszystkich usług routera (systemctl status router.target)"

  systemctl daemon-reload
  local u state bad=0
  say "włączam autostart usług"
  for u in "${units[@]}" router.target router-bootcheck.service irqbalance.service; do
    systemctl enable "$u" >/dev/null 2>&1 || true
    state=$(systemctl is-enabled "$u" 2>/dev/null || true)
    case $state in
      enabled|static|alias|indirect|generated) printf '    %-28s %s\n' "$u" "$state" ;;
      *) printf '    %-28s %s  <- UWAGA\n' "$u" "${state:-brak}"; bad=1 ;;
    esac
  done
  man_add service router.target "grupa usług routera, start z multi-user.target"
  man_add service router-bootcheck.service "kontrola po starcie (BOOT_OK / BOOT_PROBLEM)"

  say "systemd-analyze verify (kontrola składni jednostek)"
  systemd-analyze verify /etc/systemd/system/router.target /etc/systemd/system/router-monitor.service \
    /etc/systemd/system/router-bootcheck.service /etc/systemd/system/netns-dataplane.service \
    /etc/systemd/system/snmpd-dataplane.service /etc/systemd/system/vpp-snmp-agent.service \
    /etc/systemd/system/router-ifaces.service /etc/systemd/system/router-ifaces-check.timer 2>&1 \
    | grep -v -e '^$' | sed 's/^/    /' || true

  say "blokada automatycznych aktualizacji VPP i BIRD (apt-mark hold)"
  local held
  held=$(dpkg-query -W -f='${Package}\n' 'vpp*' 'libvppinfra' 'python3-vpp-api' bird3 hsflowd 2>/dev/null \
         | grep -v -e '-dbg$' -e '-dev$' || true)
  if [[ -n $held ]]; then
    # shellcheck disable=SC2086
    apt-mark hold $held >/dev/null
    man_add other "apt-mark hold: $(echo $held | xargs)" "aktualizacja tylko świadomie (README, rozdz. 12)"
  fi

  say "start całości: systemctl start router.target"
  systemctl start router.target || warn "nie wszystkie usługi wystartowały (pełny start po restarcie serwera)"
  systemctl list-dependencies router.target --no-pager 2>/dev/null | sed 's/^/    /' || true
  ((bad == 0)) && ok "autostart skonfigurowany: router.target + router-bootcheck" || warn "część usług nie jest włączona — patrz lista wyżej"
}

fw_example_conf() {
  cat <<'EOF'
# /etc/router/firewall.conf — firewall tranzytu na VPP (polecenie router-fw)
# Po edycji:  router-fw check  →  router-fw diff  →  router-fw apply   (apply --confirm 120 = cofnięcie bez potwierdzenia)
# Ruchu DO routera (BGP, BFD, SNMP, ICMP) ten plik nie dotyczy — to zadanie netfiltera w netns dataplane.
#
# zone   INTERFEJS  STREFA       strefa to dowolna nazwa do 24 znaków; blokady doraźne (router-fw block) działają w strefie "internet"
# list   NAZWA      adres/prefiks ...        albo:  list NAZWA include /etc/router/fw-lists/plik.list
# kierunek    akcja   proto  src   sport  dst   dport  opis
#   kierunek: internet->  = ruch wchodzący z interfejsów strefy,   ->internet  = ruch wychodzący do strefy
#   akcja: permit | deny      proto: tcp udp icmp icmp6 any      adres: any | prefiks | @lista | a,b,c
#   port: any | 25 | 25,587 | 1024-65535 (tylko tcp i udp)
# Kolejność ma znaczenie: pierwsza pasująca reguła wygrywa, wyjątki (whitelist) wpisuj nad blokadą.
# Co nie pasuje do żadnej reguły, przechodzi.
#
#zone  hu0.100  internet     # Transit: EPIX
#zone  hu0.300  clients      # Core: BNG
#list  smtp-ok  203.0.113.25/32  203.0.113.26/32
#->internet   permit  tcp  @smtp-ok  any  any  25     serwery poczty klientów
#->internet   deny    tcp  any       any  any  25     blokada SMTP od klientów
#internet->   deny    tcp  any       any  any  445    SMB z internetu

set counters on
EOF
}

st_fw() {
  local bu; bu=$(bird_unit)
  mkdir -p /var/lib/router /var/log/router-monitor /etc/router/fw-lists
  prog_router_fw | put_file /opt/router/bin/router-fw "firewall tranzytu VPP (acl-plugin): strefy, reguły, blokady, liczniki" 755
  ln -sfn /opt/router/bin/router-fw /usr/local/sbin/router-fw
  man_add file /usr/local/sbin/router-fw "polecenie router-fw (show / diff / apply / check / block / counters)"
  if [[ -f /etc/router/firewall.conf ]]; then
    say "zostawiam istniejący /etc/router/firewall.conf"
  else
    fw_example_conf | put_file /etc/router/firewall.conf "firewall tranzytu: strefy, listy i reguły (domyślnie bez reguł)"
  fi
  man_add dir /etc/router/fw-lists "długie listy adresów dla firewall.conf (list NAZWA include ...)"
  put_file /etc/systemd/system/router-fw.service "odtworzenie reguł firewalla po każdym starcie VPP" <<'EOF'
[Unit]
Description=Router: firewall tranzytu VPP (ACL z /etc/router/firewall.conf)
Documentation=file:/opt/router/README.md
BindsTo=vpp.service
After=vpp.service netns-dataplane.service router-ifaces.service
OnFailure=router-alert@%n.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/router/bin/router-fw boot
TimeoutStartSec=300
EOF
  printf '[Unit]\nWants=router-fw.service\n' \
    | put_file /etc/systemd/system/vpp.service.d/50-fw.conf "start VPP (także automatyczny restart) odtwarza reguły firewalla"
  printf '[Unit]\nAfter=router-fw.service\n' \
    | put_file "/etc/systemd/system/$bu.service.d/40-fw.conf" "BIRD startuje po wgraniu reguł firewalla"
  printf '[Unit]\nWants=router-fw.service\nAfter=router-fw.service\n' \
    | put_file /etc/systemd/system/router.target.d/10-fw.conf "router.target obejmuje router-fw.service"
  put_file /etc/systemd/system/router-fw-check.service "kontrola zgodności VPP z firewall.conf (rozjazd → alarm)" <<'EOF'
[Unit]
Description=Router: kontrola zgodności ACL w VPP z firewall.conf
Documentation=file:/opt/router/README.md
After=router-fw.service

[Service]
Type=oneshot
ExecStart=/opt/router/bin/router-fw check --log
SuccessExitStatus=1 2 3
EOF
  put_file /etc/systemd/system/router-fw-check.timer "co 5 minut: kontrola zgodności firewalla" <<'EOF'
[Unit]
Description=Router: co 5 minut kontrola zgodności ACL w VPP z firewall.conf
Documentation=file:/opt/router/README.md

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
  put_file /etc/systemd/system/router-fw-expire.service "zdejmowanie wygasłych blokad doraźnych" <<'EOF'
[Unit]
Description=Router: zdjęcie wygasłych blokad doraźnych firewalla
Documentation=file:/opt/router/README.md
After=router-fw.service

[Service]
Type=oneshot
ExecStart=/opt/router/bin/router-fw expire
SuccessExitStatus=1 2 3
EOF
  put_file /etc/systemd/system/router-fw-expire.timer "co minutę: wygasanie blokad doraźnych" <<'EOF'
[Unit]
Description=Router: co minutę zdejmij wygasłe blokady doraźne firewalla
Documentation=file:/opt/router/README.md

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable router-fw.service router-fw-check.timer router-fw-expire.timer >/dev/null 2>&1 \
    || warn "nie włączono jednostek router-fw"
  systemctl start router-fw-check.timer router-fw-expire.timer >/dev/null 2>&1 || true
  if vppctl show version >/dev/null 2>&1; then
    systemctl start router-fw.service || warn "router-fw.service nie wystartował — journalctl -u router-fw"
  else
    warn "VPP nie odpowiada — reguły firewalla zostaną wgrane przy starcie VPP (router-fw.service)"
  fi
  systemd-analyze verify /etc/systemd/system/router-fw.service /etc/systemd/system/router-fw-check.timer \
    /etc/systemd/system/router-fw-expire.timer 2>&1 | sed 's/^/    /' || true
  man_add service router-fw.service "odtwarza reguły firewalla po starcie VPP (przed BIRD)"
  man_add service router-fw-check.timer "co 5 min: rozjazd VPP vs firewall.conf → %FW-4-DRIFT"
  man_add service router-fw-expire.timer "co 1 min: wygasanie blokad doraźnych (router-fw block)"
  ok "firewall: edytuj /etc/router/firewall.conf, potem: router-fw check / diff / apply"
}

guard_example_conf() {
  cat <<'EOF'
# /etc/router/synack-guard.conf — ochrona przed odbiciami SYN-ACK / RST / UDP (polecenie router-guard)
# Włączanie na żądanie:  router-guard on <prefiks|IP|grupa> [--enforce] [--for 2h]
#                        router-guard status | enforce | monitor | off
# Wymaga wtyczki VPP synack_guard (budowana razem z VPP, etap 10) i R630 widzącego oba kierunki ruchu.
#
# Interfejsy VPP: uplinki (tu sprawdzamy SYN-ACK) i strona klientów (tu zapisujemy SYN). Rozłączne.
#in-if    hu0.100 hu0.200
#out-if   hu0.300
#
# Grupy prefiksów do wywołań "router-guard on web"
#group web      203.0.113.0/24
#group hosting  198.51.100.0/24  2001:db8:100::/48
#
# Parametry (wartości domyślne)
#ttl            60        # sekundy ważności wpisu TCP
#udp-ttl        30        # sekundy ważności wpisu UDP
#warmup         60        # monitor przed przejściem na enforce (tablica uczy się wychodzących SYN)
#max-on         6h        # automatyczne wyłączenie
#default-mode   monitor   # monitor | enforce (po "on" bez opcji)
#tcp-rst        pass      # pass | handshake (RST przechodzi tylko jako odpowiedź na SYN z chronionego prefiksu)
#udp            on        # filtr UDP z portów amplifikacji
#udp-ports      19 53 111 123 137 161 389 1900 3702 5353 11211
#udp-frags      pass      # pass | drop (niepierwsze fragmenty UDP)
#check-isn      on        # numer potwierdzenia SYN-ACK musi być ISN+1
#table-v4       4000000   # rozmiary tablic stanów (zmiana tylko przy wyłączonej ochronie)
#table-v6       1000000
#alarm-pps      10000     # %GUARD-4-VIOLATIONS powyżej tylu naruszeń na sekundę
EOF
}

st_guard() {
  mkdir -p /var/lib/router /var/log/router-monitor
  prog_router_guard | put_file /opt/router/bin/router-guard "ochrona przed odbiciami SYN-ACK/RST/UDP (wtyczka VPP synack_guard): włączanie na żądanie" 755
  ln -sfn /opt/router/bin/router-guard /usr/local/sbin/router-guard
  man_add file /usr/local/sbin/router-guard "polecenie router-guard (on / off / status / enforce / monitor)"
  if [[ -f /etc/router/synack-guard.conf ]]; then
    say "zostawiam istniejący /etc/router/synack-guard.conf"
  else
    guard_example_conf | put_file /etc/router/synack-guard.conf "ochrona przed odbiciami: interfejsy, grupy prefiksów, parametry (domyślnie wszystko w komentarzach)" 644
  fi
  put_file /etc/systemd/system/router-guard.service "odtworzenie ochrony przed odbiciami po każdym starcie VPP (jeśli była włączona)" <<'EOF'
[Unit]
Description=Router: odtworzenie ochrony synack-guard po starcie VPP
Documentation=file:/opt/router/README.md
BindsTo=vpp.service
After=vpp.service netns-dataplane.service router-ifaces.service router-fw.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/router/bin/router-guard boot
TimeoutStartSec=300
SuccessExitStatus=3
EOF
  printf '[Unit]\nWants=router-guard.service\n' \
    | put_file /etc/systemd/system/vpp.service.d/60-guard.conf "start VPP (także automatyczny restart) odtwarza ochronę synack-guard"
  printf '[Unit]\nWants=router-guard.service\nAfter=router-guard.service\n' \
    | put_file /etc/systemd/system/router.target.d/20-guard.conf "router.target obejmuje router-guard.service"
  put_file /etc/systemd/system/router-guard-check.service "kontrola zgodności VPP z router-guard, alarmy (naruszenia, zapełnienie tablic)" <<'EOF'
[Unit]
Description=Router: kontrola synack-guard (rozjazd, naruszenia, zapełnienie tablic)
Documentation=file:/opt/router/README.md
After=router-guard.service

[Service]
Type=oneshot
ExecStart=/opt/router/bin/router-guard check --log
SuccessExitStatus=1 2 3
EOF
  put_file /etc/systemd/system/router-guard-check.timer "co minutę: kontrola synack-guard" <<'EOF'
[Unit]
Description=Router: co minutę kontrola synack-guard
Documentation=file:/opt/router/README.md

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
  put_file /etc/systemd/system/router-guard-expire.service "wyłączenie ochrony po upływie czasu, przejście na enforce po rozgrzewce" <<'EOF'
[Unit]
Description=Router: synack-guard — wygasanie ochrony i przejście na enforce
Documentation=file:/opt/router/README.md
After=router-guard.service

[Service]
Type=oneshot
ExecStart=/opt/router/bin/router-guard expire
SuccessExitStatus=1 2 3 4
EOF
  put_file /etc/systemd/system/router-guard-expire.timer "co minutę: wygasanie ochrony synack-guard" <<'EOF'
[Unit]
Description=Router: co minutę wygaś ochronę synack-guard po upływie czasu
Documentation=file:/opt/router/README.md

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable router-guard.service router-guard-check.timer router-guard-expire.timer >/dev/null 2>&1 \
    || warn "nie włączono jednostek router-guard"
  systemctl start router-guard-check.timer router-guard-expire.timer >/dev/null 2>&1 || true
  if vppctl show synack-guard >/dev/null 2>&1 && ! vppctl show synack-guard 2>&1 | grep -q 'unknown input'; then
    systemctl start router-guard.service || warn "router-guard.service nie wystartował — journalctl -u router-guard"
    ok "wtyczka synack_guard załadowana w VPP"
  else
    warn "wtyczka synack_guard nie jest załadowana w VPP — wejdzie w życie po przebudowie VPP (install-router.sh --from 10) i restarcie VPP"
  fi
  systemd-analyze verify /etc/systemd/system/router-guard.service /etc/systemd/system/router-guard-check.timer \
    /etc/systemd/system/router-guard-expire.timer 2>&1 | sed 's/^/    /' || true
  man_add service router-guard.service "odtwarza ochronę synack-guard po starcie VPP (jeśli była włączona)"
  man_add service router-guard-check.timer "co 1 min: rozjazd, naruszenia, zapełnienie tablic synack-guard"
  man_add service router-guard-expire.timer "co 1 min: wygasanie ochrony i przejście na enforce"
  ok "ochrona przed odbiciami: uzupełnij /etc/router/synack-guard.conf, potem: router-guard on <prefiks> [--enforce]"
}

st_docs() {
  local bu; bu=$(bird_unit)
  local ifn=() i
  for i in "${!NIC_PCI[@]}"; do ifn+=("hu$i"); done
  local readme
  shopt -u patsub_replacement 2>/dev/null || true
  cat >"$STATE_DIR/README.template" <<'READMEEOF'
# Router BGP — R630 + ConnectX-4 (VPP + BIRD)

Dokumentacja wygenerowana przez `install-router.sh` dnia @@DATE@@ na hoście `@@HOST@@`.
Wszystkie wartości poniżej pochodzą z tej instalacji.

Szybki stan routera w każdej chwili:

```
router-check                      # pełna kontrola: usługi, VPP, BIRD, SNMP, RAID, ostatnie alarmy
systemctl status router.target    # wszystkie usługi routera naraz
tail -f /var/log/router-monitor/router-monitor.log   # alarmy na żywo
```

---

## 1. Architektura

```
             upstreamy / EPIX / BNG  (VLAN-y na porcie 100G)
                              │
              ┌───────────────┴────────────────┐
              │  ConnectX-4 (@@NIC@@)          │
              │  porty w VPP: @@IFNAMES@@      │
              └───────────────┬────────────────┘
                              │ DPDK (mlx5, bez vfio)
   ┌──────────────────────────┴───────────────────────────────┐
   │ VPP @@VPPVER@@  — forwarding pakietów                     │
   │   main-core @@MAIN@@, workery @@WORKERS@@ (NUMA @@NUMA@@)  │
   │   linux-cp: lustro interfejsów do netns "dataplane"       │
   │   sflow: próbki 1:@@SAMPLING@@ → hsflowd                  │
   └───────┬───────────────────────────────┬──────────────────┘
           │ TAP (linux-cp)                │ statystyki (/run/vpp/stats.sock)
   ┌───────┴──────────────────────┐   ┌────┴─────────────────────────────┐
   │ netns "dataplane"             │   │ router-monitor (alarmy co 1 s)    │
   │   BIRD 3 (BGP)  → trasy do    │   │ vpp-snmp-agent (liczniki → SNMP)  │
   │     kernela → linux-nl → VPP  │   │ hsflowd (sFlow → kolektor)        │
   │   snmpd (UDP 161, LibreNMS)   │   └───────────────────────────────────┘
   └───────────────────────────────┘
   Zarządzanie awaryjne: port 1G na płycie (eth2) + iDRAC — poza VPP.
```

Zasada działania:

- **VPP** przekazuje cały ruch tranzytowy. Kernel Linuksa go nie widzi (dlatego iptables/nftables nie filtrują tranzytu — robią to ACL-e w VPP).
- **linux-cp** tworzy w netns `dataplane` odpowiedniki interfejsów VPP. Ruch do samego routera (BGP, SSH, SNMP) VPP przekazuje do Linuksa.
- **BIRD** działa w netns `dataplane`, wpisuje najlepsze trasy do tablicy kernela, a plugin **linux-nl** przenosi je do tablicy VPP.
- Rdzenie VPP są wyłączone z harmonogramu systemu (`isolcpus=@@ISOL@@`), a karta i VPP pracują na tym samym węźle NUMA (@@NUMA@@).

---

## 2. Usługi i automatyczny start

Wszystkie usługi routera zbiera jednostka **`router.target`** (włączona w `multi-user.target`).
Po restarcie serwera wstają same, w tej kolejności:

| Kolejność | Usługa | Rola | Po awarii |
|---|---|---|---|
| 1 | `netns-dataplane.service` | tworzy netns `dataplane` | — |
| 2 | `vpp.service` | dataplane (forwarding) | restart po 5 s, max 5× / 10 min, potem alarm |
| 3 | `router-ifaces.service` | odtwarza VLAN-y, adresy i loopbacki z `/etc/router/ifaces.conf` | uruchamia się przy każdym starcie VPP (także po automatycznym restarcie) |
| 4 | `@@BIRDUNIT@@.service` | BGP (w netns dataplane), startuje po odtworzeniu interfejsów | restartuje się razem z VPP; po awarii restart po 5 s |
| 5 | `snmpd-dataplane.service` | SNMP dla LibreNMS (UDP 161 w netns dataplane) | restart |
| 6 | `vpp-snmp-agent.service` | liczniki interfejsów VPP → SNMP (AgentX), opisy z ifaces.conf | restart po 5 s |
| 7 | `hsflowd.service` | eksport sFlow do kolektora | — |
| 8 | `router-monitor.service` | alarmy obciążenia w czasie rzeczywistym | restart po 5 s |
| 9 | `router-notify.service` | wysyła alarmy e-mailem (kolejka `/var/spool/router-notify`) | restart po 10 s |
| 10 | `router-bootcheck.service` | po starcie: wykrywa nieczysty restart / kernel panic, sprawdza usługi, wynik do logu i e-mailem | przy starcie i zamknięciu systemu |
| — | `router-ifaces-check.timer` | co 5 min: czy VPP zgadza się z ifaces.conf (rozjazd → alarm) | — |
| — | `mdmonitor` / `smartd` | zdarzenia RAID / zdrowie dysków | — |
| — | `irqbalance` | przerwania z pominięciem rdzeni VPP | — |

Polecenia:

```
systemctl status router.target                 # stan całości
systemctl list-dependencies router.target      # co wchodzi w skład
systemctl restart vpp                          # restart VPP (BIRD zrestartuje się razem z nim → sesje BGP wstaną od nowa)
systemctl restart @@BIRDUNIT@@                         # sam BIRD
journalctl -u vpp -u @@BIRDUNIT@@ -b                   # logi od ostatniego startu
```

Uwaga: restart VPP zawsze oznacza krótką przerwę w ruchu i ponowne zestawienie sesji BGP.

Pakiety VPP i BIRD są zablokowane przed automatyczną aktualizacją (`apt-mark hold`), żeby zwykłe `apt upgrade` nie zrestartowało routera. Aktualizacja świadomie, w oknie serwisowym — patrz rozdział 12.

---

## 3. Pliki i katalogi

| Ścieżka | Zawartość |
|---|---|
| `/opt/router/README.md` | ta dokumentacja |
| `/opt/router/install-router.sh` | kopia skryptu instalacyjnego (`router-check` = `install-router.sh --check`; aktualizacja programów: `upgrade_script`) |
| `/etc/router/version` | wersja skryptu zainstalowana na routerze i daty instalacji/aktualizacji |
| `/opt/router/bin/router-monitor` | monitor obciążenia (Python) |
| `/opt/router/bin/router-alert` | alarm przy awarii usługi (wołany przez systemd) |
| `/opt/router/bin/mdadm-alert` | alarm przy zdarzeniu RAID (wołany przez mdadm) |
| `/opt/router/bin/router-bootcheck` | kontrola po starcie systemu, wykrywanie nieczystego restartu |
| `/opt/router/bin/router-notify` | wysyłka alarmów e-mailem (SMTP) |
| `/opt/router/bin/smartd-alert` | alarm z smartd (zdrowie dysków) |
| `/opt/router/bin/router-fw` | firewall tranzytu VPP (`router-fw check / diff / apply / block / counters`), konfiguracja `/etc/router/firewall.conf` |
| `/opt/router/bin/router-guard` | ochrona przed odbiciami SYN-ACK/RST/UDP w VPP (`router-guard on / off / status / enforce`), konfiguracja `/etc/router/synack-guard.conf` |
| `/opt/router/bin/router-fw-update` | ręczna aktualizacja firmware karty (`router-fw-update`) |
| `/opt/router/bin/router-ifaces` | interfejsy z `ifaces.conf` (`router-ifaces`, rozdział 10) |
| `/opt/router/vpp-snmp-agent/` | agent SNMP dla VPP |
| `/etc/router/ifaces.conf` | **interfejsy: porty, VLAN-y, adresy IPv4/IPv6, loopbacki, opisy** (edytujesz Ty) |
| `/etc/router/snmp-ifaces.yaml` | opisy dla SNMP (ifAlias) — generowany przez `router-ifaces`, nie edytuj |
| `/etc/router/router.env` | parametry instalacji (porty, rdzenie, community SNMP) |
| `/etc/router/router-monitor.conf` | progi alarmów router-monitor |
| `/etc/router/notify.conf` | SMTP i odbiorcy alarmów (tylko root, poza historią etckeeper — zawiera hasło) |
| `/etc/router/hardware-audit.md` | wynik audytu sprzętu z instalacji |
| `/etc/vpp/startup.conf` | konfiguracja VPP (rdzenie, pamięć, porty, linux-cp) |
| `/etc/vpp/bootstrap.vpp` | polecenia VPP po starcie (MTU 1500, porty up, sFlow) |
| `/etc/bird/bird.conf`, `/etc/bird/conf.d/` | BIRD (sesje BGP dokłada skrypt sieciowy w `conf.d/`) |
| `/etc/snmp/snmpd.conf` | SNMP (community, AgentX, extend mdadm) |
| `/etc/hsflowd.conf` | kolektor sFlow |
| `/etc/systemd/system/router.target` | grupa usług routera |
| `/etc/systemd/system/*.service`, `*.service.d/` | jednostki i nakładki systemd |
| `/etc/sysctl.d/81-vpp-router.conf`, `82-router-neigh.conf` | hugepages, bufory netlink, tablice ARP/ND |
| `/etc/default/grub.d/90-vpp.cfg` | izolacja rdzeni VPP |
| `/etc/modules-load.d/mlx5-dpdk.conf` | moduły mlx5/RDMA |
| `/etc/mdadm/mdadm.conf` | `PROGRAM /opt/router/bin/mdadm-alert` |
| `/etc/smartd.conf` | `-M exec /opt/router/bin/smartd-alert` |
| `/etc/sysctl.d/83-router-panic.conf` | restart po kernel panic / oops / zawieszeniu kernela |
| `/etc/systemd/system.conf.d/90-router-watchdog.conf` | watchdog sprzętowy (restart przy całkowitym zawieszeniu) |
| `/etc/tmpfiles.d/router-cpu.conf` | governor `performance`, turbo |
| `/var/lib/router/` | znaczniki czystego wyłączenia (wykrywanie awarii), stan `router-ifaces` (`ifaces.state.json`, `ifaces.last-good.conf`) |
| `/var/spool/router-notify/` | kolejka alarmów do wysłania e-mailem |
| `/var/log/router-monitor/` | logi alarmów (60 dni, rotacja dzienna) |
| `@@DATADIR@@/` | źródła, paczki .deb, logi instalacji, kopie oryginałów, `MANIFEST.txt` |

Pełna lista każdego zapisanego pliku, usługi i pakietu: `@@DATADIR@@/MANIFEST.txt`.

---

## 4. Logi

| Co | Gdzie |
|---|---|
| Alarmy routera (monitor, awarie usług, RAID, kontrola po starcie) | `/var/log/router-monitor/router-monitor.log` oraz syslog/journal, facility `local0` |
| Zmiany interfejsów (każde polecenie vppctl z wynikiem) | `/var/log/router-monitor/router-ifaces.log` |
| VPP | `/var/log/vpp/vpp.log`, `journalctl -u vpp` |
| BIRD | syslog (`journalctl -u @@BIRDUNIT@@`) |
| Instalacja | `@@DATADIR@@/logs/install.log` + osobny log każdego etapu |

Alarmy wysyłane są do sysloga z facility `local0`. Jeśli przekierujesz syslog na zewnętrzny serwer (np. rsyslog → LibreNMS), alarmy pojawią się też tam:

```
# /etc/rsyslog.d/90-remote.conf
local0.*  @adres-serwera-syslog:514
```

Bieżący stan monitora (odświeżany co sekundę): `/run/router-monitor/state.json`.

---

## 5. router-monitor — co robi i jak czytać jego komunikaty

### Po co

Workery VPP zawsze pokazują 100% CPU, bo bez przerwy odpytują kartę. Dlatego `top` i SNMP nie mówią nic o rzeczywistym obciążeniu, a do tego SNMP uśrednia dane do kilku minut — krótki DDoS ginie. router-monitor co sekundę czyta wewnętrzne statystyki VPP i zapisuje zdarzenia do logu, podobnie jak ASR loguje przeciążenia QFP.

### Co mierzy

| Miara | Skąd | Co znaczy |
|---|---|---|
| Rozmiar wektora workera | `/sys/vector_rate_per_worker` w VPP | Ile pakietów VPP obrabia naraz: ~1 = luz, 256 = pełne nasycenie rdzenia. Najlepszy wskaźnik obciążenia VPP. |
| rx-miss + rx-no-buf | liczniki interfejsów VPP | Pakiety, które karta odebrała, ale VPP nie zdążył ich zabrać (albo zabrakło buforów). **To jest realna utrata ruchu** — odpowiednik dropów QFP. |
| Odrzucenia sprzętowe karty | `vppctl show hardware-interfaces` (liczniki `*discard*`, `*out_of_buffer*`) co 10 s | Karta odrzuca pakiety sama (limit karty/PCIe lub przepełnienie). |
| Punt | licznik `/if/punt` | Ruch kierowany do samego routera (BGP, SSH, ICMP). Duża wartość = atak na control plane. |
| Rdzenie systemowe | `/proc/stat` (rdzenie poza VPP) | Zajętość rdzeni BIRD/SNMP/systemu, np. przy przeliczaniu pełnej tablicy BGP. |
| Heartbeat VPP | `/sys/heartbeat` | Czy VPP żyje. Brak przez @@HANG@@ s = zawieszenie. |
| RAID | `/proc/mdstat` co 10 s | Degradacja i odbudowa macierzy. |

### Komunikaty

Format jak w syslogu Cisco: `%OBSZAR-POZIOM-ZDARZENIE: opis`. Poziom: 1 = alarm krytyczny, 2 = krytyczny, 3 = błąd, 4 = ostrzeżenie, 5 = informacja ważna, 6 = informacja.

| Komunikat | Znaczenie | Co zrobić |
|---|---|---|
| `%VPP-4-LOAD_HIGH` | wektor workera ≥ `VEC_WARN` | obserwować; przy częstych wystąpieniach rozważyć więcej workerów |
| `%VPP-2-LOAD_CRITICAL` | wektor ≥ `VEC_CRIT`, VPP blisko nasycenia | sprawdzić, czy to atak (sFlow/FastNetMon), ewentualnie blackhole |
| `%VPP-5-LOAD_NORMAL` | koniec przeciążenia, z czasem trwania i szczytem | — |
| `%VPP-2-RX_MISS` | karta gubi pakiety, VPP nie nadąża | to już utrata ruchu: zidentyfikować cel ataku, RTBH/Flowspec u upstreamu |
| `%VPP-3-NIC_DISCARD` | karta odrzuca pakiety sprzętowo | limit karty/PCIe; przy stałym występowaniu — ConnectX-5 |
| `%VPP-4-PUNT_HIGH` | dużo ruchu do adresów routera | sprawdzić ACL i policer na control plane |
| `%VPP-2-DOWN` / `%VPP-5-UP` | brak dostępu do statystyk VPP / powrót | zwykle restart VPP; patrz `journalctl -u vpp` |
| `%VPP-1-HANG` | VPP żyje, ale nie odpowiada | monitor sam zrestartuje VPP (`HANG_RESTART=1`) |
| `%VPP-6-STATS` | co minutę: szczyty z ostatniej minuty | historia obciążenia z dokładnością do minuty |
| `%SYS-4-CPU_HIGH` | rdzeń systemowy zajęty ≥ `HK_CPU_PCT`% przez `HK_CPU_SECONDS` s | zwykle przeliczanie tras BGP; jeśli trwa długo — sprawdzić BIRD |
| `%SYS-2-SERVICE_FAIL` | usługa (VPP/BIRD) padła, systemd ją restartuje | sprawdzić `journalctl -u <usługa>`, core dump: `coredumpctl` |
| `%SYS-1-SERVICE_DOWN` | usługa nie wstaje mimo restartów | interwencja: konsola iDRAC lub eth2 |
| `%SYS-5-BOOT_OK` / `%SYS-2-BOOT_PROBLEM` | wynik kontroli po starcie serwera | przy BOOT_PROBLEM: `router-check` |
| `%SYS-1-KERNEL_PANIC` | poprzedni start zakończył się awarią kernela, serwer wstał sam | przeczytać zapis w `/var/lib/systemd/pstore/`, zgłosić/zaktualizować kernel |
| `%SYS-1-UNCLEAN_REBOOT` | poprzedni start nie zakończył się normalnie (zasilanie, watchdog, panic bez zapisu) | sprawdzić iDRAC (Lifecycle Log), zasilacze, `journalctl -b -1` |
| `%SMART-2-…` | smartd zgłasza problem z dyskiem | przygotować wymianę dysku |
| `%SYS-6-MAIL_SENT` / `%SYS-3-MAIL_FAIL` / `%SYS-4-MAIL_LIMIT` | wysyłka e-maili: wysłano / błąd SMTP / limit na godzinę | przy MAIL_FAIL sprawdzić `/etc/router/notify.conf`, `router-notify test` |
| `%MD-1-DEGRADEDARRAY`, `%MD-1-FAIL` | macierz zdegradowana / dysk padł | wymienić dysk, `mdadm --manage /dev/mdX --add /dev/sdY` |
| `%MD-5-REBUILD20` … | postęp odbudowy RAID | — |

Każde zdarzenie jest logowane na początku, potem co `REPEAT_EVERY` s przypomnienie („trwa Ns”), a na końcu linia `*_NORMAL`/`*_END` z czasem trwania i wartością szczytową. Przykład krótkiego DDoS:

```
%VPP-4-LOAD_HIGH: worker 1 (cpu 5) wektor 100/256, pętle 90.0k/s, workery>64: 12/12
%VPP-2-RX_MISS: utrata pakietów na wejściu: hu0 2.00M pkt/s (VPP nie nadąża lub brak buforów); rx 30.00M pps / 168.00Gb/s
%VPP-2-LOAD_CRITICAL: worker 1 (cpu 5) wektor 200/256 … (eskalacja po 2s)
%VPP-5-LOAD_NORMAL: koniec po 8s, szczyt: worker 1 (cpu 5) wektor 200/256 …
%VPP-6-STATS: szczyty 60s: wektor 200 (worker 1), rx 30.00M pps / 168.00Gb/s, rx-miss 4000000 pkt, …
```

### Progi

Plik `/etc/router/router-monitor.conf`. Po zmianie: `systemctl restart router-monitor`.
Wartości startowe są szacunkowe — po teście obciążeniowym (TRex) warto je dopasować do realnego zachowania tego serwera.

---

## 6. Automatyczne restarty i alarmy usług

- **VPP**: `Restart=always`, 5 s przerwy, maksymalnie 5 prób w 10 minut. Każda awaria → `%SYS-2-SERVICE_FAIL`. Po wyczerpaniu prób → `%SYS-1-SERVICE_DOWN`.
- **BIRD**: związany z VPP (`BindsTo=vpp.service`). Gdy VPP się restartuje, BIRD też — sesje BGP zestawiają się od nowa, trasy wracają do VPP. Sam BIRD po awarii wstaje po 5 s.
- **Zawieszenie VPP** (proces żyje, nie odpowiada): wykrywa router-monitor po @@HANG@@ s i restartuje VPP (wyłączenie: `HANG_RESTART=0`).
- **Kontrola po starcie**: `router-bootcheck` czeka do 3 minut, aż wszystkie usługi wstaną, sprawdza porty VPP i BIRD, i zapisuje `%SYS-5-BOOT_OK` albo `%SYS-2-BOOT_PROBLEM` z listą problemów.

---

## 7. Powiadomienia e-mail

Każdy alarm (router-monitor, awaria usługi, RAID, smartd, kontrola po starcie, kernel panic) trafia do kolejki `/var/spool/router-notify/`, a usługa `router-notify` wysyła go mailem przez wskazany serwer SMTP. Mail idzie portem zarządzającym (eth2), więc działa także wtedy, gdy VPP leży.

Konfiguracja: `/etc/router/notify.conf` (tylko root, poza historią etckeeper, bo zawiera hasło):

```
ALERT_EMAILS="noc@firma.pl, dyzurny@firma.pl"
SMTP_HOST=smtp.firma.pl
SMTP_PORT=587
SMTP_SECURITY=starttls        # starttls (587) | ssl (465) | none (25)
SMTP_USER=router@firma.pl
SMTP_PASS="hasło"
SMTP_FROM=router@firma.pl
MAIL_SEND="CRASH SERVICES BOOT RAID DISKS NIC_FW VPP_STATE VPP_DROPS VPP_LOAD VPP_PUNT SYS_CPU IFACES FIREWALL OTHER"
MAIL_SEND_CLEAR=yes           # yes = wysyłaj też zakończenia zdarzeń (np. LOAD_NORMAL z czasem trwania)
MAIL_MAX_SEV=5                # wysyłane poziomy 1..5
MAIL_MIN_INTERVAL=60          # zdarzenia w ciągu 60 s idą jednym mailem
MAIL_MAX_PER_HOUR=30          # limit maili na godzinę (nadmiar zbiorczo w następnym)
```

Zmiany działają w ciągu 5 sekund (bez restartu). Test: `router-notify test`. Bieżący wybór: `router-notify categories`.

**Co wysyłać mailem — kategorie (`MAIL_SEND`):**

| Kategoria | Zdarzenia |
|---|---|
| `CRASH` | `%SYS-1-KERNEL_PANIC`, `%SYS-1-UNCLEAN_REBOOT` |
| `SERVICES` | `%SYS-2-SERVICE_FAIL`, `%SYS-1-SERVICE_DOWN` (VPP, BIRD) |
| `BOOT` | `%SYS-5-BOOT_OK`, `%SYS-2-BOOT_PROBLEM` |
| `RAID` | `%MD-…` (awaria dysku, degradacja, odbudowa) |
| `DISKS` | `%SMART-…` (zdrowie dysków) |
| `NIC_FW` | `%SYS-5-NIC_FW_UPDATED`, `%SYS-3-NIC_FW_FAIL` |
| `VPP_STATE` | `%VPP-2-DOWN`, `%VPP-5-UP`, `%VPP-1-HANG` |
| `VPP_DROPS` | `%VPP-2-RX_MISS`, `%VPP-3-NIC_DISCARD` |
| `VPP_LOAD` | `%VPP-4-LOAD_HIGH`, `%VPP-2-LOAD_CRITICAL` |
| `VPP_PUNT` | `%VPP-4-PUNT_HIGH` |
| `SYS_CPU` | `%SYS-4-CPU_HIGH` |
| `FIREWALL` | `%FW-5-APPLIED`, `%FW-4-DRIFT`, `%FW-2-CONFIG_ERROR`, `%FW-5-BLOCK` (rozdział 10a) |
| `IFACES` | `%IFACE-5-CONFIG_APPLIED`, `%IFACE-4-DRIFT`, `%IFACE-2-CONFIG_ERROR`, `%IFACE-3-APPLY_FAIL` (rozdział 10) |
| `STATS` | `%VPP-6-STATS` co minutę — zwykle nie chcesz tego mailem |
| `OTHER` | wszystko, co nie pasuje do powyższych |
| `ALL` | wszystkie kategorie |

Przykład — tylko poważne rzeczy, bez zakończeń: `MAIL_SEND="CRASH SERVICES RAID DISKS VPP_DROPS"`, `MAIL_SEND_CLEAR=no`.

Zasady, żeby nie zasypać skrzynki przy DDoS:

- pierwsze zdarzenie po okresie ciszy idzie od razu; kolejne w ciągu `MAIL_MIN_INTERVAL` są zbierane w jeden mail,
- wysyłane są zgłoszenia, eskalacje i zakończenia zdarzeń (z czasem trwania i szczytem); przypomnienia „trwa Ns” i minutowe `%VPP-6-STATS` nie,
- temat maila pokazuje najpoważniejsze zdarzenie i liczbę pozostałych, np. `[@@HOSTSHORT@@] KRYTYCZNE: %VPP-2-RX_MISS (+3)`,
- przy błędzie SMTP zdarzenia czekają w kolejce, ponowna próba co 1–10 minut; błąd trafia do logu jako `%SYS-3-MAIL_FAIL`.

---

## 8. Kernel panic, zawieszenia, watchdog

Router ma sam wstać po każdej awarii systemu:

| Sytuacja | Co się dzieje |
|---|---|
| kernel panic | restart po @@PANICSEC@@ s — ustawione w linii kernela (`panic=@@PANICSEC@@`, działa od pierwszej sekundy startu) i w sysctl (`kernel.panic`) |
| kernel oops (błąd w kernelu) | traktowany jak panic → restart (`oops=panic`, `kernel.panic_on_oops=1`) |
| zawieszenie kernela (soft/hard lockup) | panic → restart (`kernel.softlockup_panic`, `kernel.hardlockup_panic`) |
| całkowite zawieszenie (kernel nie zdąży zgłosić paniki) | watchdog sprzętowy: systemd przestaje go odświeżać → płyta restartuje serwer po @@WDSEC@@ s |
| awaria VPP / BIRD | systemd restartuje usługę (rozdział 6) |

Po każdym takim restarcie `router-bootcheck` wykrywa, że poprzedni start nie zakończył się normalnym wyłączeniem, i wysyła `%SYS-1-UNCLEAN_REBOOT`, a jeśli zachował się zapis paniki (UEFI pstore) — `%SYS-1-KERNEL_PANIC` z pierwszą linią błędu. Zapisy paniki: `/var/lib/systemd/pstore/`, logi poprzedniego startu: `journalctl -b -1` (journal jest trwały).

Sprawdzenie ustawień: `sysctl kernel.panic kernel.panic_on_oops`, `systemctl show -p RuntimeWatchdogUSec`, `ls /dev/watchdog*`.

---

## 9. Audyt sprzętu (z instalacji)

Na początku każdej instalacji skrypt robi pełny audyt: firmware serwera, ustawienia BIOS (bezpośrednio z iDRAC przez Redfish, jeśli podasz `IDRAC_HOST/USER/PASS`; inaczej wnioskowane z Linuksa), procesory, Hyper-Threading, NUMA, pamięć (każdy moduł, kanały, taktowanie, błędy ECC), karta (model, PSID, PCIe, firmware), dyski i RAID, zasilacze i temperatury (IPMI). Na tej podstawie dobiera konfigurację VPP i wypisuje zalecenia: WYMAGANE / ZALECANE / OPCJONALNE, z dokładnym miejscem w BIOS.

Sam audyt, bez instalacji: `install-router --audit`. Pełny raport: `/etc/router/hardware-audit.md`.

`AUTO` = skrypt zmienił ustawienie sam, `WARN` = wymaga działania (zwykle w BIOS).

**Hyper-Threading — wyłączyć.** Worker VPP potrzebuje całego rdzenia fizycznego. Drugi wątek dzieli z nim cache i jednostki wykonawcze, nie dodaje przepustowości VPP, a zwiększa wahania opóźnień. Na tym serwerze rdzeni fizycznych jest dość. BIOS: System BIOS → Processor Settings → Logical Processor = Disabled. Dopóki HT jest włączony, skrypt dodaje `nosmt` do kernela.

@@AUDIT@@

Dodatkowe parametry kernela dodane automatycznie: `@@EXTRACMD@@`.

---

## 10. Interfejsy: VLAN-y, adresy, loopback (`/etc/router/ifaces.conf`)

Cała konfiguracja interfejsów jest w jednym pliku. Edytujesz plik, potem `router-ifaces apply` — skrypt porównuje plik z tym, co jest w VPP, i wykonuje **tylko różnice** (jak `commit` na routerze).

```
# interfejs  vlan  ipv4                ipv6                   opis
hu0          -     -                   -                      Port 100G: trunk VLAN do switcha
hu0          100   192.0.2.2/30        2001:db8:100::2/64     Transit: EPIX AS62081
hu0          200   198.51.100.2/30     -                      Transit: Upstream-2 10G
hu0          300   10.255.0.1/30       -                      Core: ASR1001-X BNG
loop0        -     203.0.113.1/32      2001:db8::1/128        Loopback: router-id, BGP, SNMP
```

| Kolumna | Znaczenie |
|---|---|
| interfejs | port VPP (`hu0`, `hu1`) albo loopback (`loop0`, `loop1`, …) |
| vlan | numer VLAN 1–4094 (802.1Q); `-` = sam port albo loopback |
| ipv4, ipv6 | adres z maską; kilka adresów po przecinku; `-` = brak |
| opis | reszta linii; trafia do SNMP (ifAlias = opis portu w LibreNMS/Cacti) i do `ip link` w netns `dataplane` |

Polecenia:

```
router-ifaces            # tabela: stan, MTU, adresy, opisy (jak "show interfaces description")
router-ifaces diff       # podgląd: co się zmieni (nic nie zmienia)
router-ifaces apply      # zastosuj: pokazuje zmiany i pyta t/N  (-y bez pytania)
router-ifaces check      # czy VPP zgadza się z ostatnio zastosowaną konfiguracją
router-ifaces render     # cała konfiguracja jako polecenia vppctl
```

Co robi `apply`:

- **Nowa linia** → tworzy VLAN (`create sub-interfaces … exact-match`) albo loopback, podnosi go i nadaje adresy. Odpowiednik w Linuksie (netns `dataplane`, ta sama nazwa, np. `hu0.100`) powstaje automatycznie, więc BIRD od razu widzi interfejs.
- **Usunięty adres** → znika z VPP i z Linuksa (sesje BGP z tego adresu się zerwą — `diff` to pokazuje).
- **Usunięta linia** → VLAN lub loopback jest kasowany. Dotyczy tylko obiektów, które utworzył `router-ifaces`; utworzone ręcznie przez `vppctl` są oznaczone `?` i pozostają nietknięte.
- **Zmieniony opis** → nowy ifAlias w SNMP (krótki restart `vpp-snmp-agent`, ruch bez zmian) i alias w Linuksie.
- Plik jest jedynym źródłem prawdy: adres dodany ręcznie (`vppctl`, `ip addr`) na interfejsie z pliku zostanie przy `apply` usunięty.
- Przed zmianami cały plik jest sprawdzany: numery VLAN, poprawność adresów, adresy sieci/rozgłoszeniowe, nakładające się podsieci, istnienie portu, duplikaty. **Jeden błąd = nic nie jest zmieniane.**

Po restarcie:

- VPP po starcie jest pusty. `router-ifaces.service` uruchamia się przy każdym starcie VPP — także po automatycznym restarcie po awarii — odtwarza konfigurację z pliku i dopiero potem startuje BIRD.
- `ifaces.conf` jest jednocześnie konfiguracją startową: zmiany zapisane, ale niezastosowane, wejdą przy najbliższym starcie VPP.
- Jeśli przy starcie plik zawiera błąd, użyta zostanie ostatnia poprawnie zastosowana wersja (`/var/lib/router/ifaces.last-good.conf`) i pójdzie alarm `%IFACE-2-CONFIG_ERROR`.

Wykrywanie rozjazdu: co 5 minut `router-ifaces-check.timer` porównuje VPP z ostatnio zastosowaną konfiguracją. Gdy ktoś zmieni coś ręcznie albo odtworzenie się nie uda, w logu pojawi się `%IFACE-4-DRIFT` (raz, z listą różnic), a po naprawie `%IFACE-5-DRIFT_END`. Sama edycja pliku bez `apply` nie jest rozjazdem — w logu jest tylko informacja `%IFACE-6-PENDING`.

| Komunikat | Znaczenie |
|---|---|
| `%IFACE-5-CONFIG_APPLIED` | zastosowano zmiany (utworzone/usunięte interfejsy, adresy, opisy) |
| `%IFACE-6-RESTORED` | konfiguracja odtworzona po starcie VPP |
| `%IFACE-4-DRIFT` / `%IFACE-5-DRIFT_END` | VPP różni się od pliku / znów zgodny |
| `%IFACE-6-PENDING` | plik zmieniony, jeszcze nie zastosowany |
| `%IFACE-2-CONFIG_ERROR` | przy starcie plik miał błąd — użyto ostatniej poprawnej wersji |
| `%IFACE-3-APPLY_FAIL`, `%IFACE-2-APPLY_FAIL` | części zmian nie dało się zastosować / VPP nie odpowiadał |

Szczegóły każdej zmiany (polecenie vppctl i odpowiedź VPP): `/var/log/router-monitor/router-ifaces.log`. Historia samego pliku: etckeeper (`git -C /etc log -p router/ifaces.conf`).

Uwagi:

- LibreNMS grupuje porty według początku opisu: `Transit:`, `Peering:`, `Core:`, `Cust:` (menu Ports → Transit/Peering/Core/Customers).
- Adres na loopbacku nadaje się na router-id BGP i na adres, pod którym LibreNMS odpytuje SNMP. SSH działa w domyślnej przestrzeni (eth2), więc na adresy w VPP na razie nie odpowiada.
- **MTU**: wszystkie porty i VLAN-y mają standardowe MTU Ethernet **1500**. VPP ustawia je na portach raz, przy starcie, zanim port zostanie podniesiony (`/etc/vpp/bootstrap.vpp`); VLAN-y i interfejsy w Linuksie dziedziczą je od portu. `router-ifaces` nigdy nie zmienia MTU, a wpis `mtu=` w pliku jest błędem.

---

## 10a. Firewall tranzytu (`router-fw`)

`router-fw` steruje filtrami ruchu **przechodzącego** przez router (ACL w VPP, tryb bezstanowy). Ruchu **do samego routera** (BGP, BFD, SNMP, ICMP) nie dotyka — to zadanie netfiltera w netns `dataplane`. SSH przez eth2 jest poza VPP, więc błąd w regułach nie odetnie dostępu do routera.

Reguły są w `/etc/router/firewall.conf` (w etckeeper). Strefa to nazwa nadana interfejsom, a kierunek mówi, czy reguła dotyczy ruchu wchodzącego z interfejsów strefy (`internet->`) czy wychodzącego do nich (`->internet`). Pierwsza pasująca reguła wygrywa, więc wyjątki (whitelist) stoją nad blokadą; co nie pasuje do żadnej reguły, przechodzi.

```
zone  hu0.100  internet                       # Transit: EPIX
zone  hu0.300  clients                        # Core: BNG
list  smtp-ok  203.0.113.25/32  203.0.113.26/32
->internet    permit  tcp  @smtp-ok  any  any  25     serwery poczty klientów
->internet    deny    tcp  any       any  any  25     blokada SMTP od klientów
internet->    deny    any  @bogony   any  any  any    bogony z internetu
internet->    deny    tcp  any       any  any  445    SMB z internetu
```

```
router-fw check                  # składnia, reguły zacienione, ostrzeżenia o BGP/BFD, rozjazd VPP
router-fw diff                   # co zmieni apply
router-fw apply                  # wdrożenie na żywo (różnicowo, bez restartu VPP)
router-fw apply --confirm 120    # j.w., ale zmiana wraca po 120 s, jeśli nie wpiszesz: router-fw confirm
router-fw block 198.51.100.7 2h  # blokada doraźna (źródło) w strefie "internet"; bez czasu = bezterminowo
router-fw unblock 198.51.100.7   # zdjęcie blokady;  router-fw blocks = lista
router-fw counters [-w]          # liczniki trafień każdej reguły: pakiety, bajty, pkt/s;  counters clear = zerowanie
```

Reguły wracają same po każdym starcie VPP (`router-fw.service`, przed BIRD). Gdy `firewall.conf` ma błąd, po starcie używana jest ostatnia poprawna wersja (`/var/lib/router/fw.last-good.conf`). Wygasłe blokady zdejmuje co minutę `router-fw-expire.timer`, a rozjazd VPP względem pliku wykrywa co 5 minut `router-fw-check.timer`.

| Zdarzenie w logu | Znaczenie |
|---|---|
| `%FW-5-APPLIED` | reguły zastosowane (lista zmian) |
| `%FW-2-CONFIG_ERROR` | błędy w `firewall.conf` (po starcie: użyto ostatniej poprawnej wersji) |
| `%FW-3-APPLY_FAIL` | VPP odrzucił polecenie; szczegóły w `/var/log/router-monitor/router-fw.log` |
| `%FW-4-DRIFT` / `%FW-5-DRIFT_END` | VPP różni się od pliku (np. ręczna zmiana) / znów zgodny |
| `%FW-5-BLOCK`, `%FW-5-UNBLOCK`, `%FW-5-BLOCK_EXPIRED` | blokady doraźne |
| `%FW-4-ROLLBACK` | `apply --confirm` nie został potwierdzony, przywrócono poprzednią wersję |

`block`, `unblock` i wygasanie blokad wgrywają **ostatnio zastosowaną** konfigurację (`fw.last-good.conf`) razem z blokadami — niezatwierdzona edycja `firewall.conf` nie wchodzi w życie przy okazji blokady. `apply --confirm` bez `confirm` (albo restart VPP w trakcie oczekiwania) przywraca poprzednią wersję także w pliku `firewall.conf`; odrzucona wersja zostaje w `/var/lib/router/fw.rejected.conf`. Listy z `include` są zapisywane w `last-good` w postaci rozwiniętej, więc cofnięcie nie zależy od późniejszych zmian w plikach list.

Liczniki działają, gdy w pliku jest `set counters on` (domyślnie); VPP zeruje liczniki listy ACL przy każdej zmianie jej reguł. Alarmy e-mail: kategoria `FIREWALL` w `router-notify` (na routerach zainstalowanych wcześniej dopisz ją do `MAIL_SEND` w `/etc/router/notify.conf`; do tego czasu zdarzenia `%FW-` trafiają do kategorii `OTHER`).

---

## 10b. Ochrona przed odbiciami (`router-guard`)

`router-guard` włącza na żądanie, dla wskazanych prefiksów lub adresów, filtr w VPP (wtyczka `synack_guard`, DPDK), który odrzuca „odpowiedzi bez pytania” przychodzące z internetu: **SYN-ACK** (opcjonalnie **RST**) bez SYN wysłanego z chronionego prefiksu oraz **UDP ze źródłowych portów amplifikacji** (DNS, NTP, CLDAP, SSDP, memcached…) bez wcześniejszego pakietu UDP do takiego portu. Nowe połączenia przychodzące (sam SYN), ACK i dane TCP nie są filtrowane, więc P2P, gry, VoIP, VPN i serwery działają normalnie. Poza włączoną ochroną filtr nie jest w ścieżce pakietów i nie kosztuje nic.

Warunek: R630 musi widzieć oba kierunki połączeń chronionego prefiksu (SYN wychodzący i odpowiedź wracająca). Dlatego zawsze zaczynaj od trybu monitor.

```
router-guard on 203.0.113.0/24 --monitor        # uczenie i liczenie, nic nie jest odrzucane (domyślnie)
router-guard status                             # naruszenia przy normalnym ruchu powinny być bliskie zeru
router-guard enforce                            # odrzucaj (albo od razu: on ... --enforce = monitor 60 s, potem enforce)
router-guard on web --enforce --for 2h          # grupa z pliku, automatyczne wyłączenie po 2 h
router-guard off 203.0.113.0/24                 # zdejmij jeden prefiks;  router-guard off = wszystko
```

Konfiguracja w osobnym pliku `/etc/router/synack-guard.conf` (interfejsy uplinków `in-if` i strony klientów `out-if`, grupy prefiksów, TTL, `tcp-rst`, `udp-ports`, `udp-frags`, rozmiary tablic). Stan włączenia przeżywa restart VPP (`router-guard.service`: po starcie monitor, po rozgrzewce enforce). Zdarzenia: `%GUARD-5-ON/OFF/MODE/EXPIRED`, `%GUARD-4-VIOLATIONS` (naruszeń na sekundę ponad `alarm-pps`), `%GUARD-4-DRIFT`, `%GUARD-2-TABLE_FULL` (tablica zapełniona: automatyczny powrót do monitora). Liczniki: `router-guard status` albo `vppctl show errors` (węzły `synack-guard-*`).

Wtyczka jest budowana razem z VPP (etap 10). Na routerze zainstalowanym wcześniej wymaga `install-router.sh --from 10` (30–60 min) i restartu VPP; do tego czasu `router-guard` zgłasza, że wtyczka nie jest załadowana. Odpowiedź na atak większy niż pojemność łączy upstreamowych to nadal RTBH lub Flowspec u upstreamów.

---

## 11. Codzienna obsługa

```
router-check                          # pełna kontrola
router-ifaces                         # interfejsy: stan, adresy, opisy (rozdział 10)
vppctl show interface                 # porty i liczniki
vppctl show hardware-interfaces hu0   # szczegóły karty, liczniki sprzętowe
vppctl show runtime                   # obciążenie workerów (kolumna Vectors/Call)
vppctl show sflow
birdc show protocols                  # sesje BGP (birdc działa z każdego miejsca)
birdc show route count
ip netns exec dataplane ip addr       # interfejsy widziane przez BIRD/SNMP
ip netns exec dataplane snmpwalk -v2c -c <community> -On 127.0.0.1 1.3.6.1.2.1.31.1.1.1.1   # ifName
```

Community SNMP: `/etc/router/router.env` (zmienna `SNMP_COMMUNITY`). snmpd działa w netns `dataplane`, więc LibreNMS odpytuje router przez adres skonfigurowany w VPP — najlepiej loopback (`loop0` w `/etc/router/ifaces.conf`). Opisy portów w LibreNMS (ifAlias) pochodzą z kolumny opisu w `ifaces.conf`.

---

## 12. Zmiany, awarie, przywracanie

**Historia /etc (etckeeper).** Każda zmiana w `/etc` jest w gicie:

```
git -C /etc log --oneline            # historia
git -C /etc show <commit>            # co się zmieniło
git -C /etc checkout <commit> -- vpp/startup.conf    # przywrócenie jednego pliku
etckeeper commit "opis zmiany"       # własny commit po ręcznej zmianie
```

**Oryginały plików systemowych** sprzed instalacji: `@@DATADIR@@/backup/` (z zachowaniem ścieżek).

**VPP nie wstaje** — sprawdź po kolei:
1. `journalctl -u vpp -b` i `/var/log/vpp/vpp.log`
2. hugepages: `grep Huge /proc/meminfo` (po restarcie powinno być @@HUGEPAGES@@ stron)
3. moduły: `lsmod | grep -E 'mlx5_ib|ib_uverbs'`
4. karta: `ethtool -i <port>` (firmware ≥ 12.28)
5. `vpp -c /etc/vpp/startup.conf` ręcznie — pokaże błąd konfiguracji

**Firmware karty.** Skrypt przy instalacji pobiera narzędzie NVIDIA `mlxup` (zawiera obrazy firmware), robi kopię obecnego firmware i sprawdza dostępną wersję. Aktualizacja tylko ręcznie, w oknie serwisowym:

```
router-fw-update --check     # obecna i dostępna wersja
router-fw-update             # aktualizacja z obrazu w mlxup (pyta o potwierdzenie: TAK)
router-fw-update --online    # najnowszy firmware z serwera NVIDIA
systemctl reboot             # nowy firmware działa po restarcie
```

Kopie firmware i wyniki zapytań: `@@DATADIR@@/firmware/`. Karta z PSID zaczynającym się od `DEL` ma firmware Della — aktualizuj pakietem z dell.com/support.

**Ponowna instalacja / naprawa etapu**: `/opt/router/install-router.sh --from <nr>` (dane robocze w `@@DATADIR@@`).

**Aktualizacja programów routera (wersjonowanie).** Wersja skryptu (`SCRIPT_VERSION` na początku `install-router.sh`) jest zapisana na routerze w `/etc/router/version`. Po zmianie któregokolwiek z osadzonych programów (router-monitor, router-notify, router-ifaces, router-alert, router-bootcheck, mdadm-alert, smartd-alert, router-fw-update, router-check) wgraj nowy `install-router.sh` na router i uruchom:

```
./install-router.sh --version                 # wersja skryptu i wersja na routerze
./install-router.sh upgrade_script --dry-run  # co się zmieni (diff), bez zapisywania
./install-router.sh upgrade_script            # podmień tylko zmienione programy
```

Podmieniane są wyłącznie programy w `/opt/router/bin`, `router-check` i kopia skryptu w `/opt/router`. Konfiguracja (`ifaces.conf`, `notify.conf`, `router.env`, `bird.conf`, `startup.conf`), jednostki systemd, VPP i BIRD pozostają nietknięte — sesje BGP się nie przerywają. Skrypt najpierw sprawdza składnię wszystkich nowych programów, potem robi kopię starych w `@@DATADIR@@/backup/upgrade-<data>/`, podmienia pliki i restartuje tylko `router-monitor` i `router-notify`, jeśli ich programy się zmieniły. Wynik trafia do `router-monitor.log` (`%SYS-5-SCRIPTS_UPGRADED`) i do historii `/etc` (etckeeper).

**Aktualizacja VPP lub BIRD** (w oknie serwisowym):

```
apt-mark unhold bird3 && apt-get install bird3 && apt-mark hold bird3
# VPP: zmień VPP_VERSION w install-router.sh, potem:  install-router.sh --from 10
```

---

## 13. Parametry tej instalacji

| Parametr | Wartość |
|---|---|
| Karta | @@NICMODEL@@ |
| Porty Mellanox (PCI) | @@NIC@@ |
| Nazwy portów w VPP | @@IFNAMES@@ |
| Węzeł NUMA karty | @@NUMA@@ |
| Rdzeń główny VPP | @@MAIN@@ |
| Workery VPP | @@WORKERS@@ |
| Izolowane rdzenie | @@ISOL@@ |
| Wersja VPP | @@VPPVER@@ |
| Router ID BIRD | @@ROUTERID@@ (zmieni go skrypt sieciowy na adres loopbacka) |
| SNMP — dozwolone źródło | @@SNMPALLOW@@ |
| sFlow | 1:@@SAMPLING@@, kolektor: @@SFLOW@@ |
| Hugepages | @@HUGEPAGES@@ × 2 MB |
| Sterta VPP / bufory | @@HEAP@@ / @@BUFFERS@@ |
| Alarmy e-mail | @@MAILTO@@ |

---

## 14. Następny krok

Ten skrypt stawia platformę i interfejsy (`/etc/router/ifaces.conf`). Sesje BGP, filtry, RPKI i ochronę control plane dokłada skrypt sieciowy (pliki w `/etc/bird/conf.d/`).
READMEEOF
  readme=$(<"$STATE_DIR/README.template")
  readme=${readme//@@DATE@@/$(now)}
  readme=${readme//@@HOST@@/$(hostname -f 2>/dev/null || hostname)}
  readme=${readme//@@NIC@@/${NIC_PCI[*]}}
  readme=${readme//@@IFNAMES@@/${ifn[*]}}
  readme=${readme//@@NUMA@@/$NUMA}
  readme=${readme//@@MAIN@@/$MAIN_CORE}
  readme=${readme//@@WORKERS@@/$WORKERS_CSV}
  readme=${readme//@@ISOL@@/$ISOL_CSV}
  readme=${readme//@@VPPVER@@/$VPP_VERSION}
  readme=${readme//@@ROUTERID@@/$ROUTER_ID}
  readme=${readme//@@SNMPALLOW@@/$SNMP_ALLOW}
  readme=${readme//@@SFLOW@@/${SFLOW_COLLECTOR:-brak (uzupełnij /etc/hsflowd.conf)}}
  readme=${readme//@@SAMPLING@@/$SFLOW_SAMPLING}
  readme=${readme//@@BIRDUNIT@@/$bu}
  readme=${readme//@@DATADIR@@/$DATA_DIR}
  readme=${readme//@@HANG@@/30}
  readme=${readme//@@HUGEPAGES@@/$HUGEPAGES_2M}
  local hs; hs=$(hostname -s 2>/dev/null || hostname)
  readme=${readme//@@HOSTSHORT@@/$hs}
  readme=${readme//@@PANICSEC@@/$PANIC_REBOOT_SEC}
  readme=${readme//@@WDSEC@@/$WATCHDOG_SEC}
  readme=${readme//@@NICMODEL@@/$NIC_MODEL}
  readme=${readme//@@HEAP@@/$MAIN_HEAP}
  readme=${readme//@@BUFFERS@@/$BUFFERS}
  readme=${readme//@@EXTRACMD@@/${EXTRA_CMDLINE[*]:-brak}}
  readme=${readme//@@MAILTO@@/${ALERT_EMAILS:-$(sed -n 's/^ALERT_EMAILS="\(.*\)"$/\1/p' /etc/router/notify.conf 2>/dev/null)}}
  readme=${readme//@@AUDIT@@/$(tail -n +3 "$DATA_DIR/audit.md")}
  printf '%s\n' "$readme" | put_file /opt/router/README.md "pełna dokumentacja routera"

  say "kopia skryptu instalacyjnego do /opt/router"
  if [[ $(readlink -f "$0") != /opt/router/install-router.sh ]]; then
    install -m 755 "$(readlink -f "$0")" /opt/router/install-router.sh
  fi
  man_add file /opt/router/install-router.sh "kopia skryptu (naprawa: --from <nr>, kontrola: --check)"
  ln -sfn /opt/router/install-router.sh /usr/local/sbin/install-router
  prog_router_check \
    | put_file /usr/local/sbin/router-check "polecenie router-check (pełna kontrola stanu)" 755
  man_add file /usr/local/sbin/install-router "dowiązanie do /opt/router/install-router.sh"
  write_version install
  man_add file "$VERSION_FILE" "wersja skryptu zainstalowana na routerze (install-router --version)"
  man_add dir /opt/router "narzędzia routera, dokumentacja, kopia skryptu"
  ok "dokumentacja: /opt/router/README.md   kontrola: router-check"
}

st_report() {
  local p d fw
  for p in "${NIC_PCI[@]}"; do
    d=$(netdev_of "$p"); fw=""
    [[ -n $d ]] && fw=$(ethtool -i "$d" 2>/dev/null | awk '/firmware-version/{print $2}' || true)
    if [[ -n $fw ]] && [[ $(printf '%s\n%s\n' "$fw" "12.28.0" | sort -V | head -n1) != "12.28.0" ]]; then
      warn "$p: firmware $fw — zaktualizuj do 12.28.4704 (mstflint) przed produkcją"
    fi
  done
  {
    echo "=============================================================================="
    echo " RAPORT INSTALACJI ROUTERA — $(now)"
    echo " host: $(hostname)   skrypt: $(readlink -f "$0")"
    echo "=============================================================================="
    echo
    echo "PARAMETRY"
    echo "  Porty VPP:        $(join_by ' ' "${NIC_PCI[@]}")  → hu0..hu$(( ${#NIC_PCI[@]} - 1 ))"
    echo "  NUMA / rdzenie:   węzeł $NUMA, main $MAIN_CORE, workery $WORKERS_CSV"
    echo "  Router ID BIRD:   $ROUTER_ID"
    echo "  SNMP:             community w $ENV_FILE, dozwolone źródło $SNMP_ALLOW"
    echo "  sFlow:            1:$SFLOW_SAMPLING, kolektor ${SFLOW_COLLECTOR:-(brak)}"
    for kind in file service pkg dir backup other; do
      case $kind in
        file)    echo; echo "PLIKI KONFIGURACYJNE (ścieżka — opis — etap)";;
        service) echo; echo "USŁUGI SYSTEMD (nazwa — stan — opis)";;
        pkg)     echo; echo "ZAINSTALOWANE PAKIETY";;
        dir)     echo; echo "KATALOGI";;
        backup)  echo; echo "KOPIE ORYGINALNYCH PLIKÓW (przywrócenie: cp -a <kopia> <oryginał>)";;
        other)   echo; echo "INNE ZMIANY";;
      esac
      awk -F'\t' -v k="$kind" '$1==k {key=$2; last[key]=$0; if(!(key in seen)){seen[key]=1; order[++n]=key}}
        END{for(i=1;i<=n;i++){split(last[order[i]],f,"\t"); print f[2] "\t" f[4] "\t" f[3]}}' "$MAN_DB" 2>/dev/null \
      | while IFS=$'\t' read -r path desc st; do
          if [[ $kind == service ]]; then
            printf '  %-42s %-10s %s\n' "$path" "$(systemctl is-active "$path" 2>/dev/null || true)" "$desc"
          else
            printf '  %-50s %s  [etap %s]\n' "$path" "$desc" "${st%% *}"
          fi
        done
    done
    echo
    echo "DANE ROBOCZE ($DATA_DIR)"
    du -sh "$SRC_DIR" "$DEB_DIR" "$LOG_DIR" "$BACKUP_DIR" 2>/dev/null | sed 's/^/  /'
    echo
    echo "LOGI"
    echo "  całość:  $MAIN_LOG"
    ls -1 "$LOG_DIR"/[0-9]*.log 2>/dev/null | sed 's/^/  etap:    /'
    echo
    echo "PRZYDATNE POLECENIA"
    echo "  vppctl show interface | show hardware-interfaces | show runtime | show sflow"
    echo "  birdc show protocols   (BIRD działa w netns dataplane, birdc działa z każdego miejsca)"
    echo "  ip netns exec dataplane ip addr      (interfejsy linux-cp widziane przez BIRD/SNMP)"
    echo "  journalctl -u vpp -u $(bird_unit) -u snmpd-dataplane -u vpp-snmp-agent -u hsflowd"
    echo "  router-ifaces [diff|apply|check]     (interfejsy z /etc/router/ifaces.conf)"
    echo "  router-check                         (pełna kontrola stanu)"
    echo "  systemctl status router.target       (wszystkie usługi routera)"
    echo "  Dokumentacja: /opt/router/README.md"
  } >"$MANIFEST"
  cat "$MANIFEST"
  ok "raport zapisany: $MANIFEST"
  if command -v etckeeper >/dev/null; then etckeeper commit "install-router.sh: instalacja zakończona" >/dev/null 2>&1 || true; fi
}

run_stage 02 "Pakiety bazowe"                         st_packages
run_stage 03 "Historia /etc (etckeeper)"              st_etckeeper
run_stage 04 "Firmware karty: pobranie, kopia, router-fw-update" st_firmware
run_stage 05 "Moduły mlx5, sysctl, hugepages"         st_kernel
run_stage 06 "Izolacja rdzeni, taktowanie, panic (GRUB)" st_isolation
run_stage 07 "Odporność: kernel panic, watchdog"      st_resilience
run_stage 08 "Netns dataplane"                        st_netns
run_stage 09 "Konfiguracja VPP + automatyczny restart" st_vpp_config
run_stage 10 "VPP $VPP_VERSION — pobranie i kompilacja (30–60 min)" st_vpp_build
run_stage 11 "VPP — instalacja i start"               st_vpp_install
run_stage 12 "BIRD 3"                                 st_bird
run_stage 13 "Interfejsy: ifaces.conf + router-ifaces" st_ifaces
run_stage 14 "SNMP (snmpd + vpp-snmp-agent + mdadm)"  st_snmp
run_stage 15 "sFlow (hsflowd)"                        st_sflow
run_stage 16 "RAID i dyski (mdadm, smartd)"           st_raid
run_stage 17 "Powiadomienia e-mail (router-notify)"   st_notify
run_stage 18 "Monitor obciążenia (router-monitor)"    st_monitor
run_stage 19 "Usługi i autostart (router.target)"     st_services
FROM_STAGE=20
run_stage 20 "Dokumentacja (/opt/router)"             st_docs
run_stage 21 "Raport instalacji"                      st_report
run_stage 22 "Firewall tranzytu (router-fw)"          st_fw
run_stage 23 "Ochrona przed odbiciami (router-guard)"  st_guard

printf '\n%s[%s] INSTALACJA ZAKOŃCZONA.%s\n' "$c_ok" "$(now)" "$c_off"
cat <<EOF
  Dokumentacja:  /opt/router/README.md
  Raport:        $MANIFEST
  Kontrola:      router-check
  Alarmy:        tail -f /var/log/router-monitor/router-monitor.log
  Interfejsy:    edytuj /etc/router/ifaces.conf, potem: router-ifaces diff / router-ifaces apply

  Izolacja rdzeni i pełna pula hugepages działają dopiero po restarcie serwera.
  Po restarcie wszystkie usługi wstaną same (router.target), a router-bootcheck
  zapisze do logu %SYS-5-BOOT_OK albo %SYS-2-BOOT_PROBLEM.
EOF
if ((REBOOT_AFTER)); then
  printf '\n%sRestart serwera za 15 s (Ctrl+C przerywa)...%s\n' "$c_warn" "$c_off"
  sleep 15
  systemctl reboot
else
  echo "  TERAZ:  reboot      (albo uruchom skrypt z flagą --reboot)"
fi
