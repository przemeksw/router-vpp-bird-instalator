# Router BGP: VPP + BIRD na Dell R630 + ConnectX-4

Instalator routera BGP (Debian 13): VPP 26.06 budowany ze źródeł (DPDK mlx5, linux-cp, sFlow), BIRD 3 w netns `dataplane`, SNMP dla LibreNMS, monitoring obciążenia w stylu ASR, alarmy e-mail, interfejsy z pliku `ifaces.conf`.

## Struktura

| Ścieżka | Co to jest |
|---|---|
| `install-router.sh` | **jedyny plik wysyłany na router** — instaluje i konfiguruje wszystko (21 etapów, wznawianie po błędzie) |
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

Pierwsze wdrożenie na działającym routerze: `bash /root/install-router.sh --from 22` (etap 22 wgrywa program i jednostki systemd; `upgrade_script` podmienia potem tylko program `router-fw`). Przed użyciem na produkcji przejdź `docs/router-fw-lab-checklist.md`. Ruchu do samego routera ten mechanizm nie filtruje — to zadanie netfiltera.

## Ochrona przed odbiciami (`router-guard`)

Filtr w VPP (wtyczka C `synack_guard`, DPDK) włączany na żądanie dla prefiksu lub IP: odrzuca SYN-ACK (opcjonalnie RST) bez SYN wysłanego z Twojej sieci oraz UDP ze źródłowych portów amplifikacji bez zapytania. Konfiguracja w osobnym pliku: `examples/synack-guard.conf.example`.

```
router-guard on 203.0.113.0/24 --monitor    # liczy, nic nie blokuje; sprawdź: router-guard status
router-guard enforce                        # odrzucaj  (albo: on ... --enforce --for 2h)
router-guard off
```

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
