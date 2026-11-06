#!/usr/bin/env bash
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
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
chk "wersja skryptu 1.5.38"                     '^SCRIPT_VERSION="1\.5\.38"' 1
chk "lspci: LnkSta z tabulatorem (wcześniej nic nie łapało)" "LnkSta:\\[\\[:space:\\]\\]\\*Speed" 3
chk "vpp_conf_diff porównuje pierścienie RX/TX" 'zmiana: pierścień RX' 1
chk "router-kthreads: efektywna maska przerwań" 'effective_affinity_list' 2
chk "SMI: średnia z okna, nie pojedyncza sekunda" '"SMI_WINDOW": 60,|^SMI_WINDOW=60$' 2
chk "dobór workerów wg wydajności rdzenia"     'NEED_W=\$\(\( \(need_pps \+ PPS_W - 1\) / PPS_W \)\)' 1
chk "workery: co najmniej NIC_CAP, najwyżej 2× i wolne rdzenie" 'want > NIC_CAP \* 2' 1
chk "pojemność routera w raporcie i router.env" 'audit INFO "Pojemność \(szacunek\)"|^INST_CAPACITY=' 2
chk "prędkość portu nominalna, gdy porty ma VPP" 'NIC_LINE=[0-9]+' 8
chk "kernel: parametry przeciw zakłóceniom"      '^KERNEL_JITTER_PARAMS="rcupdate\.rcu_normal_after_boot=1 iommu=pt skew_tick=1"$' 1
chk "kernel: tsc=reliable tylko przy stabilnym TSC" 'EXTRA_CMDLINE\+=\(tsc=reliable\)' 1
chk "upgrade/--check/set_workers sprawdzają parametry kernela" 'kernel_params_ok' 6
chk "jeden procesor: co najmniej 2 rdzenie dla systemu" 'HK_RES=\$\(\( \(\$\{#PHYS\[@\]\} \+ 7\) / 8 \)\); \(\(HK_RES < 2\)\) && HK_RES=2' 1
chk "rdzeń główny i workery po rdzeniach systemowych" 'MAIN_CORE=\$\{PHYS\[HK_RES\]\}' 1
chk "pierścień RX dopasowany do buforów" 'while \(\( BUFFERS > 0 && \$\(rings_need\) > BUFFERS' 1
chk "zmniejszony pierścień nie jest rozjazdem przy upgrade" 'INST_RX_DESC_CAP' 3
chk "BIRD: priorytet na rdzeniach systemowych" '15-priority.conf' 2
chk "router-monitor: zajętość workerów z pętli (IdleLoops)" '^class IdleLoops:' 1
chk "router-top: kolumna zajętości i pasek %"  '^def busy_pct\(loops, base\):' 1
chk "luz uczony, nie wpisany na sztywno (router-monitor i router-top)" '^IDLE_VEC = 1\.1$' 2
chk "router-snmp: rvWorkerBusyPct i rvVppWorkerBusyMax" '\(4, "rvWorkerBusyPct", "gauge"|\(24, "rvVppWorkerBusyMax", "gauge"' 2
chk "instalacja pyta o adres loop0"            'read -rp "  Adres loop0 \[\$\{LOOP0_ADDR:--\}\]: " ans' 1
chk "loop0 z router.env przy kolejnych uruchomieniach" 'INST_LOOP0_ADDR="\$\{LOOP0_ADDR:--\}"|^INST_LOOP0_ADDR=' 1
chk "loop0: odczyt INST_LOOP0_ADDR z router.env" "sed -n 's/\^INST_LOOP0_ADDR=" 1
v32() { eval "$(sed -n '/^valid_ip4_32() {/,/^}/p' install-router.sh)"; valid_ip4_32 "$1"; }
for a in 10.10.10.10/32 185.1.2.3/32 1.0.0.1/32; do
  if v32 "$a"; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  valid_ip4_32 odrzuca poprawny $a"; fi
done
for a in 10.10.10.10 10.10.10.10/24 256.1.1.1/32 0.0.0.0/32 127.0.0.1/32 224.0.0.1/32 abc/32 "10.10.10.10/32 x"; do
  if v32 "$a"; then fail=$((fail+1)); echo "BŁĄD  valid_ip4_32 przyjmuje zły '$a'"; else pass=$((pass+1)); fi
done
chk "router-top: karta 5 kolejki RX"           '5: \("Kolejki RX", QueueStats, screen_queues\)' 1
chk "router-snmp: OID-y wywłaszczeń i SMI"     '\(22, "rvVppWkPreempt", "gauge"|\(23, "rvVppSmi", "gauge"' 2
chk "router-monitor: RX_MISS z przyczyną"      'burst jednego przepływu na jednej kolejce RSS: worker nie był' 1
chk "router-monitor: HK_GRACE po starcie"      '"HK_GRACE": 300,|^HK_GRACE=300$|uptime\(\) >= CFG\["HK_GRACE"\]' 3
chk "router-ifaces: alarm wkładek z timera"    '^def optics_check\(state\):|optics_check\(state\)$' 2
chk "router-ifaces: czeka na flowprobe params z bootstrap.vpp" '^def wait_flowprobe_params\(timeout\):|wait_flowprobe_params\(30\)' 2
chk "router-kthreads: przerwania (plan_irqs)"  '^def plan_irqs\(irqlist, isolated, present\):' 1
chk "router-kthreads: tryb timera --quiet → ISOL_FIX" 'line = "%SYS-4-ISOL_FIX: " \+ msg' 1
chk "router-kthreads-check.timer w st_isolation" 'systemctl enable --now router-kthreads-check.timer' 1
chk "moduł msr ładowany przy starcie"         'put_file /etc/modules-load.d/router-msr.conf' 1
chk "router-monitor: licznik SMI (MSR 0x34)"  '^MSR_SMI_COUNT = 0x34$' 1
chk "router-monitor: alarm SMI"               'Alarm\("SYS", 3, "SMI", "SMI_END"\)' 1
chk "router-monitor.conf: SMI_PER_S"          '^SMI_PER_S=5$' 1
chk "router-notify: SMI i ISOL_FIX w VPP_DROPS" '\^SYS-\(SMI\|ISOL_FIX\)' 1
chk "--check: częstość SMI z 5 s pomiaru"     'SMI na rdzeniu workera \(cpu \$c\)' 3
chk "pierścień RX = maksimum ConnectX-4 (burst jednego przepływu)" '^VPP_RX_DESC=32768 ' 1
chk "set_workers: sam startup.conf → tylko restart VPP" 'zmienił się tylko startup.conf' 1
chk "router-monitor: WK_GRACE po starcie VPP (kod i konfiguracja)" '"WK_GRACE": 120,|^WK_GRACE=120$|t0 - vpp_seen_t < CFG\["WK_GRACE"\]' 3
chk "router-monitor: CPU procesów bez wątków na izolowanych rdzeniach" 'procs = read_proc_cpu\(isolated\)' 1
chk "router-guard w UPGRADE_PROGRAMS"          '"router-guard\|/opt/router/bin/router-guard\|755\|prog_router_guard\|"' 1
chk "router-fw w UPGRADE_PROGRAMS"            '"router-fw\|/opt/router/bin/router-fw\|755\|prog_router_fw\|"' 1
chk "TOTAL_STAGES=27"                         '^TOTAL_STAGES=27$' 1
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
chk "FIREWALL w domyślnym MAIL_SEND (3 miejsca + instrukcja)" 'SYS_CPU IFACES FIREWALL RPKI OTHER' 4
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
chk "SSH_CLIENT bez set -u (sudo, konsola)"    '\$\{SSH_CLIENT[^:]' 0
chk "snmpd: blok zaufanych sieci (dataplane i mgmt)" '^\$\(snmp_trusted_block\)$' 2
chk "snmpd: pass_persist router-snmp (dataplane i mgmt)" '^\$\(snmp_ext_block\)$' 2
chk "snmpd-dataplane: IF-MIB tylko z vpp-snmp-agent" 'mteTriggerConf,interfaces,ifTable,ifXTable -f -p /run/snmpd-dataplane\.pid$' 1
chk "router-snmp: etap SNMP i upgrade_script"      '^  snmp_router_ext$' 2
chk "router-snmp w upgrade_script"                 '^  "router-snmp\|/opt/router/bin/router-snmp\|755\|prog_router_snmp\|router-snmp\.service"$' 1
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
chk "NetFlow: eksport do dedykowanego TAP-a, nie do loop0/ROUTER_ID" 'echo "set ipfix exporter collector \$NETFLOW_TAP_LINUX port \$NETFLOW_PORT src \$NETFLOW_TAP_VPP' 1
chk "NetFlow: dedykowany TAP tworzony w bootstrap.vpp (host-ns dataplane)" 'echo "create tap id 0 host-if-name nf-export host-ns dataplane' 1
chk "NetFlow: TAP-y to NIE adres VPP (ROUTER_ID) — ip4-local by odrzucił jako spoofing" '^NETFLOW_TAP_VPP=' 1
chk "NetFlow: tap0 w osobnej tabeli routingu (VRF), nie w głównej z hu0/hu1" 'echo "set interface ip table tap0 \$NETFLOW_TAP_FIB"' 1
chk "NetFlow: eksporter dostaje fib-id tej samej, odizolowanej tabeli" 'fib-id \$NETFLOW_TAP_FIB' 3
chk "NetFlow: przykład netflow.conf, gdy NETFLOW_COLLECTORS puste" '192\.0\.2\.10:2055   # przykład: FastNetMon' 1
chk "NetFlow: router-netflow w UPGRADE_PROGRAMS" '"router-netflow\|/opt/router/bin/router-netflow\|755\|prog_router_netflow\|router-netflow\.service"' 1
chk "NetFlow: wyłącznik NETFLOW_ENABLE domyślnie yes" '^NETFLOW_ENABLE=yes' 1
chk "NetFlow: INST_NETFLOW_ENABLE zapisywane do router.env" '^INST_NETFLOW_ENABLE=\$NETFLOW_ENABLE' 1
chk "NetFlow: bootstrap.vpp/upgrade_vpp_sync/vpp_conf_diff sprawdzają NETFLOW_ENABLE" 'if \[\[ \$NETFLOW_ENABLE == yes \]\]; then' 3
chk "NetFlow: st_netflow ma wczesny return przy wyłączonym NETFLOW_ENABLE" '\$NETFLOW_ENABLE != yes \]\]; then' 1
chk "NetFlow: fw_rules pomija regułę portu, gdy wyłączone" 'where == \*dataplane\* && \$NETFLOW_ENABLE == yes' 1
chk "NetFlow: router-ifaces czyta INST_NETFLOW_ENABLE z router.env" 'INST_NETFLOW_ENABLE=\(yes\|no\)' 1
chk "NetFlow: router-ifaces wyłącza flowprobe na interfejsie, gdy NETFLOW_ENABLE=no" 'NetFlow/IPFIX: wyłączone \(NETFLOW_ENABLE=no albo nonetflow w ifaces\.conf\)' 1
chk "NetFlow: żywy włącznik netflow-on/netflow-off (plik stanu)" '^NETFLOW_STATE_FILE = ROOT \+ "/etc/router/netflow\.enabled"' 1
chk "NetFlow: netflow-on/netflow-off w wyborze poleceń router-ifaces" 'choices=\["show", "diff", "apply", "check", "render", "boot", "snmp",' 1
chk "NetFlow: argparse zna netflow-on/netflow-off" '"optics", "errors", "netflow-on", "netflow-off"\]\)' 1
chk "NetFlow: funkcja do_netflow (włącznik bez restartu VPP)" '^def do_netflow\(args, enable\):' 1
chk "NetFlow: dispatch netflow-on/netflow-off w main()" '"netflow-on": lambda a: do_netflow\(a, True\), "netflow-off": lambda a: do_netflow\(a, False\)' 1
chk "NetFlow: menu router ma akcję Włącz NetFlow/IPFIX" 'router-ifaces", "netflow-on"\]' 1
chk "NetFlow: menu router ma akcję Wyłącz NetFlow/IPFIX" 'router-ifaces", "netflow-off"\]' 1
chk "NetFlow: menu router ma akcję Restart replikacji NetFlow" '\["systemctl", "restart", "router-netflow"\]' 1
chk "NetFlow: menu router ma akcję Zatrzymaj replikację NetFlow" '\["systemctl", "stop", "router-netflow"\]' 1
chk "NetFlow: NETFLOW_INSTALLED (instalacyjne, niezależne od żywego przełącznika)" '^NETFLOW_INSTALLED = _inst_netflow_enable\(\)' 1
chk "NetFlow: kotwica na loop0 (licznik referencji nigdy nie spada do zera)" 'NetFlow/IPFIX: kotwica \(licznik referencji nigdy nie spada do zera\)' 2
chk "NetFlow: Entry ma pole netflow_override (nadpisanie per-interfejs)" 'self\.netflow_override = None' 1
chk "NetFlow: parser rozpoznaje słowo netflow/nonetflow w opisie" 'm = re\.match\(r"\^\(nonetflow\|netflow\)\\b\\s\*", desc, re\.I\)' 1
chk "NetFlow: plan() liczy want_fp z globalnego przełącznika i nadpisania" 'want_fp = NETFLOW_INSTALLED and \(NETFLOW_ENABLED if e\.netflow_override is None else e\.netflow_override\)' 1
chk "NetFlow: ostrzeżenie, gdy znacznik użyty na loopbacku (bez efektu)" 'znacznik netflow na loopbacku nie ma znaczenia' 1
chk "etap 26 uruchamia st_loop0_access"       '^run_stage 26 .*st_loop0_access$' 1
chk "etap 27 uruchamia st_rpki"               '^run_stage 27 .*st_rpki$' 1
chk "RPKI: domyślnie bez odrzucania"          'define RPKI_ENFORCE = 0;' 1
chk "RPKI: tryb nie nadpisywany przy powtórce" '^  if \[\[ ! -f /etc/bird/rpki-mode.conf \]\]; then$' 1
chk "RPKI: krótki expire (fail-open po 1 h)"  '^  expire keep 3600; ' 1
chk "RPKI: kategoria e-mail"                  '\("RPKI", "RPKI: ' 1
chk "RPKI: MAIL_SEND zawiera RPKI"            'FIREWALL RPKI OTHER' 4
chk "funkcja st_loop0_access"                 '^st_loop0_access\(\) \{' 1
chk "LOOP0_ADDR domyślnie 10.10.10.10/32"     '^LOOP0_ADDR="10\.10\.10\.10/32"' 1
chk "DATAPLANE_SSH i MGMT_SNMP w ustawieniach" '^(DATAPLANE_SSH|MGMT_SNMP)=yes' 2
chk "ROUTER_ID z loop0"                       'ROUTER_ID=\$\{LOOP0_ADDR%%/\*\}' 1
chk "ifaces.conf: domyślny wiersz loop0"      'loop0 - "\$LOOP0_ADDR" - "Loopback: zarządzanie' 2
chk "sshd-dataplane.service"                  'put_file /etc/systemd/system/sshd-dataplane\.service' 1
chk "sshd-dataplane: osobny sshd_config"      '^ExecStart=/usr/sbin/sshd -D -f /etc/ssh/sshd_config_dataplane$' 1
chk "snmpd-mgmt.service"                      'snmpd-mgmt\.conf -p /run/snmpd-mgmt\.pid$' 1
chk "snmpd-dataplane tylko na loop0 i 127.0.0.1" 'udp:127\.0\.0\.1:161,udp:' 2
chk "ip_nonlocal_bind w dataplane"            'net\.ipv4\.ip_nonlocal_bind = 1' 1
chk "sekcja Dostęp przez loop0 w do_check"    '== Dostęp przez loop0 \(SSH, SNMP\) ==' 1
chk "SSH_ROOT_LOGIN=no domyślnie"             '^SSH_ROOT_LOGIN=no' 1
chk "funkcja ssh_admin_user"                  '^ssh_admin_user\(\) \{' 1
chk "sshd-dataplane: hasło z ustawienia"      '^PasswordAuthentication \$SSH_PASSWORD_AUTH$' 1
chk "SSH_PASSWORD_AUTH=yes domyślnie"         '^SSH_PASSWORD_AUTH=yes' 1
chk "root przez hasło odrzucany"              'rootlogin=prohibit-password; fi' 1
chk "sshd-dataplane: PermitRootLogin z ustawienia" '^PermitRootLogin \$rootlogin$' 1
chk "sshd portu zarządzającego: drop-in 00-router-access" 'put_file /etc/ssh/sshd_config\.d/00-router-access\.conf' 1
chk "brak zwykłego użytkownika nie odcina roota" 'brak zwykłego użytkownika z sudo' 1
chk "router (menu) w UPGRADE_PROGRAMS"        '"router\|/opt/router/bin/router\|755\|prog_router\|"' 1
chk "router (menu) instalowany w st_docs"     'prog_router \| put_file /opt/router/bin/router ' 1
chk "dowiązanie /usr/local/sbin/router"       'ln -sfn /opt/router/bin/router /usr/local/sbin/router$' 2
chk "rozdział o menu router w README"         '^## 10d\. Menu `router`' 1
chk "router-monitor: minutowe STATS domyślnie wyłączone (konfiguracja)" '^SUMMARY_EVERY=0$' 1
chk "router-monitor: minutowe STATS domyślnie wyłączone (kod)"  '"SUMMARY_EVERY": 0,' 1
chk "router-monitor.conf: LOG_MAX_SEV=4"      '^LOG_MAX_SEV=4$' 1
chk "router-monitor: filtr alarmy.log"        'fh\.addFilter\(AlarmFilter\(\)\)' 1
# wywłaszczenia workerów VPP (kcompactd1 na cpu 5 wywłaszczał vpp_wk_0 → rx_out_of_buffer): alarm, narzędzie, sysctl, usługa
chk "router-monitor: alarm WK_PREEMPT"        'Alarm\("VPP", 3, "WK_PREEMPT", "WK_PREEMPT_END"\)' 1
chk "router-monitor: liczniki z /proc/<pid>/task" '^def read_worker_preempt\(pid\):' 1
chk "router-monitor: PID VPP po nazwie wątku (bez pidfile)" '^def find_vpp_pid\(\):' 1
chk "router-monitor.conf: próg WK_PREEMPT"    '^WK_PREEMPT=1$' 1
chk "router-notify: WK_PREEMPT w kategorii VPP_DROPS" 'VPP-\(RX_MISS\|NIC_DISCARD\|WK_PREEMPT\)' 1
chk "NIC_DISCARD bez rx_out_of_buffer (= rx-miss, liczony podwójnie)" '\(\?:discard\|out_of_buffer\)' 0
chk "xstats discard: router-monitor i router-snmp" '\]\]\*discard\[A-Za-z0-9_' 3
chk "router-kthreads: program osadzony"       "^prog_router_kthreads\(\) \{" 1
chk "router-kthreads: w UPGRADE_PROGRAMS z usługą" '^  "router-kthreads\|/opt/router/bin/router-kthreads\|755\|prog_router_kthreads\|router-kthreads.service"$' 1
chk "router-kthreads.service włączana w st_isolation" 'systemctl enable --now router-kthreads.service' 1
chk "sysctl: proaktywna kompakcja wyłączona"  '^vm.compaction_proactiveness = 0$' 1
chk "upgrade_vpp_sync sprawdza kompakcję i usługę" 'sysctl -n vm.compaction_proactiveness 2>/dev/null\) == 0 \]\]' 1
chk "vpp_conf_diff: kompakcja i usługa (z nadpisaniem w testach)" 'VPP_COMPACT_PROACTIVE-|VPP_KTHREADS_UNIT:-' 3
chk "router-kthreads w router.target"         'vpp.service router-kthreads.service router-ifaces.service' 1
chk "--check: wywłaszczenia workerów"         'nr_involuntary_switches' 7
chk "stopka z autorem (ifaces, fw, guard) definiowana"  '^def signature\(\):' 3
chk "stopka z autorem wołana po poleceniu"    '^    signature\(\)$' 3
chk "tryb set_workers w argumentach"          'set_workers\|--set-workers\) MODE=workers' 1
chk "liczba workerów jako argument"           '^    \[0-9\]\|\[0-9\]\[0-9\]\) ' 1
chk "dry-run dozwolony też dla set_workers"   'MODE != upgrade && \$MODE != workers' 1
chk "set_workers czyta router.env"            'MODE == check \|\| \$MODE == upgrade \|\| \$MODE == workers' 1
chk "do_set_workers zdefiniowane i wołane"    '^do_set_workers\(\) \{' 1
chk "dispatch trybu workers po etapie 01"     '^if \[\[ \$MODE == workers \]\]; then do_set_workers; exit \$\?; fi' 1
chk "set_workers przelicza izolację i VPP"    'run_stage 0[69] .*st_(isolation|vpp_config)$' 5
chk "sama izolacja: bez restartu VPP"         'if ! vpp_conf_diff vpp >/dev/null; then' 1
chk "set_workers bez N: obecna liczba"        'cur_w=\$\(sed -n .s/\^\[\[:space:\]\]\*corelist-workers' 1
chk "upgrade_script uzupełnia izolację"       '^if \[\[ \$MODE == upgrade \]\]; then do_upgrade; upgrade_vpp_sync; exit 0; fi' 1
chk "set_workers nie wymaga internetu"        '^\[\[ \$MODE == workers \]\] \|\| timeout 10 getent' 1
chk "bufory liczone funkcją calc_buffers"      '^calc_buffers\(\) \{' 1
chk "bufory VPP z liczby workerów i portów"   'BUFFERS=\$\(calc_buffers "\$\{#NIC_PCI\[@\]\}" "\$VPP_WORKERS"' 1
chk "plan set_workers pokazuje bufory"        'bufory .*\$BUFFERS' 5
# calc_buffers: test funkcjonalny (czysta arytmetyka, wyciągnięta z instalatora)
cb=$(sed -n '/^calc_buffers() {/,/^}/p' install-router.sh)
if [[ -n $cb ]]; then
  eval "$cb"
  t() { local got; got=$(calc_buffers "$2" "$3" "$4" "$5"); if [[ $got == "$6" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  calc_buffers $1: oczekiwano $6, jest $got"; fi; }
  t "1 port, 12 workerów: 8× zapotrzebowanie"          1 12 4096 1024 704512
  t "2 porty, 12 workerów"                              2 12 4096 1024 1196032
  t "mało workerów: dolny próg 524288"                  1 2 1024 1024 524288
else
  fail=$((fail+1)); echo "BŁĄD  brak funkcji calc_buffers do testu"
fi
chk "plan set_workers pokazuje porty VPP i jak zawęzić" 'porty VPP \(%d\): %s' 1
# --- wybór karty/portu Mellanox numerem i bufory statycznie na maksimum
chk "lista portów Mellanox"                   '^list_mlx5_ports\(\) \{' 1
chk "wybór portu numerem (choose_nic)"        '^choose_nic\(\) \{' 1
chk "choose_nic wołane dla instalacji i workerów" '^\[\[ \$MODE == "" \|\| \$MODE == workers \|\| \$MODE == audit \]\] && choose_nic' 1
chk "flaga --choose-nic"                      '--choose-nic\|--nic\) CHOOSE_NIC=1' 1
chk "max_buffers zdefiniowane"                '^max_buffers\(\) \{' 1
chk "tryby VPP_BUFFERS max|auto|liczba"       '^case \$VPP_BUFFERS in' 1
mb=$(sed -n '/^max_buffers() {/,/^}/p' install-router.sh)
if [[ -n $mb ]]; then
  eval "$mb"
  tm() { local got; got=$(max_buffers "$2" "$3"); if [[ $got == "$4" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  max_buffers $1: oczekiwano $4, jest $got"; fi; }
  tm "8 GB hugepages na węźle, sterta 4 GB"  8192 4096 933888
  tm "4 GB hugepages, sterta 2 GB"            4096 2048 245760
  tm "za mało pamięci: dolny próg"            2048 2048 32768
  tm "router lodz2: 8037 MB na węźle, sterta 4 GB" 8037 4096 884736
else
  fail=$((fail+1)); echo "BŁĄD  brak funkcji max_buffers do testu"
fi
# choose_nic: test funkcjonalny na sztucznym sysfs (2 porty jednej karty + port innej karty)
fn=$(sed -n '/^netdev_of() /p;/^list_mlx5_ports() {/,/^}/p;/^choose_nic() {/,/^}/p' install-router.sh)
if [[ -n $fn ]]; then
  nicroot=$(mktemp -d)
  mkdir -p "$nicroot/drivers/mlx5_core"
  for spec in "0000:82:00.0 enp130s0f0np0 1 1 100000" "0000:82:00.1 enp130s0f1np1 1 0 -1" "0000:03:00.0 enp3s0 0 1 25000"; do
    set -- $spec
    d=$nicroot/devices/$1; mkdir -p "$d/net/$2" "$nicroot/net/$2"
    echo 0x15b3 >"$d/vendor"; echo 0x1013 >"$d/device"; echo "$3" >"$d/numa_node"
    ln -s ../../drivers/mlx5_core "$d/driver"
    echo "$4" >"$nicroot/net/$2/carrier"; echo "$5" >"$nicroot/net/$2/speed"
  done
  mkdir -p "$nicroot/devices/0000:82:00.2"; echo 0x15b3 >"$nicroot/devices/0000:82:00.2/vendor"   # VF/obcy: bez sterownika mlx5_core
  runnic() {   # runnic "<odpowiedź>" <NIC_PCI wejściowe...> → wypisuje wynikowe NIC_PCI
    local ans=$1; shift
    ( eval "$fn"; warn() { :; }; say() { :; }; ok() { :; }
      PCI_SYSFS=$nicroot/devices NET_SYSFS=$nicroot/net PCI_ARGS=() ASSUME_YES=0 CHOOSE_NIC=1 ROUTER_TEST_TTY=1 MODE=""
      NIC_PCI=("$@")
      choose_nic <<<"$ans" >/dev/null
      echo "${NIC_PCI[*]}" )
  }
  tn() { local got; got=$(runnic "$2" "${@:4}"); if [[ $got == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  choose_nic $1: oczekiwano '$3', jest '$got'"; fi; }
  tn "numer 1 = pierwszy port"                 1 "0000:03:00.0" 0000:82:00.0 0000:82:00.1      # kolejność: 03:00.0, 82:00.0, 82:00.1
  tn "numer 2 = port z linkiem karty 82"       2 "0000:82:00.0" 0000:82:00.0 0000:82:00.1
  tn "kilka numerów po przecinku"              "2,3" "0000:82:00.0 0000:82:00.1" 0000:82:00.0
  tn "Enter = dotychczasowy wybór"             "" "0000:82:00.1" 0000:82:00.1
  tn "zły numer, potem poprawny"               $'9\n3' "0000:82:00.1" 0000:82:00.0
  # bez terminala/--yes: bez pytania, port z linkiem, gdy zapisanego brak
  got=$( ( eval "$fn"; warn() { :; }; say() { :; }; ok() { :; }; PCI_SYSFS=$nicroot/devices NET_SYSFS=$nicroot/net PCI_ARGS=() ASSUME_YES=1 CHOOSE_NIC=0 MODE=""
           NIC_PCI=(0000:99:00.0); choose_nic </dev/null >/dev/null; echo "${NIC_PCI[*]}" ) )
  if [[ $got == "0000:03:00.0 0000:82:00.0" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  choose_nic bez pytań: oczekiwano porty z linkiem, jest '$got'"; fi
  rm -rf "$nicroot"
else
  fail=$((fail+1)); echo "BŁĄD  brak list_mlx5_ports/choose_nic do testu"
fi
# set_workers: rozpoznanie zmian w startup.conf (rdzenie, bufory, sterta, porty), nie tylko rdzeni
vd=$(sed -n '/^KERNEL_JITTER_PARAMS=/p; /^kernel_params_ok() {/,/^}/p; /^vpp_conf_diff() {/,/^}/p' install-router.sh)
if [[ -n $vd ]]; then
  vdc=$(mktemp)
  cat >"$vdc" <<'EOC'
cpu {
  main-core 3
  corelist-workers 5,7,9
}
buffers {
  buffers-per-numa 262144
}
memory { main-heap-size 4G }
dpdk {
  dev 0000:82:00.0 { name hu0 num-rx-queues 3 }
  dev 0000:82:00.1 { name hu1 num-rx-queues 3 }
}
EOC
  vds=$(mktemp); echo "vm.nr_hugepages = 8037" >"$vds"
  vdb=$(mktemp)
  { echo "create tap id 0 host-if-name nf-export host-ns dataplane host-ip4-addr 192.0.2.2/30"
    echo "set ipfix exporter collector 192.0.2.2 port 2055 src 192.0.2.1 fib-id 100 template-interval 20"
    echo "flowprobe params record l2 l3 l4 active 60 passive 300"; } >"$vdb"
  tv() { local got; got=$( ( eval "$vd"; VPP_STARTUP_CONF=$vdc VPP_SYSCTL_CONF=$vds VPP_BOOTSTRAP=$vdb NETFLOW_ACTIVE_TIMER=60 NETFLOW_PASSIVE_TIMER=300 ROUTER_ID=10.10.10.10 NETFLOW_PORT=2055 NETFLOW_ENABLE=yes NETFLOW_TAP_VPP=192.0.2.1 NETFLOW_TAP_LINUX=192.0.2.2 NETFLOW_TAP_FIB=100 NETFLOW_TEMPLATE_INTERVAL=20 WORKERS_CSV=$2 BUFFERS=$3 MAIN_HEAP=$4 HUGEPAGES_2M=${7:-8037}; NIC_PCI=($5); vpp_conf_diff; echo "rc=$?" ) | tr '\n' ' ' ); if [[ $got == *"$6"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  vpp_conf_diff $1: oczekiwano '$6', jest '$got'"; fi; }
  tv "bez zmian"              5,7,9 262144 4G "0000:82:00.0 0000:82:00.1" "rc=1"
  tv "same bufory"            5,7,9 1081344 4G "0000:82:00.0 0000:82:00.1" "bufory 262144 → 1081344"
  tv "zmiana portów"          5,7,9 262144 4G "0000:82:00.0" "porty 0000:82:00.0 0000:82:00.1 → 0000:82:00.0"
  tv "zmiana rdzeni"          5,7,9,11 262144 4G "0000:82:00.0 0000:82:00.1" "rdzenie 5,7,9 → 5,7,9,11"
  tv "zmiana sterty"          5,7,9 262144 2G "0000:82:00.0 0000:82:00.1" "sterta 4G → 2G"
  tv "tylko hugepages"        5,7,9 262144 4G "0000:82:00.0 0000:82:00.1" "hugepages 8037 → 11251" 11251
  vdg=$(mktemp); echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT isolcpus=3,5,7,9 rcu_nocbs=3,5,7,9 panic=10"' >"$vdg"
  got=$( ( eval "$vd"; VPP_STARTUP_CONF=$vdc VPP_SYSCTL_CONF=$vds VPP_BOOTSTRAP=$vdb NETFLOW_ACTIVE_TIMER=60 NETFLOW_PASSIVE_TIMER=300 ROUTER_ID=10.10.10.10 NETFLOW_PORT=2055 NETFLOW_ENABLE=yes NETFLOW_TAP_VPP=192.0.2.1 NETFLOW_TAP_LINUX=192.0.2.2 NETFLOW_TAP_FIB=100 NETFLOW_TEMPLATE_INTERVAL=20 VPP_GRUB_CONF=$vdg WORKERS_CSV=5,7,9 BUFFERS=262144 MAIN_HEAP=4G HUGEPAGES_2M=8037 NOHZ_CSV=5,7,9 HK_CSV=0-2; NIC_PCI=(0000:82:00.0 0000:82:00.1); vpp_conf_diff; echo "rc=$?" ) | tr '\n' ' ' )
  if [[ $got == *"izolacja rdzeni"*"rc=0"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  vpp_conf_diff stara izolacja: jest '$got'"; fi
  echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT isolcpus=managed_irq,domain,3,5,7,9 nohz_full=5,7,9 rcu_nocbs=3,5,7,9 irqaffinity=0-2 panic=10 rcupdate.rcu_normal_after_boot=1 iommu=pt skew_tick=1"' >"$vdg"
  got=$( ( eval "$vd"; VPP_STARTUP_CONF=$vdc VPP_SYSCTL_CONF=$vds VPP_BOOTSTRAP=$vdb NETFLOW_ACTIVE_TIMER=60 NETFLOW_PASSIVE_TIMER=300 ROUTER_ID=10.10.10.10 NETFLOW_PORT=2055 NETFLOW_ENABLE=yes NETFLOW_TAP_VPP=192.0.2.1 NETFLOW_TAP_LINUX=192.0.2.2 NETFLOW_TAP_FIB=100 NETFLOW_TEMPLATE_INTERVAL=20 VPP_GRUB_CONF=$vdg WORKERS_CSV=5,7,9 BUFFERS=262144 MAIN_HEAP=4G HUGEPAGES_2M=8037 NOHZ_CSV=5,7,9 HK_CSV=0-2; NIC_PCI=(0000:82:00.0 0000:82:00.1); vpp_conf_diff; echo "rc=$?" ) | tr '\n' ' ' )
  if [[ $got == "rc=1 " ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  vpp_conf_diff nowa izolacja: jest '$got'"; fi
  echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT isolcpus=managed_irq,domain,3,5,7,9 nohz_full=5,7,9 rcu_nocbs=3,5,7,9 irqaffinity=0-2 panic=10"' >"$vdg.old"
  got=$( ( eval "$vd"; VPP_STARTUP_CONF=$vdc VPP_SYSCTL_CONF=$vds VPP_BOOTSTRAP=$vdb NETFLOW_ACTIVE_TIMER=60 NETFLOW_PASSIVE_TIMER=300 ROUTER_ID=10.10.10.10 NETFLOW_PORT=2055 NETFLOW_ENABLE=yes NETFLOW_TAP_VPP=192.0.2.1 NETFLOW_TAP_LINUX=192.0.2.2 NETFLOW_TAP_FIB=100 NETFLOW_TEMPLATE_INTERVAL=20 VPP_GRUB_CONF=$vdg.old WORKERS_CSV=5,7,9 BUFFERS=262144 MAIN_HEAP=4G HUGEPAGES_2M=8037 NOHZ_CSV=5,7,9 HK_CSV=0-2; NIC_PCI=(0000:82:00.0 0000:82:00.1); vpp_conf_diff; echo "rc=$?" ) | tr '\n' ' ' )
  if [[ $got == *"parametry kernela"*"iommu=pt"*"rc=0"* && $got != *"izolacja rdzeni"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  vpp_conf_diff brak parametrów kernela: jest '$got'"; fi
  rm -f "$vdg.old"
  cm=$(eval "$(sed -n '/^cpu_mask() {/,/^}/p' install-router.sh)"; cpu_mask 0 1 40)
  if [[ $cm == "00000100,00000003" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  cpu_mask: jest '$cm'"; fi
  got=$( ( eval "$vd"; VPP_STARTUP_CONF=$vdc VPP_SYSCTL_CONF=$vds VPP_BOOTSTRAP=$vdb NETFLOW_ACTIVE_TIMER=60 NETFLOW_PASSIVE_TIMER=300 ROUTER_ID=10.10.10.10 NETFLOW_PORT=2055 NETFLOW_ENABLE=yes NETFLOW_TAP_VPP=192.0.2.1 NETFLOW_TAP_LINUX=192.0.2.2 NETFLOW_TAP_FIB=100 NETFLOW_TEMPLATE_INTERVAL=20 VPP_GRUB_CONF=/nonexistent WORKERS_CSV=5,7,9 BUFFERS=262144 MAIN_HEAP=4G HUGEPAGES_2M=8037 NOHZ_CSV=5,7,9 HK_CSV=0-2; NIC_PCI=(0000:82:00.0 0000:82:00.1); vpp_conf_diff vpp; echo "rc=$?" ) | tr '\n' ' ' )
  if [[ $got == "rc=1 " ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  vpp_conf_diff vpp (bez izolacji): jest '$got'"; fi
  vdt=$(mktemp); echo '[always] madvise never' >"$vdt"
  got=$( ( eval "$vd"; VPP_STARTUP_CONF=$vdc VPP_SYSCTL_CONF=$vds VPP_BOOTSTRAP=$vdb NETFLOW_ACTIVE_TIMER=60 NETFLOW_PASSIVE_TIMER=300 ROUTER_ID=10.10.10.10 NETFLOW_PORT=2055 NETFLOW_ENABLE=yes NETFLOW_TAP_VPP=192.0.2.1 NETFLOW_TAP_LINUX=192.0.2.2 NETFLOW_TAP_FIB=100 NETFLOW_TEMPLATE_INTERVAL=20 VPP_GRUB_CONF=$vdg VPP_NUMA_BALANCING=1 VPP_THP_FILE=$vdt WORKERS_CSV=5,7,9 BUFFERS=262144 MAIN_HEAP=4G HUGEPAGES_2M=8037 NOHZ_CSV=5,7,9 HK_CSV=0-2; NIC_PCI=(0000:82:00.0 0000:82:00.1); vpp_conf_diff; echo "rc=$?" ) | tr '\n' ' ' )
  if [[ $got == *"numa_balancing"*"transparent hugepages"*"rc=0"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  vpp_conf_diff numa_balancing/THP: jest '$got'"; fi
  vdt2=$(mktemp); echo 'always [madvise] never' >"$vdt2"
  got=$( ( eval "$vd"; VPP_STARTUP_CONF=$vdc VPP_SYSCTL_CONF=$vds VPP_BOOTSTRAP=$vdb NETFLOW_ACTIVE_TIMER=60 NETFLOW_PASSIVE_TIMER=300 ROUTER_ID=10.10.10.10 NETFLOW_PORT=2055 NETFLOW_ENABLE=yes NETFLOW_TAP_VPP=192.0.2.1 NETFLOW_TAP_LINUX=192.0.2.2 NETFLOW_TAP_FIB=100 NETFLOW_TEMPLATE_INTERVAL=20 VPP_GRUB_CONF=$vdg VPP_NUMA_BALANCING=0 VPP_THP_FILE=$vdt2 WORKERS_CSV=5,7,9 BUFFERS=262144 MAIN_HEAP=4G HUGEPAGES_2M=8037 NOHZ_CSV=5,7,9 HK_CSV=0-2; NIC_PCI=(0000:82:00.0 0000:82:00.1); vpp_conf_diff; echo "rc=$?" ) | tr '\n' ' ' )
  if [[ $got == "rc=1 " ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  vpp_conf_diff numa_balancing=0 i THP madvise: jest '$got'"; fi
  got=$( ( eval "$vd"; VPP_STARTUP_CONF=$vdc VPP_SYSCTL_CONF=$vds VPP_BOOTSTRAP=/nonexistent NETFLOW_ACTIVE_TIMER=60 NETFLOW_PASSIVE_TIMER=300 ROUTER_ID=10.10.10.10 NETFLOW_PORT=2055 NETFLOW_ENABLE=yes NETFLOW_TAP_VPP=192.0.2.1 NETFLOW_TAP_LINUX=192.0.2.2 NETFLOW_TAP_FIB=100 NETFLOW_TEMPLATE_INTERVAL=20 VPP_GRUB_CONF=$vdg VPP_NUMA_BALANCING=0 VPP_THP_FILE=$vdt2 WORKERS_CSV=5,7,9 BUFFERS=262144 MAIN_HEAP=4G HUGEPAGES_2M=8037 NOHZ_CSV=5,7,9 HK_CSV=0-2; NIC_PCI=(0000:82:00.0 0000:82:00.1); vpp_conf_diff; echo "rc=$?" ) | tr '\n' ' ' )
  if [[ $got == *"NetFlow/IPFIX"*"rc=0"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  vpp_conf_diff flowprobe nieskonfigurowany: jest '$got'"; fi
  got=$( ( eval "$vd"; VPP_STARTUP_CONF=$vdc VPP_SYSCTL_CONF=$vds VPP_BOOTSTRAP=$vdb NETFLOW_ACTIVE_TIMER=60 NETFLOW_PASSIVE_TIMER=300 ROUTER_ID=10.10.10.10 NETFLOW_PORT=2055 NETFLOW_ENABLE=yes NETFLOW_TAP_VPP=192.0.2.1 NETFLOW_TAP_LINUX=192.0.2.2 NETFLOW_TAP_FIB=100 NETFLOW_TEMPLATE_INTERVAL=20 VPP_GRUB_CONF=$vdg VPP_NUMA_BALANCING=0 VPP_THP_FILE=$vdt2 VPP_COMPACT_PROACTIVE=20 VPP_KTHREADS_UNIT=/nonexistent VPP_KTHREADS_TIMER=/nonexistent WORKERS_CSV=5,7,9 BUFFERS=262144 MAIN_HEAP=4G HUGEPAGES_2M=8037 NOHZ_CSV=5,7,9 HK_CSV=0-2; NIC_PCI=(0000:82:00.0 0000:82:00.1); vpp_conf_diff; echo "rc=$?" ) | tr '\n' ' ' )
  if [[ $got == *"compaction_proactiveness"*"router-kthreads.service / router-kthreads-check.timer"*"rc=0"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  vpp_conf_diff kompakcja/router-kthreads: jest '$got'"; fi
  got=$( ( eval "$vd"; VPP_STARTUP_CONF=$vdc VPP_SYSCTL_CONF=$vds VPP_BOOTSTRAP=$vdb NETFLOW_ACTIVE_TIMER=60 NETFLOW_PASSIVE_TIMER=300 ROUTER_ID=10.10.10.10 NETFLOW_PORT=2055 NETFLOW_ENABLE=yes NETFLOW_TAP_VPP=192.0.2.1 NETFLOW_TAP_LINUX=192.0.2.2 NETFLOW_TAP_FIB=100 NETFLOW_TEMPLATE_INTERVAL=20 VPP_GRUB_CONF=$vdg VPP_NUMA_BALANCING=0 VPP_THP_FILE=$vdt2 VPP_COMPACT_PROACTIVE=0 VPP_KTHREADS_UNIT=$vdt2 VPP_KTHREADS_TIMER=$vdt2 WORKERS_CSV=5,7,9 BUFFERS=262144 MAIN_HEAP=4G HUGEPAGES_2M=8037 NOHZ_CSV=5,7,9 HK_CSV=0-2; NIC_PCI=(0000:82:00.0 0000:82:00.1); vpp_conf_diff; echo "rc=$?" ) | tr '\n' ' ' )
  if [[ $got == "rc=1 " ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  vpp_conf_diff kompakcja=0 i router-kthreads.service jest: jest '$got'"; fi
  # pierścienie: fixture startup.conf nie ma num-rx-desc → podbicie VPP_RX_DESC musi być zmianą (wcześniej "zgodny")
  echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT isolcpus=managed_irq,domain,3,5,7,9 nohz_full=5,7,9 rcu_nocbs=3,5,7,9 irqaffinity=0-2 panic=10 rcupdate.rcu_normal_after_boot=1 iommu=pt skew_tick=1"' >"$vdg"
  sed -i.bak 's/num-rx-queues 3 }/num-rx-queues 3 num-rx-desc 16384 num-tx-desc 4096 }/' "$vdc"
  for want in "32768 rc=0" "16384 rc=1"; do
    got=$( ( eval "$vd"; VPP_STARTUP_CONF=$vdc VPP_SYSCTL_CONF=$vds VPP_BOOTSTRAP=$vdb NETFLOW_ACTIVE_TIMER=60 NETFLOW_PASSIVE_TIMER=300 ROUTER_ID=10.10.10.10 NETFLOW_PORT=2055 NETFLOW_ENABLE=yes NETFLOW_TAP_VPP=192.0.2.1 NETFLOW_TAP_LINUX=192.0.2.2 NETFLOW_TAP_FIB=100 NETFLOW_TEMPLATE_INTERVAL=20 VPP_GRUB_CONF=$vdg VPP_NUMA_BALANCING=0 VPP_THP_FILE=$vdt2 VPP_COMPACT_PROACTIVE=0 VPP_KTHREADS_UNIT=$vdt2 VPP_KTHREADS_TIMER=$vdt2 VPP_RX_DESC=${want% *} VPP_TX_DESC=4096 WORKERS_CSV=5,7,9 BUFFERS=262144 MAIN_HEAP=4G HUGEPAGES_2M=8037 NOHZ_CSV=5,7,9 HK_CSV=0-2; NIC_PCI=(0000:82:00.0 0000:82:00.1); vpp_conf_diff vpp; echo "rc=$?" ) | tr '\n' ' ' )
    if [[ $got == *"${want#* }"* && ( ${want% *} == 16384 || $got == *"pierścień RX 16384 → 32768"* ) ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  vpp_conf_diff pierścień RX ${want% *}: jest '$got'"; fi
  done
  rm -f "$vdc.bak"
  rm -f "$vdg" "$vdt" "$vdt2"
  rm -f "$vdc" "$vds" "$vdb"
else
  fail=$((fail+1)); echo "BŁĄD  brak funkcji vpp_conf_diff"
fi
chk "do_set_workers nie kończy się tylko po rdzeniach" 'vpp_conf_diff >/dev/null [|][|] return 0' 1
# calc_hugepages: automatyczna pula hugepages (35% RAM, 2048..12288 stron po 2 MB)
ch=$(sed -n '/^calc_hugepages() {/,/^}/p' install-router.sh)
if [[ -n $ch ]]; then
  eval "$ch"
  th() { local got; got=$(calc_hugepages "$2"); if [[ $got == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  calc_hugepages $1: oczekiwano $3, jest $got"; fi; }
  th "router lodz2 (64 GB RAM)"   64296 11251
  th "mało RAM: dolny próg"       8192 2048
  th "dużo RAM: górny próg"       262144 12288
else
  fail=$((fail+1)); echo "BŁĄD  brak funkcji calc_hugepages"
fi
chk "set_workers uruchamia też etap 05 (hugepages)" 'run_stage 05 .*st_kernel$' 2
# hugepages_for: pula hugepages wyliczona od zapotrzebowania (sterta + zapas + bufory, +15%, po równo na węzły), nie z % RAM
hf=$(sed -n '/^hugepages_for() {/,/^}/p' install-router.sh)
if [[ -n $hf ]]; then
  eval "$hf"
  tf() { local got; got=$(hugepages_for "$2" "$3" "$4" "$5"); if [[ $got == "$6" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  hugepages_for $1: oczekiwano $6, jest $got"; fi; }
  tf "lodz2: 704512 buforów, sterta 4 GB, 2 węzły"  704512 4096 2 64296 8110
  tf "mało RAM: ograniczone do 50% RAM"             704512 2048 2 8192 2048
else
  fail=$((fail+1)); echo "BŁĄD  brak funkcji hugepages_for"
fi
# dobór workerów wg wydajności rdzenia: <opis> <MHz maks.> <wolne rdzenie> <NIC_CAP> <porty Mb/s> <PCIe Gb/s> <oczekiwane workery>
sizing=$(sed -n '/^CYC_FWD=1600/,/^MAIN_CORE=/p' install-router.sh | sed '$d')
tw() {
  local got
  got=$( ( audit() { :; }; rec() { :; }; eval "$(sed -n '/^fmt_mpps() {/p' install-router.sh)"
           PHYS=(0); VPP_WORKERS=auto VPP_SIZING_PKT=800 NIC_MODEL=test ROUTER_TEST_CPU_KHZ=$2 avail_w=$3 NIC_CAP=$4 \
           PORTS_MBPS=$5 PCIE_GBPS=$6; eval "$sizing"; echo "$VPP_WORKERS" ) 2>&1 )
  if [[ $got == "$7" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  dobór workerów $1: oczekiwano $7, jest '$got'"; fi
}
tw "R630 (3,6 GHz, CX-4, PCIe Gen3)"        3600000 18 12 200000 100 12
tw "wolny 2,0 GHz: więcej niż NIC_CAP"       2000000 18 12 200000 100 18
tw "wolny, mało rdzeni: tyle, ile wolnych"   2000000 10 12 200000 100 10
tw "bardzo wolny: najwyżej 2× NIC_CAP"       1200000 40 8  200000 100 16
tw "szybki 4,5 GHz: NIC_CAP (zapas na DDoS)" 4500000 30 12 100000 100 12
tw "CX-4 Lx 2×25G: mało ruchu, NIC_CAP"      2400000 20 8  50000  0   8
chk "domyślnie VPP_BUFFERS=auto (od zapotrzebowania)" '^VPP_BUFFERS=auto ' 1
printf '\nWynik: %d OK, %d błędów\n' "$pass" "$fail"
((fail == 0))
