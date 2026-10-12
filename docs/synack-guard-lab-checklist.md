# synack-guard — lista kontrolna do labu (VPP 26.06)

Moduł C (`synack_guard.c`) nie był kompilowany ani uruchamiany na maszynie deweloperskiej. Rdzeń (`synack_guard_core.h`) i `router-guard` są przetestowane lokalnie. Poniższe punkty trzeba wykonać **przed użyciem na produkcji**, w kolejności.

## A. Kompilacja i ładowanie

| # | Sprawdzenie | Jak | Gdzie poprawić |
|---|---|---|---|
| 1 | Moduł się kompiluje w drzewie VPP | `install-router.sh --from 10`; błędy kompilacji `synack_guard.c` | `synack_guard.c` (miejsca „WERSJA:”) |
| 2 | Nagłówki bihash i szablony | błędy przy dwóch typach tablic w jednym pliku | kolejność `#include <vppinfra/bihash_*.h>` i `bihash_template.[hc]` |
| 3 | `vnet_feature_next_u16` | błąd nazwy funkcji | makro `SG_FEATURE_NEXT` |
| 4 | `clib_bihash_add_or_overwrite_stale_*`, `clib_bihash_search_inline_2_with_hash_*`, `clib_bihash_elts_*` | błędy sygnatur | użycia w `sg_node_inline`, `sg_show_command_fn` |
| 5 | Wtyczka się ładuje | `vppctl show plugins | grep synack`, `vppctl show synack-guard` | — |

## B. Zachowanie (generator: scapy lub TRex)

| # | Sprawdzenie | Oczekiwane |
|---|---|---|
| 6 | `synack-guard interface <if> in/out`, `prefix`, `mode monitor` | `show synack-guard` pokazuje stan; `show interface features <if>` — węzły na łuku |
| 7 | SYN z chronionego prefiksu → SYN-ACK z `ack = ISN+1` | przechodzi, `show errors` Passed rośnie |
| 8 | SYN-ACK bez SYN | monitor: przechodzi, Violation no flow rośnie; enforce: Dropped rośnie, pakiet nie wychodzi |
| 9 | SYN-ACK ze złym ISN | Violation bad isn (przy `check-isn on`) |
| 10 | Wpis po TTL | SYN-ACK po 61 s jest naruszeniem |
| 11 | RST: `tcp-rst pass` / `handshake` | zgodnie z polityką |
| 12 | UDP: zapytanie do :53, odpowiedź z :53 | przechodzi; odpowiedź bez zapytania — naruszenie |
| 13 | Prefiks spoza ochrony, ACK, dane, SYN przychodzący | nietknięte |
| 14 | IPv6 (SYN, SYN-ACK, UDP), podinterfejsy VLAN (dot1q) | j.w. |
| 15 | Asymetria uplinków: SYN wychodzi uplinkiem A, SYN-ACK wraca B | przechodzi (tablica globalna) |
| 16 | Retransmisja SYN | odświeża czas, SYN-ACK przechodzi |

## C. Wydajność i odporność

| # | Sprawdzenie | Jak | Cel |
|---|---|---|---|
| 17 | Koszt dla ruchu zwykłego | forwarding 64 B z węzłami i bez; `show runtime` clocks/packet | ≤ 40 cykli/pakiet narzutu |
| 18 | Odrzucanie SYN-ACK | TRex: SYN-ACK 64 B na chronione prefiksy, rosnąca szybkość; granica, od której rośnie `rx-miss` | ≥ 8 Mpps na worker, tablica z 2 mln wpisów |
| 19 | Zapełnienie tablicy | SYN-flood „z klienta” | `%GUARD-2-TABLE_FULL`, przejście na monitor, brak crasha |
| 20 | Restart VPP | `systemctl restart vpp` w trakcie ochrony | `router-guard.service` odtwarza ochronę w monitorze, enforce po rozgrzewce |
| 21 | `router-guard status` | liczniki z `show errors` zgadzają się z `show synack-guard` | formaty w `read_errors()` / `read_vpp()` |
| 22 | Format wyjścia `show synack-guard` i `show errors` | porównaj z oczekiwanym przez `router-guard` | `read_vpp()`, `read_errors()` |

## D. Włączenie na produkcji

1. Upewnij się, że dla chronionego prefiksu nie istnieje trasa wyjścia poza R630.
2. `router-guard on <prefiks> --monitor`; po 30–60 s `router-guard status`: naruszenia powinny być bliskie zeru przy normalnym ruchu. Jeśli rosną, część ruchu omija R630 — nie włączaj `enforce`.
3. `router-guard enforce` (albo od razu `on <prefiks> --enforce --for 2h`).
