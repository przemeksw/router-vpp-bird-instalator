# synack-guard / router-guard — skrót projektu

Pełny projekt: `docs/superpowers/specs/2026-10-12-synack-guard-design.md`. Plan: `docs/superpowers/plans/2026-10-12-synack-guard.md`.

- **Cel:** na żądanie, per prefiks lub IP, odrzucać w VPP „odpowiedzi bez pytania” z internetu: SYN-ACK (opcjonalnie RST) bez SYN wysłanego z chronionego prefiksu oraz UDP ze źródłowych portów amplifikacji bez wcześniejszego pakietu UDP do takiego portu. SYN, ACK i dane TCP przechodzą.
- **Moduł VPP (C):** węzły `synack-guard-{in,out}-ip{4,6}` na łukach `ip4-unicast` / `ip6-unicast`, wspólna tablica stanów (bihash), tablice prefiksów per długość, liczniki jako błędy węzłów (`show errors`). Źródła są osadzone w `install-router.sh` (`emit_guard_plugin`), wyciągane do `build/synack_guard/`, kopiowane do drzewa VPP w etapie 10.
- **Rdzeń niezależny od VPP:** `synack_guard_core.h` (klasyfikacja, werdykty, klucze, zbiory prefiksów) — testowany na hoście (`bash tests/test-guard-core.sh`, ASan/UBSan).
- **Sterowanie:** `router-guard on/off/enforce/monitor/status/check/boot/expire`, plik `/etc/router/synack-guard.conf`, stan w `/var/lib/router/guard.state.json`.
- **Tryby:** `monitor` (liczy, nie blokuje) i `enforce`; `on --enforce` = monitor przez `warmup`, potem enforce. Po restarcie VPP ochrona wraca w trybie monitor.
- **Warunek:** R630 widzi oba kierunki połączeń chronionego prefiksu.
- **Poza zakresem:** ACK i dane TCP poza sesją (pełne śledzenie), nowe SYN do adresów niebędących serwerami (osobne zadanie w `router-fw`), ruch do samego routera.
- **Nie zweryfikowane na prawdziwym VPP:** cały moduł C (brak VPP na maszynie deweloperskiej) — patrz `docs/synack-guard-lab-checklist.md`.
