# router-fw — lista kontrolna do labu (VPP 26.06)

Symulator (`tests/fakevpp.py`) zakłada składnię i format wyjścia VPP z dokumentacji. Poniższe punkty trzeba potwierdzić na prawdziwym VPP **przed pierwszym użyciem na produkcji**. Przy każdym punkcie: gdzie poprawić kod, jeśli VPP zachowuje się inaczej.

| # | Sprawdzenie | Jak | Gdzie poprawić |
|---|---|---|---|
| 1 | Składnia reguł: `src`/`dst` jako `0.0.0.0/0` i `::/0`, `proto`, `sport`/`dport` (liczba i zakres), `tag` na końcu, reguły po przecinku, IPv4 i IPv6 w jednej liście | `vppctl 'set acl-plugin acl permit src 10.0.0.0/8 dst 0.0.0.0/0 proto 6 dport 25, deny src ::/0 dst ::/0 tag test'` | `Flat.text()`, `Group.acl_command()` |
| 2 | Format `show acl-plugin acl` | ma zawierać `acl-index N count M tag {test}` | `ACL_RE` w `read_vpp()` |
| 3 | Format `show acl-plugin interface` | po `set acl-plugin interface hu0.100 input acl N`: `sw_if_index X:` i `input acl(s): N` | `SWIF_RE`, `BIND_RE` |
| 4 | Podmiana w miejscu `set acl-plugin acl index N ...` | działa bez błędu, ruch nie jest chwilowo nieprzefiltrowany (test z ciągłym ruchem) | `Step.command()` (`replace`) |
| 5 | Domyślne zachowanie przy braku dopasowania | pakiet niepasujący do żadnej reguły jest odrzucany? (dlatego `router-fw` dopisuje `permit any`) | `build_groups()` |
| 6 | ACL wejściowy i wyjściowy na podinterfejsie dot1q (`hu0.100`) | ruch testowy z i do VLAN-u, liczniki rosną | `plan()` |
| 7 | Liczniki: jak włączyć | `acl_stats_intf_counters_enable` przez `vpp_papi`; czy istnieje polecenie CLI | `enable_counters()` |
| 8 | Liczniki: nazwa segmentu i układ | `vpp_get_stats dump /acl` albo `VPPStats()["/acl/N/matches"]`; czy liczą w trybie bezstanowym i na ACL wyjściowym; czy zerują się po podmianie ACL | `read_counters()` |
| 9 | Koszt wydajnościowy | 10, 100, 1000 reguł; liczniki włączone i wyłączone; `vppctl show runtime` (vectors/call, clocks/packet) na ruchu zbliżonym do produkcyjnego | decyzja: długość list, `set counters off` |
| 10 | BGP/BFD po `apply` | sesje nie spadają przy podmianie ACL | — |
| 11 | Restart VPP | kolejność `router-ifaces` → `router-fw` → BIRD, reguły wracają (`journalctl -u router-fw`) | jednostki w `st_fw` |
| 12 | `apply --confirm 60` bez `confirm` | po 60 s wraca poprzednia wersja; `systemctl list-timers | grep router-fw-rollback` | `arm_rollback()` |
| 13 | Długa lista (powyżej `MAX_CMD`, 120 KB) | odmowa z komunikatem; sprawdź realny limit argumentu `vppctl` | `MAX_CMD` |
| 14 | Następny krok (poza tym planem) | `ip punt policer` / `set punt-limit`: `vppctl help ip punt policer`, `vppctl help policer add` | nowe zadanie |
