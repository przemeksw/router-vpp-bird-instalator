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

## Cacti (1.2)

Cacti nie ma formatu szablonów, który dałoby się poprawnie wygenerować poza samym Cacti, bo eksport XML zawiera
wewnętrzne skróty (hash) instancji. Dlatego są tu **zapytania SNMP (Data Queries)**: definicje tablic z indeksami,
nazwami i wszystkimi OID-ami. Wykresy dodajesz do nich raz, w interfejsie Cacti.

1. Skopiuj `cacti/resource/snmp_queries/*.xml` do `<cacti>/resource/snmp_queries/`.
2. Dla każdego pliku utwórz zapytanie w *Data Collection → Data Queries → Add*:
   - nazwa: dowolna, np. „Router VPP - sesje BGP”;
   - XML Path: `<path_cacti>/resource/snmp_queries/router_vpp_bgp_peers.xml`;
   - Data Input Method: **Get SNMP Data (Indexed)**.
3. Dla wybranych kolumn wyjściowych (`direction = output`) utwórz Data Template i Graph Template i powiąż je z
   zapytaniem w sekcji *Associated Graph Templates*. Liczniki Counter64 ustaw jako COUNTER, pozostałe jako GAUGE.
4. Na urządzeniu (adres loop0) dodaj zapytanie w *Associated Data Queries* i sprawdź je opcją *Verbose Query*.
5. Pojedyncze wartości, np. wolne bufory VPP (`...630.2.11.0`) albo różnicę FIB i BIRD (`...630.2.20.0`), dodaj
   szablonem **SNMP - Generic OID Template**. Numery OID są w [OID-LIST.md](OID-LIST.md).

| Plik | Tablica |
|---|---|
| `router_vpp_bgp_peers.xml` | sesje BGP: stan, czas, prefiksy przyjęte, wysłane i odfiltrowane, limit, upadki |
| `router_vpp_ports.xml` | porty VPP: rx-miss, rx-no-buf, błędy, drops, punt, odrzucenia sprzętowe |
| `router_vpp_errors.xml` | liczniki `show errors` (tylko niezerowe) |
| `router_vpp_workers.xml` | wektor każdego workera |
| `router_vpp_services.xml` | usługi routera |
| `router_vpp_rpki.xml` | RPKI: połączenie, VRP IPv4 i IPv6 |
| `router_vpp_raid.xml` | macierze mdadm |
| `router_vpp_disks.xml` | SMART: stan, temperatura, sektory, czas pracy, zużycie |
| `router_vpp_temps.xml` | temperatury procesorów |

Ruch na portach i VLAN-ach daje standardowe zapytanie Cacti **SNMP - Interface Statistics** (IF-MIB z
`vpp-snmp-agent`).
