# synack-guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (wykonanie inline, wybrane przez właściciela). Kroki mają checkboxy `- [ ]`.

**Goal:** Filtr odbić (SYN-ACK, opcjonalnie RST, UDP z portów amplifikacji) w VPP/DPDK włączany na żądanie per prefiks, z trybem monitor, sterowany poleceniem `router-guard` i osobnym plikiem `/etc/router/synack-guard.conf`.

**Architecture:** Moduł VPP w C (dwa węzły na łuku `ip4-unicast`/`ip6-unicast`: `out` zapisuje SYN i UDP do wspólnej tablicy bihash, `in` sprawdza odpowiedzi) z logiką niezależną od VPP w `synack_guard_core.h` (testowana na hoście). Sterowanie: `router-guard` (Python, wzorzec `router-fw`) przez CLI modułu. Wszystko osadzone w `install-router.sh`.

**Tech Stack:** C (VPP 26.06, bihash, feature arc), Python 3 stdlib, bash, systemd; testy: `cc` na hoście, `unittest` + `tests/fakevpp.py`.

**Spec:** `docs/superpowers/specs/2026-10-12-synack-guard-design.md`

## Global Constraints

- Źródłem prawdy jest `install-router.sh` (heredoki). Pliki C trafiają do drzewa VPP w etapie 10 (`st_vpp_build`) do `src/plugins/synack_guard/`. `build/` jest generowany przez `tools/extract.sh`.
- Moduł C **nie może być tu skompilowany ani uruchomiony** (brak VPP na tej maszynie). Weryfikowane lokalnie: `synack_guard_core.h` (testy `cc`) i `router-guard`. Moduł VPP (`synack_guard.c`) przechodzi lab (`docs/synack-guard-lab-checklist.md`).
- Etap instalatora **23**; `TOTAL_STAGES=23`; bez przenumerowywania. Zdarzenia `%GUARD-<sev>-<MNEM>`; kategoria e-mail `FIREWALL` obejmuje też `^GUARD-`.
- `router-guard` używa tylko biblioteki standardowej; linie ≤ 125 znaków; teksty po polsku.
- Katalog nie jest repozytorium git: brak kroków `commit`; punkt kontrolny to `bash tests/run-tests.sh`.

## Review Focus

1. SYN-ACK / RST / UDP bez wpisu w trybie `monitor` przechodzi i jest liczony, w `enforce` jest odrzucany (core: `gc_in_verdict`).
2. Niepierwszy fragment, nagłówki rozszerzeń IPv6, pakiet krótszy niż nagłówek TCP/UDP — bez odczytu poza buforem i bez naruszenia (core).
3. Wpis starszy niż TTL = brak wpisu; zły ISN odrzucany tylko przy `check-isn on` (core).
4. `router-guard on` bez załadowanej wtyczki: komunikat i brak zmian (kod 3).
5. Restart VPP w trakcie ochrony: `boot` odtwarza ochronę w trybie `monitor`, a `enforce` wraca po `warmup`.

---

### Task 1: `synack_guard_core.h` i testy na hoście

**Files:** Create `synack_guard_core.h` (osadzony w `install-router.sh`, wyciągany do `build/synack_guard/`), `tests/guard_core_test.c`, `tests/test-guard-core.sh`; Modify `tests/run-tests.sh`.

**Interfaces — Produces:** `gc_pkt_t`; `gc_classify_v4/v6(const uint8_t *ip, uint32_t len, gc_pkt_t *p)` (klasy `GC_NONE/GC_TCP_SYN/GC_TCP_SYNACK/GC_TCP_RST/GC_UDP`, pole `frag`); `gc_cfg_t` (tryb, `rst_handshake`, `check_isn`, `udp_frags_drop`, `ttl`, `udp_ttl`, mapa portów); `gc_out_action`, `gc_in_need_lookup`, `gc_in_verdict(p, cfg, found, val, now)` (PASS / NO_FLOW / BAD_ISN / FRAG_DROP); klucze `gc_key4/gc_key6`; wartość `gc_val_pack/unpack`; zbiory prefiksów `gc_pset4_*`, `gc_pset6_*` (tablice per długość prefiksu).

- [ ] Napisz `tests/guard_core_test.c` (RED: `bash tests/test-guard-core.sh` nie kompiluje się — brak nagłówka).
- [ ] Zaimplementuj nagłówek; testy: klasyfikacja SYN, SYN-ACK, RST, UDP, fragment, IPv6 z nagłówkiem rozszerzeń, pakiet za krótki; werdykty z tabeli polityki (monitor/enforce, ttl, ISN, `rst_handshake`, porty UDP); prefiksy (najdłuższy prefiks, /32, brak, IPv6).
- [ ] `bash tests/test-guard-core.sh` → wszystkie testy OK; dopisz do `tests/run-tests.sh`.

### Task 2: `router-guard` (Python) na symulatorze

**Files:** Modify `install-router.sh` (`prog_router_guard`, `UPGRADE_PROGRAMS`), `tools/extract.sh`, `tools/lint.sh`, `tests/run-tests.sh`, `tests/fakevpp.py`; Create `tests/test_router_guard.py`.

**Interfaces — Produces:** polecenia `on`, `off`, `enforce`, `monitor`, `status`, `check [--log]`, `boot`, `expire`; `parse_conf(text) -> (Conf, errs)`; stan `guard.state.json`; CLI modułu używane przez narzędzie: `synack-guard interface|prefix|mode|config`, `show synack-guard` (format ustalony w tym zadaniu: wiersze `mode: …`, `prefix: …`, `interface: <if> in|out`, `table-v4: used/size`).

- [ ] Testy (RED: brak polecenia): parser pliku, `on` (kolejność poleceń: config → interfejsy → prefiksy → tryb), `--enforce` z `warmup`, `off`, wygasanie, `boot` po restarcie VPP, brak wtyczki (kod 3), błędy pliku (kod 2), `check` wykrywa rozjazd, `status` pokazuje liczniki z `show errors`.
- [ ] Implementacja, rozszerzenie `fakevpp.py`, GREEN.

### Task 3: Źródła modułu VPP i osadzenie w instalatorze

**Files:** Create `vpp-plugin/synack_guard/{synack_guard.c,CMakeLists.txt}`; Modify `install-router.sh` (funkcje `emit_guard_*`, `st_vpp_build`), `tests/test-installer.sh`.

- [ ] Test statyczny (RED): `st_vpp_build` kopiuje wtyczkę; heredoki zawierają 3 pliki.
- [ ] Napisz `synack_guard.c` (węzły z dwoma przejściami: klasyfikacja + prefetch koszyka, potem wyszukiwanie; CLI; rejestracja łuków; liczniki błędów) — bez kompilacji; kontrola składni samego nagłówka rdzenia (`cc -fsyntax-only`).
- [ ] GREEN: testy statyczne i `bash -n install-router.sh`.

### Task 4: Etap 23, jednostki, dokumentacja

**Files:** Modify `install-router.sh` (`st_guard`, `run_stage 23`, `TOTAL_STAGES`, kategoria e-mail, README routera), `tests/test-installer.sh`; Create `examples/synack-guard.conf.example`, `docs/synack-guard-lab-checklist.md`, `docs/synack-guard-design.md`; Modify `README.md`.

- [ ] Testy statyczne (RED), implementacja, GREEN; pełne `bash tests/run-tests.sh`.

### Task 5: Przegląd końcowy

- [x] Recenzja całości (świeży kontekst), poprawki Critical/Important z testem RED→GREEN, ledger.
