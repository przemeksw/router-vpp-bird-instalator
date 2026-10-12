#!/usr/bin/env bash
# Testy trybu upgrade_script (install-router.sh) — bez roota, bez routera, działa na macOS i Linuksie.
# Wyciąga z install-router.sh funkcje programów i do_upgrade, przekierowuje ścieżki do katalogu tymczasowego.
#   bash tests/test-upgrade.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/opt/router/bin" "$W/sbin" "$W/etc/router" "$W/var/log" "$W/data/backup"

# --- funkcje z install-router.sh, ścieżki systemowe przekierowane do $W
awk '/^# PROGRAMY routera/{f=1} /^if \[\[ \$MODE == upgrade \]\]/{f=0} f' install-router.sh \
  | sed -e "s#/opt/router#$W/opt/router#g" -e "s#/usr/local/sbin#$W/sbin#g" -e "s#/var/log/router#$W/var/log#g" -e "s#/etc/logrotate.d#$W/etc/logrotate.d#g" \
      -e "s#/etc/router/INSTRUKCJA.md#$W/etc/router/INSTRUKCJA.md#g" \
  >"$W/funcs.sh"
[[ -s $W/funcs.sh ]] || { echo "nie znaleziono funkcji upgrade w install-router.sh"; exit 1; }

# --- atrapy poleceń systemowych
cat >"$W/bin/systemctl" <<SH
#!/bin/sh
echo "systemctl \$*" >>"$W/systemctl.log"
[ "\$1" = is-active ] && { [ "\${2:-}" = --quiet ] && shift; case "\$2" in router-monitor.service|router-notify.service) exit 0 ;; *) echo inactive; exit 3 ;; esac; }
exit 0
SH
cat >"$W/bin/stat" <<SH
#!/bin/sh
# atrapa "stat -c %a <plik>" (macOS nie ma -c)
[ "\$1" = -c ] && exec python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "\$3"
exec /usr/bin/stat "\$@"
SH
printf '#!/bin/sh\nexit 0\n' >"$W/bin/logger"
chmod 755 "$W/bin/"*
export PATH="$W/bin:$PATH"

# harness: wywołuje do_upgrade w osobnym procesie (die = exit)
cat >"$W/run.sh" <<SH
now() { date '+%F %T'; }
say() { echo "  → \$*"; }; ok() { echo "  [OK] \$*"; }; warn() { echo "  [UWAGA] \$*"; }
die() { echo "  [BŁĄD] \$*"; exit 1; }
bird_unit() { echo bird; }
man_add() { :; }
put_file() { mkdir -p "\$(dirname "\$1")"; cat >"\$1"; }
c_ok=; c_warn=; c_err=; c_hdr=; c_dim=; c_off=
MLXUP_URLS=(http://a); NIC_PCI=(0000:82:00.0); DATA_DIR=$W/data; BACKUP_DIR=$W/data/backup
VERSION_FILE=$W/etc/router/version
ASSUME_YES=\${ASSUME_YES:-0}; DRY_RUN=\${DRY_RUN:-0}; SCRIPT_VERSION=\${SCRIPT_VERSION:-1.0.0}
source $W/funcs.sh
eval "\${OVERRIDE:-:}"
do_upgrade
SH
up() { env "$@" bash "$W/run.sh" 2>&1; }

pass=0 fail=0
t() {   # t <opis> <oczekiwany kod> <polecenie...>
  local name=$1 want=$2 out rc; shift 2
  out=$("$@" 2>&1); rc=$?
  if [[ $rc == "$want" ]]; then pass=$((pass + 1)); printf '  OK    %s\n' "$name"
  else fail=$((fail + 1)); printf '  BŁĄD  %s (kod %s, oczekiwano %s)\n' "$name" "$rc" "$want"; printf '%s\n' "$out" | sed 's/^/        /'; fi
}
has() { local o; o=$("${@:2}" 2>&1); grep -qF -- "$1" <<<"$o"; }

echo "6. upgrade_script"
t "pierwsze wgranie (pliki NOWE)"           0 up SCRIPT_VERSION=1.0.0
t "router-monitor zainstalowany"            0 test -x "$W/opt/router/bin/router-monitor"
t "router-check zainstalowany"              0 test -x "$W/sbin/router-check"
t "router-fw zainstalowany"                 0 test -x "$W/opt/router/bin/router-fw"
t "router-guard zainstalowany"              0 test -x "$W/opt/router/bin/router-guard"
t "router-top zainstalowany"                0 test -x "$W/opt/router/bin/router-top"
t "instrukcja w etc/router"                 0 grep -q 'instrukcja obsługi produkcyjnej' "$W/etc/router/INSTRUKCJA.md"
t "plik wersji: 1.0.0"                      0 grep -qx 'SCRIPT_VERSION=1.0.0' "$W/etc/router/version"
t "kopia skryptu w opt/router"              0 test -f "$W/opt/router/install-router.sh"
: >"$W/systemctl.log"
t "ponowny upgrade: brak zmian"             0 up SCRIPT_VERSION=1.0.0
t "brak restartów przy braku zmian"         1 grep -q restart "$W/systemctl.log"

echo "# zmiana ręczna na routerze"
echo '# ręczna zmiana' >>"$W/opt/router/bin/router-monitor"
cp "$W/opt/router/bin/router-monitor" "$W/tampered"
t "dry-run: pokazuje ZMIENIONY"             0 has ZMIENIONY up DRY_RUN=1 SCRIPT_VERSION=1.0.0
t "dry-run: diff w wyniku"                  0 has '-# ręczna zmiana' up DRY_RUN=1 SCRIPT_VERSION=1.0.0
t "dry-run: plik nietknięty"                0 cmp -s "$W/tampered" "$W/opt/router/bin/router-monitor"
mkdir -p "$W/var/log-monitor"   # stary /var/log/router-monitor (po przekierowaniu ścieżek)
echo 'stary-alarm' >"$W/var/log-monitor/router-monitor.log"
echo 'stary-fw' >"$W/var/log-monitor/router-fw.log.1"
t "upgrade podmienia plik"                  0 up SCRIPT_VERSION=1.0.1
t "migracja: stary katalog usunięty"        1 test -e "$W/var/log-monitor"
t "migracja: router-monitor.log → alarmy.log" 0 grep -q 'stary-alarm' "$W/var/log/alarmy.log"
t "migracja: router-fw.log.1 → firewall.log.1" 0 grep -q 'stary-fw' "$W/var/log/firewall.log.1"
t "rotacja: logrotate.d/router"             0 test -f "$W/etc/logrotate.d/router"
t "rotacja: codziennie, 20 dni"             0 grep -qzE 'daily\n  rotate 20\n' "$W/etc/logrotate.d/router"
t "router-monitor przywrócony"              1 grep -q 'ręczna zmiana' "$W/opt/router/bin/router-monitor"
t "kopia starej wersji w backup/upgrade-*"  0 grep -rq 'ręczna zmiana' "$W/data/backup"
t "restart router-monitor"                  0 grep -q 'restart router-monitor.service' "$W/systemctl.log"
t "bez restartu router-notify (bez zmian)"  1 grep -q 'restart router-notify.service' "$W/systemctl.log"
t "bez restartu VPP/BIRD"                   1 grep -qE 'restart (vpp|bird)' "$W/systemctl.log"
t "plik wersji: 1.0.1"                      0 grep -qx 'SCRIPT_VERSION=1.0.1' "$W/etc/router/version"
t "UPGRADED_AT zapisane"                    0 grep -q '^UPGRADED_AT=' "$W/etc/router/version"
t "wpis SCRIPTS_UPGRADED w logu"            0 grep -q 'SCRIPTS_UPGRADED' "$W/var/log/alarmy.log"

echo "# błąd składni w nowej wersji"
cp "$W/opt/router/bin/router-notify" "$W/notify.before"
t "zepsuty program: upgrade przerwany"      1 up SCRIPT_VERSION=1.0.2 "OVERRIDE=prog_router_notify() { printf '#!/usr/bin/python3\ndef (:\n'; }"
t "nic nie zmieniono"                       0 cmp -s "$W/notify.before" "$W/opt/router/bin/router-notify"
t "wersja nadal 1.0.1"                      0 grep -qx 'SCRIPT_VERSION=1.0.1' "$W/etc/router/version"

echo "# starszy skrypt niż na routerze"
t "obniżenie wersji bez zgody: przerwane"   1 up SCRIPT_VERSION=0.9.0 ASSUME_YES=0 </dev/null
t "obniżenie z --yes: wykonane"             0 up SCRIPT_VERSION=0.9.0 ASSUME_YES=1

echo "# --version"
t "--version nie wymaga roota"              0 has "wersja" bash install-router.sh --version

printf '\nWynik upgrade: %d OK, %d błędów\n' "$pass" "$fail"
((fail == 0))
