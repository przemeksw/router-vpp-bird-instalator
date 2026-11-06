# Diagnostyka strat pakietów — lodz2-vpp, 5–6 listopada 2026

Router: Dell R630, 2× Xeon E5-2698 v4 (20 rdzeni, 2,2 GHz, turbo do 3,6 GHz), ConnectX-4 2×100G (`hu0`, `hu1`, NUMA 1),
VPP 26.06 + BIRD, 12 workerów (rdzenie 5–27 nieparzyste), `vpp_main` na rdzeniu 3. Instalator: wersja 1.5.46.
Porównanie: `lodz1` — ten sam typ karty (ConnectX-4, firmware 12.24) pod zwykłym Linuksem, bez VPP.

## Skąd brały się straty — przyczyny znalezione i usunięte

| # | Objaw | Przyczyna | Poprawka | Wersja |
|---|---|---|---|---|
| 1 | `%VPP-2-RX_MISS` co kilka godzin, kilkaset pakietów | `kcompactd1` (kompakcja pamięci jądra) siedział na rdzeniu workera 0 i budził się co 500 ms — 22 tys. wywłaszczeń | `vm.compaction_proactiveness=0`, `router-kthreads` przypina wątki jądra i przerwania poza rdzenie VPP (przy starcie i co 5 min) | 1.5.28–1.5.32 |
| 2 | Przerwania RCU (~1/s) na rdzeniach workerów, IOMMU tłumaczące adresy DMA | domyślne parametry jądra | `rcupdate.rcu_normal_after_boot=1 iommu=pt skew_tick=1 tsc=reliable` w GRUB | 1.5.36 |
| 3 | `RX_MISS` ~4 tys. pakietów **co 5 minut** | alarm wkładek (DDM) w `router-ifaces-check.timer`: odczyt EEPROM wkładki VPP wykonuje w barierze — wszystkie workery stały ~0,4 s | alarm wkładek domyślnie wyłączony (`OPTICS_CHECK_EVERY=0`), ręczne `router-ifaces optics` z ostrzeżeniem | 1.5.46 |
| 4 | router-monitor zgłaszał `DOWN/UP` co sekundę | błąd w kodzie (nadpisana zmienna) | poprawione + test pętli monitora | 1.5.39 |

## Sprawdzone i wykluczone

- **Pierścień RX 32768** (maksimum deklarowane przez kartę) — **zatrzymuje odbiór** na ConnectX-4 z VPP 26.06 (port nadaje, nie odbiera). Zostaje 16384, instalator ma twardą granicę `VPP_RX_DESC_MAX=16384`.
- Przerwania (IPI, TLB), przerwania kontrolera dysków (0 na rdzeniach VPP), brak buforów VPP, NUMA, taktowanie rdzeni, PCIe (x16 8 GT/s, AER czyste, ASPM nieobsługiwane), bariera z netlinka (BGP), timery 5-minutowe (polecenia `vppctl` trwają 1–12 ms).
- **Scatter** — `max-frame-size 1522` mieści się w jednym buforze 2048 B, więc 1 bufor na pakiet, pierścień = pełne 16384 pakietów.
- **PAUSE (flow control)** — wyłączone na obu routerach.
- **Uncore** — stałe 2,8 GHz (min = max) na obu procesorach.
- **Rozkład RSS** — skrót z adresów i portów dla IPv4 i IPv6 (optymalny). Jedno połączenie zawsze idzie przez jedną kolejkę — tak ma być.
- **MPRQ** — karta obsługuje, ale VPP nie umie buforów „doczepionych” przez sterownik; działałoby tylko z kopiowaniem każdego pakietu, a pojemność kolejki w pakietach się nie zmienia. Odłożone.

## Co zostało (stan 6.11, 13:35)

1. **Bursty jednego połączenia** — `RX_MISS` co kilkadziesiąt minut, kilkadziesiąt–kilkaset pakietów. Jedno połączenie wysłane z pełną prędkością 100G zapełnia pierścień swojej kolejki w ~1,7 ms. Fizyczny limit przy pierścieniu 16384.
2. **Odrzucenia w buforze karty (`rx_phy_discard`)** — ~1 na milion pakietów przy ~600 tys. pkt/s, podczas gdy `lodz1` (Linux) przy ~540 tys. pkt/s miał 0.

### Test w toku: dopełnianie zapisu pakietu (`rxq_pkt_pad_en=1`)

Sterownik jądra (Linux) domyślnie kończy zapis każdego pakietu na pełnej linii pamięci 64 B; DPDK domyślnie nie. Częściowe zapisy linii na Xeon E5 v4 spowalniają zapis karty do pamięci → bufor karty szybciej się zapełnia przy burstach.

- 6.11 ~13:24: dopisane **ręcznie** w `/etc/vpp/startup.conf` (`devargs rxq_pkt_pad_en=1` na `hu0` i `hu1`), kopia: `/etc/vpp/startup.conf.przed-pad`, restart VPP.
- Wynik po 7,5 min: **0,12 straty na milion** (przed: ~1,1) — obiecujący, do potwierdzenia pomiarem godzinnym.
- Do czasu dodania do instalatora **nie uruchamiać `install-router set_workers`** (przepisze `startup.conf` i usunie opcję).
- Cofnięcie: `cp /etc/vpp/startup.conf.przed-pad /etc/vpp/startup.conf && systemctl restart vpp`.

Punkty pomiarowe (`lodz2`):

| Czas | `rx_phy_discard` | `rx packets` (hu0) |
|---|---|---|
| 13:25:47 (start po restarcie) | 70 | 39 571 623 |
| 13:26:57 | 104 | 76 914 643 |
| 13:34:25 | 135 | 337 313 792 |

Punkt odniesienia `lodz1` (Linux, `eth4`), 13:17:42: `rx_out_of_buffer` 186 283 104, `rx_discards_phy` 147 500 487 (bez przyrostu w ~25 min), `rx_packets` 6 658 679 792 534.

### Zbieranie danych o pikach ruchu

`/root/pik-watch.sh` w tmux `pikwatch` zapisuje co 2 s (przez 30 min) do `/root/pik-watch.log`: czas, `rx frames ok`, `rx_phy_discard`, `rx_out_of_buffer`. Analiza:

```
awk 'NR>1 {dp=$2-p; dd=$3-d; if (dd>0) printf "%s  ruch %6.0f kpps  STRATA %d pkt\n", $1, dp/2000, dd} {p=$2; d=$3}' /root/pik-watch.log
awk 'NR>1 {dp=($2-p)/2000; s+=dp; n++; if (dp>m) m=dp} {p=$2} END {printf "średnio %.0f kpps, maks %.0f kpps\n", s/n, m}' /root/pik-watch.log
```

## Kolejne kroki

1. Wynik testu `rxq_pkt_pad_en` po godzinie (pomiar jak wyżej). Jeśli straty na milion zostaną ~0,1–0,2 → dodać do instalatora jako domyślne dla kart Mellanox (`VPP_NIC_DEVARGS`).
2. Jeśli nie pomoże: w oknie serwisowym `rxq_cqe_comp_en=0` (Linux ma kompresję CQE wyłączoną).
3. Osobny test: 16 workerów zamiast 12 (`lodz1` ma 20 kolejek; NVIDIA radzi więcej kolejek przy `rx_phy_discard`) — `install-router set_workers 16`, restart serwera, pomiar strat na milion.
4. Porównanie dobowe `lodz1` vs `lodz2` (straty na milion odebranych pakietów, ten sam okres, bez przenoszenia ruchu).
5. Włączyć maile z alarmami (`/etc/router/notify.conf`, `router-notify test`), ponownie zaimportować szablony monitoringu z `templates/`.

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
