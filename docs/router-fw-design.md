# router-fw — skrót projektu

Pełny projekt: `docs/superpowers/specs/2026-10-12-router-fw-design.md`. Plan: `docs/superpowers/plans/2026-10-12-router-fw.md`.

- `router-fw` steruje wyłącznie filtrami tranzytu w VPP (acl-plugin, tryb bezstanowy). Ruch do samego routera filtruje netfilter w netns `dataplane`, poza tym narzędziem.
- Plik `/etc/router/firewall.conf`: strefy (`zone`), listy (`list`), reguły `kierunek akcja proto src sport dst dport opis`. Pierwsza pasująca reguła wygrywa; domyślnie `permit`.
- Jedna lista ACL na parę strefa + kierunek (`internet:in`, `internet:out`...), tag ACL `rfw:<strefa>:<kier>:<sha8>` — zmiana treści to nowy sha, ACL jest podmieniany w miejscu (`index N`), więc nie ma okna bez filtra.
- Blokady doraźne (`router-fw block`) trafiają na początek listy `internet:in`; wygasają przez `router-fw-expire.timer`.
- `apply --confirm N` uzbraja `systemd-run` z cofnięciem; `router-fw confirm` je anuluje.
- `block`/`unblock`/`expire` wgrywają ostatnio zastosowaną konfigurację (last-good) + blokady; last-good zawiera listy `include` w postaci rozwiniętej; `rollback` i `boot` po niepotwierdzonym `apply --confirm` przywracają też plik `firewall.conf` (odrzucony: `fw.rejected.conf`).
- Liczniki trafień: segment statystyk VPP `/acl/<indeks>/matches`, włączane API `acl_stats_intf_counters_enable`; VPP zeruje je przy zmianie treści listy.
- Poza zakresem: firewall stanowy, NAT, Flowspec, `ip punt policer` (`set punt-limit`) — składnia policera niepotwierdzona.
