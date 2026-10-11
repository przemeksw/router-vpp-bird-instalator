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
