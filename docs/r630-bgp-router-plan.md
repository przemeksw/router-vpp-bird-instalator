# Router BGP na Dell R630 + ConnectX-4 — plan (rekomendacja)

Status: rekomendacja z 2026-10-11, do potwierdzenia przez Przemka.

## Sprzęt
- Dell PowerEdge R630, 2× Xeon E5-2698 v4 (Broadwell, 20C/40T, 2,2 GHz, 4 kanały DDR4-2400 na CPU).
- Mellanox ConnectX-4 (MT27700, PCI 15b3:1013), 100G, PCIe 3.0 x16.
- Topologia: router-on-a-stick — jeden port 100G do switcha Huawei, ruch wchodzi jednym VLAN-em, wychodzi drugim.
- Uplinki: 3×10G + 15G = 45G → najgorszy przypadek floodu 64B ≈ 67 Mpps (45 Gb/s ÷ 672 b/ramkę).

## Decyzja: VPP (DPDK mlx5) + linux-cp + BIRD
| Data plane | IPv4 ~Mpps/rdzeń (orientacyjnie) | Na 67 Mpps |
|---|---|---|
| Linux kernel | ~1,4 | ~48 rdzeni — nierealne |
| XDP (bpf_fib_lookup, full table) | ~5,6 | ~12 rdzeni; omija nftables, brak ICMP/fragmentacji w fast-path |
| VPP | ~10 | 7–8 workerów → 12 z zapasem |

- Limit karty: CX-4 100G, Broadwell E5-2697A v4, PCIe 3.0 x16, ruch in/out tym samym portem, DPDK l3fwd 8 rdzeni: 93,9 Mpps @64B, line rate od 1024B (raport DPDK 17.05 Mellanox).

## Rozmieszczenie (NUMA)
- R630: slot 1 (low-profile, x16) → CPU2; slot full-height (x16) → CPU1; w konfiguracji 3-slotowej slot 2 jest elektrycznie x8 (~50 Gb/s) — nie używać.
- Rekomendacja: karta w slocie 1 → CPU2 = wyłącznie VPP, CPU1 = system, BIRD, RPKI, FastNetMon, snmpd.
- Weryfikacja: `lspci -vv -s <bdf> | grep LnkSta` (8GT/s, Width x16), `cat /sys/class/net/<if>/device/numa_node`, `lscpu` (Dell często przeplata numerację: node0 parzyste, node1 nieparzyste).
- RAM: wszystkie 4 kanały CPU karty (B1–B4).
- BIOS: System Profile = Performance, Logical Processor (HT) = Disabled, Node Interleaving = Disabled.
- Karta: `mstflint -d <bdf> q` (PSID); VPI (MCX455A/456A) → `mstconfig -d <bdf> set LINK_TYPE_P1=2`; FW 12.28.4704 (PSID DEL* → FW Della). Dwa porty → LACP do switcha (redundancja).
- Zarządzanie (SSH/SNMP/iDRAC) przez port 1G NDC, poza VPP.

## Oprogramowanie
- System: Debian 13 (trixie, kernel 6.12) — wybór Przemka.
- VPP 26.06: fd.io nie publikuje paczek dla Debian 13 (tylko 12 i Ubuntu 22.04/24.04; issue FDio/vpp#3635), ale Makefile gałęzi stable/2606 obsługuje debian-13 → własny build `make install-dep && make pkg-deb` na osobnej maszynie/kontenerze Debian 13, potem instalacja .deb na routerze (lokalne repo).
- Reszta na Debian 13: bird3/bird2 (Debian lub CZ.NIC), FastNetMon (Debian: 1.2.9), Routinator (repo NLnet Labs), mstflint, snmpd — dostępne; hsflowd budować ze źródeł.
- Moduły: `mlx5_ib`, `ib_uverbs`; karta zostaje na `mlx5_core` (bifurcated, bez vfio).
- BIRD 3.3.x z repo CZ.NIC (pkg.labs.nic.cz, Debian 12/13); zachowawczo 2.19.x. Nie bird2 2.0.12 z bookworma.
- BIRD w netns `dataplane` (`NetworkNamespacePath=/run/netns/dataplane`), best-path → kernel → linux-nl → FIB VPP.
- RPKI: Routinator albo rpki-client + StayRTR (invalid = reject); import limit; BFD gdzie się da.
- Pełna tablica: ~1,08 mln IPv4 (APNIC, 2026-10-03) + IPv6.

### startup.conf (szkielet, sekcje unix/api-segment z paczki)
```
cpu {
  main-core 1
  corelist-workers 3,5,7,9,11,13,15,17,19,21,23,25
}
memory  { main-heap-size 4G  main-heap-page-size default-hugepage }
buffers { buffers-per-numa 262144  default data-size 2048 }
statseg { size 1G }
dpdk {
  dev 0000:82:00.0 { name hu0  num-rx-queues 12  num-rx-desc 4096  num-tx-desc 4096 }
}
plugins {
  plugin linux_cp_plugin.so { enable }
  plugin linux_nl_plugin.so { enable }
  plugin sflow_plugin.so { enable }
}
linux-cp { default netns dataplane  lcp-sync  lcp-auto-subint }
linux-nl { nl-rx-buffer-size 134217728 }
```

### sysctl / boot
```
# /etc/sysctl.d/80-vpp.conf (sysctl.d nie obsługuje komentarzy w linii)
# 2 MB hugepages: 16 GB, po 8 GB na węzeł NUMA
vm.nr_hugepages = 8192
vm.max_map_count = 20000
kernel.shmmax = 17179869184
# bufor netlink dla linux-nl przy full table
net.core.rmem_max = 134217728
```
- GRUB: `isolcpus=<rdzenie VPP> rcu_nocbs=<rdzenie VPP>`; irqbalance z `IRQBALANCE_BANNED_CPULIST`.
- `net.*` są per-netns — np. `gc_thresh` dla LAN-u EPIX ustawiać w netns dataplane.

## DDoS
- Flood większy niż uplink → tylko RTBH/Flowspec u upstreamów; ustalić community blackhole (RFC 7999, 65535:666) z tranzytami i EPIX.
- Flood do abonenta → przejdzie przez router i zatka ASR1001-X (max 20 Gb/s): sFlow z VPP → hsflowd → FastNetMon → BIRD: /32 jako `blackhole` (linux-cp → drop w VPP) + ogłoszenie z community blackhole.
- Control plane: `ip punt policer` + ACL dla ruchu do adresów routera (BGP tylko od sąsiadów, BFD).

## Monitoring i testy
- LibreNMS: vpp-snmp-agent (AgentX) w netns dataplane — inaczej SNMP widzi tylko ruch puntowany.
- Przed produkcją: TRex, 64B i IMIX, z full table; `vppctl show runtime`, `show hardware-interfaces` (imissed). Sesje BGP muszą przetrwać flood.
- Upgrade VPP = przerwa w forwardingu → GRACEFUL_SHUTDOWN (RFC 8326) przed pracami; docelowo drugi router.

## Potwierdzone (2026-10-11)
- Karta: MCX416A-CCAT (ConnectX-4 EN, 2× QSFP28 100G, tylko Ethernet), PCI 0000:82:00.0 i 0000:82:00.1, LnkSta 8GT/s x16 (ok).
- lscpu: 2×20 rdzeni, 1 wątek/rdzeń (HT wyłączony), numeracja przeplatana: node0 = parzyste, node1 = nieparzyste.
- RAM: 8×8 GB DDR4 dual rank 2133 MHz, A1–A4 i B1–B4 → 4 kanały na CPU, 32 GB/węzeł.
- iDRAC: CSIOR wyłączony, inventory może być nieaktualne (pokazuje HT Enabled, lscpu mówi inaczej).
- numa_node karty = 1 (CPU2) → VPP na rdzeniach nieparzystych, szkielet startup.conf pasuje.
- dmesg: 126.016 Gb/s PCIe (8 GT/s x16) — wspólne dla obu portów.
- FW karty 12.20.1010 (stary) → aktualizacja do 12.28.4704 po instalacji Debiana. Komunikat `mlx5e_tc_post_act_init: firmware level support is missing` dotyczy offloadu TC — bez znaczenia dla VPP.
- Obecnie Alpine (tymczasowo); docelowo Debian 12. Zarządzanie: eth2 (192.168.80.0/24), z internetem — zostaje poza VPP.

## Do ustalenia
- PSID (mstflint q), System Profile w BIOS, nazwy interfejsów pod Debianem.
- Topologia: upstreamy (VLAN, ASN, IP, full/default, community blackhole, BFD), prefiksy AS61078, strona BNG, ruch szczytowy.
- Debian 12 + repo fd.io czy Debian 13 + własny build VPP.
- BIRD 3 czy 2.
- RTBH/Flowspec u każdego upstreamu.
