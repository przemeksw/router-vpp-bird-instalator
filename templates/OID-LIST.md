# Obiekty SNMP routera (router-snmp)

Generowany: `tools/build-templates.py`. Wartości skalarne mają sufiks `.0`, kolumny tablic — indeks wiersza.
Typy: int = Integer32, gauge = Gauge32, counter = Counter32, counter64 = Counter64 (rośnie, NMS liczy na sekundę).

| OID | Nazwa | Typ | Jedn. | Opis |
|---|---|---|---|---|
| `1.3.6.1.4.1.8072.9999.9999.630.1.1.0` | rvDataAge | gauge | s | Wiek danych w sekundach (router-snmp collect odswieza co 30 s) |
| `1.3.6.1.4.1.8072.9999.9999.630.1.2.0` | rvVersion | string |  | Wersja programow routera (install-router.sh) |
| `1.3.6.1.4.1.8072.9999.9999.630.1.3.0` | rvAlarmsHour | gauge |  | Alarmy poziomu 1-4 w alarmy.log w ostatniej godzinie |
| `1.3.6.1.4.1.8072.9999.9999.630.1.4.0` | rvAlarmsCritHour | gauge |  | Alarmy poziomu 1-2 (krytyczne) w ostatniej godzinie |
| `1.3.6.1.4.1.8072.9999.9999.630.1.5.0` | rvLastAlarm | string |  | Ostatni alarm poziomu 1-4 z alarmy.log |
| `1.3.6.1.4.1.8072.9999.9999.630.1.6.0` | rvServicesDown | gauge |  | Liczba uslug routera, ktore nie dzialaja |
| `1.3.6.1.4.1.8072.9999.9999.630.2.1.0` | rvVppUp | int |  | 1 = VPP odpowiada, 0 = nie |
| `1.3.6.1.4.1.8072.9999.9999.630.2.2.0` | rvVppVectorMax | gauge |  | Najwiekszy sredni wektor workera (1 = luz, 256 = nasycenie) |
| `1.3.6.1.4.1.8072.9999.9999.630.2.3.0` | rvVppWorkers | gauge |  | Liczba workerow VPP |
| `1.3.6.1.4.1.8072.9999.9999.630.2.4.0` | rvVppPuntPps | gauge | pps | Ruch do control plane (punt), pakiety/s |
| `1.3.6.1.4.1.8072.9999.9999.630.2.5.0` | rvVppRxMissPps | gauge | pps | Pakiety gubione na wejsciu (rx-miss + rx-no-buf), pakiety/s |
| `1.3.6.1.4.1.8072.9999.9999.630.2.6.0` | rvVppNicDiscardPps | gauge | pps | Pakiety odrzucane sprzetowo przez karte, pakiety/s |
| `1.3.6.1.4.1.8072.9999.9999.630.2.7.0` | rvVppHkCpuMax | gauge | % | Najbardziej zajety rdzen systemowy (BIRD, SNMP, system), % |
| `1.3.6.1.4.1.8072.9999.9999.630.2.8.0` | rvVppBufAvail | gauge |  | Bufory VPP wolne |
| `1.3.6.1.4.1.8072.9999.9999.630.2.9.0` | rvVppBufUsed | gauge |  | Bufory VPP zajete |
| `1.3.6.1.4.1.8072.9999.9999.630.2.10.0` | rvVppBufCached | gauge |  | Bufory VPP w pamieci podrecznej watkow |
| `1.3.6.1.4.1.8072.9999.9999.630.2.11.0` | rvVppBufFreePct | gauge | % | Bufory VPP wolne + podreczne, % puli |
| `1.3.6.1.4.1.8072.9999.9999.630.2.12.0` | rvVppDrops | counter64 |  | Suma licznikow drops interfejsow VPP |
| `1.3.6.1.4.1.8072.9999.9999.630.2.13.0` | rvVppRxMiss | counter64 |  | Suma rx-miss i rx-no-buf portow |
| `1.3.6.1.4.1.8072.9999.9999.630.2.14.0` | rvVppPunt | counter64 |  | Suma pakietow punt |
| `1.3.6.1.4.1.8072.9999.9999.630.2.15.0` | rvVppErrors | counter64 |  | Suma licznikow show errors o poziomie error |
| `1.3.6.1.4.1.8072.9999.9999.630.2.16.0` | rvFib4Routes | gauge |  | Trasy IPv4 w FIB VPP (VRF 0) |
| `1.3.6.1.4.1.8072.9999.9999.630.2.17.0` | rvFib6Routes | gauge |  | Trasy IPv6 w FIB VPP (VRF 0) |
| `1.3.6.1.4.1.8072.9999.9999.630.2.18.0` | rvBird4Routes | gauge |  | Sieci IPv4 w tablicy master4 BIRD |
| `1.3.6.1.4.1.8072.9999.9999.630.2.19.0` | rvBird6Routes | gauge |  | Sieci IPv6 w tablicy master6 BIRD |
| `1.3.6.1.4.1.8072.9999.9999.630.2.20.0` | rvFibDiffPct | gauge | % | Najwieksza roznica FIB VPP wzgledem BIRD (IPv4/IPv6), % |
| `1.3.6.1.4.1.8072.9999.9999.630.2.21.0` | rvIfacesDrift | int |  | 1 = interfejsy VPP roznia sie od ifaces.conf |
| `1.3.6.1.4.1.8072.9999.9999.630.3.1.1` | rvWorkerIndex | int |  | Numer workera |
| `1.3.6.1.4.1.8072.9999.9999.630.3.1.2` | rvWorkerName | string |  | Worker i rdzen CPU |
| `1.3.6.1.4.1.8072.9999.9999.630.3.1.3` | rvWorkerVector | gauge |  | Sredni rozmiar wektora (1 = luz, 256 = nasycenie) |
| `1.3.6.1.4.1.8072.9999.9999.630.4.1.1` | rvPortIndex | int |  | Indeks |
| `1.3.6.1.4.1.8072.9999.9999.630.4.1.2` | rvPortName | string |  | Nazwa portu w VPP |
| `1.3.6.1.4.1.8072.9999.9999.630.4.1.3` | rvPortRxMiss | counter64 |  | rx-miss: karta zgubila pakiety, bo VPP nie nadazal |
| `1.3.6.1.4.1.8072.9999.9999.630.4.1.4` | rvPortRxNoBuf | counter64 |  | rx-no-buf: brak buforow VPP |
| `1.3.6.1.4.1.8072.9999.9999.630.4.1.5` | rvPortRxErrors | counter64 |  | rx-error |
| `1.3.6.1.4.1.8072.9999.9999.630.4.1.6` | rvPortTxErrors | counter64 |  | tx-error |
| `1.3.6.1.4.1.8072.9999.9999.630.4.1.7` | rvPortDrops | counter64 |  | drops |
| `1.3.6.1.4.1.8072.9999.9999.630.4.1.8` | rvPortPunt | counter64 |  | punt (ruch do control plane) |
| `1.3.6.1.4.1.8072.9999.9999.630.4.1.9` | rvPortHwDiscards | counter64 |  | Odrzucenia sprzetowe karty (xstats discard, out_of_buffer) |
| `1.3.6.1.4.1.8072.9999.9999.630.5.1.1` | rvErrorIndex | int |  | Indeks |
| `1.3.6.1.4.1.8072.9999.9999.630.5.1.2` | rvErrorNode | string |  | Wezel grafu VPP |
| `1.3.6.1.4.1.8072.9999.9999.630.5.1.3` | rvErrorReason | string |  | Powod |
| `1.3.6.1.4.1.8072.9999.9999.630.5.1.4` | rvErrorSeverity | string |  | Poziom: error, warn, info |
| `1.3.6.1.4.1.8072.9999.9999.630.5.1.5` | rvErrorCount | counter64 |  | Licznik |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.1` | rvBgpPeerIndex | int |  | Indeks |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.2` | rvBgpPeerName | string |  | Nazwa protokolu w BIRD |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.3` | rvBgpPeerDescr | string |  | Opis sesji (description) |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.4` | rvBgpPeerNeighbor | string |  | Adres sasiada |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.5` | rvBgpPeerRemoteAs | gauge |  | AS sasiada |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.6` | rvBgpPeerState | int |  | 1 idle, 2 connect, 3 active, 4 opensent, 5 openconfirm, 6 established |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.7` | rvBgpPeerEnabled | int |  | 1 = sesja wlaczona, 0 = wylaczona (disable) |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.8` | rvBgpPeerUptime | gauge | s | Czas od zestawienia sesji, s (0 = nie zestawiona) |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.9` | rvBgpPeerImported | gauge |  | Prefiksy przyjete |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.10` | rvBgpPeerExported | gauge |  | Prefiksy wyslane |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.11` | rvBgpPeerFiltered | gauge |  | Prefiksy odrzucone przez filtr |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.12` | rvBgpPeerImportLimit | gauge |  | Limit prefiksow (0 = brak) |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.13` | rvBgpPeerLastError | string |  | Ostatni blad sesji |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.14` | rvBgpPeerAfi | string |  | Kanaly: ipv4, ipv6 |
| `1.3.6.1.4.1.8072.9999.9999.630.6.1.15` | rvBgpPeerFlaps | counter |  | Upadki zestawionej sesji od startu kolektora |
| `1.3.6.1.4.1.8072.9999.9999.630.7.1.1` | rvServiceIndex | int |  | Indeks |
| `1.3.6.1.4.1.8072.9999.9999.630.7.1.2` | rvServiceName | string |  | Jednostka systemd |
| `1.3.6.1.4.1.8072.9999.9999.630.7.1.3` | rvServiceUp | int |  | 1 = dziala, 0 = nie |
| `1.3.6.1.4.1.8072.9999.9999.630.7.1.4` | rvServiceState | string |  | Stan systemd (ActiveState/SubState) |
| `1.3.6.1.4.1.8072.9999.9999.630.8.1.0` | rvFwEnabled | int |  | 1 = firewall aktywny na stale (router-fw enable) |
| `1.3.6.1.4.1.8072.9999.9999.630.8.2.0` | rvFwDrift | int |  | 1 = ACL w VPP roznia sie od ostatnio zastosowanej konfiguracji |
| `1.3.6.1.4.1.8072.9999.9999.630.8.3.0` | rvFwAcls | gauge |  | Listy ACL routera wgrane do VPP |
| `1.3.6.1.4.1.8072.9999.9999.630.8.4.0` | rvFwRules | gauge |  | Reguly w firewall.conf (ostatnio zastosowanym) |
| `1.3.6.1.4.1.8072.9999.9999.630.8.5.0` | rvFwDenyPkts | counter64 |  | Pakiety odrzucone przez reguly deny (z blokadami) |
| `1.3.6.1.4.1.8072.9999.9999.630.8.6.0` | rvFwDenyBytes | counter64 | B | Bajty odrzucone przez reguly deny |
| `1.3.6.1.4.1.8072.9999.9999.630.8.7.0` | rvFwPermitPkts | counter64 |  | Pakiety przepuszczone przez reguly permit |
| `1.3.6.1.4.1.8072.9999.9999.630.8.8.0` | rvFwBlockPkts | counter64 |  | Pakiety odrzucone przez blokady dorazne |
| `1.3.6.1.4.1.8072.9999.9999.630.8.9.0` | rvFwBlocks | gauge |  | Aktywne blokady dorazne (router-fw block) |
| `1.3.6.1.4.1.8072.9999.9999.630.9.1.0` | rvGuardActive | int |  | 1 = ochrona wlaczona |
| `1.3.6.1.4.1.8072.9999.9999.630.9.2.0` | rvGuardMode | int |  | 0 = off, 1 = monitor, 2 = enforce |
| `1.3.6.1.4.1.8072.9999.9999.630.9.3.0` | rvGuardPrefixes | gauge |  | Chronione prefiksy |
| `1.3.6.1.4.1.8072.9999.9999.630.9.4.0` | rvGuardChecked | counter64 |  | Sprawdzone odpowiedzi |
| `1.3.6.1.4.1.8072.9999.9999.630.9.5.0` | rvGuardPassed | counter64 |  | Przepuszczone (jest wpis w tablicy) |
| `1.3.6.1.4.1.8072.9999.9999.630.9.6.0` | rvGuardViolations | counter64 |  | Naruszenia (brak wpisu, zly ISN) |
| `1.3.6.1.4.1.8072.9999.9999.630.9.7.0` | rvGuardDropped | counter64 |  | Odrzucone (enforce) |
| `1.3.6.1.4.1.8072.9999.9999.630.9.8.0` | rvGuardRecorded | counter64 |  | Zapisane wpisy (SYN, UDP) |
| `1.3.6.1.4.1.8072.9999.9999.630.9.9.0` | rvGuardInsertFailed | counter64 |  | Bledy zapisu do tablicy |
| `1.3.6.1.4.1.8072.9999.9999.630.9.10.0` | rvGuardRstSent | counter64 |  | Wyslane RST (reply-rst) |
| `1.3.6.1.4.1.8072.9999.9999.630.9.11.0` | rvGuardTable4Pct | gauge | % | Zapelnienie tablicy IPv4, % |
| `1.3.6.1.4.1.8072.9999.9999.630.9.12.0` | rvGuardTable6Pct | gauge | % | Zapelnienie tablicy IPv6, % |
| `1.3.6.1.4.1.8072.9999.9999.630.9.13.0` | rvGuardDrift | int |  | 1 = VPP rozni sie od stanu router-guard |
| `1.3.6.1.4.1.8072.9999.9999.630.10.1.1` | rvRpkiIndex | int |  | Indeks |
| `1.3.6.1.4.1.8072.9999.9999.630.10.1.2` | rvRpkiName | string |  | Nazwa protokolu RPKI w BIRD |
| `1.3.6.1.4.1.8072.9999.9999.630.10.1.3` | rvRpkiUp | int |  | 1 = polaczenie z walidatorem zestawione |
| `1.3.6.1.4.1.8072.9999.9999.630.10.1.4` | rvRpkiVrp4 | gauge |  | VRP IPv4 |
| `1.3.6.1.4.1.8072.9999.9999.630.10.1.5` | rvRpkiVrp6 | gauge |  | VRP IPv6 |
| `1.3.6.1.4.1.8072.9999.9999.630.11.1.1` | rvRaidIndex | int |  | Indeks |
| `1.3.6.1.4.1.8072.9999.9999.630.11.1.2` | rvRaidName | string |  | Macierz (md0) |
| `1.3.6.1.4.1.8072.9999.9999.630.11.1.3` | rvRaidDegraded | int |  | 1 = zdegradowana |
| `1.3.6.1.4.1.8072.9999.9999.630.11.1.4` | rvRaidState | string |  | Stan dyskow, np. UU |
| `1.3.6.1.4.1.8072.9999.9999.630.11.1.5` | rvRaidSyncPct | gauge | % | Postep odbudowy/synchronizacji (100 = brak) |
| `1.3.6.1.4.1.8072.9999.9999.630.11.1.6` | rvRaidLevel | string |  | Poziom RAID |
| `1.3.6.1.4.1.8072.9999.9999.630.12.1.1` | rvDiskIndex | int |  | Indeks |
| `1.3.6.1.4.1.8072.9999.9999.630.12.1.2` | rvDiskName | string |  | Urzadzenie |
| `1.3.6.1.4.1.8072.9999.9999.630.12.1.3` | rvDiskModel | string |  | Model i numer seryjny |
| `1.3.6.1.4.1.8072.9999.9999.630.12.1.4` | rvDiskHealthOk | int |  | 1 = SMART PASSED, 0 = FAILED |
| `1.3.6.1.4.1.8072.9999.9999.630.12.1.5` | rvDiskTemp | gauge | C | Temperatura, C |
| `1.3.6.1.4.1.8072.9999.9999.630.12.1.6` | rvDiskRealloc | gauge |  | Sektory realokowane |
| `1.3.6.1.4.1.8072.9999.9999.630.12.1.7` | rvDiskPending | gauge |  | Sektory oczekujace |
| `1.3.6.1.4.1.8072.9999.9999.630.12.1.8` | rvDiskPowerOnHours | gauge | h | Czas pracy, godziny |
| `1.3.6.1.4.1.8072.9999.9999.630.12.1.9` | rvDiskWearPct | gauge | % | Zuzycie SSD, % (0 = brak danych) |
| `1.3.6.1.4.1.8072.9999.9999.630.13.1.1` | rvTempIndex | int |  | Indeks |
| `1.3.6.1.4.1.8072.9999.9999.630.13.1.2` | rvTempName | string |  | Czujnik |
| `1.3.6.1.4.1.8072.9999.9999.630.13.1.3` | rvTempValue | gauge | C | Temperatura, C |
| `1.3.6.1.4.1.8072.9999.9999.630.13.1.4` | rvTempCrit | gauge | C | Prog krytyczny czujnika, C (0 = brak) |
| `1.3.6.1.4.1.8072.9999.9999.630.14.1.0` | rvRpkiEnforce | int |  | 1 = rpki_filter() odrzuca trasy INVALID, 0 = tylko podglad (domyslnie) |
| `1.3.6.1.4.1.8072.9999.9999.630.14.2.0` | rvRpkiInvalid | gauge |  | Trasy INVALID w tablicach BIRD (pomiar co 5 min) |
| `1.3.6.1.4.1.8072.9999.9999.630.14.3.0` | rvRpkiValidatorUp | int |  | 1 = Routinator dziala |
| `1.3.6.1.4.1.8072.9999.9999.630.14.4.0` | rvRpkiCheckAge | gauge | s | Wiek ostatniej kontroli router-rpki check, s |

## BGP4-MIB (`.1.3.6.1.2.1.15`, standard, sesje IPv4)

bgpVersion, bgpLocalAs, bgpIdentifier oraz bgpPeerTable (indeks = adres IPv4 sąsiada): stan, AdminStatus,
adresy, AS (4-bajtowe jako 23456), FsmEstablishedTransitions, FsmEstablishedTime. Liczniki komunikatów = 0
(BIRD ich nie podaje). Sesje IPv6 i prefiksy: rvBgpPeerTable.
