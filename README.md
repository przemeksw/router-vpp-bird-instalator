# Router BGP: VPP + BIRD na Dell R630 + ConnectX-4

Instalator routera BGP (Debian 13): VPP 26.06 budowany ze źródeł (DPDK mlx5, linux-cp, sFlow), BIRD 3 w netns `dataplane`, SNMP dla LibreNMS, monitoring obciążenia w stylu ASR, alarmy e-mail, interfejsy z pliku `ifaces.conf`.

## Struktura

| Ścieżka | Co to jest |
|---|---|
| `install-router.sh` | **jedyny plik wysyłany na router** — instaluje i konfiguruje wszystko (25 etapów, wznawianie po błędzie) |
| `docs/README-router.example.md` | przykład dokumentacji, którą instalator generuje na routerze w `/opt/router/README.md` |
| `docs/r630-bgp-router-plan.md` | sprzęt, decyzje, NUMA, DDoS — plan projektu |
| `docs/router-ifaces-design.md` | założenia `router-ifaces` (VLAN-y, adresy, loopbacki) |
| `examples/ifaces.conf.example` | przykładowy `/etc/router/ifaces.conf` |
| `tools/extract.sh` | wyciąga programy osadzone w instalatorze do `build/` (router-ifaces, router-monitor, router-notify) |
| `tools/lint.sh` | kontrola przed wysłaniem: `bash -n`, shellcheck, składnia Pythona, flake8 |
| `tests/run-tests.sh` | testy `router-ifaces` na symulatorze VPP (`tests/fakevpp.py`) oraz `upgrade_script` (`tests/test-upgrade.sh`) — bez VPP i bez roota |
| `tests/test_router_fw.py` | testy `router-fw`: parser, kompilator ACL, plan zmian i polecenia na symulatorze VPP |
| `tests/test-installer.sh` | statyczna kontrola spójności instalatora (etap 22, jednostki, kategorie e-mail) |
| `examples/firewall.conf.example` | przykładowy `/etc/router/firewall.conf` |
| `examples/synack-guard.conf.example` | przykładowy `/etc/router/synack-guard.conf` (router-guard) |
| `tests/test_router_guard.py`, `tests/test-guard-core.sh`, `tests/guard_core_test.c` | testy router-guard (symulator VPP) i rdzenia modułu C (kompilator na hoście, ASan/UBSan) |
| `docs/synack-guard-design.md`, `docs/synack-guard-lab-checklist.md` | skrót projektu i lista kontrolna do labu |
| `docs/router-fw-design.md`, `docs/router-fw-lab-checklist.md` | skrót projektu firewalla i lista kontrolna do labu |

Programy `router-ifaces`, `router-monitor`, `router-notify` i pozostałe narzędzia są osadzone w `install-router.sh` (heredoc). **Edytuj je w `install-router.sh`**, a `build/` traktuj jako podgląd — jest generowany i nie trafia do gita.

## Praca w VS Code

1. Otwórz folder (`File → Open Folder`). VS Code zaproponuje zalecane rozszerzenia (ShellCheck, Python, flake8, Remote-SSH) — zainstaluj.
2. Narzędzia pomocnicze (macOS): `brew install shellcheck` i `pip3 install flake8`.
3. Zadania: `Cmd+Shift+P → Tasks: Run Task`:
   - **Router: kontrola (lint)** — przed każdym wysłaniem na router,
   - **Router: testy router-ifaces** — po zmianach w `router-ifaces`,
   - **Router: wyślij install-router.sh na router** — lint + `scp` na adres zarządzania (eth2).
4. Git: `Source Control → Initialize Repository`, pierwszy commit. Hasła (SMTP, iDRAC) nigdy nie trafiają do repo — wpisuje się je na routerze.

## Wdrożenie na routerze

```
scp install-router.sh root@192.168.80.111:/root/
ssh root@192.168.80.111
bash /root/install-router.sh --audit     # sam audyt sprzętu i BIOS, bez zmian
bash /root/install-router.sh             # instalacja (po błędzie: to samo polecenie wznawia)
reboot
router-check                             # kontrola po restarcie
```

Po instalacji wszystko jest w `/opt/router` (narzędzia, README, kopia instalatora), konfiguracja w `/etc/router`, a dane robocze instalacji w `/root/router_install_data`.

## Wersjonowanie i aktualizacja programów

Wersja jest w zmiennej `SCRIPT_VERSION` na początku `install-router.sh` (podbijaj ją przy każdej zmianie programów). Instalator zapisuje ją na routerze w `/etc/router/version`.

Po zmianie któregoś z osadzonych programów wgraj nowy plik i zaktualizuj tylko programy — bez ponownej instalacji, bez restartu VPP i BIRD:

```
scp install-router.sh root@192.168.80.111:/root/
ssh root@192.168.80.111
bash /root/install-router.sh --version                 # wersja skryptu i wersja na routerze
bash /root/install-router.sh upgrade_script --dry-run  # co się zmieni (diff), bez zapisywania
bash /root/install-router.sh upgrade_script            # podmiana zmienionych programów
```

`upgrade_script` podmienia wyłącznie programy w `/opt/router/bin` (`router-monitor`, `router-notify`, `router-ifaces`, `router-alert`, `router-bootcheck`, `mdadm-alert`, `smartd-alert`, `router-fw-update`), `router-check` i kopię skryptu w `/opt/router`. Nie rusza konfiguracji, jednostek systemd, VPP ani BIRD. Najpierw sprawdza składnię nowych programów, robi kopię starych w `/root/router_install_data/backup/upgrade-<data>/`, restartuje tylko `router-monitor` i `router-notify` (jeśli ich programy się zmieniły) i zapisuje `%SYS-5-SCRIPTS_UPGRADED` w logu. Pierwsze użycie na routerze zainstalowanym przed wprowadzeniem wersjonowania działa tak samo (brak `/etc/router/version` = wersja nieznana).

## Firewall tranzytu (`router-fw`)

Reguły ruchu przechodzącego przez router (VPP, ACL) są w `/etc/router/firewall.conf`; format i przykłady: `examples/firewall.conf.example`.

```
router-fw check                  # składnia, ostrzeżenia, rozjazd VPP
router-fw diff                   # co zmieni apply
router-fw apply --confirm 120    # wdrożenie z automatycznym cofnięciem po 120 s (router-fw confirm = zostaje)
router-fw block 198.51.100.7 2h  # blokada doraźna źródła
router-fw counters -w            # liczniki trafień reguł na żywo
```

**Instalator nie uruchamia firewalla** — po dopasowaniu `/etc/router/firewall.conf`: `router-fw check` → `diff` → `apply --confirm 120` → `confirm` → **`router-fw enable`** (aktywacja na stałe: reguły wracają po każdym restarcie). `router-fw disable` wyłącza. Szczegóły: README routera, rozdział 10a „Aktywacja na stałe”.

Pierwsze wdrożenie na działającym routerze: `bash /root/install-router.sh --from 22` (etap 22 wgrywa program i jednostki systemd; `upgrade_script` podmienia potem tylko program `router-fw`). Przed użyciem na produkcji przejdź `docs/router-fw-lab-checklist.md`. Ruchu do samego routera ten mechanizm nie filtruje — to zadanie netfiltera.

## Ochrona przed odbiciami (`router-guard`)

Filtr w VPP (wtyczka C `synack_guard`) włączany na żądanie dla wybranych prefiksów lub adresów — chroni klientów przed atakami odbitymi (SYN-ACK reflection, amplifikacja UDP). Konfiguracja: `/etc/router/synack-guard.conf` (przykład: `examples/synack-guard.conf.example`).

```
router-guard on 203.0.113.0/24              # włącz w trybie monitor (liczy, nic nie blokuje)
router-guard status                         # czy rosną naruszenia?
router-guard enforce                        # zacznij odrzucać
router-guard off                            # wyłącz
router-guard on web --enforce --for 2h      # wszystko naraz: 60 s monitor, potem enforce, wyłączenie po 2 h
```

### Jak działa ochrona — od zera

Atak odbity (reflection) wygląda tak: atakujący wysyła do tysięcy serwerów w internecie pakiety **SYN** (albo zapytania UDP: DNS, NTP, memcached…) z **podrobionym adresem nadawcy — adresem Twojego klienta**. Serwery odpowiadają — **SYN-ACK** (albo dużą odpowiedzią UDP) — do klienta, który o nic nie pytał. Ten zalew odpowiedzi to atak.

Ochrona rozpoznaje „odpowiedź bez pytania”:
1. Na interfejsach **od strony klientów** (`out-if`) zapamiętuje każde pytanie wysłane z chronionego prefiksu: **SYN** (i jego numer sekwencyjny) oraz **pakiet UDP do portu amplifikacji** (53, 123, 161, 11211…). Wpis żyje `ttl` = 60 s (UDP: `udp-ttl` = 30 s).
2. Na **uplinkach** (`in-if`) każdą **odpowiedź do chronionego prefiksu** porównuje z zapamiętanymi pytaniami:
   - **SYN-ACK** — czy był pasujący SYN (te same adresy i porty, nie starszy niż 60 s) i czy numer potwierdzenia = numer SYN + 1,
   - **UDP ze źródłowego portu amplifikacji** — czy było zapytanie do tego serwera i portu (nie starsze niż 30 s),
   - **RST** — tylko gdy `tcp-rst handshake` (domyślnie RST nie jest sprawdzany),
   - **niepierwszy fragment UDP** — tylko gdy `udp-frags drop` (nie ma portów, nie da się sprawdzić — wtedy odrzucany w enforce).
3. Odpowiedź bez pasującego pytania to **naruszenie**. Co się z nim dzieje — zależy od **trybu**.

**Nigdy nie jest sprawdzane** (zawsze przechodzi bez zmian): ruch do adresów, które nie są chronione; nowe połączenia przychodzące (sam SYN — serwery klientów działają); ACK i dane TCP; UDP z innych portów niż lista amplifikacji; ruch wychodzący od klientów (jest tylko zapamiętywany); ICMP.

### Tryby — co dokładnie robi każdy

| Tryb | Pakiet bez naruszenia | Naruszenie (odpowiedź bez pytania) | Kiedy używać |
|---|---|---|---|
| **off** (wyłączona) | przechodzi | — (nic nie jest sprawdzane) | normalnie. Węzły filtra są zdjęte z interfejsów — **zero kosztu**, VPP działa jakby filtra nie było |
| **monitor** | przechodzi | **przechodzi** do klienta; liczony w „naruszenia”, zapisany w dzienniku zdarzeń (`router-top` karta 4: „PRZESZEDŁ (monitor)”) | na początku ataku i zawsze przed enforce: sprawdzasz, czy filtr rozpoznaje atak i czy **nie łapie normalnego ruchu** |
| **enforce** | przechodzi | **odrzucony** w VPP — nie dociera do klienta; liczony w „odrzucone”. Router nic nie odsyła (chyba że `reply-rst on`, niżej) | gdy monitor potwierdził atak, a przy normalnym ruchu naruszeń jest ~0 |

**Odrzucony** znaczy: pakiet jest usuwany w VPP na wejściu uplinka, zanim trafi do tablicy tras — nie idzie dalej, nie obciąża łącza do klienta, klient go nie widzi. Nic nie jest wysyłane z powrotem (ani ICMP, ani RST).

**`reply-rst on`** (w `synack-guard.conf`, domyślnie wyłączone) zmienia tylko jedno: w **enforce**, dla **SYN-ACK bez pasującego SYN**, zamiast samego odrzucenia router odsyła do serwera, który go wysłał, pakiet **RST** — tak jak zrobiłby to komputer klienta. Serwer kończy wtedy połączenie i **przestaje powtarzać SYN-ACK** (bez RST powtarza do ok. 60 s). Limit `reply-rst-pps` (domyślnie 10 000/s); ponad limit — samo odrzucenie. RST nigdy nie jest wysyłany dla: złego numeru potwierdzenia, RST, UDP, trybu monitor (tam tylko licznik „RST do wysłania”).

### Polecenia — co dokładnie robi każde

| Polecenie | Co robi |
|---|---|
| `router-guard on <prefiks\|IP\|grupa>[,…]` | Włącza ochronę dla wskazanych adresów (dopisuje je do już chronionych). Podpina filtr na interfejsach `in-if` i `out-if`, wgrywa ustawienia z pliku. Tryb: jeśli ochrona już działa — dotychczasowy docelowy; jeśli nie — `default-mode` z pliku (domyślnie **monitor**). |
| `… --monitor` | Jak wyżej, tryb **monitor**. |
| `… --enforce` | Jak wyżej, ale **najpierw monitor przez `warmup` (60 s), potem automatycznie enforce**. Rozgrzewka jest po to, żeby filtr zdążył zapamiętać SYN-y połączeń, które klient już nawiązuje — bez niej zerwałyby się w pierwszej minucie. |
| `… --for 2h` | Ochrona wyłączy się sama po tym czasie (30m, 2h, 1d). Bez `--for` — po `max-on` (domyślnie 6 h). Nie da się ustawić dłużej niż `max-on`. |
| `router-guard enforce` | Przełącza **od razu** na enforce (bez rozgrzewki — zakłada, że monitor już działał). Dotyczy wszystkich chronionych prefiksów. |
| `router-guard monitor` | Przełącza od razu na monitor (przestaje odrzucać, dalej liczy). |
| `router-guard off <prefiks>` | Zdejmuje ochronę z jednego prefiksu; reszta działa dalej. |
| `router-guard off` | Wyłącza całkowicie: tryb off, filtr zdjęty z interfejsów, lista prefiksów pusta. |
| `router-guard status` | Stan: tryb, prefiksy, za ile się wyłączy, zapełnienie tablic, liczniki (sprawdzone, przepuszczone, naruszenia, odrzucone, RST) z szybkością na sekundę. |
| `router-guard check` | Sprawdza plik i czy VPP zgadza się ze stanem ochrony. |

**Dodanie nowego prefiksu w trakcie enforce** (`on <nowy> --enforce`): cała ochrona wraca na czas rozgrzewki do monitora (żeby nowy prefiks nie stracił trwających połączeń), potem znów enforce.

### Co dzieje się samo
| Sytuacja | Zachowanie |
|---|---|
| minął czas (`--for` / `max-on`) | co minutę timer sprawdza; po terminie ochrona się wyłącza, w `alarmy.log` `%GUARD-5-EXPIRED` + e-mail |
| koniec rozgrzewki | przejście z monitor na enforce (`%GUARD-5-MODE`) |
| restart VPP lub serwera w trakcie ochrony | ochrona wraca **w monitorze**, po rozgrzewce enforce (jeśli taki był cel); jeśli czas minął — nie wraca |
| tablica stanów zapełniona w ≥ 90 % (w enforce) | **automatyczne przejście na monitor** (`%GUARD-2-TABLE_FULL`) — przy pełnej tablicy filtr nie zapamiętuje nowych SYN, więc w enforce zacząłby odrzucać prawdziwe połączenia |
| naruszeń więcej niż `alarm-pps` na sekundę | `%GUARD-4-VIOLATIONS` (najwyżej raz na 10 min) |
| ktoś zmienił VPP ręcznie | `%GUARD-4-DRIFT` |

### Ustawienia (`/etc/router/synack-guard.conf`)
| Ustawienie | Domyślnie | Znaczenie |
|---|---|---|
| `in-if` | — | uplinki (stąd przychodzą odpowiedzi do sprawdzenia) |
| `out-if` | — | interfejsy klientów (stąd wychodzą SYN i zapytania UDP, które są zapamiętywane) |
| `group NAZWA prefiks…` | — | nazwa dla `router-guard on NAZWA` |
| `ttl` | 60 | ile sekund pamiętany jest SYN |
| `udp-ttl` | 30 | ile sekund pamiętane jest zapytanie UDP |
| `warmup` | 60 | ile sekund monitora przed enforce |
| `max-on` | 6h | najdłuższy czas ochrony |
| `default-mode` | monitor | tryb po `on` bez `--monitor`/`--enforce` |
| `check-isn` | on | SYN-ACK musi potwierdzać numer z SYN (wykrywa podrobione SYN-ACK do trwających połączeń) |
| `tcp-rst` | pass | `pass` = RST nie jest sprawdzany; `handshake` = RST też musi mieć pasujący SYN |
| `udp` | on | sprawdzanie UDP z portów amplifikacji |
| `udp-ports` | 19 53 111 123 137 161 389 1900 3702 5353 11211 | porty źródłowe odpowiedzi UDP, które są sprawdzane |
| `udp-frags` | pass | `drop` = w enforce odrzucaj niepierwsze fragmenty UDP do chronionych adresów |
| `reply-rst` | off | `on` = w enforce odsyłaj RST na SYN-ACK bez SYN |
| `reply-rst-pps` | 10000 | limit RST na sekundę |
| `table-v4` / `table-v6` | 4000000 / 1000000 | rozmiar pamięci zapamiętanych pytań (zmiana tylko przy wyłączonej ochronie) |
| `alarm-pps` | 10000 | próg alarmu o naruszeniach |

### Ważne ograniczenia
- Router **musi widzieć oba kierunki** ruchu chronionego prefiksu (pytanie wychodzi przez ten router i odpowiedź wraca przez ten router). Jeśli część ruchu klienta wychodzi inną drogą, odpowiedzi na nią wyglądają jak atak — w monitorze zobaczysz naruszenia przy normalnym ruchu. **Wtedy nie włączaj enforce.**
- Atak większy niż przepustowość łączy do upstreamów zapcha łącza, zanim dotrze do routera — guard tego nie zmieni; potrzebny RTBH / Flowspec u operatora.

Wtyczka jest budowana razem z VPP (etap 10); na działającym routerze wymaga `install-router.sh --from 10` (restart VPP) oraz `--from 23` dla polecenia i jednostek. **Moduł C nie był kompilowany ani uruchamiany poza testami rdzenia** — przed produkcją przejdź `docs/synack-guard-lab-checklist.md`. Skrót projektu: `docs/synack-guard-design.md`.

## Codzienna praca na routerze z VS Code (Remote-SSH)

`Cmd+Shift+P → Remote-SSH: Connect to Host → root@192.168.80.111`, potem `File → Open… → /etc/router`. Edytujesz `ifaces.conf` jak lokalny plik, a w terminalu VS Code (już na routerze):

```
router-ifaces diff      # podgląd zmian
router-ifaces apply     # wdrożenie na żywo, bez restartu VPP
router-ifaces           # stan interfejsów
```

Zmiany w `/etc` są automatycznie wersjonowane na routerze przez etckeeper (`git -C /etc log -p router/ifaces.conf`).

## Status

Instalator i narzędzia sprawdzone składniowo (bash -n, shellcheck, flake8) i testami na symulatorze. Na prawdziwym R630 jeszcze nie był uruchamiany — pierwsze uruchomienie: najpierw `--audit`, potem instalacja w oknie serwisowym.

## Logi (`/var/log/router/`)

Jeden katalog na wszystkie logi routera: `alarmy.log` (wszystkie alarmy i zdarzenia, z niego idą e-maile), `firewall.log`, `guard.log`, `ifaces.log` (szczegóły: polecenia vppctl i odpowiedzi VPP), `vpp.log` i `bird.log` (przez rsyslog — Debian 13 domyślnie ma tylko journald, etap 24 go instaluje). Rotacja codziennie, domyślnie 20 dni (`LOG_KEEP_DAYS` w instalatorze). Starszy katalog `/var/log/router-monitor/` jest przenoszony automatycznie (etap 18, 24 albo `upgrade_script`).

## Czas, DNS, ochrona CPU (etap 25)

Strefa `Europe/Warsaw`, chrony z serwerami GUM (`tempus1/2.gum.gov.pl`), DNS 46.45.78.2, 46.45.114.2, 8.8.8.8. iptables w dwóch miejscach — port zarządzający (`/etc/iptables/rules.v4`, netfilter-persistent) i netns dataplane, czyli adresy w VPP i loop0 (`/etc/iptables/dataplane.rules.v4`, `router-dataplane-fw.service`): zaufane sieci (`TRUSTED_NETS`) pełny dostęp, SSH/SNMP z reszty świata DROP, limit pingu do kernela — w tabeli `raw` (PREROUTING, przed trasowaniem). Conntrack wyłączony (`/etc/modprobe.d/router-no-conntrack.conf`) — kernel nie przekazuje ruchu, robi to VPP. SNMP w VPP wpuszcza community z zaufanych sieci. Na działającym routerze: `bash /root/install-router.sh --from 25`.

## Podgląd na żywo (`router-top`)

`router-top` — odświeżanie co sekundę, tylko odczyt, przewijanie długich list (↑↓ PgUp PgDn): **1** obciążenie VPP (wektor workerów — odpowiednik QFP) i ruch łączny, **2** ruch na portach i VLAN-ach (Gb/s, pkt/s, zgubione pakiety — jak iptraf-ng), **3** liczniki reguł firewalla z opisami, **4** guard (liczniki z szybkością, najczęstsze źródła i cele, ostatnie 30 naruszeń z decyzją: odrzucony / +RST / przeszedł). Lista guarda pochodzi z nowego polecenia wtyczki `show synack-guard events` (próbka, najwyżej 200 zdarzeń/s na wątek). `router-top --once N` = jeden odczyt jako tekst.

## Audyt zgodności z VPP

`docs/audyt-vpp-2026-10-12.md` — zgodność konfiguracji, poleceń i wtyczki z VPP v26.06 oraz wpływ wszystkich mechanizmów na wydajność i ciągłość pracy routera.

## Start z drugiego dysku RAID1 (`install-uefi-mdadm.sh`)

Osobny skrypt (nie jest częścią `install-router.sh`). Przy rozruchu UEFI partycja EFI (`/boot/efi`) jest tylko na pierwszym dysku — gdy ten padnie, serwer nie wystartuje, choć RAID z systemem działa. Skrypt kopiuje ESP na drugi dysk macierzy, dodaje wpis UEFI „debian-sdX” (na końcu kolejności startu) i instaluje hook apt, który po każdej aktualizacji pakietów (GRUB, shim) odświeża kopię. Niczego nie formatuje, można go uruchamiać wielokrotnie.

```
scp install-uefi-mdadm.sh root@router:/root/
bash /root/install-uefi-mdadm.sh --dry-run    # plan: który dysk, która partycja, jaki wpis UEFI
bash /root/install-uefi-mdadm.sh              # wykonanie (pyta o potwierdzenie)
```
Opcje: `--disk /dev/sdb` (wskaż drugi dysk ręcznie), `--yes`, `--no-hook`. Test startu z drugiego dysku: w oknie serwisowym F11 / iDRAC → „debian-sdb”.
