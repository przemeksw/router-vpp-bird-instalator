# router-ifaces — projekt
## Interfejsy (decyzja 2026-10-11)
- Jedno źródło prawdy: `/etc/router/ifaces.conf` — kolumny: interfejs (hu0/hu1/loopN), vlan (1–4094 lub -), ipv4, ipv6 (kilka po przecinku), opis. Bez MTU: stałe 1500 (standard Ethernet), ustawiane w bootstrap.vpp przed podniesieniem portów; `mtu=` w pliku = błąd (decyzja Przemka).
- `router-ifaces` (Python, /opt/router/bin): `show`, `diff`, `apply` (tylko różnice, walidacja całego pliku przed zmianą), `check` (rozjazd vs ostatnio zastosowana wersja), `render`, `boot`.
- VLAN: `create sub-interfaces hu0 N dot1q N exact-match`, para linux-cp przez `lcp-auto-subint`; port: `lcp create hu0 host-if hu0`; loopback: `create loopback interface instance N` + `lcp create`.
- Usuwa tylko obiekty, które sam utworzył (stan `/var/lib/router/ifaces.state.json`); ręczne z vppctl zostawia.
- Po starcie VPP: `router-ifaces.service` (BindsTo vpp, Wants z drop-inu vpp, BIRD After); błąd w pliku → `ifaces.last-good.conf` + `%IFACE-2-CONFIG_ERROR`.
- Timer co 5 min: `%IFACE-4-DRIFT` / `%IFACE-5-DRIFT_END`; kategoria e-mail `IFACES`.
- Opisy → `/etc/router/snmp-ifaces.yaml` (format vppcfg) → `vpp-snmp-agent -c` → ifAlias; agent czyta plik tylko przy starcie, więc restart przy zmianie.
- Adresy w Linuksie synchronizuje lcp-sync; router-ifaces sprawdza i dopina je przez `ip -n dataplane addr`, gdy synchronizacja zawiedzie.
- Nieprzetestowane na prawdziwym VPP (testy na symulatorze vppctl): do sprawdzenia format `show lcp`, zachowanie lcp-sync dla adresów.
