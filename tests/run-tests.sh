#!/usr/bin/env bash
# Testy router-ifaces na symulatorze VPP (tests/fakevpp.py) oraz trybu upgrade_script (tests/test-upgrade.sh) — bez VPP, bez roota, działa na macOS i Linuksie.
#   bash tests/run-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
bash tools/extract.sh >/dev/null || exit 1
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/root/etc/router"
ln -s "$PWD/tests/fakevpp.py" "$W/bin/fakevppctl"
ln -s "$PWD/tests/fakevpp.py" "$W/bin/fakeip"
chmod 755 tests/fakevpp.py
export ROUTER_IFACES_ROOT=$W/root FAKEVPP_STATE=$W/vpp.json ROUTER_IFACES_SYSTEMD=0
export ROUTER_IFACES_VPPCTL=$W/bin/fakevppctl ROUTER_IFACES_IP=$W/bin/fakeip
RI="python3 $PWD/build/router-ifaces"
CONF=$W/root/etc/router/ifaces.conf
echo 'INST_NIC_PCI="0000:82:00.0 0000:82:00.1"' >"$W/root/etc/router/router.env"
pass=0 fail=0
t() {   # t <opis> <oczekiwany kod> <polecenie...>
  local name=$1 want=$2 out rc; shift 2
  out=$("$@" 2>&1); rc=$?
  if [[ $rc == "$want" ]]; then pass=$((pass + 1)); printf '  OK    %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  BŁĄD  %s (kod %s, oczekiwano %s)\n' "$name" "$rc" "$want"
    [[ -n $out ]] && printf '%s\n' "$out" | sed 's/^/        /'
  fi
}
has() { local o; o=$("${@:2}" 2>&1); grep -qF -- "$1" <<<"$o"; }   # has <tekst> <polecenie...>
vpp() { $W/bin/fakevppctl "$@"; }

cat >"$CONF" <<'C'
hu0     -    -                -                    Trunk 100G
hu0     100  192.0.2.2/30     2001:db8:100::2/64   Transit: EPIX AS62081
hu0     200  198.51.100.2/30  -                    Transit: Upstream-2
hu0     300  10.255.0.1/30    -                    Core: BNG
loop0   -    203.0.113.1/32   2001:db8::1/128      Loopback
C
echo "1. pierwsze wdrożenie"
t "diff pokazuje zmiany (kod 1)"            1 $RI diff
t "apply"                                   0 $RI apply -y
t "check: zgodne"                           0 $RI check
t "VLAN 100 ma adres w VPP"                 0 has "L3 192.0.2.2/30" vpp show interface address
t "VLAN 100 ma parę linux-cp"               0 has "hu0.100" vpp show lcp
t "opis w Linuksie"                         0 has "Transit: EPIX AS62081" $W/bin/fakeip -n dataplane -j link show
t "opis w pliku SNMP"                       0 grep -q '"Transit: EPIX AS62081"' "$W/root/etc/router/snmp-ifaces.yaml"
t "diff po apply: brak zmian"               0 $RI diff

echo "2. zmiany: adres, opis, usunięcie VLAN-u"
sed -i.bak -e 's#192.0.2.2/30#192.0.2.6/30#' -e 's#Core: BNG#Core: ASR1001-X BNG#' -e '/^hu0     200/d' "$CONF"
t "apply"                                   0 $RI apply -y
t "stary adres usunięty"                    1 has "L3 192.0.2.2/30" vpp show interface address
t "nowy adres jest"                         0 has "L3 192.0.2.6/30" vpp show interface address
t "VLAN 200 skasowany"                      1 has "hu0.200" vpp show interface
t "nowy opis"                               0 has "Core: ASR1001-X BNG" $W/bin/fakeip -n dataplane -j link show

echo "3. obiekty ręczne i rozjazd"
vpp create sub-interfaces hu0 999 dot1q 999 exact-match >/dev/null
vpp set interface ip address hu0.100 172.16.0.1/24 >/dev/null
t "check wykrywa rozjazd (kod 1)"           1 $RI check
t "check --log zapisuje DRIFT"              1 $RI check --log
t "DRIFT w logu"                            0 grep -q "IFACE-4-DRIFT" "$W/root/var/log/router-monitor/router-monitor.log"
t "apply naprawia"                          0 $RI apply -y
t "obcy adres usunięty"                     1 has "172.16.0.1" vpp show interface address
t "ręczny VLAN 999 nietknięty"              0 has "hu0.999" vpp show interface
t "DRIFT_END w logu"                        0 grep -q "IFACE-5-DRIFT_END" "$W/root/var/log/router-monitor/router-monitor.log"

echo "4. błędy w pliku = nic nie jest zmieniane"
cp "$CONF" "$W/good.conf"
cat >>"$CONF" <<'C'
hu0     4095 10.0.0.1/24      -   zły VLAN
hu2     10   10.1.0.1/24      -   nie ma portu
hu0     400  10.255.0.2/30    -   nakłada się na hu0.300
hu0     401  10.9.0.0/24      -   adres sieci
hu0     402  10.8.0.1/30      -   mtu=9000 MTU zabronione
C
t "diff: błędy (kod 2)"                     2 $RI diff
t "apply: błędy (kod 2)"                    2 $RI apply -y
t "komunikat o MTU"                         0 has "MTU nie ustawia się" $RI diff
t "VLAN 400 nie powstał"                    1 has "hu0.400" vpp show interface

echo "5. restart VPP i odtworzenie"
rm -f "$FAKEVPP_STATE"
t "boot z błędnym plikiem → last-good"      0 $RI boot --timeout 5
t "CONFIG_ERROR w logu"                     0 grep -q "IFACE-2-CONFIG_ERROR" "$W/root/var/log/router-monitor/router-monitor.log"
t "VLAN 100 odtworzony"                     0 has "L3 192.0.2.6/30" vpp show interface address
cp "$W/good.conf" "$CONF"
rm -f "$FAKEVPP_STATE"
t "boot z poprawnym plikiem"                0 $RI boot --timeout 5
t "check po boot: zgodne"                   0 $RI check
t "loopback odtworzony"                     0 has "L3 203.0.113.1/32" vpp show interface address

echo
bash tests/test-upgrade.sh || fail=$((fail + 1))

echo
python3 tests/test_router_fw.py || fail=$((fail + 1))

echo
bash tests/test-installer.sh || fail=$((fail + 1))

echo
bash tests/test-guard-core.sh || fail=$((fail + 1))

echo
python3 tests/test_router_guard.py || fail=$((fail + 1))

printf '\nWynik: %d OK, %d błędów\n' "$pass" "$fail"
((fail == 0))
