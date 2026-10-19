# Szablony monitoringu: LibreNMS, Zabbix, Cacti

Szablony do routera z `install-router.sh` w wersji 1.5.0 lub nowszej. Na działającym routerze wystarczy
`install-router.sh upgrade_script`, który doinstaluje kolektor `router-snmp` i dopisze go do snmpd.

Plików w tym katalogu nie edytuj ręcznie, bo generuje je `python3 tools/build-templates.py` ze schematu OID w
programie `router-snmp`. Zmiana obiektu SNMP to zmiana w `install-router.sh` (`prog_router_snmp`: `SCALARS` i `TABLES`)
i ponowne uruchomienie generatora. Test `tests/test_router_snmp.py` pilnuje, żeby szablony nie rozjechały się z agentem.

## Co oddaje router

Odpytuj adres **loop0**, bo tam działa `snmpd-dataplane` i tylko tam są porty VPP. Port zarządzający (`snmpd-mgmt`)
oddaje to samo bez portów VPP, więc dodaj router tylko raz, po loop0.

| Źródło | Gałąź | Zawartość |
|---|---|---|
| `vpp-snmp-agent` (AgentX) | IF-MIB `ifTable`, `ifXTable` | porty VPP, VLAN-y, loop0: liczniki 64-bitowe, stan, prędkość, `ifAlias` z `ifaces.conf` |
| `router-snmp` | ROUTER-VPP-MIB `.1.3.6.1.4.1.8072.9999.9999.630` | BGP (IPv4 i IPv6), zdrowie VPP, FIB vs BIRD, firewall, guard, RPKI, usługi, RAID, SMART, temperatury CPU, alarmy |
| `router-snmp` | BGP4-MIB `.1.3.6.1.2.1.15` | sesje BGP IPv4 w standardzie (strona „BGP” w LibreNMS) |
| snmpd | HOST-RESOURCES, UCD-SNMP | CPU, RAM, systemy plików, load; `extend mdadm` dla aplikacji LibreNMS |

Pełna lista obiektów jest w [OID-LIST.md](OID-LIST.md), a plik MIB w `mib/ROUTER-VPP-MIB.txt`.

Dane zbiera `router-snmp.service` co 30 sekund (SMART co 10 minut, firewall i guard co minutę) i zapisuje je do
`/run/router-snmp/cache.json`. snmpd tylko czyta ten plik, więc zapytanie SNMP nigdy nie czeka na `vppctl` ani `birdc`.
Jeśli kolektor stanie, `rvDataAge` rośnie, a po 5 minutach router przestaje oddawać pozostałe wartości. Szablony
alarmują w obu przypadkach.

Sprawdzenie:

```
router-snmp walk                                                   # na routerze: wszystko, co widzi NMS
snmpwalk -v2c -c <community> <loop0> .1.3.6.1.4.1.8072.9999.9999.630  # z serwera NMS
snmpwalk -v2c -c <community> <loop0> .1.3.6.1.2.1.15                 # BGP4-MIB
```

Ograniczenia:

- BGP4-MIB zna tylko sesje IPv4 i 2-bajtowe numery AS. 4-bajtowy AS jest w nim podawany jako 23456 (AS_TRANS), a liczniki
  komunikatów wynoszą 0, bo BIRD ich nie podaje. Sesje IPv6, prawdziwe numery AS i liczby prefiksów są w
  `rvBgpPeerTable`.
- `rvBgpPeerFlaps` liczy upadki sesji od pierwszego uruchomienia kolektora.
- Liczniki VPP (Counter64) zerują się po restarcie VPP. NMS traktuje to jak przekręcenie licznika i pomija jedną próbkę.

## LibreNMS

LibreNMS rozpoznaje router jako system `vpprouter` (Linux z ROUTER-VPP-MIB) i zakłada czujniki ze stanami i limitami.
Domyślne reguły alarmów LibreNMS (sensor poza limitem, czujnik stanu w błędzie) działają na nich bez dodatkowej
konfiguracji.

Instalacja na serwerze LibreNMS, z katalogu `templates/`:

```
L=/opt/librenms
cp librenms/os_detection/vpprouter.yaml  $L/resources/definitions/os_detection/
cp librenms/os_discovery/vpprouter.yaml  $L/resources/definitions/os_discovery/
mkdir -p $L/mibs/vpprouter && cp librenms/mibs/vpprouter/ROUTER-VPP-MIB $L/mibs/vpprouter/
chown -R librenms:librenms $L/resources/definitions $L/mibs/vpprouter
rm -f $L/cache/os_defs.cache
sudo -u librenms $L/discovery.php -h <router> -d | grep -iE 'vpprouter|ROUTER-VPP'
```

Router dodaj po adresie loop0 (SNMP v2c, community z `/etc/router/router.env`). Jeśli był już dodany jako `linux`,
po skopiowaniu plików wystarczy ponowne odkrywanie (`discovery.php -h <router>`), bo typ systemu zmieni się sam.

Po odkryciu w LibreNMS pojawią się:

- **Czujniki stanu:** VPP, każda sesja BGP (IPv4 i IPv6, z opisem), usługi routera, RPKI, macierze RAID, SMART
  dysków, zgodność interfejsów, firewalla i guarda z konfiguracją, tryb guarda.
- **Liczniki z limitami:** największy wektor workera (ostrzeżenie 64, alarm 160), punt, rx-miss, odrzucenia
  sprzętowe, niedziałające usługi, alarmy krytyczne, prefiksy per sesja, VRP, trasy FIB i BIRD.
- **Procenty:** wolne bufory VPP (alarm poniżej 20%), rdzeń systemowy, różnica FIB i BIRD, tablice guarda, zużycie SSD.
- **Temperatury:** dyski i procesory.
- **BGP:** strona sesji IPv4 z BGP4-MIB.
- **Aplikacja mdadm:** włącz ją w ustawieniach urządzenia, w zakładce Applications.

Progi zmienisz w LibreNMS (edycja czujnika) albo w `os_discovery/vpprouter.yaml` przed kopiowaniem. Aktualizacja
LibreNMS (`daily.sh`) nie usuwa tych plików, ale `validate.php` może je zgłaszać jako dodatkowe.

## Zabbix (6.0 i nowsze)

1. Zaimportuj `zabbix/router_vpp_bird_snmp.yaml`. W Zabbix 6.0 jest to *Configuration → Templates → Import*, w 6.4 i
   7.x *Data collection → Templates → Import*.
2. Dodaj host z interfejsem SNMP na adresie **loop0** (SNMPv2, community z `/etc/router/router.env`).
3. Podłącz szablony **Router VPP BIRD by SNMP** (ten) oraz standardowy **Linux by SNMP** (interfejsy IF-MIB, CPU,
   pamięć, systemy plików).

Szablon zawiera:

- **Pozycje skalarne:** wiek danych, VPP, bufory, FIB i BIRD, firewall, guard, alarmy. Liczniki Counter64 są od razu
  przeliczane na wartość na sekundę.
- **Odkrywanie:** sesje BGP, porty VPP, liczniki błędów VPP, usługi, RPKI, RAID, dyski, temperatury CPU, workery.
- **Wyzwalacze:**
  - VPP nie działa;
  - przeciążony worker;
  - rx-miss;
  - odrzucenia karty;
  - punt;
  - kończące się bufory;
  - rozjazd FIB i BIRD;
  - rozjazd interfejsów, firewalla i guarda;
  - sesja BGP nie zestawiona (tylko gdy jest włączona);
  - sesja flapuje;
  - prefiksy blisko limitu;
  - usługa nie działa;
  - brak RPKI;
  - zdegradowany RAID;
  - SMART;
  - temperatury;
  - nieaktualne dane.
- **Makra z progami**, które zmieniasz na hoście albo w szablonie:

  | Makro | Domyślnie |
  |---|---|
  | `{$RV.VECTOR.WARN}` / `{$RV.VECTOR.CRIT}` | 64 / 160 |
  | `{$RV.RXMISS.MAX}` | 1 pkt/s |
  | `{$RV.DISCARD.MAX}` | 1 pkt/s |
  | `{$RV.PUNT.MAX}` | 20000 pkt/s |
  | `{$RV.HKCPU.MAX}` | 90% |
  | `{$RV.BUF.FREE.MIN}` | 20% |
  | `{$RV.FIB.DIFF.MAX}` | 2% |
  | `{$RV.GUARD.TABLE.MAX}` | 90% |
  | `{$RV.BGP.FLAPS.MAX}` | 3 na godzinę |
  | `{$RV.BGP.LIMIT.PCT}` | 90% limitu |
  | `{$RV.DISK.TEMP.MAX}` | 60 °C |
  | `{$RV.DISK.WEAR.MAX}` | 80% |
  | `{$RV.CPU.TEMP.MAX}` | 85 °C |
  | `{$RV.DATA.AGE.MAX}` | 300 s |

## Cacti (1.2.20 i nowsze)

Cały szablon jest w jednym pliku: **`cacti/install-cacti-router-vpp.sh`**. Skopiuj go na serwer Cacti i uruchom:

```
scp templates/cacti/install-cacti-router-vpp.sh root@<serwer-cacti>:/root/
bash /root/install-cacti-router-vpp.sh --preview    # podgląd: co zostanie dodane lub zmienione
bash /root/install-cacti-router-vpp.sh              # instalacja (katalog Cacti wykrywany sam)
bash /root/install-cacti-router-vpp.sh /var/www/html/cacti   # albo z podanym katalogiem
```

Skrypt zapisuje 9 zapytań SNMP do `<cacti>/resource/snmp_queries/` i importuje szablon przez
`cli/import_template.php`. Ponowne uruchomienie, np. po aktualizacji routera, aktualizuje te same obiekty i nie
tworzy kopii.

Dlaczego skrypt, a nie sam plik XML do zaimportowania w przeglądarce: zapytanie SNMP w Cacti to plik XML na dysku
serwera. Import w przeglądarce (*Import Templates*) nie zapisuje plików. Zapisuje je tylko pakiet (*Import Packages*),
ale Cacti przyjmuje wyłącznie pakiety podpisane kluczem Cacti Group.

Jeśli wolisz import w przeglądarce: skopiuj `cacti/resource/snmp_queries/*.xml` do `<cacti>/resource/snmp_queries/`,
a potem zaimportuj `cacti/router_vpp_bird_cacti.xml` w *Import/Export → Import Templates*. Efekt jest ten sam.

Po instalacji:

1. *Management → Devices → Add*: adres **loop0**, SNMP v2c, community z `/etc/router/router.env`,
   Device Template **Router VPP BIRD**.
2. W urządzeniu: *Create Graphs for this Device*. Wykresy skalarne powstają od razu. Wykresy z zapytań (sesje BGP,
   porty, dyski itd.) zaznaczasz na liście, a zapytanie sprawdzisz opcją *Verbose Query*.

Co zawiera szablon urządzenia **Router VPP BIRD**:

| Wykresy skalarne | Wykresy z zapytań SNMP (dla każdego wiersza tablicy) |
|---|---|
| VPP: największy wektor workera, straty pakietów, punt, bufory i wolne bufory | VPP: wektor każdego workera |
| System: najbardziej zajęty rdzeń | Port VPP: rx-miss, rx-no-buf, odrzucenia karty, błędy, drops, punt |
| Trasy IPv4 i IPv6: FIB VPP i BIRD, różnica FIB i BIRD | `show errors`: każdy niezerowy licznik |
| Firewall: pakiety permit, deny i blokad, odrzucony ruch (b/s), blokady doraźne | BGP: prefiksy (przyjęte, wysłane, odfiltrowane, limit), stan sesji |
| Guard: liczniki i zapełnienie tablic | Usługi routera, RPKI (VRP), RAID (synchronizacja, degradacja) |
| RPKI: trasy INVALID; alarmy, niedziałające usługi, stan (VPP, rozjazdy), wiek danych | Dyski: temperatura, sektory, zużycie SSD; temperatury CPU |

Liczniki są zapisywane jako DERIVE z minimum 0, więc zerowanie po restarcie VPP daje jedną pustą próbkę zamiast
skoku na wykresie. Krok próbkowania bierze się z domyślnego profilu źródeł danych w Cacti (zwykle 5 minut).

Szablon podpina też standardowe obiekty Cacti, o ile są zainstalowane (pakiety *Generic SNMP Device* i
*Net-SNMP Device*): **SNMP - Interface Statistics** (ruch na portach i VLAN-ach z `vpp-snmp-agent`), *Get Mounted
Partitions*, *Uptime*, *Load Average*, *Memory Usage* i *CPU Utilization*.

Pliki w `cacti/`:

| Plik | Do czego |
|---|---|
| `install-cacti-router-vpp.sh` | **jeden plik do instalacji**: zapytania SNMP i szablon w środku |
| `router_vpp_bird_cacti.xml` | sam szablon do importu w przeglądarce (wymaga plików z `resource/`) |
| `resource/snmp_queries/*.xml` | zapytania SNMP: sesje BGP, porty, `show errors`, workery, usługi, RPKI, RAID, dyski, temperatury |
