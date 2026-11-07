# Diagnostyka strat pakietów — lodz2-vpp, 5–6 listopada 2026

Router: Dell R630, 2× Xeon E5-2698 v4 (20 rdzeni, 2,2 GHz, turbo do 3,6 GHz), ConnectX-4 2×100G (`hu0`, `hu1`, NUMA 1),
VPP 26.06 + BIRD, 12 workerów (rdzenie 5–27 nieparzyste), `vpp_main` na rdzeniu 3. Instalator: wersja 1.5.48.
Porównanie: `lodz1` — ten sam typ karty (ConnectX-4, firmware 12.24) pod zwykłym Linuksem, bez VPP.

## Skąd brały się straty — przyczyny znalezione i usunięte

| # | Objaw | Przyczyna | Poprawka | Wersja |
|---|---|---|---|---|
| 1 | `%VPP-2-RX_MISS` co kilka godzin, kilkaset pakietów | `kcompactd1` (kompakcja pamięci jądra) siedział na rdzeniu workera 0 i budził się co 500 ms — 22 tys. wywłaszczeń | `vm.compaction_proactiveness=0`, `router-kthreads` przypina wątki jądra i przerwania poza rdzenie VPP (przy starcie i co 5 min) | 1.5.28–1.5.32 |
| 2 | Przerwania RCU (~1/s) na rdzeniach workerów, IOMMU tłumaczące adresy DMA | domyślne parametry jądra | `rcupdate.rcu_normal_after_boot=1 iommu=pt skew_tick=1 tsc=reliable` w GRUB | 1.5.36 |
| 3 | `RX_MISS` ~4 tys. pakietów **co 5 minut** | alarm wkładek (DDM) w `router-ifaces-check.timer`: odczyt EEPROM wkładki VPP wykonuje w barierze — wszystkie workery stały ~0,4 s | alarm wkładek domyślnie wyłączony (`OPTICS_CHECK_EVERY=0`), ręczne `router-ifaces optics` z ostrzeżeniem | 1.5.46 |
| 4 | router-monitor zgłaszał `DOWN/UP` co sekundę | błąd w kodzie (nadpisana zmienna) | poprawione + test pętli monitora | 1.5.39 |
| 5 | Odrzucenia w buforze karty (`rx_phy_discard`) ~1 na mln pakietów; Linux na tej samej karcie: 0 | DPDK mlx5 inaczej niż jądro: bez dopełniania zapisu pakietu do pełnej linii 64 B (częściowe zapisy linii spowalniają DMA na Xeonie) i z kompresją CQE | `VPP_NIC_DEVARGS="rxq_pkt_pad_en=1,rxq_cqe_comp_en=0"` — odbiór jak w jądrze. Pomiar: bez opcji ~1,1/mln → samo dopełnianie ~0,2/mln → oba 0 w teście 30 min, **ale po teście (14:37–15:05) znów ~0,3/mln** — usunięte tylko częściowo, patrz „Co zostało” | 1.5.48 |
| 6 | Cacti przypisywał wykresy złym interfejsom po restarcie VPP / dodaniu VLAN-u; Akvorado bez nazw interfejsów | `vpp-snmp-agent`: ifIndex = 1000 + numer VPP (przesuwa się); NetFlow podawał sam numer VPP | stały ifIndex (`/var/lib/router/snmp-ifindex.json`) w SNMP, `router-netflow` podmienia ten sam numer w IPFIX — jak `snmp ifindex persist` w Cisco | 1.5.47 |

## Sprawdzone i wykluczone

- **Pierścień RX 32768** (maksimum deklarowane przez kartę) — **zatrzymuje odbiór** na ConnectX-4 z VPP 26.06 (port nadaje, nie odbiera). Zostaje 16384, instalator ma twardą granicę `VPP_RX_DESC_MAX=16384`.
- Przerwania (IPI, TLB), przerwania kontrolera dysków (0 na rdzeniach VPP), brak buforów VPP, NUMA, taktowanie rdzeni, PCIe (x16 8 GT/s, AER czyste, ASPM nieobsługiwane), bariera z netlinka (BGP), timery 5-minutowe (polecenia `vppctl` trwają 1–12 ms).
- ~~**Scatter** — `max-frame-size 1522` mieści się w jednym buforze 2048 B, więc 1 bufor na pakiet, pierścień = pełne 16384 pakietów.~~ **Błąd — patrz „Odbiór skalarny i 8 segmentów na pakiet” niżej.**
- **PAUSE (flow control)** — wyłączone na obu routerach.
- **Uncore** — stałe 2,8 GHz (min = max) na obu procesorach.
- **Rozkład RSS** — skrót z adresów i portów dla IPv4 i IPv6 (optymalny). Jedno połączenie zawsze idzie przez jedną kolejkę — tak ma być.
- **MPRQ** — karta obsługuje, ale VPP nie umie buforów „doczepionych” przez sterownik; działałoby tylko z kopiowaniem każdego pakietu (`mprq_en=1,mprq_max_memcpy_len` ≥ największy pakiet), a pojemność kolejki w pakietach się nie zmienia. Odłożone ze względu na `RX_MISS` — ale dla `rx_discards_phy` to główna pozostała różnica względem jądra (striding RQ); kopiowanie przy dzisiejszym obciążeniu (wektor 1–2) jest do udźwignięcia. Kandydat do testu po porównaniu z `lodz1`.

## Jak czytać `RX_MISS` i `NIC_DISCARD` — liczniki odświeżane co 10 s

VPP nie czyta liczników karty na bieżąco. `rx-miss` (`imissed` z DPDK = `rx_out_of_buffer`) i xstats (`*discard*`)
przepisuje do segmentu statystyk proces `dpdk-process` **co 10 s** (`DPDK_STATS_POLL_INTERVAL 10.0`,
`dpdk_update_counters`). Każde `vppctl show hardware-interfaces` (router-top karta 5, `router-ifaces errors`)
odświeża je od razu i przesuwa ten 10-sekundowy cykl. Skutki dla komunikatów `router-monitor`:

- `RX_MISS ... N pkt/s` to w praktyce **N pakietów zgubionych w ciągu ostatnich ≤10 s**, podzielone przez 1 s
  pomiaru — nie prędkość. „Koniec po 1s” znaczy tylko, że licznik skoczył raz.
- Strata mogła nastąpić do ~10 s **przed** godziną w logu.
- Przyczyna w opisie jest sprawdzana w oknie 3 s (`WK_PREEMPT`, `SMI`), a strata mogła być wcześniej. Opis „burst
  jednego przepływu” jest tylko domyślną odpowiedzią, gdy nic innego nie trafiło w te 3 s — to nie jest dowód.
  Z tego samego powodu „SMI z BIOS-u” to zbieżność czasowa, a nie potwierdzona przyczyna.
- **Od 1.5.49** monitor podaje pakiety (`hu0 435.2k pkt (od poprzedniego odczytu karty, ≤13 s)`), przyczyny szuka
  w całym oknie `MISS_WINDOW` = 13 s i dopisuje dowody: `w ostatnich 13 s: wektor maks. …, wywłaszczenia …, SMI +…`
  (`SMI ?` = bez pomiaru). Strata większa niż wszystkie pierścienie portu razem (kolejki × `num-rx-desc` ze
  `startup.conf`) jest opisana jako zatrzymanie VPP, nie burst.
- `NIC_DISCARD` monitor czyta co 10 s (`XSTATS_EVERY`), więc `N pkt/s` ≈ N×10 pakietów w oknie 10 s.
  Okna poniżej progu (< 10 pakietów) nie trafiają do logu.

## Odbiór skalarny i 8 segmentów na pakiet (6.11, ~17:00) — prawdopodobnie najważniejsze znalezisko

`vppctl show hardware-interfaces hu0` pokazuje **`rx burst mode: Scalar`** (bez wektorowego odbioru DPDK mlx5)
i `rx offload active: ipv4-cksum scatter`. Z kodu źródłowego:
- DPDK mlx5 (`mlx5_rxtx_vec.c`) wyłącza odbiór wektorowy, gdy kolejka ma więcej niż jeden segment na pakiet
  (`sges_n != 0`), przy LRO, współdzielonej kolejce albo ograniczeniu SIMD (`--force-max-simd-bitwidth`);
- liczba segmentów (`mlx5_rxq.c`) wynika z MTU **w chwili tworzenia kolejek**: `max_rx_pktlen = MTU + 18`, dzielone
  na bufory po 2048 B (`default data-size 2048`), zaokrąglone w górę do potęgi 2;
- VPP tworzy kolejki przy starcie (`dpdk_device_setup`) z MTU = `ethernet_main.default_mtu`, a domyślnie to **9000**
  (`ethernet/init.c`); instalator nie ustawia `ethernet { default-mtu }`;
- późniejsze `set interface mtu 1500 hu0` (bootstrap) woła tylko `rte_eth_dev_set_mtu` (`dpdk_set_max_frame_size`) —
  **kolejek nie przebudowuje**.
Wniosek (wyliczony, do potwierdzenia): 9018 B / 2048 B = 5 segmentów → 8 (potęga 2) → **każdy deskryptor RX ma 8
buforów**, odbiór skalarny, a pierścień 16384 buforów mieści **2048 pakietów na kolejkę, nie 16384**.
Skutki: (1) pierścień 8× mniejszy, niż zakładaliśmy — 12 ms bariery `show hardware-interfaces` przy ~106 kpps na
kolejkę to ~1,3 tys. pakietów, blisko 2048 — tłumaczy straty od `router-snmp` (przy 16384 rachunek ich nie tłumaczył);
(2) karta pobiera dla każdego pakietu deskryptor 8× większy (128 B zamiast 16 B) — możliwy udział w `rx_phy_discard`;
Linux na `lodz1` przy MTU 1500 ma jeden bufor na pakiet — to realna różnica VPP/Linux; (3) cała pojemność pierścieni
to 12 × 2048 ≈ 24,6 tys. pakietów, nie 197 tys. (rachunek dla 14:45 i `ring_capacity` w router-monitor trzeba poprawić).
Poprawka: `ethernet { default-mtu 1500 }` w `startup.conf` (restart VPP) → kolejki z MTU 1500 → 1 segment, odbiór
wektorowy. Sprawdzenie po restarcie: `rx burst mode` ≠ `Scalar`.
Sprawdzone (6.11, ~17:10): `show dpdk version` bez `--force-max-simd-bitwidth` — z przyczyn odbioru skalarnego zostaje
tylko wiele segmentów na pakiet (LRO nieaktywne, współdzielonych kolejek brak). Za duże ramki (jumbo ze switcha)
**wykluczone**: karta nie ma liczników długości/CRC, a w `show errors` od startu VPP (14:13) nie ma odrzuceń za rozmiar —
dominują `ACL deny` 2,44 mln (firewall), `ip4 ttl <= 1` 0,79 mln, odpowiedzi ICMP. Drobne: `tap4096-tx no free tx slots`
121 (pakiety do Linuksa/control plane odrzucone przy pełnej kolejce TAP).

**Potwierdzone (6.11, 17:04):** po dopisaniu `ethernet { default-mtu 1500 }` i restarcie VPP:
`rx burst mode: Vector SSE`, `max-frame-size 1522`, porty i VLAN-y `up`, sesje BGP wróciły (iBGP_LODZ1 v0303 jako
ostatnia — `Active` 30 s po restarcie). Od tej chwili pierścień mieści 16384 pakietów na kolejkę (12 × 16384 ≈ 197 tys.).
Wcześniej (do 17:04) było to 12 × 2048 ≈ 24,6 tys. — rachunek dla 14:45: zgubienie 435 tys. przy ~0,94 Mpps wymagało
postoju wszystkich workerów ≥ ~0,5 s (nie 0,65 s), nadal duże zdarzenie o nieznanej przyczynie.
W instalatorze: **1.5.50** — `ethernet { default-mtu }` z `PORT_MTU` w `startup.conf`, wykrywanie braku/innej wartości
w `vpp_conf_diff` i `upgrade_vpp_sync`, router-monitor liczy pojemność pierścienia z buforami na pakiet.
Obserwacja: `router-snmp` włączony — jeśli `RX_MISS` przy nim nie wracają, większy pierścień wchłania postoje
`show hardware-interfaces`; po dobie porównać `RX_MISS` i `NIC_DISCARD` (na milion) z 6.11 przed 17:04.
Po restarcie router-top pokazywał wszystkie workery ~33–38% zajęte przy wektorze 1.0 i ~65 kpps na workera — to nie
obciążenie, tylko nieaktualny „luz”: router-monitor uczy się maksimum pętli/s na luzie i tylko je podnosi, a uczył
się przy odbiorze skalarnym. Po zmianie na wektorowy pusty obieg kosztuje inaczej (~2,9 mln pętli/s), więc
1 − 2,9/4,4 ≈ 34% na stałe. W 1.5.50: luz zapisywany z podpisem konfiguracji VPP (`startup.conf` bez komentarzy),
odrzucany, gdy VPP wstanie z inną konfiguracją (też w router-top), stary format pliku odrzucany; pojemność pierścieni
liczona od nowa przy każdym restarcie VPP. Doraźnie: `rm /var/lib/router/vpp-idle-loops.json; systemctl restart
router-monitor` i ponowne uruchomienie router-top.

## Po poprawce MTU (6.11 17:04 – 7.11)

Od restartu VPP z `ethernet { default-mtu 1500 }` (odbiór wektorowy, 1 bufor na pakiet) przez dobę **brak wpisów
`RX_MISS` i `NIC_DISCARD` w logu router-monitor** (próg logu: ≥ 10 pakietów w oknie 10 s). Wcześniej `NIC_DISCARD`
pojawiał się co ~2 min. Najpewniej 8 buforów na pakiet (deskryptor 8× większy, odbiór skalarny) odpowiadało też za
odrzucenia w buforze karty, nie tylko za mały pierścień. Do potwierdzenia: surowe liczniki od startu VPP
(`rx_phy_discard_packets`, `rx-miss` z segmentu statystyk) — log nie pokazuje okien poniżej progu.

**1.5.51:** `VPP_NIC_DEVARGS="rxq_pkt_pad_en=1"` — kompresja CQE z powrotem włączona. Wdrożenie: `upgrade_script`
wykrywa zmianę devargs, działa po restarcie VPP (okno serwisowe, sesje BGP spadną). Po restarcie: `rx burst mode`
ma być nadal `Vector`; jeśli `NIC_DISCARD` wróci — przywrócić `rxq_cqe_comp_en=0` (`VPP_NIC_DEVARGS` w `router.env`
albo kopia `/etc/vpp/startup.conf.przed-cqe`).

## Co zostało (stan 6.11, 15:05)

Log z 14:37–15:05 (ruch 0,66–0,98 Mpps, 5,7–9 Gb/s):

**1. Odrzucenia w buforze karty wróciły.** 13 okien `NIC_DISCARD` w 28 min (co ~2 min), po 1–6 pkt/s, czyli
≥ ~390 pakietów na ~1,1–1,6 mld odebranych → **~0,3/mln** (dolna granica). To tyle, ile dało samo
`rxq_pkt_pad_en=1` (~0,2/mln). **Potwierdza to sam `pik-watch` z oboma opcjami:** 11 zdarzeń między 14:18:46
a 14:40:24, razem 204 pakiety (4–53 w próbce 2 s), ruch średnio 768 kpps, w szczycie 1346 kpps. Wpis „0” w tabeli
testów był błędny. Nie ma dowodu, że `rxq_cqe_comp_en=0` cokolwiek zmienia. **Od 1.5.51 kompresja CQE wraca (domyślne DPDK)** — oszczędza PCIe przy zalewie małymi pakietami (DDoS), a jej wyłączenie nic nie dało; patrz „Po poprawce MTU”.
Do sprawdzenia:
- czy opcje dalej działają: `grep devargs /etc/vpp/startup.conf`, `systemctl show vpp -p ActiveEnterTimestamp`
  (czy VPP był restartowany po dopisaniu);
- ~~podwójne liczenie~~ — **wykluczone**: w segmencie statystyk są tylko `rx_phy_discard_packets` i
  `tx_phy_discard_packets` na port (bez liczników prio), monitor czyta je stamtąd (bez `vppctl`);
- ~~PCIe MaxPayload~~ — **wykluczone**: karta `0000:82:00.0` (port główny `80:03.0`) ma MaxPayload 256 B
  (karta umie 512, port główny 256), MaxReadReq 4096 B, łącze 8 GT/s x16;
- różnica z `lodz1` — ~~pierścień 1024~~: `lodz1` ma pierścień RX **8192** (`ethtool -g`), tu 16384 × 12 kolejek. Duży
  pierścień oznacza, że karta pisze do buforów, których dawno nie ma w LLC (DDIO), więc każdy zapis DMA jest wolniejszy.
  **Hipoteza bez pomiaru na tym routerze.** Podparcie: (a) tutejszy pomiar — dopełnianie zapisu do pełnej linii
  (`rxq_pkt_pad_en`) zmniejszyło odrzucenia ~4×, więc koszt zapisu DMA w pamięci ma tu znaczenie; (b) literatura —
  „leaky DMA” (ResQ, NSDI 2018) i DDIO przy 100G (Farshin i in., USENIX ATC 2020): pierścienie większe niż część LLC
  dla DDIO powodują chybienia zapisów DMA. Związek z samym `rx_phy_discard` to wnioskowanie, nie pomiar.
  Najpierw pomiar bez ingerencji: `pcm-pcie -e` (Intel PCM) — trafienia/chybienia zapisów PCIe w LLC. Test
  pierścienia 4096 dopiero, jeśli chybień jest dużo; mierzyć straty/mln **i** `RX_MISS` (mniejszy pierścień = więcej
  strat przy burstach jednego przepływu). Przy ~0,3/mln może się w ogóle nie opłacać.
  **Pomiar `pcm-pcie -e 5` (6.11, ~16:00, gniazdo 1 = karta; na 5 s):**

  | Zdarzenie | Razem | Chybienia LLC | Trafienia |
  |---|---|---|---|
  | ItoM (karta zapisuje pełną linię — odbiór) | 65–75 mln | 60–69 mln (~90%) | 5–9 mln |
  | RFO (karta zapisuje część linii) | **0** | — | — |
  | PCIeRdCur (karta czyta — nadawanie) | 81–86 mln | ~0,7 mln (~1%) | 81–85 mln |
  | DRd (rdzenie czytają dane) | 78–87 mln | 2,6–3 mln (~3%) | 75–84 mln |

  Wnioski: (1) `rxq_pkt_pad_en=1` działa — zapisów częściowych (RFO, wymagają odczytu linii z pamięci) jest 0;
  (2) ~90% zapisów karty trafia w linie spoza LLC, ale bez RFO to zapis z alokacją, bez czekania na pamięć, przy
  ~8 Gb/s (~1 GB/s) — znikome obciążenie pamięci i PCIe; (3) workery czytają pakiety z LLC (97% trafień), więc
  „leaky DMA” tu nie ma; (4) bufor jest zapisywany przez kartę dopiero po obiegu pierścienia (16384 pakietów ≈ 0,2 s
  na kolejkę) — przy 4096 nadal ~60 ms, linia i tak wypadnie z LLC, więc mniejszy pierścień chybień nie usunie.
  **Hipoteza pierścienia odrzucona — testu 4096 nie robić.** ~~Pozostałe ~0,3/mln to granica PCIe Gen3~~ — **nie
  trzyma się**, jeśli `lodz1` (Linux, ta sama karta) przy porównywalnym ruchu ma 0: granica PCIe dotyczyłaby jej tak samo.
  Najpierw sprawdzić, czy porównanie jest uczciwe (model serwera, ruch w pps i Gb/s, `rx_discards_phy` z `ethtool -S`
  w tym samym czasie). Jeśli tak — zostaje różnica w ścieżce odbioru: jądro mlx5e używa domyślnie **striding RQ**
  (jeden deskryptor na wiele pakietów), DPDK w VPP — jednego deskryptora na pakiet (bez MPRQ), więc karta musi
  pobierać z pamięci deskryptor dla każdego pakietu; przy burście jej potok może na tym stać, a bufor portu się
  przepełnia (`rx_discards_phy`, nie `rx_out_of_buffer`). Dokumentacja DPDK mlx5 opisuje MPRQ właśnie jako oszczędność
  PCIe przy dużej liczbie pakietów. ~~Hipoteza~~ — **odrzucona**: `lodz1` ma `rx_striding_rq: off` (też jeden
  deskryptor na pakiet) i `rx_cqe_compress: off` — ścieżka odbioru jest taka sama jak w VPP po 1.5.48.

  **`lodz1` (6.11, ~16:20, `eth4`, Linux):** w 10 min 389,6 mln pakietów (~650 kpps), `rx_discards_phy` +0,
  `rx_out_of_buffer` +0. Ale od startu karty: 6,66 bln pakietów, **`rx_discards_phy` 147,5 mln (~22/mln)**,
  `rx_out_of_buffer` 186,3 mln (~28/mln). Linux na tej karcie też gubi w buforze karty — w sumie dużo więcej niż
  `lodz2` dziś (~0,3/mln); kiedy, nie wiadomo (pewnie incydenty/ataki). Teza „Linux nie gubi, VPP gubi” opierała się na
  krótkich oknach przy innym ruchu (`lodz1` ~650 kpps, `lodz2` 0,8–1 Mpps) i nie jest udowodniona. Do porównania
  potrzebny jest zapis obu routerów w tym samym czasie, w przedziałach ruchu (np. doba, co 10 s).
  Pierwsze 5 min równocześnie (16:20–16:25): `lodz1` (~645 kpps) — 0; `lodz2` — 6 okien `NIC_DISCARD` (16:21:39–16:24:49,
  ~130 pakietów). W tym samym czasie VPP gubi w karcie, a Linux nie — ale przy innym ruchu (`lodz2` ~0,8–1 Mpps,
  inne przepływy), więc to jeszcze nie dowód różnicy VPP/Linux. Zapis `lodz1` co 10 s trwa (`/root/lodz1-watch.log`).
  **Topologia (6.11):** większość ruchu wpływa z zewnątrz na `lodz2` i dopiero z niego idzie do `lodz1`. Operatorzy są
  podłączeni do przełącznika 4×10G, przełącznik do `lodz2` 100G — **na wejściu `lodz2` najwyżej ~40 Gb/s**, także
  chwilowo (przy 40G wejścia port 100G przełącznika nigdy nie jest zatkany, więc nie wypuszcza zbuforowanych serii).
  ~~Mikrobursty 100G szybsze niż PCIe~~ — **odpada**: 40G to mniej niż połowa możliwości PCIe Gen3 x16. Przyczyna
  odrzuceń w buforze karty `lodz2` jest **nieznana**: karta nie zdążyła przekazać pakietów do pamięci serwera,
  choć ruch był daleko poniżej jej możliwości — wskazuje to na chwilowe zatrzymanie po stronie serwera (PCIe/pamięć)
  albo w samej karcie. Narzędzie: liczniki karty z jądra (`ethtool -S` na sieciowym urządzeniu jądra tej samej
  karty) — m.in. `outbound_pci_stalled_*`, `rx_buffer_passed_thres_phy`, jeśli firmware je udostępnia. Do sprawdzenia: czy `lodz1` był
  wcześniej routerem brzegowym (ruch od operatorów prosto na niego) — jeśli tak, jego ~22/mln od startu liczników to
  wynik Linuksa na tej samej pozycji, ~70× gorszy niż `lodz2` z VPP (~0,3/mln).

**Skala (`router-ifaces errors`, 6.11 15:42, od startu VPP):** `rx_out_of_buffer` = `rx_missed_errors` = 438 827, `rx_phy_discard_packets` = 1189. Samo zdarzenie z 14:45 to 435,2 tys., czyli **~99% wszystkich strat na wejściu**; wszystkie pozostałe `RX_MISS` razem to ~3,6 tys. pakietów.

**2. 14:45:16 — `RX_MISS` 435 tys. pakietów** (przy 0,94 Mpps), opis: „SMI z BIOS-u”. To nie jest burst jednego
przepływu. Wszystkie pierścienie razem mieszczą 12 × 16384 ≈ 197 tys. pakietów. Żeby zgubić 435 tys., **wszystkie
workery** musiały stać ≥ ~0,65 s. Inna możliwość: jeden worker stał kilka sekund. Strata była między ~14:45:03
a 14:45:16 (odświeżanie co 10 s, sprawdzane co 3 s). `journalctl` 14:44:50–14:45:20 pokazuje tylko:
- 14:44:53 — timery minutowe i `router-rpki-check`; 14:44:58,95–14:44:59,18 — `router-fw-check` i `router-ifaces-check`
  (~17 s przed wpisem, raczej przed oknem; te same co 5 minut dają zwykle 200–300 pakietów, nie 435 tys.);
- 14:45:08 — `vpp-snmp-agent`: „Replacing serving dataset (555 OIDs)” — **wykluczone**: ten wpis jest równo co 30 s
  przez cały dzień, a duża strata była raz;
- żadnego upgrade, restartu usług, wpisu jądra (MCE/EDAC) ani BIRD-a (loguje do syslogu wszystko — brak zmian sesji BGP).
- SEL (`ipmitool sel elist`): z 6.11 nic. Nie ma błędów pamięci ECC, więc SMI od zapisu ECC do SEL nie ma
  potwierdzenia. W SEL są za to powtarzające się „Power Supply AC lost” (3.10, 6.10, 22.10 ×2, 30.10) — osobna
  sprawa: zasilanie jednego z zasilaczy.
Przyczyna nieznana. Zostaje SMI z innego źródła (monitor widział przyrost licznika SMI w 3 s przed wpisem) albo
zatrzymanie w samym VPP. Do 1.5.48 monitor nie zapisywał przyrostu SMI — od 1.5.49 następne takie zdarzenie
będzie miało w opisie przyrost SMI, wywłaszczenia i wektor z 13 s przed wpisem. Strat na kolejkę nie da się podać:
mlx5 ma jeden licznik `rx_out_of_buffer` na port.

**3. Pozostałe `RX_MISS` (24–302 pakiety)** — 14:37:30, 14:50:08, 14:55:08, 14:57:38. Dwa z nich wypadły **dokładnie
co 300 s** (14:50:08 i 14:55:08), a 14:45:16 mieści się w tym samym rytmie z dokładnością do 10 s. Wyglądało to na
coś okresowego. W `journalctl`: `router-fw-check` i `router-ifaces-check`
startują razem o 14:44:58,95, 14:49:58,96 (i dalej co 5 min, o :58,9) i kończą się po 0,1–0,24 s. `RX_MISS`
14:50:08 jest ~9 s później, czyli przy najbliższym odświeżeniu licznika po ich przebiegu. Obie kontrole wywołują
serię poleceń `vppctl` wykonywanych w barierze (wszystkie workery stoją):
`router-fw check` — `show interface`, `show acl-plugin acl`, `show acl-plugin interface`;
`router-ifaces check` — `show interface`, `show interface address`, `show lcp`, `show ip6 interface`,
`show flowprobe feature`, `show flowprobe params`.
Strata jest tylko czasem (14:40, 15:00, 15:05 — bez), bo pierścień zapełnia się tylko przy dużym przepływie na jednej
kolejce: przepływ 5 Gb/s (~420 kpps przy 1500 B) zapełnia 16384 deskryptorów w ~39 ms, więc wystarczy bariera
kilkudziesięciu ms. Wcześniejsze wykluczenie timerów (vppctl 1–12 ms) nie uwzględniało takiego przepływu.
**Pomiar (6.11, po 15:20) praktycznie wyklucza tę hipotezę:** każde z tych poleceń trwa w całości 2,0–2,8 ms
(razem ze startem `vppctl` i połączeniem z gniazdem CLI; sama bariera jest krótsza), wydruki mają 0–69 linii.
Nawet przepływ 9 Gb/s (~750 kpps przy 1500 B) zapełnia pierścień 16384 dopiero po ~22 ms, więc bariera rzędu 1–2 ms
nie może zgubić pakietów. Zbieżność 14:50:08 i 14:55:08 z kontrolami to najpewniej przypadek (dwa trafienia).
Ostatecznie zamknie to rozkład wszystkich `RX_MISS` z kilku dni względem startów `router-fw-check` (skrypt w
rozmowie diagnostycznej; przypadkiem w 15 s po kontroli wypada ~5% zdarzeń).
Pojedyncze `RX_MISS` poza tym rytmem (14:37:30, 14:57:38, kilkadziesiąt pakietów) mogą być burstami jednego
połączenia: przy 100G jedno połączenie zapełnia pierścień swojej kolejki w ~1,7 ms.

**4. Nowy główny podejrzany: `show hardware-interfaces` (bariera + odczyt liczników mlx5).**
`RX_MISS` 14:22–15:27 (13 wpisów): 14:50:08, 14:55:08, 14:57:38, 15:23:08, 15:23:38 — wszystkie w tej samej fazie
`:x8` (to faza odświeżania licznika, więc „co 300 s” było złudzeniem), a 15:23:08 i 15:23:38 dzielą **dokładnie 30 s**.
Potem skupisko 15:26:47, 15:27:07, :11, :29, :34 — 5 strat w 47 s, w nieregularnych odstępach 4–20 s, czyli licznik
był odświeżany częściej niż co 10 s: ktoś wywoływał `show hardware-interfaces` (router-top karta 5,
`router-ifaces errors -w`).
- `show hardware-interfaces` **nie jest mp-safe** (źródło VPP, `interface_cli.c`: bez `.is_mp_safe`, w przeciwieństwie
  do `show interface`) — wykonuje się w barierze, wszystkie workery stoją.
- Dla mlx5 to polecenie najpierw odświeża liczniki karty (`dpdk_update_counters` → xstats), a xstats portu mlx5 DPDK
  czyta przez jądro (ethtool → polecenia do firmware karty), więc bariera trwa tyle, ile odpowiada firmware — to może
  być dużo dłużej niż 2 ms zwykłych poleceń. Ta sama klasa problemu co odczyt EEPROM wkładek (przyczyna nr 3).
- **`router-snmp` woła `vppctl show hardware-interfaces` co 30 s** (liczniki `*discard*` dla SNMP) — stąd rytm 30 s i
  stała faza `:x8`. router-top karta 5 i `router-ifaces errors` robią to samo przy każdym odświeżeniu (komentarz
  w router-top, że to „bez bariery”, jest błędny).
Do potwierdzenia: czas `vppctl show hardware-interfaces` (10 pomiarów) i eksperyment — `router-snmp` zatrzymany na
godzinę, bez router-top karty 5 i `router-ifaces errors`; porównać liczbę `RX_MISS` z godziną poprzednią.
Jeśli się potwierdzi: `router-snmp`, router-top i `router-ifaces errors` czytają xstats z segmentu statystyk
(`/interfaces/<port>/<licznik>`, jak router-monitor) — bez `vppctl`, bez bariery.

**Wynik (6.11):** `vppctl show hardware-interfaces` trwa równo 12 ms (inne polecenia 2–3 ms) — ~10 ms to odczyt
liczników karty w barierze. Eksperyment: `router-snmp` zatrzymany o 15:44:58, bez router-top karty 5 i
`router-ifaces errors`:

| Okres | `show hardware-interfaces` | `RX_MISS` |
|---|---|---|
| 14:13–15:44 (91 min) | `router-snmp` co 30 s + router-top 5 / `router-ifaces errors` | 15 wpisów (~3,6 tys. pkt bez 14:45) |
| 15:45–16:41 (56 min) | brak | **0** |

12 minut to za mało: także przy działającym `router-snmp` bywały przerwy 16–25 min bez `RX_MISS` (14:57→15:23,
15:27→15:43). Rozstrzygające jest dopiero ≥1–2 h. `NIC_DISCARD` bez `router-snmp` bez zmian (5 okien w 12 min,
jak wcześniej co 2–3 min) — odrzucenia w karcie nie zależą od `show hardware-interfaces`.
Ostatni wpis przed eksperymentem (15:43:34, już w formacie 1.5.49, w trakcie `router-ifaces errors -w`):
3 pakiety, wektor maks. 2, wywłaszczenia 0, SMI +0 przy 1,06 Mpps — czyli nic poza samym poleceniem.
W czasie eksperymentu nic innego nie woła `show hardware-interfaces`: brak otwartych sesji router-top /
`router-ifaces -w`, `vpp-snmp-agent` nie używa CLI (tylko API i segment statystyk), a podsłuch uruchomień `vppctl`
złapał tylko kontrole 5-minutowe (`show interface`, `show ip6 interface`, `show acl-plugin interface`,
`show flowprobe params`).
Do domknięcia: `router-snmp` z powrotem → czy `RX_MISS` wracają (test odwrotny).

Przebieg testów (pomiar `pik-watch`, co 2 s, 30 min; straty w buforze karty na milion pakietów):

| Ustawienie | Ruch średnio | Straty / mln |
|---|---|---|
| bez opcji (domyślne DPDK) | ~600 kpps | ~1,1 |
| `rxq_pkt_pad_en=1` | ~700 kpps | ~0,2 |
| `rxq_pkt_pad_en=1,rxq_cqe_comp_en=0` | 768 kpps (szczyt 1346) | **nie 0**: 204 pakiety w 11 zdarzeniach 14:18–14:40 |
| ten sam, log `router-monitor` 14:37–15:05 | 0,66–0,98 Mpps | ~0,3 (dolna granica) |

Dodatkowo z `journalctl`: `router-rpki-check` kończy się błędem co 5 minut — RPKI jest na lodz2 celowo wyłączone
(nie połączone z BIRD), nie ma związku ze stratami.

Na `lodz2` opcje zostały dopisane ręcznie przed 1.5.48 — ta sama wartość jest teraz domyślna w instalatorze, więc `upgrade_script` i `set_workers` niczego nie zmienią (kopie ręczne: `/etc/vpp/startup.conf.przed-pad`, `.przed-cqe`).

## Kolejne kroki

1. ~~Kontrole 5-minutowe~~ — praktycznie wykluczone (polecenia 2–3 ms). Dla pewności rozkład `RX_MISS` z kilku dni
   względem startów `router-fw-check`; zmiana timerów tylko, jeśli wyjdzie wyraźnie ponad 5%.
   Od 1.5.49 (wdrożone na lodz2 6.11) zbierać kolejne `RX_MISS` z dowodami z okna 13 s (wektor, wywłaszczenia, SMI).
2. ~~`router-monitor`: pakiety zamiast pkt/s, przyczyna w całym oknie, przyrost SMI w opisie~~ — zrobione w 1.5.49.
   Wdrożyć na lodz2 (`install-router upgrade_script`, restart `router-monitor`).
3. `NIC_DISCARD` (~0,3/mln, niezależne od `router-snmp`): hipotezy pierścienia i MPRQ odrzucone. `lodz1` (Linux)
   ma od startu ~22/mln w buforze karty. Ewentualnie doba zapisu obu routerów naraz; poza tym zaakceptować i
   podnieść próg alarmu (punkt 7).
   Liczyć straty na milion pakietów w porze największego ruchu, nie tylko przy ~700 kpps.
4. **Decyzja 7.11: 18 workerów** (cały węzeł karty: main 3, workery 5–39 nieparzyste) — zapas na ataki małymi
   pakietami, nie wydajność przy zwykłym ruchu (workery zajęte w 14–18%). Karta nie jest granicą: ConnectX-4 100GbE
   w raporcie Mellanox (DPDK 17.05, test #4, E5-2697A v4, 8 rdzeni l3fwd) — 93,88 Mpps przy 64 B bez strat, a na
   wejściu `lodz2` jest najwyżej 40 Gb/s (59,5 Mpps przy 64 B). Kolejek mlx5 ma tysiące; 18 kolejek (nie potęga 2) →
   tablica RSS 512 pozycji, rozkład nierówny o ~2%. Dry-run: pierścień zostaje 16384, bufory 2 916 352 bez zmian
   (potrzeba ~1,5 mln). W oknie serwisowym razem z 1.5.51: `upgrade_script`, `set_workers 18`, restart serwera;
   po starcie `rx burst mode: Vector`, 18 kolejek RX na port, doba obserwacji `RX_MISS`/`NIC_DISCARD`.
5. Porównanie dobowe z `lodz1` (straty na milion odebranych pakietów).
6. Włączyć maile z alarmami (`/etc/router/notify.conf`, `router-notify test`), ponownie zaimportować szablony monitoringu z `templates/`, w Cacti jednorazowo „Reload Data Query” po wdrożeniu stałego ifIndex.
7. Próg `NIC_DISCARD_PPS` (dziś 1 pkt/s ≈ 10 pakietów w oknie 10 s) — rozważyć wyższy, żeby pojedyncze bursty nie dawały alarmów.

## Pojemność (pomiar `show runtime`, koszt pakietu ~1300–1450 cykli bez NetFlow)

| Konfiguracja | 64 B Mpps | 64 B Gb/s | 400 B Mpps | 400 B Gb/s | ~1100 B Mpps | ~1100 B Gb/s |
|---|---|---|---|---|---|---|
| VPP bez NetFlow (z firewallem) | 24–33 | 12–17 | 24–31 | 77–100 ¹ | 11 ¹ | 100 ¹ |
| VPP z NetFlow na wszystkich VLAN-ach | 8–10 | 4–5 | 8–10 | 26–32 | 8–10 | 70–88 |
| Linux bez VPP (`lodz1`, 24 rdzenie) | 4–5 | 2–2,6 | 4–5 | 13–16 | 4–5 | 35–44 |

¹ limit złącza PCIe Gen3 x16 (~100 Gb/s na kierunek), nie CPU. Firewall (ACL in + out) to ~40% kosztu pakietu.

**Korekta (6.11, ~17:40) — tabela powyżej jest zawyżona i niepotwierdzona.** `show runtime` podaje takty TSC, który
biegnie ze stałą częstotliwością nominalną 2,2 GHz (nie turbo), więc worker ma 2,2 mld taktów/s. Pomiar przy ruchu
1,19 Mpps (wektor 1,4–1,8 pakietu na wywołanie, po zmianie na odbiór wektorowy): przetwarzanie ~2100–2400 taktów
na pakiet (`acl-plugin-in` ~520–600, `acl-plugin-out` ~430–500, `ethernet-input` ~300–380, `hu0-tx` ~255–270,
`ip4-lookup`/`ip4-input`/`ip4-rewrite`/`hu0-output` po ~120–180) + odbiór z karty ~1000 → **~3300–3400 taktów**,
zgodnie z zajętością w router-top (14–18%). Firewall (4 reguły) ~1000–1100 taktów, ~45% przetwarzania — to głównie
stały narzut wtyczki ACL (hash 5-tuple, sesje), nie liczba reguł.
Wydajność przy tym koszcie: ~650 tys. pkt/s na workera, 12 workerów: 100% ≈ 7,8 Mpps (~69 Gb/s przy 1100 B);
bezpiecznie (najbardziej obciążony worker 70%, rozkład kolejek 1,17× średniej) ≈ **4,7 Mpps / ~40 Gb/s**.
Przy większym ruchu wektor rośnie i stały narzut na wywołanie rozkłada się na więcej pakietów — koszt na pakiet
spada (podstawa wydajności VPP), ale o ile na tym serwerze, pokaże dopiero test obciążeniowy (np. TRex).
Wiersz „Linux bez VPP” w tabeli to szacunek. **Pomiar `lodz1` (6.11, ~17:50, Linux, 2× E5-2690 v2 3,0 GHz, 20 rdzeni):**
852 tys. pkt/s na `eth4`, czas jądra + przerwania + softirq = 6,29 rdzenia → **~7,4 µs pracy rdzenia na pakiet**
(~22 tys. cykli przy 3,0 GHz). `lodz2` z VPP przy 1,09 Mpps: ~1,7 rdzenia → **~1,55 µs na pakiet** (~3400 taktów TSC
2,2 GHz). VPP ~4,8× taniej na pakiet już przy małym ruchu, mimo wolniejszego zegara. Ekstrapolacja liniowa: `lodz1`
nasyciłby wszystkie 20 rdzeni przy ~2,7 Mpps (w praktyce jądro skaluje się gorzej), `lodz2` 12 workerów przy ~7,7 Mpps
(przy większym ruchu koszt VPP spada). Zastrzeżenia: inne procesory, `lodz1` może mieć inny firewall (conntrack/
nftables), `system` obejmuje całą pracę jądra, pojedyncza próbka 10 s.

## Lekcje

- Każde cykliczne polecenie `vppctl` na routerze z ruchem może zatrzymać wszystkie workery (bariera). Przed dodaniem do timera/monitora: zmierzyć czas wykonania.
- Wartości „maksymalne” deklarowane przez kartę (np. 32768 deskryptorów) nie znaczą „działające z VPP” — każdą zmianę ścieżki odbioru testować w oknie serwisowym z gotowym cofnięciem i mierzyć straty na milion pakietów.
