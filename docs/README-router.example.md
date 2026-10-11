# Router BGP — R630 + ConnectX-4 (VPP + BIRD)

Dokumentacja wygenerowana przez `install-router.sh` dnia 2026-10-11 22:44:14 na hoście `lodz2`.
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
              │  ConnectX-4 (0000:82:00.0 0000:82:00.1)          │
              │  porty w VPP: hu0 hu1      │
              └───────────────┬────────────────┘
                              │ DPDK (mlx5, bez vfio)
   ┌──────────────────────────┴───────────────────────────────┐
   │ VPP v26.06  — forwarding pakietów                     │
   │   main-core 3, workery 5,7,9,11,13,15,17,19,21,23,25,27 (NUMA 1)  │
   │   linux-cp: lustro interfejsów do netns "dataplane"       │
   │   sflow: próbki 1:10000 → hsflowd                  │
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
- Rdzenie VPP są wyłączone z harmonogramu systemu (`isolcpus=3,5,7,9,11,13,15,17,19,21,23,25,27`), a karta i VPP pracują na tym samym węźle NUMA (1).

---

## 2. Usługi i automatyczny start

Wszystkie usługi routera zbiera jednostka **`router.target`** (włączona w `multi-user.target`).
Po restarcie serwera wstają same, w tej kolejności:

| Kolejność | Usługa | Rola | Po awarii |
|---|---|---|---|
| 1 | `netns-dataplane.service` | tworzy netns `dataplane` | — |
| 2 | `vpp.service` | dataplane (forwarding) | restart po 5 s, max 5× / 10 min, potem alarm |
| 3 | `router-ifaces.service` | odtwarza VLAN-y, adresy i loopbacki z `/etc/router/ifaces.conf` | uruchamia się przy każdym starcie VPP (także po automatycznym restarcie) |
| 4 | `bird.service` | BGP (w netns dataplane), startuje po odtworzeniu interfejsów | restartuje się razem z VPP; po awarii restart po 5 s |
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
systemctl restart bird                         # sam BIRD
journalctl -u vpp -u bird -b                   # logi od ostatniego startu
```

Uwaga: restart VPP zawsze oznacza krótką przerwę w ruchu i ponowne zestawienie sesji BGP.

Pakiety VPP i BIRD są zablokowane przed automatyczną aktualizacją (`apt-mark hold`), żeby zwykłe `apt upgrade` nie zrestartowało routera. Aktualizacja świadomie, w oknie serwisowym — patrz rozdział 12.

---

## 3. Pliki i katalogi

| Ścieżka | Zawartość |
|---|---|
| `/opt/router/README.md` | ta dokumentacja |
| `/opt/router/install-router.sh` | kopia skryptu instalacyjnego (`router-check` = `install-router.sh --check`) |
| `/opt/router/bin/router-monitor` | monitor obciążenia (Python) |
| `/opt/router/bin/router-alert` | alarm przy awarii usługi (wołany przez systemd) |
| `/opt/router/bin/mdadm-alert` | alarm przy zdarzeniu RAID (wołany przez mdadm) |
| `/opt/router/bin/router-bootcheck` | kontrola po starcie systemu, wykrywanie nieczystego restartu |
| `/opt/router/bin/router-notify` | wysyłka alarmów e-mailem (SMTP) |
| `/opt/router/bin/smartd-alert` | alarm z smartd (zdrowie dysków) |
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
| `/root/router_install_data/` | źródła, paczki .deb, logi instalacji, kopie oryginałów, `MANIFEST.txt` |

Pełna lista każdego zapisanego pliku, usługi i pakietu: `/root/router_install_data/MANIFEST.txt`.

---

## 4. Logi

| Co | Gdzie |
|---|---|
| Alarmy routera (monitor, awarie usług, RAID, kontrola po starcie) | `/var/log/router-monitor/router-monitor.log` oraz syslog/journal, facility `local0` |
| Zmiany interfejsów (każde polecenie vppctl z wynikiem) | `/var/log/router-monitor/router-ifaces.log` |
| VPP | `/var/log/vpp/vpp.log`, `journalctl -u vpp` |
| BIRD | syslog (`journalctl -u bird`) |
| Instalacja | `/root/router_install_data/logs/install.log` + osobny log każdego etapu |

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
| Heartbeat VPP | `/sys/heartbeat` | Czy VPP żyje. Brak przez 30 s = zawieszenie. |
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
- **Zawieszenie VPP** (proces żyje, nie odpowiada): wykrywa router-monitor po 30 s i restartuje VPP (wyłączenie: `HANG_RESTART=0`).
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
MAIL_SEND="CRASH SERVICES BOOT RAID DISKS NIC_FW VPP_STATE VPP_DROPS VPP_LOAD VPP_PUNT SYS_CPU IFACES OTHER"
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
| `IFACES` | `%IFACE-5-CONFIG_APPLIED`, `%IFACE-4-DRIFT`, `%IFACE-2-CONFIG_ERROR`, `%IFACE-3-APPLY_FAIL` (rozdział 10) |
| `STATS` | `%VPP-6-STATS` co minutę — zwykle nie chcesz tego mailem |
| `OTHER` | wszystko, co nie pasuje do powyższych |
| `ALL` | wszystkie kategorie |

Przykład — tylko poważne rzeczy, bez zakończeń: `MAIL_SEND="CRASH SERVICES RAID DISKS VPP_DROPS"`, `MAIL_SEND_CLEAR=no`.

Zasady, żeby nie zasypać skrzynki przy DDoS:

- pierwsze zdarzenie po okresie ciszy idzie od razu; kolejne w ciągu `MAIL_MIN_INTERVAL` są zbierane w jeden mail,
- wysyłane są zgłoszenia, eskalacje i zakończenia zdarzeń (z czasem trwania i szczytem); przypomnienia „trwa Ns” i minutowe `%VPP-6-STATS` nie,
- temat maila pokazuje najpoważniejsze zdarzenie i liczbę pozostałych, np. `[lodz2] KRYTYCZNE: %VPP-2-RX_MISS (+3)`,
- przy błędzie SMTP zdarzenia czekają w kolejce, ponowna próba co 1–10 minut; błąd trafia do logu jako `%SYS-3-MAIL_FAIL`.

---

## 8. Kernel panic, zawieszenia, watchdog

Router ma sam wstać po każdej awarii systemu:

| Sytuacja | Co się dzieje |
|---|---|
| kernel panic | restart po 10 s — ustawione w linii kernela (`panic=10`, działa od pierwszej sekundy startu) i w sysctl (`kernel.panic`) |
| kernel oops (błąd w kernelu) | traktowany jak panic → restart (`oops=panic`, `kernel.panic_on_oops=1`) |
| zawieszenie kernela (soft/hard lockup) | panic → restart (`kernel.softlockup_panic`, `kernel.hardlockup_panic`) |
| całkowite zawieszenie (kernel nie zdąży zgłosić paniki) | watchdog sprzętowy: systemd przestaje go odświeżać → płyta restartuje serwer po 60 s |
| awaria VPP / BIRD | systemd restartuje usługę (rozdział 6) |

Po każdym takim restarcie `router-bootcheck` wykrywa, że poprzedni start nie zakończył się normalnym wyłączeniem, i wysyła `%SYS-1-UNCLEAN_REBOOT`, a jeśli zachował się zapis paniki (UEFI pstore) — `%SYS-1-KERNEL_PANIC` z pierwszą linią błędu. Zapisy paniki: `/var/lib/systemd/pstore/`, logi poprzedniego startu: `journalctl -b -1` (journal jest trwały).

Sprawdzenie ustawień: `sysctl kernel.panic kernel.panic_on_oops`, `systemctl show -p RuntimeWatchdogUSec`, `ls /dev/watchdog*`.

---

## 9. Audyt sprzętu (z instalacji)

Na początku każdej instalacji skrypt robi pełny audyt: firmware serwera, ustawienia BIOS (bezpośrednio z iDRAC przez Redfish, jeśli podasz `IDRAC_HOST/USER/PASS`; inaczej wnioskowane z Linuksa), procesory, Hyper-Threading, NUMA, pamięć (każdy moduł, kanały, taktowanie, błędy ECC), karta (model, PSID, PCIe, firmware), dyski i RAID, zasilacze i temperatury (IPMI). Na tej podstawie dobiera konfigurację VPP i wypisuje zalecenia: WYMAGANE / ZALECANE / OPCJONALNE, z dokładnym miejscem w BIOS.

Sam audyt, bez instalacji: `install-router --audit`. Pełny raport: `/etc/router/hardware-audit.md`.

`AUTO` = skrypt zmienił ustawienie sam, `WARN` = wymaga działania (zwykle w BIOS).

**Hyper-Threading — wyłączyć.** Worker VPP potrzebuje całego rdzenia fizycznego. Drugi wątek dzieli z nim cache i jednostki wykonawcze, nie dodaje przepustowości VPP, a zwiększa wahania opóźnień. Na tym serwerze rdzeni fizycznych jest dość. BIOS: System BIOS → Processor Settings → Logical Processor = Disabled. Dopóki HT jest włączony, skrypt dodaje `nosmt` do kernela.

### Serwer i firmware

| Stan | Obszar | Wynik | Komentarz |
|---|---|---|---|
| INFO | Model | Dell Inc. PowerEdge R630 | - |
| INFO | BIOS | 2.x (data) | najnowszy BIOS dla modelu: support Della |
| WARN | Tryb startu | BIOS (legacy) | log paniki nie przetrwa restartu (samo wykrycie awarii działa) |

### Procesory

| Stan | Obszar | Wynik | Komentarz |
|---|---|---|---|
| INFO | Model | 2 × Intel(R) Xeon(R) CPU E5-2698 v4 @ 2.20GHz (turbo do 3600 MHz) | - |
| OK | Hyper-Threading | wyłączony | tak ma być dla routera VPP |
| OK | NUMA | węzłów: 2, interleaving wyłączony | - |

### Pamięć RAM

| Stan | Obszar | Wynik | Komentarz |
|---|---|---|---|
| OK | Kanały procesora A | 4 moduły (wszystkie kanały) | - |
| OK | Kanały procesora B | 4 moduły (wszystkie kanały) | - |

### Karta sieciowa

| Stan | Obszar | Wynik | Komentarz |
|---|---|---|---|
| INFO | Model | ConnectX-4 (MCX416A-CCAT) | - |
| OK | PCIe 0000:82:00.0 | 8GT/s x16 | - |
| WARN | Firmware | 12.20.1010 | stary firmware |

### Zalecenia

1. **[ZALECANE] Zaktualizuj firmware karty**  
   Gdzie: system (po instalacji)  
   router-fw-update (ręcznie, wymaga restartu)

Dodatkowe parametry kernela dodane automatycznie: `panic=10 oops=panic`.

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

**Oryginały plików systemowych** sprzed instalacji: `/root/router_install_data/backup/` (z zachowaniem ścieżek).

**VPP nie wstaje** — sprawdź po kolei:
1. `journalctl -u vpp -b` i `/var/log/vpp/vpp.log`
2. hugepages: `grep Huge /proc/meminfo` (po restarcie powinno być 7900 stron)
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

Kopie firmware i wyniki zapytań: `/root/router_install_data/firmware/`. Karta z PSID zaczynającym się od `DEL` ma firmware Della — aktualizuj pakietem z dell.com/support.

**Ponowna instalacja / naprawa etapu**: `/opt/router/install-router.sh --from <nr>` (dane robocze w `/root/router_install_data`).

**Aktualizacja VPP lub BIRD** (w oknie serwisowym):

```
apt-mark unhold bird3 && apt-get install bird3 && apt-mark hold bird3
# VPP: zmień VPP_VERSION w install-router.sh, potem:  install-router.sh --from 10
```

---

## 13. Parametry tej instalacji

| Parametr | Wartość |
|---|---|
| Karta | ConnectX-4 |
| Porty Mellanox (PCI) | 0000:82:00.0 0000:82:00.1 |
| Nazwy portów w VPP | hu0 hu1 |
| Węzeł NUMA karty | 1 |
| Rdzeń główny VPP | 3 |
| Workery VPP | 5,7,9,11,13,15,17,19,21,23,25,27 |
| Izolowane rdzenie | 3,5,7,9,11,13,15,17,19,21,23,25,27 |
| Wersja VPP | v26.06 |
| Router ID BIRD | 192.168.80.111 (zmieni go skrypt sieciowy na adres loopbacka) |
| SNMP — dozwolone źródło | 192.168.80.0/24 |
| sFlow | 1:10000, kolektor: brak (uzupełnij /etc/hsflowd.conf) |
| Hugepages | 7900 × 2 MB |
| Sterta VPP / bufory | 4G / 262144 |
| Alarmy e-mail | noc@tradepartner.pl |

---

## 14. Następny krok

Ten skrypt stawia platformę i interfejsy (`/etc/router/ifaces.conf`). Sesje BGP, filtry, RPKI i ochronę control plane dokłada skrypt sieciowy (pliki w `/etc/bird/conf.d/`).
