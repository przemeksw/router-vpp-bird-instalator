#!/usr/bin/env bash
# Kontrola spójności instalatora (statyczna): etap 22, jednostki systemd router-fw, kategoria e-mail FIREWALL.
#   bash tests/test-installer.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
pass=0 fail=0
chk() {   # chk <opis> <wyrażenie regularne> [oczekiwana liczba trafień]
  local n; n=$(grep -cE -- "$2" install-router.sh)
  if [[ ${3:-} ]] && [[ $n -eq $3 ]] || [[ -z ${3:-} && $n -ge 1 ]]; then pass=$((pass + 1)); printf '  OK    %s\n' "$1"
  else fail=$((fail + 1)); printf '  BŁĄD  %s (trafień: %s)\n' "$1" "$n"; fi
}
echo "8. instalator: router-fw"
chk "wersja skryptu 1.3.0"                     '^SCRIPT_VERSION="1\.3\.0"' 1
chk "router-guard w UPGRADE_PROGRAMS"          '"router-guard\|/opt/router/bin/router-guard\|755\|prog_router_guard\|"' 1
chk "router-fw w UPGRADE_PROGRAMS"            '"router-fw\|/opt/router/bin/router-fw\|755\|prog_router_fw\|"' 1
chk "TOTAL_STAGES=23"                         '^TOTAL_STAGES=23$' 1
chk "etap 22 uruchamia st_fw"                 '^run_stage 22 .*st_fw$' 1
chk "funkcja st_fw"                           '^st_fw\(\) \{' 1
chk "program router-fw instalowany"           'prog_router_fw \| put_file /opt/router/bin/router-fw ' 1
chk "przykładowy firewall.conf (nie nadpisuje)" 'fw_example_conf \| put_file /etc/router/firewall.conf' 1
chk "router-fw.service: boot po VPP"          '^ExecStart=/opt/router/bin/router-fw boot$' 1
chk "router-fw.service: po router-ifaces"     '^After=vpp.service netns-dataplane.service router-ifaces.service$' 1
chk "timer kontroli rozjazdu"                 '^ExecStart=/opt/router/bin/router-fw check --log$' 1
chk "timer wygasania blokad"                  '^ExecStart=/opt/router/bin/router-fw expire$' 1
chk "drop-in router.target"                   'router.target.d/10-fw.conf' 1
chk "drop-in BIRD po firewallu"               '/40-fw.conf' 1
chk "drop-in VPP uruchamia firewall"          'vpp.service.d/50-fw.conf' 1
chk "router-fw w do_check (usługi)"           'router-ifaces router-fw router-guard "\$\(bird_unit\)"' 1
chk "sekcja Firewall w do_check"              'Firewall \(/etc/router/firewall.conf\)' 1
chk "kategoria FIREWALL w router-notify"      '\("FIREWALL", ' 1
chk "FIREWALL w domyślnym MAIL_SEND (3 miejsca)" 'SYS_CPU IFACES FIREWALL OTHER' 3
chk "rozdział 10a w README routera"           '^## 10a\. Firewall tranzytu' 1
chk "etap 23 uruchamia st_guard"              '^run_stage 23 .*st_guard$' 1
chk "funkcja st_guard"                        '^st_guard\(\) \{' 1
chk "router-guard instalowany"                'prog_router_guard \| put_file /opt/router/bin/router-guard ' 1
chk "przykładowy synack-guard.conf"           'guard_example_conf \| put_file /etc/router/synack-guard.conf' 1
chk "router-guard.service: boot po VPP"       '^ExecStart=/opt/router/bin/router-guard boot$' 1
chk "timer kontroli router-guard"             '^ExecStart=/opt/router/bin/router-guard check --log$' 1
chk "timer wygasania router-guard"            '^ExecStart=/opt/router/bin/router-guard expire$' 1
chk "drop-in VPP uruchamia router-guard"      'vpp.service.d/60-guard.conf' 1
chk "drop-in router.target (guard)"           'router.target.d/20-guard.conf' 1
chk "wtyczka kopiowana do drzewa VPP"         '^  emit_guard_plugin "\$vdir/src/plugins/synack_guard"$' 1
chk "funkcja emit_guard_plugin"               '^emit_guard_plugin\(\) \{' 1
chk "router-guard w do_check (usługi)"        'router-fw router-guard "\$\(bird_unit\)"' 1
chk "kategoria FIREWALL obejmuje GUARD"       '\("FIREWALL", .*\^\(FW\|GUARD\)-' 1
chk "rozdział 10b w README routera"           '^## 10b\. Ochrona przed odbiciami' 1
printf '\nWynik: %d OK, %d błędów\n' "$pass" "$fail"
((fail == 0))
