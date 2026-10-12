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
chk "wersja skryptu 1.4.0"                     '^SCRIPT_VERSION="1\.4\.0"' 1
chk "router-guard w UPGRADE_PROGRAMS"          '"router-guard\|/opt/router/bin/router-guard\|755\|prog_router_guard\|"' 1
chk "router-fw w UPGRADE_PROGRAMS"            '"router-fw\|/opt/router/bin/router-fw\|755\|prog_router_fw\|"' 1
chk "TOTAL_STAGES=25"                         '^TOTAL_STAGES=25$' 1
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
chk "FIREWALL w domyślnym MAIL_SEND (3 miejsca + instrukcja)" 'SYS_CPU IFACES FIREWALL OTHER' 4
chk "rozdział 10a w README routera"           '^## 10a\. Firewall tranzytu' 1
chk "etap 23 uruchamia st_guard"              '^run_stage 23 .*st_guard$' 1
chk "instrukcja instalowana w etapie 20"     'router_manual \| put_file /etc/router/INSTRUKCJA.md' 1
chk "instrukcja w upgrade_script"            '^  "INSTRUKCJA.md\|/etc/router/INSTRUKCJA.md\|644\|router_manual\|"$' 1
chk "router-fw działa tylko po enable (3 jednostki)" '^ConditionPathExists=/etc/router/firewall\.enabled$' 3
chk "etap 22 nie startuje router-fw.service"  'systemctl start router-fw\.service' 0
chk "README: aktywacja firewalla"             '^### Aktywacja na stałe$' 1
chk "VPP: limit i wygasanie ARP/ND"           'set ip neighbor-config ip4 limit \$NEIGH_MAX age \$NEIGH_AGE recycle' 1
chk "bootstrap.vpp z neigh_vpp_cmds"          '^    neigh_vpp_cmds$' 1
chk "netns: bez RA"                           '^net\.ipv6\.conf\.default\.accept_ra = 0$' 1
chk "netns: nowe interfejsy bez link-local"   '^net\.ipv6\.conf\.default\.addr_gen_mode = 1$' 1
chk "netns: sysctl przy każdym starcie"       'ExecStartPost=-/usr/sbin/ip netns exec dataplane /usr/sbin/sysctl -q -p /etc/router/dataplane-sysctl\.conf' 1
chk "router-ifaces: ra-suppress"              'ip6 nd %s ra-suppress' 1
chk "router-ifaces: disable ip6 interface"    'disable ip6 interface %s' 1
chk "router-top instalowany (etap 18)"        'prog_router_top \| put_file /opt/router/bin/router-top' 1
chk "router-top w upgrade_script"            '^  "router-top\|/opt/router/bin/router-top\|755\|prog_router_top\|"$' 1
chk "wtyczka: show synack-guard events"      '\.path = "show synack-guard events"' 1
chk "wtyczka: show bez bariery (mp_safe)"     '^  \.is_mp_safe = 1' 2
chk "wtyczka: liczenie tablic w tle"          '\.name = "synack-guard-count"' 1
chk "README: rozdział 10d router-top"         '^## 10d\. Podgląd na żywo' 1
chk "narzędzia: mtr, nmap, screen"            '^            mtr-tiny nmap screen\)$' 1
chk "etap 25 uruchamia st_system"            '^run_stage 25 .*st_system$' 1
chk "strefa czasowa Europe/Warsaw"            '^TIMEZONE="Europe/Warsaw"$' 1
chk "NTP: serwery GUM"                        '^NTP_SERVERS="tempus1\.gum\.gov\.pl tempus2\.gum\.gov\.pl"' 1
chk "DNS: trzy serwery"                       '^DNS_SERVERS="46\.45\.78\.2 46\.45\.114\.2 8\.8\.8\.8"' 1
chk "zaufane sieci jak w obecnej polityce"    '^TRUSTED_NETS=\("10\.0\.0\.0/8\|LOCAL" "172\.16\.0\.0/12\|LOCAL" "192\.168\.0\.0/16\|LOCAL" "46\.45\.64\.0/18\|ALL BLOKOWE"\)' 1
chk "iptables netns dataplane przy starcie"   'ip netns exec dataplane /usr/sbin/iptables-restore /etc/iptables/dataplane\.rules\.v4' 2
chk "iptables-persistent bez pytań"           'iptables-persistent/autosave_v4 boolean false' 1
chk "conntrack zablokowany w modprobe"        '^install nf_conntrack /bin/false$' 1
chk "router-check sprawdza conntrack"         'conntrack wyłączony"; fi' 1
chk "ochrona przed odcięciem SSH"             'NIE jest w TRUSTED_NETS' 1
chk "snmpd: blok zaufanych sieci"             '^\$\(snmp_trusted_block\)$' 1
chk "etap 24 uruchamia st_logs"               '^run_stage 24 .*st_logs$' 1
chk "rsyslog: reguły /var/log/router"         'file="/var/log/router/(vpp|bird)\.log"' 2
chk "migracja /var/log/router-monitor"     '^  migrate_logdir$' 3
chk "brak starego katalogu logów w programach" '>>/var/log/router-monitor|ROOT \+ "/var/log/router-monitor' 0
chk "rotacja /var/log/router"                 '^/var/log/router/\*\.log \{$' 1
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
chk "wtyczka: wycofanie prefiksu przy błędzie"  'if \(sg_rebuild_prefixes \(vm\)\)' 1
chk "build: sprawdza .so wtyczki w paczce"    'grep -q .synack_guard_plugin' 1
chk "funkcja guard_plugin_log"               '^guard_plugin_log\(\) \{' 1
chk "log VPP sprawdzany w etapie 23 i --check" '^  guard_plugin_log$' 2
chk "router-guard w do_check (usługi)"        'router-fw router-guard "\$\(bird_unit\)"' 1
chk "kategoria FIREWALL obejmuje GUARD"       '\("FIREWALL", .*\^\(FW\|GUARD\)-' 1
chk "rozdział 10b w README routera"           '^## 10b\. Ochrona przed odbiciami' 1

# fw_rules naprawdę generuje obecną politykę (wykonanie funkcji z instalatora)
fwt() {   # fwt <opis> <wersja IP> <wyrażenie> [0 = ma NIE wystąpić]
  local out
  out=$( { sed -n '/^LOG_KEEP_DAYS=/,/^ICMP_ECHO_TOTAL=/p' install-router.sh; awk '/^fw_rules\(\) \{/,/^}/' install-router.sh
           echo "SNMP_ALLOW=192.168.80.0/24; fw_rules $2 test"; } | bash 2>&1)
  if grep -qE -- "$3" <<<"$out"; then [[ ${4:-1} == 1 ]]; else [[ ${4:-1} == 0 ]]; fi
  if (($? == 0)); then pass=$((pass + 1)); printf '  OK    %s\n' "$1"; else fail=$((fail + 1)); printf '  BŁĄD  %s\n' "$1"; fi
}
fwt "reguły: 46.45.64.0/18 ACCEPT"         4 '^-A PREROUTING -s 46\.45\.64\.0/18 .*"ALL BLOKOWE" -j ACCEPT$'
fwt "reguły: DROP tcp 22,161"              4 '^-A PREROUTING -p tcp -m multiport --dports 22,161 .* -j DROP$'
fwt "reguły: DROP udp 22,161"              4 '^-A PREROUTING -p udp -m multiport --dports 22,161 .* -j DROP$'
fwt "reguły: limit pingu na adres"         4 'echo-request -m hashlimit --hashlimit-above 10/sec .*--hashlimit-mode srcip'
fwt "reguły: LibreNMS ma SNMP"             4 '^-A PREROUTING -s 192\.168\.80\.0/24 -p udp --dport 161'
fwt "reguły v6: icmpv6 echo"               6 'ipv6-icmp --icmpv6-type echo-request'
fwt "reguły v6: bez adresów IPv4"          6 '-s [0-9]+\.' 0
fwt "reguły: COMMIT"                       4 '^COMMIT$'
fwt "reguły: w tabeli raw"                 4 '^\*raw$'
fwt "reguły: nic w filter INPUT"           4 '^-A INPUT' 0
fwt "reguły: bez conntrack/state"          4 '(-m (state|conntrack)|-j CT)' 0
printf '\nWynik: %d OK, %d błędów\n' "$pass" "$fail"
((fail == 0))
