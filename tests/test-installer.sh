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
chk "wersja skryptu 1.4.0"                     '^SCRIPT_VERSION="1\.4\.0"' 1
chk "router-guard w UPGRADE_PROGRAMS"          '"router-guard\|/opt/router/bin/router-guard\|755\|prog_router_guard\|"' 1
chk "router-fw w UPGRADE_PROGRAMS"            '"router-fw\|/opt/router/bin/router-fw\|755\|prog_router_fw\|"' 1
chk "TOTAL_STAGES=26"                         '^TOTAL_STAGES=26$' 1
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
chk "snmpd: blok zaufanych sieci (dataplane i mgmt)" '^\$\(snmp_trusted_block\)$' 2
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
chk "hsflowd: tymczasowy kolektor, gdy SFLOW_COLLECTOR puste" 'echo "  collector \{ ip=127\.0\.0\.1 udpport=6343 \}' 1
chk "etap 26 uruchamia st_loop0_access"       '^run_stage 26 .*st_loop0_access$' 1
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
chk "stopka z autorem (ifaces, fw, guard) definiowana"  '^def signature\(\):' 3
chk "stopka z autorem wołana po poleceniu"    '^    signature\(\)$' 3
chk "tryb set_workers w argumentach"          'set_workers\|--set-workers\) MODE=workers' 1
chk "liczba workerów jako argument"           '^    \[0-9\]\|\[0-9\]\[0-9\]\) ' 1
chk "dry-run dozwolony też dla set_workers"   'MODE != upgrade && \$MODE != workers' 1
chk "set_workers czyta router.env"            'MODE == check \|\| \$MODE == upgrade \|\| \$MODE == workers' 1
chk "do_set_workers zdefiniowane i wołane"    '^do_set_workers\(\) \{' 1
chk "dispatch trybu workers po etapie 01"     '^if \[\[ \$MODE == workers \]\]; then do_set_workers; exit \$\?; fi' 1
chk "set_workers przelicza izolację i VPP"    'run_stage 0[69] .*st_(isolation|vpp_config)$' 4
chk "set_workers nie wymaga internetu"        '^\[\[ \$MODE == workers \]\] \|\| timeout 10 getent' 1
chk "bufory liczone funkcją calc_buffers"      '^calc_buffers\(\) \{' 1
chk "bufory VPP z liczby workerów i portów"   'BUFFERS=\$\(calc_buffers "\$\{#NIC_PCI\[@\]\}" "\$VPP_WORKERS"' 1
chk "plan set_workers pokazuje bufory"        'bufory .*\$BUFFERS' 4
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
vd=$(sed -n '/^vpp_conf_diff() {/,/^}/p' install-router.sh)
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
  tv() { local got; got=$( ( eval "$vd"; VPP_STARTUP_CONF=$vdc VPP_SYSCTL_CONF=$vds WORKERS_CSV=$2 BUFFERS=$3 MAIN_HEAP=$4 HUGEPAGES_2M=${7:-8037}; NIC_PCI=($5); vpp_conf_diff; echo "rc=$?" ) | tr '\n' ' ' ); if [[ $got == *"$6"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "BŁĄD  vpp_conf_diff $1: oczekiwano '$6', jest '$got'"; fi; }
  tv "bez zmian"              5,7,9 262144 4G "0000:82:00.0 0000:82:00.1" "rc=1"
  tv "same bufory"            5,7,9 1081344 4G "0000:82:00.0 0000:82:00.1" "bufory 262144 → 1081344"
  tv "zmiana portów"          5,7,9 262144 4G "0000:82:00.0" "porty 0000:82:00.0 0000:82:00.1 → 0000:82:00.0"
  tv "zmiana rdzeni"          5,7,9,11 262144 4G "0000:82:00.0 0000:82:00.1" "rdzenie 5,7,9 → 5,7,9,11"
  tv "zmiana sterty"          5,7,9 262144 2G "0000:82:00.0 0000:82:00.1" "sterta 4G → 2G"
  tv "tylko hugepages"        5,7,9 262144 4G "0000:82:00.0 0000:82:00.1" "hugepages 8037 → 11251" 11251
  rm -f "$vdc" "$vds"
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
chk "domyślnie VPP_BUFFERS=auto (od zapotrzebowania)" '^VPP_BUFFERS=auto ' 1
printf '\nWynik: %d OK, %d błędów\n' "$pass" "$fail"
((fail == 0))
