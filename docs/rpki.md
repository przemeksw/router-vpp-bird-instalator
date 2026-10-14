# RPKI: Routinator + BIRD (`router-rpki`)

Etap 27 instalatora stawia walidator RPKI i podłącza go do BIRD. **Domyślnie nic nie jest odrzucane.** BIRD tylko
sprawdza trasy, a `router-rpki invalid` pokazuje, co zostałoby odrzucone. Ty decydujesz:

- **gdzie** RPKI działa: wywołujesz `rpki_filter()` w filtrze importu wybranych sesji, np. tylko globalnych T1;
- **kiedy** zaczyna odrzucać: `router-rpki enable`, a wyłączasz je przez `router-rpki disable`.

Gdy walidator przestanie działać, BIRD po najwyżej godzinie przestaje cokolwiek odrzucać i przepuszcza wszystko.
Odrzucenia są tylko wtedy, gdy walidator działa i dane są świeże.

## Jak to jest zbudowane

```
 internet (RRDP/rsync)
        │  port zarządzający (eth2)
 ┌──────▼─────────────── przestrzeń główna ─┐      ┌──────────────── netns dataplane ─────────┐
 │ Routinator                               │      │ BIRD                                     │
 │  RTR  169.254.31.1:3323 (rpki0) ◄────────┼─veth─┼─► rpki1 169.254.31.2                     │
 │  HTTP 127.0.0.1:8323 (stan, metryki)     │      │  protocol rpki rpki_routinator           │
 └──────────────────────────────────────────┘      │  tablice rpki4 / rpki6 (VRP)             │
                                                   │  rpki_invalid(), rpki_filter()           │
                                                   └──────────────────────────────────────────┘
```

- **Routinator** (NLnet Labs, pakiet z `packages.nlnetlabs.nl`) działa w przestrzeni głównej. Pobiera dane przez port
  zarządzający, więc działa też wtedy, gdy sesje BGP leżą. Pobrane dane trzyma na dysku
  (`/var/lib/routinator`), więc po restarcie od razu je serwuje.
- **Łącze `rpki0` ↔ `rpki1`** (veth, `router-rpki-link.service`) to jedyna droga z BIRD do walidatora. RTR słucha tylko na
  tym łączu, więc z zewnątrz nie ma do niego dostępu.
- **BIRD** dostaje VRP przez RTR do tablic `rpki4` i `rpki6`. Plik `/etc/bird/conf.d/05-rpki.conf` generuje
  instalator.
- Zgoda ARIN (TAL) jest w pakiecie Routinatora, nic nie trzeba akceptować ręcznie.

## Wynik sprawdzenia trasy

| Wynik | Kiedy | Co robi `rpki_filter()` |
|---|---|---|
| VALID | jest ROA i trasa się z nim zgadza | przepuszcza |
| NOT FOUND (UNKNOWN) | dla prefiksu nie ma żadnego ROA (duża część internetu) | przepuszcza |
| **INVALID** | jest ROA, ale trasa ma inny AS źródłowy albo jest dłuższa niż `maxLength` | **odrzuca tylko po `router-rpki enable`** |

Trasa może być INVALID tylko wtedy, gdy istnieje ROA, które jej przeczy. Gdy tablice ROA są puste (walidator nie
działa od ponad godziny), każda trasa jest NOT FOUND i nic nie jest odrzucane.

## Włączenie RPKI w sesjach (Twoje filtry BGP)

Instalator nie zmienia sesji ani filtrów. W pliku z konfiguracją BGP (w `/etc/bird/conf.d/`, nazwa ma sortować się
po `05-rpki.conf`, np. `20-bgp.conf`) dopisz `rpki_filter();` na początku filtru importu tych sesji, w których RPKI
ma działać:

```
filter import_t1 {
  rpki_filter();                 # INVALID odrzucany dopiero po "router-rpki enable"
  # ... Twoje reguły (bogony, długość prefiksu, AS-path) ...
  accept;
}

protocol bgp t1_cogent {
  description "Transit: Cogent";
  neighbor 192.0.2.1 as 174;
  ipv4 {
    import table on;             # zalecane: BIRD pamięta trasy sprzed filtra i sam je przelicza
    import filter import_t1;
    export filter export_t1;
  };
}
```

Sesje bez `rpki_filter()` nie są dotykane: ich trasy INVALID przechodzą zawsze, ale nadal widać je w podglądzie.

Dostępne funkcje (z `05-rpki.conf`):

| Funkcja | Działanie |
|---|---|
| `rpki_filter()` | gdy odrzucanie jest włączone i trasa jest INVALID, robi `reject`; inaczej nic nie robi |
| `rpki_invalid()` | `true`, gdy trasa jest INVALID; do własnych reguł i podglądu (`show route where rpki_invalid()`) |

Własna logika, np. obniżenie preferencji zamiast odrzucenia:
`if rpki_invalid() then bgp_local_pref = 50;`

## Podgląd: co zostałoby odrzucone

```
router-rpki                         # stan: walidator, połączenie BIRD, VRP, tryb, liczba INVALID
router-rpki invalid --count         # ile tras jest teraz INVALID (wszystkie sesje)
router-rpki invalid t1_cogent       # trasy INVALID od jednej sesji
birdc show route where rpki_invalid()
birdc show route protocol t1_cogent where rpki_invalid() count
```

Zrób to przed włączeniem odrzucania. Trasy INVALID to zwykle błędy w ROA albo przejęcia prefiksów. Warto przejrzeć,
czy nie ma wśród nich prefiksów ważnych klientów.

## Włączenie i wyłączenie odrzucania

```
router-rpki enable      # trasy INVALID odrzucane w sesjach z rpki_filter()
router-rpki disable     # powrót do podglądu (stan domyślny)
```

Co robi polecenie:

1. Zapisuje `/etc/bird/rpki-mode.conf` (`define RPKI_ENFORCE = 1` albo `0`). Tego pliku nie edytuj ręcznie.
2. Sprawdza całą konfigurację (`bird -p`). Przy błędzie przywraca poprzedni tryb i nic nie zmienia.
3. Robi `birdc configure`: BIRD przelicza filtry **bez zrywania sesji**. Jeśli to się nie uda, przywraca poprzedni
   tryb.
4. Zapisuje zdarzenie `%RPKI-5-ENFORCE_ON` albo `%RPKI-5-ENFORCE_OFF` w `alarmy.log` i wysyła e-mail
   (kategoria `RPKI`).

Tryb przeżywa restart serwera i ponowne uruchomienie instalatora (etap 27 nie nadpisuje `rpki-mode.conf`).

Po włączeniu odrzucone trasy znikają z tablicy. Widać je tylko przy `import keep filtered on` w kanale
(`birdc show route filtered`). Liczbę tras INVALID w sesjach bez `rpki_filter()` dalej pokazuje `router-rpki invalid`.

## Gdy walidator przestanie działać

Ustawienia połączenia w `05-rpki.conf`: `refresh keep 900`, `retry keep 90`, `expire keep 3600`.

| Czas od awarii | Co się dzieje |
|---|---|
| 0–5 min | BIRD używa ostatnich, świeżych danych; `router-rpki check` (co 5 min) zapisuje `%RPKI-3-DOWN` i wysyła e-mail |
| do 1 h | BIRD nadal używa ostatnich danych; krótki restart Routinatora niczego nie zmienia |
| po 1 h (expire) | BIRD czyści tablice ROA: każda trasa jest NOT FOUND, **nic nie jest odrzucane** |
| walidator wraca | BIRD pobiera VRP, `%RPKI-5-UP`; trasy są przeliczane same, odrzucanie wraca (jeśli włączone) |

Przeliczanie po zmianie danych ROA BIRD 3 robi sam (opcja kanału `rpki reload`, domyślnie włączona). Potrzebuje do
tego `import table on` w kanale albo obsługi route refresh u sąsiada, a mają ją praktycznie wszyscy.

Jeśli padnie tylko internet na porcie zarządzającym, Routinator działa dalej i serwuje ostatnie dane. Są poprawne,
dopóki nie wygasną same obiekty RPKI, czyli zwykle przez wiele godzin. Routinator zapisze błędy pobierania w
journalu.

Chcesz krótszy czas: zmień `expire keep 3600` (najmniej 600, musi być większe od `refresh` i `retry`) w szablonie
instalatora `rpki_bird_conf` i uruchom etap 27 ponownie (`install-router.sh --from 27`).

## Monitoring i alarmy

| Gdzie | Co |
|---|---|
| `alarmy.log` + e-mail (`RPKI`) | `%RPKI-3-DOWN` (walidator albo połączenie BIRD padło), `%RPKI-5-UP`, `%RPKI-5-ENFORCE_ON/OFF` |
| SNMP (`router-snmp`) | `rvRpkiEnforce`, `rvRpkiInvalid`, `rvRpkiValidatorUp`, `rvRpkiCheckAge`; tablica `rvRpkiTable` (połączenie BIRD, VRP IPv4/IPv6) |
| Szablony (`templates/`) | LibreNMS: czujniki RPKI; Zabbix: wyzwalacze „Routinator nie działa”, „RPKI: brak połączenia z walidatorem” |
| `router-check`, menu `router` | usługi `routinator`, `router-rpki-link`; akcje „RPKI: stan”, „RPKI: trasy INVALID” |

## Pliki i usługi

| Element | Opis |
|---|---|
| `/etc/bird/conf.d/05-rpki.conf` | tablice ROA, `protocol rpki rpki_routinator`, funkcje (generuje instalator) |
| `/etc/bird/rpki-mode.conf` | tryb: `RPKI_ENFORCE = 0/1` (zmienia `router-rpki enable/disable`) |
| `/etc/routinator/routinator.conf` | konfiguracja pakietu; instalator ustawia tylko `rtr-listen` i `http-listen` |
| `routinator.service` (+ `routinator.service.d/10-router.conf`) | walidator; restart po awarii, limit pamięci 4 GB, najwyżej 2 rdzenie (`validation-threads = 2`, `CPUQuota=200%`), niski priorytet CPU i dysku |
| `router-rpki-link.service` | veth `rpki0` (169.254.31.1) ↔ `rpki1` w dataplane (169.254.31.2) |
| `router-rpki-check.timer` | co 5 min `router-rpki check --log`: alarmy, liczba tras INVALID |
| `/var/lib/router/rpki.state.json` | ostatni wynik kontroli (dla SNMP) |
| `/opt/router/bin/router-rpki` | polecenie (`router-rpki --help`) |

## Diagnostyka

```
systemctl status routinator router-rpki-link
journalctl -u routinator -n 50
curl -s http://127.0.0.1:8323/status          # stan Routinatora (ostatnie pobranie, liczba VRP)
birdc show protocols all rpki_routinator      # połączenie BIRD ↔ Routinator, VRP
ip -n dataplane addr show rpki1               # łącze po stronie BIRD
birdc eval 'roa_check(rpki4, 1.1.1.0/24, 13335)'   # ręczne sprawdzenie prefiksu i AS
```

Pierwsze pobranie danych po instalacji trwa 5–15 minut. Do tego czasu `router-rpki` pokazuje brak VRP, a nic nie jest
odrzucane. To pierwsze pobieranie nie wywołuje alarmu; alarm `%RPKI-3-DOWN` przy braku VRP pojawia się dopiero, gdy
walidator miał już dane i je stracił.

Walidacja co 10 minut obciąża rdzenie systemowe przez kilkanaście sekund. Routinator ma więc najwyżej 2 wątki
walidacji i niski priorytet, żeby BIRD i snmpd zawsze miały wolny procesor.
