# synack-guard — filtr odbić (SYN-ACK, RST, UDP) w VPP (moduł C + polecenie `router-guard`)

Data: 2026-10-12. Status: projekt do przeglądu.

## Cel

Router R630 (VPP + DPDK) ma na żądanie, dla wskazanych prefiksów lub pojedynczych adresów, **nie przepuszczać do sieci SYN-ACK, na który sieć nie wysłała SYN**. To jest obrona przed atakami typu TCP SYN reflection flood (w tym carpet bombing na całe prefiksy), w których tysiące prawdziwych serwerów odsyła SYN-ACK na sfałszowany adres ofiary.

Wymagania od operatora:

1. Włączane **ręcznie, na żądanie**, per prefiks lub IP; poza atakiem koszt zerowy.
2. Konfiguracja w **osobnym pliku** (`/etc/router/synack-guard.conf`).
3. Tryb **monitor** (liczy, co zostałoby odrzucone, niczego nie blokuje) obok trybu **enforce**.
4. Działa **wyłącznie w VPP na DPDK**, jak najszybciej (cel: odrzucanie floodu SYN-ACK na poziomie dziesiątek Mpps na całym routerze).

### Polityka (tryb zrównoważony, dla ISP)

Ruch przychodzący do chronionego prefiksu:

- **Nowe połączenia przychodzące (sam SYN) przechodzą.** P2P, gry, VoIP, VPN i serwery domowe działają.
- **Odrzucamy tylko „odpowiedź bez pytania”:**
  - **SYN-ACK** bez SYN wysłanego z chronionego prefiksu (etap 1, rdzeń),
  - **RST / RST+ACK** bez SYN z chronionego prefiksu (etap 1, opcja `tcp-rst handshake`; domyślnie `pass`),
  - **UDP ze źródłowych portów amplifikacji** (domyślnie 19, 53, 111, 123, 137, 161, 389, 1900, 3702, 5353, 11211) bez wcześniejszego pakietu UDP wysłanego z chronionego prefiksu do takiego portu (etap 2).
- **ACK i dane TCP poza sesją przechodzą** (pełne śledzenie połączeń: etap 3, poza tą specyfikacją).

Poza zakresem tej specyfikacji (osobne zadania):

- Reguła „odrzuć nowe SYN do adresów, które nie są serwerami” (bez stanu; kolumna flag TCP w `router-fw`).
- Pełne śledzenie połączeń TCP (ACK i dane poza sesją, w tym połączenia zainicjowane z zewnątrz): osobne zadanie, bo wymaga stanu przez cały czas życia połączenia. Architektura (tablica stanów + prefiksy) pozwala je dodać później.
- Ochrona ruchu do samego routera (zadanie netfiltera) oraz saturacja łączy upstreamowych (RTBH i Flowspec u upstreamów).

## Warunek działania

R630 musi widzieć **oba kierunki** połączeń z chronionego prefiksu: SYN wychodzący od klienta i SYN-ACK wracający z internetu. Chroniony prefiks to adresy widziane przez R630 (po ewentualnym NAT). Jeśli SYN wyjdzie inną drogą, a SYN-ACK wróci przez R630, prawidłowa odpowiedź zostanie odrzucona. Tryb monitor służy do sprawdzenia tego warunku przed włączeniem `enforce`.

## Architektura

```
 uplinki (interfejsy "in-if")                     BNG (interfejsy "out-if")
 ───────────────────────────────►  R630 / VPP  ◄───────────────────────────────
   SYN-ACK do chronionego prefiksu                   SYN od klienta z chronionego prefiksu
   synack-guard-in:  szukaj w tablicy                synack-guard-out: zapisz wpis (+ ISN, czas)
   brak wpisu → drop (enforce) / licz (monitor)
   (to samo dla RST przy tcp-rst=handshake i dla UDP z portów amplifikacji)
                       ▲                ▲
                       └─ wspólna tablica stanów (bihash, jedna dla wszystkich workerów)
```

| Element | Rola | Gdzie |
|---|---|---|
| Moduł VPP `synack_guard_plugin.so` (C) | węzły ścieżki szybkiej, tablica stanów, tablica prefiksów, liczniki, polecenia CLI | `vppctl` |
| `router-guard` (Python, osadzony w `install-router.sh`) | włączanie i wyłączanie na żądanie, plik konfiguracyjny, stan, odtwarzanie po starcie VPP, zdarzenia, liczniki | `/opt/router/bin/router-guard` |
| `/etc/router/synack-guard.conf` | interfejsy, grupy prefiksów, parametry | etckeeper |
| `/var/lib/router/guard.state.json` | co jest włączone teraz (prefiksy, tryb, czas wyłączenia) | odtwarzane po restarcie VPP |

Decyzja: oddzielne polecenie `router-guard`, nie podkomenda `router-fw`. To inny mechanizm (stan, moduł C, tryby), a `router-fw` ma już ponad 1200 linii. Wspólne pomocnicze funkcje (log, zdarzenia, blokada, JSON) są kopiowane, tak jak w `router-ifaces` i `router-fw` (każde narzędzie jest samodzielne).

## Ścieżka szybka (moduł C)

### Punkty zaczepienia

Dwa węzły na łuku funkcji `ip4-unicast` (i `ip6-unicast`), włączane tylko na wskazanych interfejsach (także podinterfejsach VLAN):

- **`synack-guard-out`** na interfejsach `out-if` (strona klientów). Dla pakietu, którego adres źródłowy jest w chronionym prefiksie, zapisuje wpis i przekazuje pakiet dalej bez zmian: dla TCP z SYN=1, ACK=0, RST=0, a dla UDP z portem docelowym z listy amplifikacji.
- **`synack-guard-in`** na interfejsach `in-if` (uplinki). Dla pakietu, którego adres docelowy jest w chronionym prefiksie, szuka wpisu: dla TCP z SYN=1, ACK=1 (SYN-ACK), dla TCP z RST=1 (tylko przy `tcp-rst handshake`) i dla UDP z portem źródłowym z listy amplifikacji. Brak wpisu (albo zły numer potwierdzenia) = naruszenie: w `enforce` pakiet idzie do drop z licznikiem, w `monitor` jest tylko liczony i przechodzi.

Wszystko inne przechodzi nietknięte po kilku instrukcjach. Włączenie i wyłączenie węzłów na interfejsie odbywa się przez `vnet_feature_enable_disable`, więc **poza atakiem węzły nie są w ścieżce pakietu**.

### Kolejność sprawdzeń (od najtańszych)

1. Protokół IP == TCP (w IPv6 bez rozszerzeń; pakiety z nagłówkami rozszerzeń przechodzą).
2. Brak fragmentu (offset = 0).
3. Flagi TCP: czytane z jednego bajtu na stałym przesunięciu (ta sama linia cache co nagłówek IP). Dla UDP: port z jednej tablicy bitowej (8 KB, mieści się w L1). Wszystko inne kończy się tutaj.
4. Prefiks chroniony (dst dla SYN-ACK, src dla SYN).
5. Dostęp do tablicy stanów.

### Struktury danych

- **Tablica stanów IPv4:** `clib_bihash_16_8`. Klucz: adres klienta, adres serwera, port klienta, port serwera i protokół (TCP lub UDP). Wartość 8 B: ISN klienta (32 bity, dla UDP 0) i czas zapisu w sekundach (32 bity). TTL osobny dla TCP (`ttl`) i UDP (`udp-ttl`).
- **Tablica stanów IPv6:** `clib_bihash_48_8` z tym samym znaczeniem pól.
- **Wspólna dla wszystkich workerów.** Odpowiedź może wrócić na inny worker niż SYN (klucz RSS karty nie jest symetryczny), więc tablice per wątek odpadają. Odczyty bihash są bez blokad, zapis blokuje jeden koszyk.
- **Wpis wstawia wyłącznie SYN z chronionego prefiksu**, nigdy SYN-ACK. Odbity flood nie powiększa tablicy.
- **Starzenie bez sprzątacza:** wstawianie nadpisuje wpisy starsze niż TTL (`clib_bihash_add_or_overwrite_stale_*` z funkcją oceniającą przeterminowanie; do potwierdzenia w źródłach VPP 26.06). Retransmitowany SYN odświeża czas.
- **Walidacja ISN:** SYN-ACK oraz RST+ACK są prawidłowe tylko wtedy, gdy numer potwierdzenia = ISN + 1 (opcja `check-isn`, domyślnie włączona). Odrzuca sfałszowane odpowiedzi, które trafiły w znaną czwórkę. Sam RST (bez ACK) przechodzi, jeśli wpis istnieje.
- **Kompromis RST:** przy `tcp-rst handshake` RST dla połączenia starszego niż TTL (serwer zrywa je po minutach) też zostanie odrzucony i klient zobaczy timeout zamiast resetu. Dlatego domyślnie `tcp-rst pass`.
- **UDP:** wpis powstaje z pakietu UDP wychodzącego do portu z listy amplifikacji; odpowiedź z tego portu przechodzi, dopóki wpis żyje (`udp-ttl`, domyślnie 30 s). Niepierwsze fragmenty UDP nie mają portów i podlegają osobnej opcji `udp-frags pass|drop` (domyślnie `pass`).
- **Prefiksy chronione:** małe tablice haszujące per długość prefiksu (do 8 różnych długości jednocześnie), klucz to zamaskowany adres. Sprawdzenie idzie od najdłuższego prefiksu. Dla IPv6 analogicznie z kluczem 128-bitowym. Zmiany prefiksów w trakcie pracy nie wymagają blokady odczytu (zamiana wskaźnika na nową tablicę w barierze).
- **Domyślne rozmiary:** IPv4 4 mln wpisów (około 150–250 MB), IPv6 1 mln; konfigurowalne w pliku. Pamięć z puli sterty głównej VPP (sprawdzana przy włączeniu względem `main-heap-size`).

### Wydajność (zasady projektowe)

- Przetwarzanie wektorowe po 4 pakiety (quad-loop) z prefetchem nagłówków i, w ścieżce SYN-ACK, z prefetchem koszyka bihash dla pakietów następnego kroku.
- Wynik klasyfikacji budowany bez rozgałęzień tam, gdzie się da; jedna tablica `next index`, wspólne `vlib_buffer_enqueue_to_next`.
- Liczniki per wątek (bez atomików w ścieżce szybkiej), zliczane do segmentu statystyk.
- Cele akceptacyjne (do pomiaru w labie, patrz niżej): narzut dla ruchu innego niż SYN i SYN-ACK nie większy niż 40 cykli na pakiet; odrzucanie SYN-ACK nie więcej niż 300 cykli na pakiet; co najmniej 8 Mpps odrzuconych SYN-ACK na worker przy tablicy z 2 mln wpisów.

### Tryby

| Tryb | Zapis wpisów (SYN, UDP) | Sprawdzanie odpowiedzi | Efekt |
|---|---|---|---|
| `monitor` | tak | tak, tylko liczy | nic nie jest odrzucane; służy do uczenia tablicy i wykrywania asymetrii |
| `enforce` | tak | tak | brak wpisu lub zły ISN = drop |

Zalecana sekwencja: `guard on <prefiks> --monitor`, odczekać 30–60 s, sprawdzić `guard status` (odrzucenia bliskie zera przy normalnym ruchu), potem `guard enforce`. Przełączenie na `enforce` bez uczenia traci tylko handshaki w locie.

### Liczniki

Standardowe liczniki błędów węzłów VPP (`show errors`, segment statystyk `/err/synack-guard-in-ip4/...` itd.; zliczane per wątek, bez atomików): `syn_recorded`, `udp_recorded`, `checked`, `pass`, `violation_no_flow`, `violation_bad_isn`, `dropped` (tylko `enforce`), `insert_failed`. W trybie `monitor` naruszenia oznaczają „zostałoby odrzucone w `enforce`”. Zapełnienie tablic pokazuje `show synack-guard`. Zerowanie: `clear errors`.

### Polecenia CLI modułu (`vppctl`)

```
synack-guard interface <if> in|out [disable]      # zaczepienie węzłów na interfejsie
synack-guard prefix <adres/długość> [del]          # chronione prefiksy (IP = /32 lub /128)
synack-guard mode off|monitor|enforce
synack-guard config ttl <s> udp-ttl <s> check-isn on|off tcp-rst pass|handshake udp on|off udp-frags pass|drop udp-ports <p,p,...> table-v4 <wpisy> table-v6 <wpisy>
show synack-guard
```

Zmiana rozmiarów tablic jest możliwa tylko przy `mode off`.

## Sterowanie: `router-guard`

Plik `/etc/router/synack-guard.conf` (osobny, w etckeeper):

```
# interfejsy VPP: gdzie sprawdzać SYN-ACK (uplinki) i gdzie zapisywać SYN (strona klientów)
in-if    hu0.100 hu0.200
out-if   hu0.300

# grupy prefiksów (opcjonalne; do wywołań "router-guard on web")
group web     203.0.113.0/24
group hosting 198.51.100.0/24  2001:db8:100::/48

# parametry
ttl            60        # sekundy ważności wpisu TCP (SYN-ACK wraca w kilka sekund, retransmisje do ok. 60 s)
udp-ttl        30        # sekundy ważności wpisu UDP
tcp-rst        pass      # pass | handshake (RST przechodzi tylko jako odpowiedź na SYN z chronionego prefiksu)
udp            on        # filtr UDP z portów amplifikacji (etap 2)
udp-ports      19 53 111 123 137 161 389 1900 3702 5353 11211
udp-frags      pass      # pass | drop (niepierwsze fragmenty UDP do chronionego prefiksu)
check-isn      on
table-v4       4000000
table-v6       1000000
max-on         6h        # automatyczne wyłączenie, jeśli operator zapomni
default-mode   monitor   # tryb po "on" bez opcji
```

Polecenia:

```
router-guard on <prefiks|IP|grupa>[,...] [--monitor|--enforce] [--for 2h]   # włącz dla prefiksów (dodaje do już chronionych)
router-guard off [prefiks|IP|grupa]      # wyłącz wskazane; bez argumentu: wszystko (węzły zdjęte z interfejsów)
router-guard enforce | monitor           # zmiana trybu dla całości
router-guard status                      # co chronimy, tryb, liczniki, zapełnienie tablicy, pkt/s
router-guard check                       # kontrola pliku i zgodności VPP ze stanem
router-guard boot                        # (systemd) odtworzenie po starcie VPP, jeśli ochrona była włączona
router-guard expire                      # (timer) wyłączenie po upływie --for / max-on
```

Zasady:

- Stan włączenia (prefiksy, tryb, wygaśnięcie) w `/var/lib/router/guard.state.json`; po restarcie VPP `router-guard.service` odtwarza go przed BIRD. Po restarcie tablica stanów jest pusta, więc odtwarzanie zawsze startuje w `monitor` na `warmup` (domyślnie 60 s) i dopiero potem przechodzi na zapisany tryb.
- `on` bez `--for` używa `max-on`. Ochrona nie zostaje włączona na stałe przez przypadek.
- Zdarzenia (`router-monitor.log`, syslog, e-mail, kategoria `FIREWALL`): `%GUARD-5-ON`, `%GUARD-5-OFF`, `%GUARD-5-MODE`, `%GUARD-4-VIOLATIONS` (próbkowane co 10 s, z pkt/s, po przekroczeniu progu), `%GUARD-2-TABLE_FULL` (zapełnienie ponad 90%: automatyczne przejście na `monitor`), `%GUARD-5-EXPIRED`.
- `check --log` (timer co 5 min) porównuje VPP z `guard.state.json` i zgłasza `%GUARD-4-DRIFT`.
- Kody wyjścia jak w `router-fw`: 0 OK, 1 różnice, 2 błąd pliku, 3 VPP nie odpowiada, 4 nieudany krok.

## Budowa i instalacja modułu

- Źródła C (`synack_guard.c`, `synack_guard.h`, `guard_core.h` z logiką niezależną od VPP, `CMakeLists.txt`) są osadzone w `install-router.sh` jako heredoki, tak jak pozostałe programy, bo na router wysyłany jest jeden plik.
- Instalator kopiuje źródła do drzewa VPP (`$SRC/vpp/src/plugins/synack_guard/`) w etapie 10, przed `make pkg-deb`. VPP wykrywa wtyczkę po `CMakeLists.txt` w katalogu, więc to najpewniejsza droga. Wtyczka trafia do paczki `vpp-plugin-core`. Ponieważ `startup.conf` ma `plugin default { enable }`, osobny wpis nie jest potrzebny.
- Zmiana kodu C wymaga przebudowy VPP (`install-router.sh --from 10`, 30–60 min) i **restartu VPP** (przerwa w ruchu i ponowne zestawienie BGP); `upgrade_script` podmienia tylko `router-guard`, nie moduł. Szybsza przebudowa wtyczki poza drzewem VPP (na bazie `vpp-dev`) jest możliwą późniejszą optymalizacją po potwierdzeniu w labie.
- `router-guard` bez załadowanej wtyczki zgłasza to wprost („wtyczka synack_guard nie jest załadowana — przebuduj VPP: install-router.sh --from 10”) i niczego nie zmienia.
- Nowy etap instalatora **23** („router-guard: polecenie, plik konfiguracyjny, jednostki”); numeracja istniejących etapów bez zmian.

## Testy

1. **Jednostkowe w C na hoście (macOS/Linux, bez VPP):** `guard_core.h` zawiera rozbiór nagłówków (klasyfikacja SYN i SYN-ACK, fragmenty, nagłówki rozszerzeń IPv6), budowę klucza, sprawdzenie ISN+1, wyszukiwanie prefiksu w tablicach per długość. Testy kompilowane `cc` i uruchamiane lokalnie.
2. **`router-guard` w Pythonie na symulatorze:** `tests/fakevpp.py` rozszerzony o polecenia `synack-guard ...` i `show synack-guard`; testy włączania, wyłączania, trybów, wygasania, odtwarzania po restarcie, błędów pliku, monitora.
3. **Testy VPP w labie** (`make test` z scapy, plik w repo): ścieżka SYN→SYN-ACK przechodzi, nieproszony SYN-ACK jest odrzucony w `enforce` i liczony w `monitor`, zły ISN, retransmisja, wygaśnięcie po TTL, prefiks spoza ochrony, IPv6, podinterfejsy VLAN.
4. **Pomiar wydajności w labie** (TRex lub pktgen): ruch 64 B SYN-ACK na chronione prefiksy z rosnącą szybkością; `show runtime` (clocks/packet, vectors/call); progi z sekcji „Wydajność”.
5. **Lista kontrolna** `docs/synack-guard-lab-checklist.md`: asymetria (liczba naruszeń w `monitor` przy normalnym ruchu bliska zeru), zachowanie przy pełnej tablicy, restart VPP, zgodność kluczy RSS karty.

## Ryzyka i ograniczenia

- **Nie da się tu skompilować ani uruchomić modułu C** (brak VPP na tej maszynie). Interfejsy VPP 26.06 (`vnet_feature`, `bihash`, API buforów) trzeba zweryfikować na buildzie Linux; spodziewane są poprawki po pierwszej kompilacji. Logika niezależna od VPP jest testowana lokalnie.
- Liczby wydajności są szacunkami do potwierdzenia pomiarem; sufit całego routera to około 90 Mpps (karta), nie filtr.
- Asymetria tras: ochrona działa tylko wtedy, gdy oba kierunki połączeń przechodzą przez R630 (patrz „Warunek działania”).
- Własny SYN-flood zarażonego klienta może wypełnić tablicę; zabezpieczenia: duży stały rozmiar, alarm `TABLE_FULL` i automatyczne przejście na `monitor`. Limit SYN na źródło jest odłożony.
- Ochrona dotyczy odbitego SYN-ACK. Ataki na pojemność łączy upstreamowych nadal wymagają RTBH lub Flowspec u upstreamów.

## Rulings (decyzje podjęte w specyfikacji)

- IPv4 i IPv6 w tej samej specyfikacji; plan wykonania wprowadza IPv4 jako pierwszy etap, IPv6 jako drugi.
- Warstwa „odrzuć nowe SYN do adresów, które nie są serwerami” nie wchodzi do tego zadania.
- Oddzielne polecenie `router-guard` i oddzielny plik konfiguracyjny.
- Wspólna (nie per wątek) tablica stanów, TTL 60 s, `check-isn` domyślnie włączone.
- Moduł wbudowany w drzewo VPP (pewna droga budowy); szybka przebudowa poza drzewem to późniejsza optymalizacja.
- Polityka zrównoważona: SYN przechodzi; SYN-ACK, opcjonalnie RST i UDP z portów amplifikacji wymagają wpisu; ACK i dane poza zakresem.
- Liczniki przez standardowe liczniki błędów węzłów VPP (`show errors`), nie osobny segment.
