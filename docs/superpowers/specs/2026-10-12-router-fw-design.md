# router-fw — firewall tranzytu na VPP (ACL)

Data: 2026-10-12. Status: projekt do przeglądu.

## Cel

Jedno polecenie `router-fw` i jeden plik `/etc/router/firewall.conf`, którymi operator:

1. blokuje i wpuszcza ruch **przechodzący** przez router (z internetu / do internetu, po src, dst, protokole i portach, z whitelistami),
2. dokłada i zdejmuje blokady doraźne (np. z FastNetMon) z czasem wygaśnięcia,
3. podgląda **liczniki trafień każdej reguły** (pakiety i bajty, jak `show access-lists` w Cisco).

Zmiany wchodzą na żywo, bez restartu VPP i bez przerywania sesji BGP, i są odtwarzane po każdym starcie VPP. Narzędzie działa tak samo jak `router-ifaces` (`show | diff | apply | check`, pliki w etckeeper, wzorzec `last-good`).

Poza zakresem:

- **Ochrona samego routera** (BGP/BFD/SNMP/ICMP do adresów routera). To zadanie netfiltera (nftables w netns `dataplane`) i zarządzasz nim osobno. `router-fw` tego nie dotyka.
- firewall stanowy dla tranzytu, NAT, Flowspec,
- filtrowanie SSH na eth2 (domyślny netns).

## Gdzie działa filtr

Tranzyt idzie wyłącznie przez VPP (kernel go nie widzi), więc filtruje go **acl-plugin VPP w trybie bezstanowym (`sl`)**. Ruch SSH przez eth2 jest poza VPP, więc błąd w `firewall.conf` nie odetnie dostępu do routera.

**Poza pierwszą wersją:** limit pakietów kierowanych do kernela (`ip punt policer` w VPP, opcja `set punt-limit`). Policer działa, zanim pakiet trafi do TAP-a, więc netfilter go nie zastąpi, ale składnia poleceń policera w VPP 26.06 jest niepotwierdzona. Wraca jako osobne zadanie po sprawdzeniu w labie.

## Plik `/etc/router/firewall.conf`

Wiersze `słowo-kluczowe ...`, komentarze `#`, kolumny rozdzielone spacjami.

```
# --- strefy (jawnie; każdy interfejs VPP, który ma być filtrowany) ---
zone  hu0.100  internet     # Transit: EPIX
zone  hu0.200  internet
zone  hu0.300  clients      # Core: BNG

# --- listy nazwane (adresy/prefiksy IPv4/IPv6); @nazwa w regułach ---
list  smtp-ok   203.0.113.25/32  203.0.113.26/32
list  bogony    include /etc/router/fw-lists/bogony.list     # dłuższe listy w osobnym pliku

# kierunek    akcja   proto  src       sport  dst   dport  opis
->internet    permit  tcp    @smtp-ok  any    any   25     serwery poczty klientów
->internet    deny    tcp    any       any    any   25     blokada SMTP od klientów
internet->    deny    any    @bogony   any    any   any    bogony z internetu
internet->    deny    tcp    any       any    any   445    SMB z internetu
internet->    deny    any    1.2.3.4/32 any   5.6.7.8/32 any  para src+dst

# --- ustawienia ---
set  counters        on        # liczniki trafień per reguła (on | off)
```

Zasady:

- **Kierunek.** `internet->` = ruch wchodzący z interfejsów strefy `internet`. `->internet` = ruch wychodzący do tej strefy. `clients->` i `->clients` analogicznie.
- **Pierwsza pasująca reguła wygrywa**, więc wyjątki (whitelist) stoją nad blokadą. `check` ostrzega o regułach zacienionych (nigdy niedopasowanych).
- **Pola.** `any` = dowolna wartość. Port: liczba, lista po przecinku (`3784,4784`) albo zakres (`1024-65535`). Protokół: `tcp`, `udp`, `icmp`, `icmp6`, `any`. Adresy: IPv4/IPv6 z prefiksem albo `@lista`. Reguła z listą mieszającą IPv4 i IPv6 jest rozbijana na reguły per rodzina adresów.
- **Domyślnie `permit`:** to, czego nie zablokujesz, przechodzi.
- **Walidacja przy `check`/`apply`:** błędy składni, nieznana strefa/lista, interfejs spoza VPP.
- **Ostrzeżenie (nie odmowa):** reguła, która obejmuje TCP/179 lub BFD (UDP 3784/4784) na interfejsach stref, może zerwać sesje BGP/BFD z sąsiadami. `check` ją wypisuje, a `apply` pyta o potwierdzenie (z `-y` pomija pytanie). Reguły tranzytu mogą omyłkowo objąć też ruch do routera, bo ACL VPP stoi przed `linux-cp`.

## Kompilacja do VPP (acl-plugin)

- Dla każdej strefy i kierunku powstaje jedna lista ACL. `internet->` → wejściowy ACL na interfejsach strefy `internet`; `->internet` → wyjściowy ACL na interfejsach strefy `internet`; analogicznie dla `clients`.
- Na końcu każdej listy `router-fw` dopisuje `permit any` (acl-plugin odrzuca pakiety niepasujące do żadnej reguły).
- Blokady doraźne trafiają na początek list `internet->` jako `deny src`.
- `apply` jest różnicowy: porównuje skompilowane ACL z tym, co jest w VPP (`show acl-plugin acl`, `show acl-plugin interface`), tworzy nową wersję ACL i dopiero potem podmienia przypięcia do interfejsów, żeby nie było okna bez filtra.

## Liczniki trafień (jak w Cisco)

acl-plugin prowadzi **liczniki per reguła** (pakiety + bajty) w segmencie statystyk VPP pod nazwą `/acl/<nr ACL>/matches`, jako wektor liczników na każdą regułę listy. `router-fw` czyta ten segment tą samą drogą co `router-monitor`, a numer ACL i numer reguły mapuje z powrotem na wiersz z `firewall.conf`:

```
# router-fw counters
internet->  (wejście: hu0.100, hu0.200)
  10  deny    any  @bogony  any  any  any     bogony z internetu         1 204 551 pkts   88.2 MB   ~1 200 pkt/s
  20  deny    tcp  any      any  any  445     SMB z internetu                 9 032 pkts    1.1 MB       ~3 pkt/s
  --  permit  any  any      any  any  any     (domyślna)                 8 811 902 144 pkts  ...
->internet  (wyjście: hu0.100, hu0.200)
  10  permit  tcp  @smtp-ok any  any  25      serwery poczty klientów       41 020 pkts   ...
  20  deny    tcp  any      any  any  25      blokada SMTP od klientów       7 812 pkts   ...
blokady doraźne: 3 wpisy, trafień łącznie 412 pkts
```

- **Pkt/s** liczone jest z różnicy między odczytami (`-w` odświeża co 1 s; bez `-w` z krótkiej próbki).
- **Zerowanie** (`counters clear`): `router-fw` zapisuje bieżące wartości jako punkt odniesienia w `fw.state.json` i odejmuje je przy wyświetlaniu. Samych liczników VPP nie dotyka.
- **Zmiana `firewall.conf`:** VPP zeruje liczniki całej listy ACL, gdy zmienia się jej treść. Po `apply` lista ze zmienioną treścią zaczyna od zera, a listy bez zmian zachowują liczniki (`router-fw` usuwa punkt odniesienia tylko dla zmienionych list).
- **Koszt:** liczniki ACL są w VPP **włączane osobno** (API `acl_stats_intf_counters_enable`) i kosztują cykle, bo każdy trafiony pakiet inkrementuje licznik we wspólnym segmencie. `router-fw` włącza je przy `boot`/`apply`, jeśli w ustawieniach jest `set counters on` (domyślnie `on`; wyłączenie: `off`). Skala kosztu wchodzi do listy kontrolnej labu.
- **Alarm:** `router-monitor` może co sekundę czytać sumę trafień reguł `deny` i logować `%FW-4-DENY_HIGH` po przekroczeniu progu (jak `PUNT_HIGH`). To opcjonalny drugi krok, nie część pierwszej wersji.

## Polecenia

```
router-fw show                  # strefy, reguły, stan w VPP
router-fw diff | check          # różnice względem stanu na żywo / kontrola pliku
router-fw apply [-y]            # wdrożenie różnicowe, na żywo
router-fw apply --confirm 120   # j.w., ale cofnięcie po 120 s, jeśli nie wpiszesz "confirm"
router-fw confirm               # potwierdzenie zmiany
router-fw block <IP|prefiks> [czas]    # blokada doraźna (np. 2h, 30m); bez czasu = bezterminowo
router-fw unblock <IP|prefiks>
router-fw blocks                # lista blokad z czasem do wygaśnięcia
router-fw counters [-w]         # liczniki trafień per reguła (pakiety, bajty, pkt/s); -w = odświeżanie co 1 s
router-fw counters clear        # zerowanie (punkt odniesienia po stronie router-fw)
router-fw boot                  # odtworzenie po starcie VPP (wołane przez systemd)
router-fw expire                # zdejmuje wygasłe blokady (wołane przez timer)
```

- **Kody wyjścia** jak w `router-ifaces`: 0 = zgodne/OK, 1 = są różnice, 2 = błąd pliku.
- **`--confirm`** zapisuje bieżącą wersję jako `last-good`, wdraża nową i uzbraja jednorazowy timer systemd, który po N sekundach wdroży `last-good`, chyba że wcześniej wykonano `confirm`. To ochrona przed odcięciem sesji BGP przez złą regułę.
- **Blokady doraźne** w `/var/lib/router/fw-blocks.json` (adres, czas utworzenia, wygaśnięcie, autor). `expire` uruchamia timer co 1 min.
- **Stan:** `/var/lib/router/fw.state.json` (skompilowany stan), `/var/lib/router/fw.last-good.conf`.
- **Log:** `/var/log/router-monitor/router-fw.log` (każde polecenie `vppctl` z wynikiem). Zdarzenia w stylu Cisco do `router-monitor.log`: `%FW-5-APPLIED`, `%FW-4-DRIFT` (stan w VPP różni się od pliku; sprawdza timer co 5 min jak `router-ifaces-check`), `%FW-2-CONFIG_ERROR`, `%FW-5-BLOCK` / `%FW-5-UNBLOCK`.
- **Powiadomienia:** nowa kategoria e-mail `FIREWALL` w `router-notify` (`%FW-…`).

## Integracja z repo

| Element | Zmiana |
|---|---|
| `install-router.sh` | funkcja `prog_router_fw` (program Python w heredocu, jak `router-ifaces`); wpis w `UPGRADE_PROGRAMS` (bez restartu usług); `SCRIPT_VERSION` → 1.2.0 |
| Nowy **etap 22** „Firewall (router-fw)” | `/opt/router/bin/router-fw` + dowiązanie w `/usr/local/sbin`; przykładowy `/etc/router/firewall.conf` (tylko jeśli go nie ma); jednostki: `router-fw.service` (odtwarza po starcie VPP, wzorem `router-ifaces.service`), `router-fw-check.timer`/`.service`, `router-fw-expire.timer`/`.service`; cofnięcie `apply --confirm` robi przejściowa jednostka `systemd-run` (`router-fw-rollback`), więc osobnego pliku jednostki nie ma; dodanie do `router.target` (drop-in) i `--check`; wpisy w MANIFEST |
| Numeracja | etap 22 dopisany na końcu, żeby nie przenumerowywać istniejących znaczników `state/NN.done`; `TOTAL_STAGES=22` |
| Istniejący router | `upgrade_script` wgra sam program `router-fw`, ale **nie wgra jednostek systemd**; pierwsze wdrożenie firewalla na działającym routerze: `install-router.sh --from 22` |
| Dokumentacja | rozdział w README generowanym na routerze (z adnotacją, że ruch do routera filtruje netfilter, poza `router-fw`), `docs/router-fw-design.md` (skrót tego dokumentu), `examples/firewall.conf.example`, `README.md` repo |
| `tools/extract.sh` / `lint.sh` | wyciąganie `build/router-fw`, `ast`/flake8 dla niego |

Nie dodaję pakietu `nftables` ani żadnej konfiguracji netfiltera.

## Testy

1. **Jednostkowe (Python, bez VPP):** parser pliku → model; kompilacja → lista ACL VPP (snapshoty tekstowe); kolejność i whitelist; zakresy i listy portów; IPv4/IPv6 i rozbijanie list mieszanych; `@lista`/`include`; wykrywanie reguł zacienionych; ostrzeżenie o regułach obejmujących BGP/BFD; wygasanie blokad; mapowanie liczników (ACL, reguła) → wiersz pliku, przenoszenie punktu odniesienia po `apply`, pkt/s z różnicy odczytów.
2. **Symulator:** `tests/fakevpp.py` rozszerzony o polecenia acl-plugin (`acl_add_replace`, przypięcie do interfejsu, `show acl-plugin ...`), oraz plik JSON zamiast segmentu statystyk z licznikami `/acl/*/matches` (zmienna `ROUTER_FW_STATS_JSON`); scenariusze `apply`, `diff`, `block/unblock/expire`, `boot` po „restarcie VPP”, `apply --confirm` z cofnięciem.
3. **Lista kontrolna do labu na prawdziwym VPP** (`docs/router-fw-lab-checklist.md`; z Maca nie do sprawdzenia):
   - zachowanie acl-plugin przy braku dopasowania (domyślny `deny`?),
   - ACL wyjściowy na podinterfejsach VLAN (dot1q),
   - przepustowość i cykle/pakiet z 10, 100 i 1000 reguł na ruchu zbliżonym do produkcyjnego,
   - sesje BGP/BFD nie spadają po `apply`,
   - liczniki: jak włączyć (API `acl_stats_intf_counters_enable` vs polecenie CLI), czy liczą także w trybie bezstanowym (`sl`) i na ACL wyjściowym, układ `/acl/<nr>/matches` w VPP 26.06, koszt cykli z włączonymi licznikami,
   - restart VPP: reguły wracają przed BIRD.
4. **`tests/test-upgrade.sh`:** dodać `router-fw` do sprawdzanych programów.

## Ryzyka

- Wydajność acl-plugin w trybie bezstanowym (w starych pomiarach CSIT około 2x cykli/pakiet przy jednej regule). Ograniczenie: filtry tylko na interfejsach stref, krótkie listy, pomiar na prawdziwym ruchu. Kompilator jest oddzielony od parsera, więc ewentualna zamiana backendu na klasyfikator nie zmienia formatu pliku.
- Dokładna składnia poleceń acl-plugin (w tym `tag` po regułach, `any` zapisane jako `0.0.0.0/0` i `::/0`) oraz format wyjścia `show acl-plugin acl` i `show acl-plugin interface` w VPP 26.06 do potwierdzenia na routerze (`vppctl ... ?`); kompilator generuje je w jednym module, żeby poprawka była lokalna.
