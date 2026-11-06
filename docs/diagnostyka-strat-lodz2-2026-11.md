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
| 5 | Odrzucenia w buforze karty (`rx_phy_discard`) ~1 na mln pakietów; Linux na tej samej karcie: 0 | DPDK mlx5 inaczej niż jądro: bez dopełniania zapisu pakietu do pełnej linii 64 B (częściowe zapisy linii spowalniają DMA na Xeonie) i z kompresją CQE | `VPP_NIC_DEVARGS="rxq_pkt_pad_en=1,rxq_cqe_comp_en=0"` — odbiór jak w jądrze. Pomiar: bez opcji ~1,1/mln → samo dopełnianie ~0,2/mln → oba **0** | 1.5.48 |
| 6 | Cacti przypisywał wykresy złym interfejsom po restarcie VPP / dodaniu VLAN-u; Akvorado bez nazw interfejsów | `vpp-snmp-agent`: ifIndex = 1000 + numer VPP (przesuwa się); NetFlow podawał sam numer VPP | stały ifIndex (`/var/lib/router/snmp-ifindex.json`) w SNMP, `router-netflow` podmienia ten sam numer w IPFIX — jak `snmp ifindex persist` w Cisco | 1.5.47 |

## Sprawdzone i wykluczone

- **Pierścień RX 32768** (maksimum deklarowane przez kartę) — **zatrzymuje odbiór** na ConnectX-4 z VPP 26.06 (port nadaje, nie odbiera). Zostaje 16384, instalator ma twardą granicę `VPP_RX_DESC_MAX=16384`.
- Przerwania (IPI, TLB), przerwania kontrolera dysków (0 na rdzeniach VPP), brak buforów VPP, NUMA, taktowanie rdzeni, PCIe (x16 8 GT/s, AER czyste, ASPM nieobsługiwane), bariera z netlinka (BGP), timery 5-minutowe (polecenia `vppctl` trwają 1–12 ms).
- **Scatter** — `max-frame-size 1522` mieści się w jednym buforze 2048 B, więc 1 bufor na pakiet, pierścień = pełne 16384 pakietów.
- **PAUSE (flow control)** — wyłączone na obu routerach.
- **Uncore** — stałe 2,8 GHz (min = max) na obu procesorach.
- **Rozkład RSS** — skrót z adresów i portów dla IPv4 i IPv6 (optymalny). Jedno połączenie zawsze idzie przez jedną kolejkę — tak ma być.
- **MPRQ** — karta obsługuje, ale VPP nie umie buforów „doczepionych” przez sterownik; działałoby tylko z kopiowaniem każdego pakietu, a pojemność kolejki w pakietach się nie zmienia. Odłożone.

## Co zostało (stan 6.11, 14:50)

- **Bursty jednego połączenia** — sporadyczne `RX_MISS` (kilkadziesiąt–kilkaset pakietów): jedno połączenie z pełną prędkością 100G zapełnia pierścień swojej kolejki w ~1,7 ms. Fizyczny limit przy pierścieniu 16384.
- Odrzucenia w buforze karty: po 1.5.48 (`rxq_pkt_pad_en=1,rxq_cqe_comp_en=0`) **0** w teście 30-minutowym przy ~700 kpps.

Przebieg testów (pomiar `pik-watch`, co 2 s, 30 min; straty w buforze karty na milion pakietów):

| Ustawienie | Ruch średnio | Straty / mln |
|---|---|---|
| bez opcji (domyślne DPDK) | ~600 kpps | ~1,1 |
| `rxq_pkt_pad_en=1` | ~700 kpps | ~0,2 |
| `rxq_pkt_pad_en=1,rxq_cqe_comp_en=0` | ~700 kpps | 0 |

Na `lodz2` opcje zostały dopisane ręcznie przed 1.5.48 — ta sama wartość jest teraz domyślna w instalatorze, więc `upgrade_script` i `set_workers` niczego nie zmienią (kopie ręczne: `/etc/vpp/startup.conf.przed-pad`, `.przed-cqe`).

## Kolejne kroki

1. Kilka dni obserwacji `RX_MISS` i `NIC_DISCARD` (każdy `RX_MISS` ma przyczynę w opisie).
2. Ewentualnie test 16 workerów zamiast 12 (`install-router set_workers 16`, restart serwera) — tylko jeśli bursty będą częstsze.
3. Porównanie dobowe z `lodz1` (straty na milion odebranych pakietów).
4. Włączyć maile z alarmami (`/etc/router/notify.conf`, `router-notify test`), ponownie zaimportować szablony monitoringu z `templates/`, w Cacti jednorazowo „Reload Data Query” po wdrożeniu stałego ifIndex.
5. Próg `NIC_DISCARD_PPS` (dziś 1 pkt/s) — rozważyć 100, żeby pojedyncze bursty nie dawały alarmów.

## Pojemność (pomiar `show runtime`, koszt pakietu ~1300–1450 cykli bez NetFlow)

| Konfiguracja | 64 B Mpps | 64 B Gb/s | 400 B Mpps | 400 B Gb/s | ~1100 B Mpps | ~1100 B Gb/s |
|---|---|---|---|---|---|---|
| VPP bez NetFlow (z firewallem) | 24–33 | 12–17 | 24–31 | 77–100 ¹ | 11 ¹ | 100 ¹ |
| VPP z NetFlow na wszystkich VLAN-ach | 8–10 | 4–5 | 8–10 | 26–32 | 8–10 | 70–88 |
| Linux bez VPP (`lodz1`, 24 rdzenie) | 4–5 | 2–2,6 | 4–5 | 13–16 | 4–5 | 35–44 |

¹ limit złącza PCIe Gen3 x16 (~100 Gb/s na kierunek), nie CPU. Firewall (ACL in + out) to ~40% kosztu pakietu.

## Lekcje

- Każde cykliczne polecenie `vppctl` na routerze z ruchem może zatrzymać wszystkie workery (bariera). Przed dodaniem do timera/monitora: zmierzyć czas wykonania.
- Wartości „maksymalne” deklarowane przez kartę (np. 32768 deskryptorów) nie znaczą „działające z VPP” — każdą zmianę ścieżki odbioru testować w oknie serwisowym z gotowym cofnięciem i mierzyć straty na milion pakietów.
