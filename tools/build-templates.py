#!/usr/bin/env python3
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
"""Generuje szablony monitoringu z jednego źródła: schematu OID programu router-snmp (install-router.sh).

  python3 tools/build-templates.py            zapisuje templates/ (MIB, Zabbix, LibreNMS, Cacti, lista OID)
  python3 tools/build-templates.py --check    tylko sprawdza, czy templates/ są aktualne (kod 1 = nie)

Szablony nie są edytowane ręcznie: zmiana obiektu SNMP = zmiana w router-snmp (SCALARS/TABLES) + ten skrypt.
"""
import hashlib
import importlib.machinery
import importlib.util
import os
import re
import subprocess
import sys
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
TOP = os.path.dirname(HERE)
OUT = os.path.join(TOP, "templates")
TEMPLATE = "Router VPP BIRD by SNMP"
GROUP = "Templates/Network devices"
GROUP_UUID = "36bff6c29af64692839d077febfc7079"     # ten sam co w szablonach dostarczanych z Zabbix
STAMP = "2026-10-13T00:00:00Z"


def load_schema():
    subprocess.run(["bash", os.path.join(TOP, "tools", "extract.sh")], check=True, stdout=subprocess.DEVNULL)
    src = os.path.join(TOP, "build", "router-snmp")
    loader = importlib.machinery.SourceFileLoader("router_snmp", src)
    spec = importlib.util.spec_from_loader("router_snmp", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


RS = load_schema()
BASE = RS.BASE
OBJ = {}          # nazwa → dict(oid kolumny/skalara bez .0, typ, jednostka, opis, tabela)
for g, gname, _d, objs in RS.SCALARS:
    for n, name, typ, unit, desc in objs:
        OBJ[name] = {"oid": "%s.%d.%d" % (BASE, g, n), "typ": typ, "unit": unit, "desc": desc, "table": None}
for t, tname, _e, _d, cols in RS.TABLES:
    for n, name, typ, unit, desc in cols:
        OBJ[name] = {"oid": "%s.%d.1.%d" % (BASE, t, n), "typ": typ, "unit": unit, "desc": desc, "table": tname}

# --------------------------------------------------------------------------- nazwy wyświetlane (po polsku)
TITLE = {
    "rvDataAge": "Router: wiek danych SNMP", "rvVersion": "Router: wersja programów",
    "rvAlarmsHour": "Router: alarmy (1-4) w ostatniej godzinie",
    "rvAlarmsCritHour": "Router: alarmy krytyczne (1-2) w ostatniej godzinie",
    "rvLastAlarm": "Router: ostatni alarm", "rvServicesDown": "Router: niedziałające usługi",
    "rvVppUp": "VPP: działa", "rvVppVectorMax": "VPP: największy wektor workera", "rvVppWorkers": "VPP: liczba workerów",
    "rvVppPuntPps": "VPP: ruch do control plane (punt)", "rvVppRxMissPps": "VPP: straty na wejściu (rx-miss)",
    "rvVppNicDiscardPps": "VPP: odrzucenia sprzętowe karty", "rvVppHkCpuMax": "System: najbardziej zajęty rdzeń systemowy",
    "rvVppBufAvail": "VPP: bufory wolne",
    "rvVppBufUsed": "VPP: bufory zajęte", "rvVppBufCached": "VPP: bufory w pamięci wątków",
    "rvVppBufFreePct": "VPP: bufory wolne, %", "rvVppDrops": "VPP: drops (wszystkie interfejsy)",
    "rvVppRxMiss": "VPP: rx-miss + rx-no-buf (porty)", "rvVppPunt": "VPP: punt (wszystkie interfejsy)",
    "rvVppErrors": "VPP: liczniki błędów (show errors, poziom error)",
    "rvFib4Routes": "FIB VPP: trasy IPv4", "rvFib6Routes": "FIB VPP: trasy IPv6",
    "rvBird4Routes": "BIRD: sieci IPv4 (master4)", "rvBird6Routes": "BIRD: sieci IPv6 (master6)",
    "rvFibDiffPct": "FIB VPP vs BIRD: różnica, %", "rvIfacesDrift": "Interfejsy: rozjazd z ifaces.conf",
    "rvFwEnabled": "Firewall: aktywny", "rvFwDrift": "Firewall: rozjazd ACL w VPP", "rvFwAcls": "Firewall: listy ACL w VPP",
    "rvFwRules": "Firewall: reguły",
    "rvFwDenyPkts": "Firewall: odrzucone pakiety", "rvFwDenyBytes": "Firewall: odrzucone bajty",
    "rvFwPermitPkts": "Firewall: przepuszczone pakiety (permit)", "rvFwBlockPkts": "Firewall: pakiety z blokad doraźnych",
    "rvFwBlocks": "Firewall: aktywne blokady doraźne",
    "rvGuardActive": "Guard: ochrona włączona", "rvGuardMode": "Guard: tryb", "rvGuardPrefixes": "Guard: chronione prefiksy",
    "rvGuardChecked": "Guard: sprawdzone odpowiedzi", "rvGuardPassed": "Guard: przepuszczone",
    "rvGuardViolations": "Guard: naruszenia",
    "rvGuardDropped": "Guard: odrzucone", "rvGuardRecorded": "Guard: zapisane wpisy",
    "rvGuardInsertFailed": "Guard: błędy zapisu do tablicy", "rvGuardRstSent": "Guard: wysłane RST",
    "rvGuardTable4Pct": "Guard: zapełnienie tablicy IPv4", "rvGuardTable6Pct": "Guard: zapełnienie tablicy IPv6",
    "rvGuardDrift": "Guard: rozjazd VPP ze stanem",
    "rvRpkiEnforce": "RPKI: odrzucanie INVALID", "rvRpkiInvalid": "RPKI: trasy INVALID w BIRD",
    "rvRpkiValidatorUp": "RPKI: Routinator działa", "rvRpkiCheckAge": "RPKI: wiek kontroli router-rpki",
    "rvWorkerVector": "wektor", "rvPortRxMiss": "rx-miss", "rvPortRxNoBuf": "rx-no-buf", "rvPortRxErrors": "rx-error",
    "rvPortTxErrors": "tx-error", "rvPortDrops": "drops", "rvPortPunt": "punt", "rvPortHwDiscards": "odrzucenia sprzętowe",
    "rvErrorCount": "licznik",
    "rvBgpPeerState": "stan", "rvBgpPeerEnabled": "włączona", "rvBgpPeerUptime": "czas zestawienia",
    "rvBgpPeerImported": "prefiksy przyjęte",
    "rvBgpPeerExported": "prefiksy wysłane", "rvBgpPeerFiltered": "prefiksy odfiltrowane",
    "rvBgpPeerImportLimit": "limit prefiksów", "rvBgpPeerLastError": "ostatni błąd", "rvBgpPeerFlaps": "upadki sesji",
    "rvBgpPeerRemoteAs": "AS sąsiada", "rvServiceUp": "działa", "rvServiceState": "stan systemd",
    "rvRpkiUp": "połączenie", "rvRpkiVrp4": "VRP IPv4", "rvRpkiVrp6": "VRP IPv6",
    "rvRaidDegraded": "zdegradowana", "rvRaidSyncPct": "synchronizacja", "rvRaidState": "dyski",
    "rvDiskHealthOk": "SMART", "rvDiskTemp": "temperatura", "rvDiskRealloc": "sektory realokowane",
    "rvDiskPending": "sektory oczekujące", "rvDiskPowerOnHours": "czas pracy", "rvDiskWearPct": "zużycie SSD",
    "rvTempValue": "temperatura", "rvTempCrit": "próg krytyczny",
}

# mapy wartości: nazwa → [(wartość, opis, stan LibreNMS 0 ok / 1 ostrzeżenie / 2 błąd / 3 nieznany)]
MAPS = {
    "Router VPP: działa": [(0, "nie działa", 2), (1, "działa", 0)],
    "Router VPP: rozjazd": [(0, "zgodne", 0), (1, "rozjazd", 1)],
    "Router VPP: włączone": [(0, "wyłączone", 3), (1, "włączone", 0)],
    "Router VPP: sesja BGP": [(1, "idle", 2), (2, "connect", 1), (3, "active", 2), (4, "opensent", 1),
                              (5, "openconfirm", 1), (6, "established", 0)],
    "Router VPP: tryb guard": [(0, "off", 3), (1, "monitor", 1), (2, "enforce", 0)],
    "Router VPP: RAID": [(0, "sprawna", 0), (1, "zdegradowana", 2)],
    "Router VPP: SMART": [(0, "FAILED", 2), (1, "PASSED", 0)],
    "Router VPP: tryb RPKI": [(0, "tylko podgląd", 0), (1, "odrzucanie", 0)],
}
VALUEMAP = {"rvVppUp": "Router VPP: działa", "rvIfacesDrift": "Router VPP: rozjazd", "rvFwDrift": "Router VPP: rozjazd",
            "rvGuardDrift": "Router VPP: rozjazd", "rvFwEnabled": "Router VPP: włączone",
            "rvGuardActive": "Router VPP: włączone", "rvGuardMode": "Router VPP: tryb guard",
            "rvBgpPeerState": "Router VPP: sesja BGP", "rvBgpPeerEnabled": "Router VPP: włączone",
            "rvServiceUp": "Router VPP: działa", "rvRpkiUp": "Router VPP: działa", "rvRaidDegraded": "Router VPP: RAID",
            "rvDiskHealthOk": "Router VPP: SMART", "rvRpkiEnforce": "Router VPP: tryb RPKI",
            "rvRpkiValidatorUp": "Router VPP: działa"}
RATE_UNIT = {"rvFwDenyBytes": "Bps"}         # licznik → wartość na sekundę; reszta liczników: pakiety/s
UNIT_MAP = {"s": "s", "%": "%", "C": "°C", "h": "h", "pps": "pps", "B": "B"}

# progi (makra Zabbix, limity LibreNMS)
MACROS = [
    ("{$RV.DATA.AGE.MAX}", "300", "Po ilu sekundach dane router-snmp uznać za nieaktualne"),
    ("{$RV.VECTOR.WARN}", "64", "Wektor workera VPP: ostrzeżenie"),
    ("{$RV.VECTOR.CRIT}", "160", "Wektor workera VPP: przeciążenie"),
    ("{$RV.RXMISS.MAX}", "1", "Straty rx-miss (pakiety/s) przez 5 minut"),
    ("{$RV.DISCARD.MAX}", "1", "Odrzucenia sprzętowe karty (pakiety/s) przez 5 minut"),
    ("{$RV.PUNT.MAX}", "20000", "Ruch do control plane (pakiety/s) przez 5 minut"),
    ("{$RV.HKCPU.MAX}", "90", "Zajętość rdzenia systemowego (%) przez 5 minut"),
    ("{$RV.BUF.FREE.MIN}", "20", "Najmniej wolnych buforów VPP (%)"),
    ("{$RV.FIB.DIFF.MAX}", "2", "Największa różnica FIB VPP i BIRD (%) przez 15 minut"),
    ("{$RV.GUARD.TABLE.MAX}", "90", "Zapełnienie tablicy guard (%)"),
    ("{$RV.BGP.FLAPS.MAX}", "3", "Upadki sesji BGP w ciągu godziny"),
    ("{$RV.BGP.LIMIT.PCT}", "90", "Prefiksy przyjęte jako % limitu sesji"),
    ("{$RV.DISK.TEMP.MAX}", "60", "Temperatura dysku (°C)"),
    ("{$RV.DISK.WEAR.MAX}", "80", "Zużycie SSD (%)"),
    ("{$RV.CPU.TEMP.MAX}", "85", "Temperatura procesora (°C)"),
]


def check_names():
    used = set(TITLE) | set(VALUEMAP) | set(RATE_UNIT)
    for lst in (SCALAR_TRIGGERS, ):
        for _e, _p, _n, names in lst:
            used |= set(names)
    for rule in DISCOVERY:
        used |= set(rule["macros"].values()) | set(rule["items"])
        for _e, _p, _n, names in rule.get("triggers", []):
            used |= set(names)
    missing = sorted(n for n in used if n not in OBJ)
    if missing:
        sys.exit("nieznane obiekty w szablonach: %s" % ", ".join(missing))


# --------------------------------------------------------------------------- Zabbix
# wyzwalacze dla skalarów: (wyrażenie z {nazwa} → /szablon/klucz, priorytet, nazwa, [obiekty])
SCALAR_TRIGGERS = [
    ("last({rvDataAge})>{$RV.DATA.AGE.MAX}", "WARNING", "Router: brak świeżych danych router-snmp (usługa router-snmp)",
     ["rvDataAge"]),
    ("last({rvVppUp})=0", "DISASTER", "VPP nie odpowiada", ["rvVppUp"]),
    ("min({rvVppVectorMax},5m)>={$RV.VECTOR.CRIT}", "HIGH", "VPP: worker przeciążony (wektor {ITEM.LASTVALUE1})",
     ["rvVppVectorMax"]),
    ("min({rvVppVectorMax},5m)>={$RV.VECTOR.WARN} and max({rvVppVectorMax},5m)<{$RV.VECTOR.CRIT}", "WARNING",
     "VPP: wysokie obciążenie workera (wektor {ITEM.LASTVALUE1})",
     ["rvVppVectorMax"]),
    ("min({rvVppRxMissPps},5m)>{$RV.RXMISS.MAX}", "HIGH", "VPP: karta gubi pakiety na wejściu (rx-miss {ITEM.LASTVALUE1})",
     ["rvVppRxMissPps"]),
    ("min({rvVppNicDiscardPps},5m)>{$RV.DISCARD.MAX}", "AVERAGE", "VPP: karta odrzuca pakiety sprzętowo ({ITEM.LASTVALUE1})",
     ["rvVppNicDiscardPps"]),
    ("min({rvVppPuntPps},5m)>{$RV.PUNT.MAX}", "WARNING", "VPP: duży ruch do control plane ({ITEM.LASTVALUE1})",
     ["rvVppPuntPps"]),
    ("min({rvVppHkCpuMax},5m)>{$RV.HKCPU.MAX}", "WARNING", "System: przeciążony rdzeń systemowy (BIRD/SNMP)",
     ["rvVppHkCpuMax"]),
    ("last({rvVppBufFreePct})<{$RV.BUF.FREE.MIN}", "HIGH", "VPP: kończą się bufory ({ITEM.LASTVALUE1} wolnych)",
     ["rvVppBufFreePct"]),
    ("min({rvFibDiffPct},15m)>{$RV.FIB.DIFF.MAX}", "AVERAGE", "FIB VPP różni się od tablicy BIRD ({ITEM.LASTVALUE1})",
     ["rvFibDiffPct"]),
    ("last({rvIfacesDrift})=1", "WARNING", "Interfejsy VPP różnią się od ifaces.conf (router-ifaces check)",
     ["rvIfacesDrift"]),
    ("last({rvFwDrift})=1", "HIGH", "Firewall: ACL w VPP różnią się od konfiguracji (router-fw check)", ["rvFwDrift"]),
    ("last({rvGuardDrift})=1", "WARNING", "Guard: VPP różni się od stanu router-guard", ["rvGuardDrift"]),
    ("last({rvGuardTable4Pct})>{$RV.GUARD.TABLE.MAX} or last({rvGuardTable6Pct})>{$RV.GUARD.TABLE.MAX}", "WARNING",
     "Guard: tablica prawie pełna", ["rvGuardTable4Pct", "rvGuardTable6Pct"]),
    ("last({rvRpkiValidatorUp})=0", "HIGH",
     "RPKI: Routinator nie działa (po 1 h bez danych BIRD przestaje odrzucać INVALID)", ["rvRpkiValidatorUp"]),
    ("last({rvRpkiCheckAge})>900", "WARNING", "RPKI: kontrola router-rpki nie działa (timer router-rpki-check)",
     ["rvRpkiCheckAge"]),
    ("last({rvAlarmsCritHour})>0", "AVERAGE", "Router: alarm krytyczny w alarmy.log w ostatniej godzinie",
     ["rvAlarmsCritHour"]),
]

# reguły odkrywania: tabela, makra LLD (makro → kolumna), pozycje (kolumny), wyzwalacze, wykres
DISCOVERY = [
    {"key": "rv.worker.discovery", "name": "Workery VPP", "table": "rvWorkerTable",
     "macros": {"{#RV.NAME}": "rvWorkerName"}, "label": "Worker {#RV.NAME}", "items": ["rvWorkerVector"],
     "graph": ("Workery VPP: wektor {#RV.NAME}", ["rvWorkerVector"])},
    {"key": "rv.port.discovery", "name": "Porty VPP", "table": "rvPortTable",
     "macros": {"{#RV.NAME}": "rvPortName"}, "label": "Port {#RV.NAME}",
     "items": ["rvPortRxMiss", "rvPortRxNoBuf", "rvPortRxErrors", "rvPortTxErrors", "rvPortDrops", "rvPortPunt",
               "rvPortHwDiscards"],
     "triggers": [("min({rvPortRxMiss},5m)>{$RV.RXMISS.MAX}", "HIGH", "Port {#RV.NAME}: karta gubi pakiety (rx-miss)",
                   ["rvPortRxMiss"])],
     "graph": ("Port {#RV.NAME}: straty i błędy", ["rvPortRxMiss", "rvPortRxNoBuf", "rvPortDrops", "rvPortHwDiscards"])},
    {"key": "rv.error.discovery", "name": "Liczniki błędów VPP", "table": "rvErrorTable", "delay": "10m",
     "macros": {"{#RV.NODE}": "rvErrorNode", "{#RV.REASON}": "rvErrorReason", "{#RV.SEV}": "rvErrorSeverity"},
     "label": "VPP {#RV.NODE}: {#RV.REASON} ({#RV.SEV})", "items": ["rvErrorCount"]},
    {"key": "rv.bgp.discovery", "name": "Sesje BGP", "table": "rvBgpPeerTable",
     "macros": {"{#RV.NAME}": "rvBgpPeerName", "{#RV.DESCR}": "rvBgpPeerDescr", "{#RV.NEIGHBOR}": "rvBgpPeerNeighbor"},
     "label": "BGP {#RV.NAME} ({#RV.NEIGHBOR})",
     "items": ["rvBgpPeerState", "rvBgpPeerEnabled", "rvBgpPeerUptime", "rvBgpPeerImported", "rvBgpPeerExported",
               "rvBgpPeerFiltered", "rvBgpPeerImportLimit", "rvBgpPeerLastError", "rvBgpPeerFlaps", "rvBgpPeerRemoteAs"],
     "triggers": [
         ("last({rvBgpPeerState})<>6 and last({rvBgpPeerEnabled})=1", "HIGH",
          "BGP {#RV.NAME} {#RV.DESCR} ({#RV.NEIGHBOR}): sesja nie jest zestawiona", ["rvBgpPeerState", "rvBgpPeerEnabled"]),
         ("(max({rvBgpPeerFlaps},1h)-min({rvBgpPeerFlaps},1h))>{$RV.BGP.FLAPS.MAX}", "WARNING",
          "BGP {#RV.NAME} ({#RV.NEIGHBOR}): sesja niestabilna (flapuje)", ["rvBgpPeerFlaps"]),
         ("last({rvBgpPeerImportLimit})>0 and "
          "last({rvBgpPeerImported})*100>last({rvBgpPeerImportLimit})*{$RV.BGP.LIMIT.PCT}",
          "WARNING", "BGP {#RV.NAME} ({#RV.NEIGHBOR}): prefiksy blisko limitu",
          ["rvBgpPeerImportLimit", "rvBgpPeerImported"]),
     ],
     "graph": ("BGP {#RV.NAME}: prefiksy", ["rvBgpPeerImported", "rvBgpPeerExported", "rvBgpPeerFiltered"])},
    {"key": "rv.service.discovery", "name": "Usługi routera", "table": "rvServiceTable",
     "macros": {"{#RV.NAME}": "rvServiceName"}, "label": "Usługa {#RV.NAME}", "items": ["rvServiceUp", "rvServiceState"],
     "triggers": [("last({rvServiceUp})=0", "HIGH", "Usługa {#RV.NAME} nie działa", ["rvServiceUp"])]},
    {"key": "rv.rpki.discovery", "name": "RPKI", "table": "rvRpkiTable",
     "macros": {"{#RV.NAME}": "rvRpkiName"}, "label": "RPKI {#RV.NAME}", "items": ["rvRpkiUp", "rvRpkiVrp4", "rvRpkiVrp6"],
     "triggers": [("last({rvRpkiUp})=0", "HIGH", "RPKI {#RV.NAME}: brak połączenia z walidatorem", ["rvRpkiUp"])],
     "graph": ("RPKI {#RV.NAME}: VRP", ["rvRpkiVrp4", "rvRpkiVrp6"])},
    {"key": "rv.raid.discovery", "name": "RAID mdadm", "table": "rvRaidTable",
     "macros": {"{#RV.NAME}": "rvRaidName", "{#RV.LEVEL}": "rvRaidLevel"}, "label": "RAID {#RV.NAME} ({#RV.LEVEL})",
     "items": ["rvRaidDegraded", "rvRaidState", "rvRaidSyncPct"],
     "triggers": [("last({rvRaidDegraded})=1", "HIGH", "RAID {#RV.NAME}: macierz zdegradowana", ["rvRaidDegraded"])]},
    {"key": "rv.disk.discovery", "name": "Dyski (SMART)", "table": "rvDiskTable", "delay": "1h",
     "macros": {"{#RV.NAME}": "rvDiskName", "{#RV.MODEL}": "rvDiskModel"}, "label": "Dysk {#RV.NAME}",
     "items": ["rvDiskHealthOk", "rvDiskTemp", "rvDiskRealloc", "rvDiskPending", "rvDiskPowerOnHours", "rvDiskWearPct"],
     "triggers": [
         ("last({rvDiskHealthOk})=0", "HIGH", "Dysk {#RV.NAME} ({#RV.MODEL}): SMART FAILED", ["rvDiskHealthOk"]),
         ("min({rvDiskTemp},15m)>{$RV.DISK.TEMP.MAX}", "WARNING", "Dysk {#RV.NAME}: wysoka temperatura", ["rvDiskTemp"]),
         ("last({rvDiskPending})>0", "WARNING", "Dysk {#RV.NAME}: sektory oczekujące na realokację", ["rvDiskPending"]),
         ("change({rvDiskRealloc})>0", "WARNING", "Dysk {#RV.NAME}: przybyło sektorów realokowanych", ["rvDiskRealloc"]),
         ("last({rvDiskWearPct})>{$RV.DISK.WEAR.MAX}", "WARNING", "Dysk {#RV.NAME}: SSD zużyty", ["rvDiskWearPct"]),
     ]},
    {"key": "rv.temp.discovery", "name": "Temperatury procesorów", "table": "rvTempTable",
     "macros": {"{#RV.NAME}": "rvTempName"}, "label": "CPU {#RV.NAME}", "items": ["rvTempValue", "rvTempCrit"],
     "triggers": [("min({rvTempValue},5m)>{$RV.CPU.TEMP.MAX}", "WARNING", "CPU {#RV.NAME}: wysoka temperatura",
                   ["rvTempValue"])],
     "graph": ("CPU {#RV.NAME}: temperatura", ["rvTempValue"])},
]

SCALAR_GRAPHS = [
    ("VPP: straty i odrzucenia", ["rvVppRxMissPps", "rvVppNicDiscardPps", "rvVppDrops", "rvVppErrors"]),
    ("VPP: obciążenie", ["rvVppVectorMax", "rvVppHkCpuMax"]),
    ("VPP: ruch do control plane", ["rvVppPuntPps"]),
    ("VPP: bufory", ["rvVppBufAvail", "rvVppBufUsed", "rvVppBufCached"]),
    ("Trasy: FIB VPP i BIRD (IPv4)", ["rvFib4Routes", "rvBird4Routes"]),
    ("Trasy: FIB VPP i BIRD (IPv6)", ["rvFib6Routes", "rvBird6Routes"]),
    ("Firewall: odrzucone i przepuszczone", ["rvFwDenyPkts", "rvFwPermitPkts", "rvFwBlockPkts"]),
    ("Guard: liczniki", ["rvGuardChecked", "rvGuardViolations", "rvGuardDropped"]),
    ("RPKI: trasy INVALID", ["rvRpkiInvalid"]),
]
COLORS = ["1A7C11", "F63100", "2774A4", "A54F10", "FC6EA3", "6C59DC", "AC8C14", "611F27"]


def uuid(*parts):
    """Stały UUIDv4 (32 znaki hex) z nazwy — ten sam przy każdym generowaniu, Zabbix wymaga wersji 4."""
    h = list(hashlib.md5("|".join(parts).encode()).hexdigest())
    h[12] = "4"
    h[16] = "89ab"[int(h[16], 16) & 3]
    return "".join(h)


def ykey(name, table):
    return "%s[{#SNMPINDEX}]" % name if table else name


def zitem(name, proto=False):
    o = OBJ[name]
    key = ykey(name, proto)
    oid = o["oid"] + (".{#SNMPINDEX}" if proto else ".0")
    title = TITLE.get(name, o["desc"])
    it = {"uuid": uuid("item", key), "name": title, "type": "SNMP_AGENT", "snmp_oid": oid, "key": key,
          "history": "7d"}
    if name in ("rvDiskHealthOk", "rvDiskTemp", "rvDiskRealloc", "rvDiskPending", "rvDiskPowerOnHours", "rvDiskWearPct"):
        it["delay"] = "10m"
    if o["typ"] == "string":
        it.update(trends="0", value_type="CHAR")
    elif o["typ"] in ("counter64", "counter") and name != "rvBgpPeerFlaps":
        it.update(value_type="FLOAT", units=RATE_UNIT.get(name, "pps"),
                  preprocessing=[{"type": "CHANGE_PER_SECOND", "parameters": [""]}])
        it["name"] = title + " /s"
    else:
        if UNIT_MAP.get(o["unit"]):
            it["units"] = UNIT_MAP[o["unit"]]
        if name == "rvBgpPeerUptime":
            it["units"] = "uptime"
    it["description"] = o["desc"] + " (" + o["oid"] + ")"
    if name in VALUEMAP:
        it["valuemap"] = {"name": VALUEMAP[name]}
    comp = {"rvVpp": "vpp", "rvFib": "routing", "rvBird": "routing", "rvFw": "firewall", "rvGuard": "guard",
            "rvBgp": "bgp", "rvWorker": "vpp", "rvPort": "vpp", "rvError": "vpp", "rvService": "services",
            "rvRpki": "rpki", "rvRaid": "storage", "rvDisk": "storage", "rvTemp": "temperature"}
    tag = "rpki" if name.startswith("rvRpki") else next((v for k, v in comp.items() if name.startswith(k)), "system")
    it["tags"] = [{"tag": "component", "value": tag}]
    return it


def zexpr(expr, names, proto):
    out = expr
    for n in names:
        out = out.replace("{%s}" % n, "/%s/%s" % (TEMPLATE, ykey(n, proto)))
    return out


def zabbix():
    items = [zitem(name) for _g, _gn, _d, objs in RS.SCALARS for _n, name, *_r in objs]
    triggers = [{"uuid": uuid("trigger", e), "expression": zexpr(e, names, False), "name": n, "priority": p}
                for e, p, n, names in SCALAR_TRIGGERS]
    graphs = []
    for gname, names in SCALAR_GRAPHS:
        graphs.append({"uuid": uuid("graph", gname), "name": gname,
                       "graph_items": [{"sortorder": str(i), "color": COLORS[i % len(COLORS)],
                                        "item": {"host": TEMPLATE, "key": n}} for i, n in enumerate(names)]})
    rules = []
    for r in DISCOVERY:
        lld = ",".join("%s,%s" % (m, OBJ[c]["oid"]) for m, c in r["macros"].items())
        protos = []
        for n in r["items"]:
            it = zitem(n, True)
            it["name"] = "%s: %s" % (r["label"], it["name"])
            protos.append(it)
        rule = {"uuid": uuid("rule", r["key"]), "name": r["name"], "type": "SNMP_AGENT",
                "snmp_oid": "discovery[%s]" % lld, "key": r["key"], "delay": r.get("delay", "1h"),
                "lifetime": "7d", "item_prototypes": protos}
        if r.get("triggers"):
            rule["trigger_prototypes"] = [{"uuid": uuid("tproto", r["key"], e), "expression": zexpr(e, names, True),
                                           "name": n, "priority": p} for e, p, n, names in r["triggers"]]
        if r.get("graph"):
            gname, names = r["graph"]
            rule["graph_prototypes"] = [{"uuid": uuid("gproto", r["key"]), "name": gname, "graph_items": [
                {"sortorder": str(i), "color": COLORS[i % len(COLORS)],
                 "item": {"host": TEMPLATE, "key": ykey(n, True)}} for i, n in enumerate(names)]}]
        rules.append(rule)
    valuemaps = [{"uuid": uuid("valuemap", name), "name": name,
                  "mappings": [{"value": str(v), "newvalue": d} for v, d, _s in m]} for name, m in MAPS.items()]
    tpl = {"uuid": uuid("template", TEMPLATE), "template": TEMPLATE, "name": TEMPLATE,
           "description": "Router VPP + BIRD (install-router.sh): BGP, zdrowie VPP, FIB, firewall, guard, RPKI, usługi, "
                          "RAID, dyski. Dane: router-snmp (ROUTER-VPP-MIB .1.3.6.1.4.1.8072.9999.9999.630). Interfejsy i "
                          "system: dołącz też szablon Linux by SNMP. Generowany: tools/build-templates.py.",
           "groups": [{"name": GROUP}], "items": items, "discovery_rules": rules,
           "macros": [{"macro": m, "value": v, "description": d} for m, v, d in MACROS],
           "valuemaps": valuemaps}
    doc = {"zabbix_export": {"version": "6.0", "date": STAMP, "groups": [{"uuid": GROUP_UUID, "name": GROUP}],
                             "templates": [tpl], "triggers": triggers, "graphs": graphs}}
    return yaml_dump(doc)


def yscalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def yaml_dump(obj, ind=0):
    """Minimalny, deterministyczny YAML (słowniki, listy, napisy w apostrofach) — bez zależności od PyYAML."""
    pad = " " * ind
    lines = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, (dict, list)) and v:
                lines.append("%s%s:" % (pad, k))
                lines.append(yaml_dump(v, ind + 2))
            elif isinstance(v, list):
                lines.append("%s%s: []" % (pad, k))
            else:
                lines.append("%s%s: %s" % (pad, k, yscalar(v)))
    else:
        for v in obj:
            if isinstance(v, (dict, list)):
                lines.append("%s-" % pad)
                lines.append(yaml_dump(v, ind + 2))
            else:
                lines.append("%s- %s" % (pad, yscalar(v)))
    return "\n".join(lines)


# --------------------------------------------------------------------------- LibreNMS
LNMS_STATE = [("rvVppUp", "VPP", "VPP"), ("rvIfacesDrift", "Interfejsy: zgodność z ifaces.conf", "Router"),
              ("rvFwDrift", "Firewall: zgodność ACL", "Router"), ("rvGuardDrift", "Guard: zgodność", "Router"),
              ("rvGuardMode", "Guard: tryb", "Router"), ("rvRpkiValidatorUp", "RPKI: Routinator", "RPKI"),
              ("rvRpkiEnforce", "RPKI: odrzucanie INVALID", "RPKI")]
LNMS_STATE_TABLE = [("rvBgpPeerState", "BGP {{ $rvBgpPeerName }} {{ $rvBgpPeerNeighbor }} {{ $rvBgpPeerDescr }}", "BGP"),
                    ("rvServiceUp", "Usługa {{ $rvServiceName }}", "Usługi"),
                    ("rvRpkiUp", "RPKI {{ $rvRpkiName }}", "RPKI"),
                    ("rvRaidDegraded", "RAID {{ $rvRaidName }} {{ $rvRaidLevel }}", "RAID"),
                    ("rvDiskHealthOk", "SMART {{ $rvDiskName }} {{ $rvDiskModel }}", "Dyski")]
# (obiekt, opis, grupa, warn, high) — high = alarm LibreNMS (sensor powyżej limitu)
LNMS_COUNT = [("rvVppVectorMax", "VPP: największy wektor workera", "VPP", 64, 160),
              ("rvVppPuntPps", "VPP: punt pps", "VPP", None, 20000),
              ("rvVppRxMissPps", "VPP: rx-miss pps", "VPP", None, 1),
              ("rvVppNicDiscardPps", "VPP: odrzucenia sprzętowe pps", "VPP", None, 1),
              ("rvServicesDown", "Niedziałające usługi", "Router", None, 0),
              ("rvAlarmsCritHour", "Alarmy krytyczne w ostatniej godzinie", "Router", None, 0),
              ("rvFwBlocks", "Firewall: blokady doraźne", "Router", None, None),
              ("rvRpkiInvalid", "RPKI: trasy INVALID w BIRD", "RPKI", None, None),
              ("rvFib4Routes", "FIB VPP IPv4", "Trasy", None, None), ("rvFib6Routes", "FIB VPP IPv6", "Trasy", None, None),
              ("rvBird4Routes", "BIRD IPv4", "Trasy", None, None), ("rvBird6Routes", "BIRD IPv6", "Trasy", None, None)]
LNMS_COUNT_TABLE = [("rvBgpPeerImported", "Prefiksy od {{ $rvBgpPeerName }} {{ $rvBgpPeerNeighbor }}", "BGP"),
                    ("rvBgpPeerExported", "Prefiksy do {{ $rvBgpPeerName }} {{ $rvBgpPeerNeighbor }}", "BGP"),
                    ("rvRpkiVrp4", "RPKI {{ $rvRpkiName }} VRP IPv4", "RPKI"),
                    ("rvRpkiVrp6", "RPKI {{ $rvRpkiName }} VRP IPv6", "RPKI"),
                    ("rvWorkerVector", "Wektor {{ $rvWorkerName }}", "VPP"),
                    ("rvDiskPending", "{{ $rvDiskName }}: sektory oczekujące", "Dyski"),
                    ("rvDiskRealloc", "{{ $rvDiskName }}: sektory realokowane", "Dyski")]
LNMS_PERCENT = [("rvVppBufFreePct", "VPP: wolne bufory", "VPP", "low", 20),
                ("rvVppHkCpuMax", "Rdzeń systemowy: zajętość", "Router", "high", 90),
                ("rvFibDiffPct", "FIB VPP vs BIRD: różnica", "Trasy", "high", 2),
                ("rvGuardTable4Pct", "Guard: tablica IPv4", "Router", "high", 90),
                ("rvGuardTable6Pct", "Guard: tablica IPv6", "Router", "high", 90)]
LNMS_PERCENT_TABLE = [("rvDiskWearPct", "{{ $rvDiskName }}: zużycie SSD", "Dyski", "high", 80),
                      ("rvRaidSyncPct", "RAID {{ $rvRaidName }}: synchronizacja", "RAID", "low", 100)]
LNMS_TEMP_TABLE = [("rvDiskTemp", "Dysk {{ $rvDiskName }}", "Dyski", 60),
                   ("rvTempValue", "CPU {{ $rvTempName }}", "CPU", 85)]


def lnms_entry(name, descr, group):
    o = OBJ[name]
    e = {"oid": o["table"] or name, "value": name, "num_oid": "'.%s.{{ $index }}'" % o["oid"],
         "descr": descr, "index": "'%s.{{ $index }}'" % name, "group": group}
    return e


def lnms_yaml_entry(e, extra=()):
    lines = ["                -"]
    for k in ("oid", "value", "num_oid", "descr", "index", "group"):
        v = e[k]
        if k in ("descr", "group", "oid", "value"):
            v = "'%s'" % v.replace("'", "''")
        lines.append("                    %s: %s" % (k, v))
    lines += ["                    %s" % x for x in extra]
    return lines


STATE_FMT = "    - { value: %d, generic: %d, graph: 0, descr: '%s' }"


def librenms():
    det = """os: vpprouter
text: 'VPP BGP Router (install-router.sh)'
type: network
icon: linux
group: unix
mib_dir: vpprouter
over:
    - { graph: device_bits, text: 'Device Traffic' }
    - { graph: device_processor, text: 'CPU Usage' }
    - { graph: device_mempool, text: 'Memory Usage' }
discovery:
    -
        sysObjectID:
            - .1.3.6.1.4.1.8072.3.2.10
        snmpget:
            oid: .%s.1.1.0
            op: '!='
            value: false
""" % BASE
    out = ["# Generowany: tools/build-templates.py (instalator routera) — nie edytuj ręcznie",
           "mib: ROUTER-VPP-MIB", "modules:", "    sensors:"]
    out += ["        state:", "            data:"]
    for name, descr, group in LNMS_STATE:
        st = MAPS[VALUEMAP[name]]
        extra = ["state_name: %s" % name, "states:"] + [STATE_FMT % (v, g, d) for v, d, g in st]
        out += lnms_yaml_entry(lnms_entry(name, descr, group), extra)
    for name, descr, group in LNMS_STATE_TABLE:
        st = MAPS[VALUEMAP[name]]
        extra = ["state_name: %s" % name, "states:"] + [STATE_FMT % (v, g, d) for v, d, g in st]
        out += lnms_yaml_entry(lnms_entry(name, descr, group), extra)
    out += ["        count:", "            data:"]
    for name, descr, group, warn, high in LNMS_COUNT:
        extra = []
        if warn is not None:
            extra.append("warn_limit: %s" % warn)
        if high is not None:
            extra.append("high_limit: %s" % high)
        out += lnms_yaml_entry(lnms_entry(name, descr, group), extra)
    for name, descr, group in LNMS_COUNT_TABLE:
        out += lnms_yaml_entry(lnms_entry(name, descr, group))
    out += ["        percent:", "            data:"]
    for name, descr, group, side, lim in LNMS_PERCENT + LNMS_PERCENT_TABLE:
        out += lnms_yaml_entry(lnms_entry(name, descr, group), ["%s_limit: %s" % (side, lim)])
    out += ["        temperature:", "            data:"]
    for name, descr, group, high in LNMS_TEMP_TABLE:
        out += lnms_yaml_entry(lnms_entry(name, descr, group), ["high_limit: %s" % high])
    return det, "\n".join(out) + "\n"


# --------------------------------------------------------------------------- MIB
SMI = {"int": "Integer32", "gauge": "Gauge32", "counter": "Counter32", "counter64": "Counter64", "string": "DisplayString"}


def mib():
    o = ["ROUTER-VPP-MIB DEFINITIONS ::= BEGIN", "",
         "-- Generowany: tools/build-templates.py (instalator routera). Agent: /opt/router/bin/router-snmp (pass_persist).",
         "-- Galaz netSnmpPlaypen (NET-SNMP-MIB) jest przeznaczona na lokalne rozszerzenia.", "",
         "IMPORTS", "    MODULE-IDENTITY, OBJECT-TYPE, Integer32, Gauge32, Counter32, Counter64 FROM SNMPv2-SMI",
         "    DisplayString FROM SNMPv2-TC", "    netSnmpPlaypen FROM NET-SNMP-MIB;", "",
         "routerVppMIB MODULE-IDENTITY", '    LAST-UPDATED "202610130000Z"', '    ORGANIZATION "PHU VIPHOST"',
         '    CONTACT-INFO "PHU VIPHOST Przemyslaw Swiderski, biuro@viphost.it"',
         '    DESCRIPTION "Router VPP + BIRD (install-router.sh): BGP, zdrowie VPP, FIB, firewall, guard,',
         '        RPKI, uslugi, RAID, dyski, temperatury."',
         '    REVISION "202610130000Z"', '    DESCRIPTION "Pierwsza wersja."',
         "    ::= { netSnmpPlaypen 630 }", ""]

    def obj(name, syntax, access, desc, parent, num, unit=""):
        o.extend(["%s OBJECT-TYPE" % name, "    SYNTAX      %s" % syntax])
        if unit:
            o.append('    UNITS       "%s"' % unit)
        o.extend(["    MAX-ACCESS  %s" % access, "    STATUS      current", '    DESCRIPTION "%s"' % desc,
                  "    ::= { %s %d }" % (parent, num), ""])

    for g, gname, gdesc, objs in RS.SCALARS:
        o += ["%s OBJECT IDENTIFIER ::= { routerVppMIB %d }" % (gname, g), ""]
        for n, name, typ, unit, desc in objs:
            obj(name, SMI[typ], "read-only", desc, gname, n, unit)
    for t, tname, ename, tdesc, cols in RS.TABLES:
        etype = ename[0].upper() + ename[1:]
        o += ["%s OBJECT-TYPE" % tname, "    SYNTAX      SEQUENCE OF %s" % etype, "    MAX-ACCESS  not-accessible",
              "    STATUS      current", '    DESCRIPTION "%s"' % tdesc, "    ::= { routerVppMIB %d }" % t, "",
              "%s OBJECT-TYPE" % ename, "    SYNTAX      %s" % etype, "    MAX-ACCESS  not-accessible",
              "    STATUS      current", '    DESCRIPTION "Wiersz: %s"' % tdesc, "    INDEX       { %s }" % cols[0][1],
              "    ::= { %s 1 }" % tname, "", "%s ::= SEQUENCE {" % etype]
        o += ["    %-28s %s%s" % (c[1], SMI[c[2]], "," if i < len(cols) - 1 else "") for i, c in enumerate(cols)]
        o += ["}", ""]
        for i, (n, name, typ, unit, desc) in enumerate(cols):
            syntax = "Integer32 (1..2147483647)" if i == 0 else SMI[typ]
            obj(name, syntax, "read-only", desc, ename, n, unit)
    o += ["END", ""]
    return "\n".join(o)


# --------------------------------------------------------------------------- Cacti
CACTI = [("rvWorkerTable", "router_vpp_workers", "Router VPP - workery (wektor)"),
         ("rvPortTable", "router_vpp_ports", "Router VPP - porty: straty i bledy"),
         ("rvErrorTable", "router_vpp_errors", "Router VPP - liczniki show errors"),
         ("rvBgpPeerTable", "router_vpp_bgp_peers", "Router VPP - sesje BGP"),
         ("rvServiceTable", "router_vpp_services", "Router VPP - uslugi"),
         ("rvRpkiTable", "router_vpp_rpki", "Router VPP - RPKI"),
         ("rvRaidTable", "router_vpp_raid", "Router VPP - RAID mdadm"),
         ("rvDiskTable", "router_vpp_disks", "Router VPP - dyski SMART"),
         ("rvTempTable", "router_vpp_temps", "Router VPP - temperatury CPU")]


def cacti(tname, title):
    t = next(x for x in RS.TABLES if x[1] == tname)
    cols = t[4]
    idx = OBJ[cols[0][1]]["oid"]
    label = cols[1][1]
    o = ["<!-- Generowany: tools/build-templates.py (instalator routera). Kopiuj do <cacti>/resource/snmp_queries/ -->",
         "<interface>", "\t<name>%s</name>" % escape(title), "\t<description>%s</description>" % escape(t[3]),
         "\t<oid_index>.%s</oid_index>" % idx, "\t<index_order>%s:%s</index_order>" % (label, cols[0][1]),
         "\t<index_order_type>numeric</index_order_type>", "\t<index_title_format>|chosen_order_field|</index_title_format>",
         "\t<fields>"]
    for n, name, typ, _unit, desc in cols:
        direction = "input" if typ == "string" or n == 1 else "output"
        o += ["\t\t<%s>" % name, "\t\t\t<name>%s</name>" % escape(desc), "\t\t\t<method>walk</method>",
              "\t\t\t<source>value</source>", "\t\t\t<direction>%s</direction>" % direction,
              "\t\t\t<oid>.%s</oid>" % OBJ[name]["oid"], "\t\t</%s>" % name]
    o += ["\t</fields>", "</interface>", ""]
    return "\n".join(o)


# --------------------------------------------------------------------------- Cacti: pełny szablon (jeden plik XML)
# Format eksportu Cacti 1.2.20+ (hash_TTVVVV<md5>: TT = typ obiektu, VVVV = 0103). Własne obiekty mają stałe skróty
# liczone z nazw, więc ponowny import aktualizuje te same obiekty zamiast tworzyć kopie. Obiekty wbudowane w Cacti
# (metody wejścia SNMP, GPRINT „Normal”, CDEF bajty→bity) są tylko wskazywane skrótem — są w każdej instalacji.
CACTI_VER = "0103"
CT = {"graph_template": "00", "data_template": "01", "host_template": "02", "data_input": "03", "data_query": "04",
      "cdef": "05", "gprint": "06", "data_input_field": "07", "data_template_item": "08", "graph_template_input": "09",
      "graph_template_item": "10", "data_query_graph": "11", "data_query_sv_graph": "12", "data_query_sv_ds": "13"}
DIM_SNMP = "3eb92bb845b9660a7445cf9740726522"            # Get SNMP Data
DIM_SNMP_IDX = "bf566c869ac6443b0c75d1c32b5a350e"        # Get SNMP Data (Indexed)
DIF_SNMP = ["92f5906c8dc0f964b41f4253df582c38", "32285d5bf16e56c478f5e83f32cda9ef", "ad14ac90641aed388139f6ba86a2e48b",
            "9c55a74bd571b4f00a96fd4b793278c6", "012ccb1d3687d3edb29c002ea66e72da", "4276a5ec6e3fe33995129041b1909762",
            "fc64b99742ec417cc424dbf8c7692d36"]           # pola Get SNMP Data; 6. = OID
DIF_SNMP_OID = "4276a5ec6e3fe33995129041b1909762"
DIF_SNMP_IDX = ["92f5906c8dc0f964b41f4253df582c38", "32285d5bf16e56c478f5e83f32cda9ef", "617cdc8a230615e59f06f361ef6e7728",
                "acb449d1451e8a2a655c2c99d31142c7", "f4facc5e2ca7ebee621f09bc6d9fc792", "1cc1493a6781af2c478fa4de971531cf",
                "b5c23f246559df38662c255f4aa21d6b", "6027a919c7c7731fbe095b6f53ab127b", "cbbe5c1ddfb264a6e5d509ce1c78c95f",
                "e6deda7be0f391399c5130e7c4a48b28", "c1f36ee60c3dc98945556d57f26e475b", "2cf7129ad3ff819a7a7ac189bee48ce8",
                "6b13ac0a0194e171d241d4b06f913158", "3a33d4fc65b8329ab2ac46a36da26b72"]
DIF_SNMP_IDX_PER_DS = {"6027a919c7c7731fbe095b6f53ab127b", "cbbe5c1ddfb264a6e5d509ce1c78c95f",
                       "e6deda7be0f391399c5130e7c4a48b28"}   # index_type, index_value, output_type: ustala Cacti
GPRINT_NORMAL = "e9c43831e54eca8069317a2ce8c6f751"
CDEF_BITS = "73f95f8b77b5508157d64047342c421e"           # Turn Bytes into Bits
# Szablony wbudowane (pakiety Generic SNMP Device / Net-SNMP Device): podpinane do szablonu urządzenia, jeśli są w Cacti
STOCK_GRAPHS = ["ab37cbed8610deeffbb20dc1fe57b330",       # Device - Uptime
                "5107ec0206562e77d965ce6b852ef9d4",       # Net-SNMP - Load Average
                "be275639d5680e94c72c0ebb4e19056d",       # Net-SNMP - Memory Usage
                "eee71ec20dc7b44635ab185bbf924dc4"]       # Net-SNMP - CPU Utilization
STOCK_QUERIES = ["d75e406fdeca4fcef45b8be3a9a63cbc",      # SNMP - Interface Statistics (porty i VLAN-y VPP)
                 "9343eab1f4d88b0e61ffc9d020f35414"]      # SNMP - Get Mounted Partitions
CACTI_HOST_TEMPLATE = "Router VPP BIRD"
CACTI_FILE = "router_vpp_bird_cacti.xml"
CACTI_INSTALLER = "install-cacti-router-vpp.sh"

# typ RRD: liczniki jako DERIVE z minimum 0 — zerowanie licznika po restarcie VPP daje jedną pustą próbkę, nie skok
DS_GAUGE, DS_DERIVE = 1, 3
LINE, AREA, STACK = 4, 7, 8


def cs(*parts):
    return hashlib.md5(("router-vpp-cacti|" + "|".join(parts)).encode()).hexdigest()


def ch(kind, md5):
    return "hash_%s%s%s" % (CT[kind], CACTI_VER, md5)


def dsname(name):
    n = name[2:] if name.startswith("rv") else name
    return n[:19]


# Wykres: (klucz, tytuł, opis osi, [(obiekt, etykieta, rodzaj linii)], opcje)
# opcje: cdef = CDEF dla wszystkich linii, upper = górna granica osi (bez sztywnego limitu)
CG_SCALAR = [
    ("vector", "VPP - najwiekszy wektor workera", "wektor", [("rvVppVectorMax", "Wektor (1 luz, 256 nasycenie)", LINE)], {}),
    ("hkcpu", "System - najbardziej zajety rdzen", "%", [("rvVppHkCpuMax", "Rdzen systemowy", AREA)], {"upper": 100}),
    ("loss", "VPP - straty pakietow", "pakiety/s", [("rvVppRxMissPps", "rx-miss + rx-no-buf", LINE),
                                                     ("rvVppNicDiscardPps", "Odrzucenia karty", LINE),
                                                     ("rvVppDrops", "Drops interfejsow", LINE),
                                                     ("rvVppErrors", "show errors (error)", LINE)], {}),
    ("punt", "VPP - ruch do control plane (punt)", "pakiety/s", [("rvVppPuntPps", "Punt", AREA)], {}),
    ("buffers", "VPP - bufory", "bufory", [("rvVppBufUsed", "Zajete", AREA), ("rvVppBufCached", "W watkach", STACK),
                                          ("rvVppBufAvail", "Wolne", STACK)], {}),
    ("buffree", "VPP - wolne bufory", "%", [("rvVppBufFreePct", "Wolne + w watkach", LINE)], {"upper": 100}),
    ("routes4", "Trasy IPv4 - FIB VPP i BIRD", "trasy", [("rvFib4Routes", "FIB VPP", AREA),
                                                         ("rvBird4Routes", "BIRD master4", LINE)], {}),
    ("routes6", "Trasy IPv6 - FIB VPP i BIRD", "trasy", [("rvFib6Routes", "FIB VPP", AREA),
                                                         ("rvBird6Routes", "BIRD master6", LINE)], {}),
    ("fibdiff", "Trasy - roznica FIB VPP i BIRD", "%", [("rvFibDiffPct", "Roznica", LINE)], {}),
    ("fwpkts", "Firewall - pakiety", "pakiety/s", [("rvFwPermitPkts", "Przepuszczone (permit)", LINE),
                                                   ("rvFwDenyPkts", "Odrzucone (deny)", LINE),
                                                   ("rvFwBlockPkts", "Blokady dorazne", LINE)], {}),
    ("fwbits", "Firewall - odrzucony ruch", "bity/s", [("rvFwDenyBytes", "Odrzucone (deny)", AREA)], {"cdef": CDEF_BITS}),
    ("fwblocks", "Firewall - blokady dorazne", "blokady", [("rvFwBlocks", "Aktywne blokady", LINE)], {}),
    ("guard", "Guard - liczniki", "pakiety/s", [("rvGuardChecked", "Sprawdzone", LINE), ("rvGuardPassed", "Przepuszczone", LINE),
                                                ("rvGuardViolations", "Naruszenia", LINE), ("rvGuardDropped", "Odrzucone", LINE),
                                                ("rvGuardRstSent", "Wyslane RST", LINE)], {}),
    ("guardtab", "Guard - zapelnienie tablic", "%", [("rvGuardTable4Pct", "Tablica IPv4", LINE),
                                                     ("rvGuardTable6Pct", "Tablica IPv6", LINE)], {"upper": 100}),
    ("rpkiinv", "RPKI - trasy INVALID", "trasy", [("rvRpkiInvalid", "INVALID", AREA)], {}),
    ("alarms", "Router - alarmy i uslugi", "liczba", [("rvAlarmsHour", "Alarmy 1-4 (1 h)", LINE),
                                                      ("rvAlarmsCritHour", "Krytyczne 1-2 (1 h)", LINE),
                                                      ("rvServicesDown", "Niedzialajace uslugi", LINE)], {}),
    ("state", "Router - stan (1 = tak)", "stan", [("rvVppUp", "VPP dziala", LINE), ("rvRpkiValidatorUp", "Routinator dziala", LINE),
                                                  ("rvIfacesDrift", "Rozjazd interfejsow", LINE),
                                                  ("rvFwDrift", "Rozjazd firewalla", LINE), ("rvGuardDrift", "Rozjazd guarda", LINE)],
     {"upper": 1}),
    ("dataage", "Router - wiek danych SNMP", "s", [("rvDataAge", "Wiek danych", LINE)], {}),
]

# Wykresy z zapytań SNMP (tablice): (klucz, tablica, tytuł po nazwie hosta, opis osi, [(kolumna, etykieta, linia)], opcje)
CG_TABLE = [
    ("worker", "rvWorkerTable", "VPP |query_rvWorkerName| - wektor", "wektor", [("rvWorkerVector", "Wektor", LINE)], {}),
    ("port", "rvPortTable", "Port |query_rvPortName| - straty i bledy", "pakiety/s",
     [("rvPortRxMiss", "rx-miss", LINE), ("rvPortRxNoBuf", "rx-no-buf", LINE), ("rvPortHwDiscards", "Odrzucenia karty", LINE),
      ("rvPortRxErrors", "rx-error", LINE), ("rvPortTxErrors", "tx-error", LINE), ("rvPortDrops", "drops", LINE),
      ("rvPortPunt", "punt", LINE)], {}),
    ("error", "rvErrorTable", "show errors |query_rvErrorNode| - |query_rvErrorReason|", "zdarzenia/s",
     [("rvErrorCount", "Licznik", AREA)], {}),
    ("bgpprefix", "rvBgpPeerTable", "BGP |query_rvBgpPeerName| |query_rvBgpPeerNeighbor| - prefiksy", "prefiksy",
     [("rvBgpPeerImported", "Przyjete", AREA), ("rvBgpPeerExported", "Wyslane", LINE),
      ("rvBgpPeerFiltered", "Odrzucone przez filtr", LINE), ("rvBgpPeerImportLimit", "Limit (0 = brak)", LINE)], {}),
    ("bgpstate", "rvBgpPeerTable", "BGP |query_rvBgpPeerName| |query_rvBgpPeerNeighbor| - stan (6 = established)", "stan",
     [("rvBgpPeerState", "Stan", LINE)], {"upper": 6}),
    ("service", "rvServiceTable", "Usluga |query_rvServiceName| (1 = dziala)", "stan", [("rvServiceUp", "Dziala", AREA)],
     {"upper": 1}),
    ("rpki", "rvRpkiTable", "RPKI |query_rvRpkiName| - VRP", "VRP", [("rvRpkiVrp4", "VRP IPv4", LINE),
                                                                    ("rvRpkiVrp6", "VRP IPv6", LINE)], {}),
    ("raidsync", "rvRaidTable", "RAID |query_rvRaidName| - synchronizacja", "%", [("rvRaidSyncPct", "Zsynchronizowane", LINE)],
     {"upper": 100}),
    ("raiddeg", "rvRaidTable", "RAID |query_rvRaidName| - zdegradowana (1 = tak)", "stan",
     [("rvRaidDegraded", "Zdegradowana", AREA)], {"upper": 1}),
    ("disktemp", "rvDiskTable", "Dysk |query_rvDiskName| - temperatura", "C", [("rvDiskTemp", "Temperatura", LINE)], {}),
    ("disksect", "rvDiskTable", "Dysk |query_rvDiskName| - sektory", "sektory",
     [("rvDiskRealloc", "Realokowane", LINE), ("rvDiskPending", "Oczekujace", LINE)], {}),
    ("diskwear", "rvDiskTable", "Dysk |query_rvDiskName| - zuzycie SSD", "%", [("rvDiskWearPct", "Zuzycie", LINE)],
     {"upper": 100}),
    ("cputemp", "rvTempTable", "CPU |query_rvTempName| - temperatura", "C",
     [("rvTempValue", "Temperatura", LINE), ("rvTempCrit", "Prog krytyczny", LINE)], {}),
]
def plain(title):
    """Tytuł bez zmiennych |query_…| (nazwa szablonu), np. „BGP - prefiksy”."""
    t = re.sub(r"\s*\|query_\w+\|", "", title)
    t = re.sub(r"\s+-\s+-\s+|\s+-\s*$", " - ", t).strip(" -")
    return re.sub(r"\s+", " ", t)


def xel(tag, value, ind):
    return "%s<%s>%s</%s>" % ("\t" * ind, tag, escape(str(value)), tag)


def ds_type(name):
    return DS_DERIVE if OBJ[name]["typ"] in ("counter64", "counter") else DS_GAUGE


def cacti_data_template(key, title, items, indexed, oid=None):
    """Szablon danych: jedna pozycja (Get SNMP Data, OID skalara) albo kilka kolumn tablicy (Get SNMP Data (Indexed))."""
    h = cs("dt", key)
    o = ["\t<%s>" % ch("data_template", h), xel("name", "Router VPP - " + title, 2), "\t\t<ds>", xel("t_name", "", 3),
         xel("name", "|host_description| - " + title, 3), xel("data_source_path", "", 3),
         xel("data_input_id", ch("data_input", DIM_SNMP_IDX if indexed else DIM_SNMP), 3), xel("t_data_source_profile_id", "", 3),
         xel("data_source_profile_id", "0", 3), xel("t_rrd_step", "", 3), xel("rrd_step", "60", 3), xel("t_active", "", 3),
         xel("active", "on", 3), "\t\t</ds>", "\t\t<items>"]
    for name in items:
        o += ["\t\t\t<%s>" % ch("data_template_item", cs("dti", key, name)), xel("t_data_source_name", "", 4),
              xel("data_source_name", dsname(name), 4), xel("t_rrd_minimum", "", 4), xel("rrd_minimum", "0", 4),
              xel("t_rrd_maximum", "", 4), xel("rrd_maximum", "U", 4), xel("t_data_source_type_id", "", 4),
              xel("data_source_type_id", ds_type(name), 4), xel("t_rrd_heartbeat", "", 4), xel("rrd_heartbeat", "600", 4),
              xel("t_data_input_field_id", "", 4), xel("data_input_field_id", "0", 4),
              "\t\t\t</%s>" % ch("data_template_item", cs("dti", key, name))]
    o += ["\t\t</items>", "\t\t<data>"]
    for i, f in enumerate(DIF_SNMP_IDX if indexed else DIF_SNMP):
        per_ds = indexed and f in DIF_SNMP_IDX_PER_DS
        val = "." + oid + ".0" if (not indexed and f == DIF_SNMP_OID) else ""
        o += ["\t\t\t<item_%03d>" % i, xel("data_input_field_id", ch("data_input_field", f), 4),
              xel("t_value", "on" if per_ds else "", 4), xel("value", val, 4), "\t\t\t</item_%03d>" % i]
    o += ["\t\t</data>", "\t</%s>" % ch("data_template", h), ""]
    return o


GRAPH_FIELDS = [("image_format_id", "3"), ("height", "200"), ("width", "700"), ("base_value", "1000"), ("slope_mode", "on"),
                ("auto_scale", "on"), ("auto_scale_opts", "2"), ("auto_scale_log", ""), ("scale_log_units", ""),
                ("auto_scale_rigid", ""), ("upper_limit", "100"), ("lower_limit", "0"), ("unit_value", ""),
                ("unit_exponent_value", ""), ("unit_length", ""), ("no_gridfit", ""), ("alt_y_grid", ""),
                ("right_axis", ""), ("right_axis_label", ""), ("right_axis_format", "0"), ("right_axis_formatter", "0"),
                ("left_axis_formatter", "0"), ("auto_padding", "on"), ("dynamic_labels", ""), ("force_rules_legend", ""),
                ("tab_width", "40"), ("legend_position", "0"), ("legend_direction", "0")]


def cacti_graph_template(key, title, vlabel, lines, opts, dt_key):
    """Szablon wykresu: linia/obszar + LAST/AVERAGE/MAX dla każdego źródła; dt_key(obiekt) = klucz szablonu danych."""
    h = cs("gt", key)
    o = ["\t<%s>" % ch("graph_template", h), xel("name", "Router VPP - " + plain(title), 2), xel("multiple", "", 2), xel("test_source", "", 2), "\t\t<graph>", xel("t_title", "", 3),
         xel("title", "|host_description| - " + title, 3), xel("t_vertical_label", "", 3), xel("vertical_label", vlabel, 3)]
    for f, v in GRAPH_FIELDS:
        if f == "upper_limit" and "upper" in opts:
            v = str(opts["upper"])
        o += [xel("t_" + f, "", 3), xel(f, v, 3)]
    o += ["\t\t</graph>", "\t\t<items>"]
    seq, inputs = 0, []
    width = max(len(lb) for _n, lb, _t in lines) + 2
    for i, (name, label, kind) in enumerate(lines):
        rrd = ch("data_template_item", cs("dti", dt_key(name), name))
        color = COLORS[i % len(COLORS)]
        cdef = ch("cdef", opts["cdef"]) if "cdef" in opts else "0"
        refs = []
        for gtype, cf, text, alpha, hr in ((kind, 1, label.ljust(width), "FF" if kind == LINE else "7F", ""),
                                           (9, 4, "Teraz:", "FF", ""), (9, 1, "Srednio:", "FF", ""),
                                           (9, 3, "Max:", "FF", "on")):
            seq += 1
            ih = cs("gti", key, name, str(seq))
            refs.append("hash_00%s%s" % (CACTI_VER, ih))
            o += ["\t\t\t<%s>" % ch("graph_template_item", ih), xel("graph_type_id", gtype, 4), xel("task_item_id", rrd, 4),
                  xel("color_id", color if gtype != 9 else "0", 4), xel("alpha", alpha, 4),
                  xel("consolidation_function_id", cf, 4), xel("cdef_id", cdef, 4), xel("vdef_id", "0", 4), xel("shift", "", 4),
                  xel("value", "", 4), xel("gprint_id", ch("gprint", GPRINT_NORMAL), 4), xel("textalign", "", 4),
                  xel("text_format", text, 4), xel("hard_return", hr, 4),
                  xel("line_width", "1.50" if gtype == LINE else "0.00", 4), xel("dashes", "", 4), xel("dash_offset", "0", 4),
                  xel("sequence", seq, 4), "\t\t\t</%s>" % ch("graph_template_item", ih)]
        inputs.append((name, label, refs))
    o += ["\t\t</items>", "\t\t<inputs>"]
    for name, label, refs in inputs:
        ih = ch("graph_template_input", cs("gti-in", key, name))
        o += ["\t\t\t<%s>" % ih, xel("name", "Zrodlo danych [%s]" % dsname(name), 4), xel("description", label, 4),
              xel("column_name", "task_item_id", 4), xel("items", "|".join(refs), 4), "\t\t\t</%s>" % ih]
    o += ["\t\t</inputs>", "\t</%s>" % ch("graph_template", h), ""]
    return o


def cacti_data_query(tname, fname, title, graphs):
    t = next(x for x in RS.TABLES if x[1] == tname)
    h = cs("dq", tname)
    o = ["\t<%s>" % ch("data_query", h), xel("name", title, 2), xel("description", t[3], 2),
         xel("xml_path", "<path_cacti>/resource/snmp_queries/%s.xml" % fname, 2),
         xel("data_input_id", ch("data_input", DIM_SNMP_IDX), 2), "\t\t<graphs>"]
    for key, _t, gtitle, _v, lines, _o in graphs:
        gh = ch("data_query_graph", cs("dqg", key))
        o += ["\t\t\t<%s>" % gh, xel("graph_template_id", ch("graph_template", cs("gt", key)), 4),
              xel("name", plain(gtitle), 4), "\t\t\t\t<rrd>"]
        for i, (name, _l, _k) in enumerate(lines):
            o += ["\t\t\t\t\t<item_%03d>" % i, xel("snmp_field_name", name, 6),
                  xel("data_template_id", ch("data_template", cs("dt", key)), 6),
                  xel("data_template_rrd_id", ch("data_template_item", cs("dti", key, name)), 6), "\t\t\t\t\t</item_%03d>" % i]
        sv = ch("data_query_sv_graph", cs("dqsv", key))
        sd = ch("data_query_sv_ds", cs("dqsd", key))
        o += ["\t\t\t\t</rrd>", "\t\t\t\t<sv_graph>", "\t\t\t\t\t<%s>" % sv, xel("field_name", "title", 6), xel("sequence", "1", 6),
              xel("text", "|host_description| - " + gtitle, 6), "\t\t\t\t\t</%s>" % sv, "\t\t\t\t</sv_graph>",
              "\t\t\t\t<sv_data_source>", "\t\t\t\t\t<%s>" % sd, xel("field_name", "name", 6),
              xel("data_template_id", ch("data_template", cs("dt", key)), 6), xel("sequence", "1", 6),
              xel("text", "|host_description| - " + re.sub(r"\s*\(.*\)$", "", gtitle), 6), "\t\t\t\t\t</%s>" % sd,
              "\t\t\t\t</sv_data_source>", "\t\t\t</%s>" % gh]
    o += ["\t\t</graphs>", "\t</%s>" % ch("data_query", h), ""]
    return o


def cacti_template():
    """Jeden plik do importu (Console → Import/Export → Import Templates): zapytania SNMP, szablony danych i wykresów,
    szablon urządzenia „Router VPP BIRD”."""
    o = ["<cacti>"]
    graphs, queries = [], []
    host = ch("host_template", cs("host"))
    for key, title, vlabel, lines, opts in CG_SCALAR:
        graphs.append(ch("graph_template", cs("gt", key)))
    for tname, fname, title in CACTI:
        queries.append(ch("data_query", cs("dq", tname)))
    graphs += [ch("graph_template", x) for x in STOCK_GRAPHS]
    queries += [ch("data_query", x) for x in STOCK_QUERIES]
    o += ["\t<%s>" % host, xel("name", CACTI_HOST_TEMPLATE, 2), xel("class", "linux", 2),
          xel("graph_templates", "|".join(graphs), 2), xel("data_queries", "|".join(queries), 2), "\t</%s>" % host, ""]
    for key, title, vlabel, lines, opts in CG_SCALAR:
        o += cacti_graph_template(key, title, vlabel, lines, opts, lambda n: "s:" + n)
    for key, tname, gtitle, vlabel, lines, opts in CG_TABLE:
        o += cacti_graph_template(key, gtitle, vlabel, lines, opts, lambda n, k=key: k)
    for key, title, vlabel, lines, opts in CG_SCALAR:
        for name, _l, _k in lines:
            o += cacti_data_template("s:" + name, "%s (%s)" % (OBJ[name]["desc"].split(" (")[0], name), [name], False,
                                     OBJ[name]["oid"])
    for key, tname, gtitle, vlabel, lines, opts in CG_TABLE:
        o += cacti_data_template(key, "%s (%s)" % (plain(gtitle), tname), [n for n, _l, _k in lines], True)
    for tname, fname, title in CACTI:
        o += cacti_data_query(tname, fname, title, [g for g in CG_TABLE if g[1] == tname])
    o += ["</cacti>", ""]
    return "\n".join(o)


CACTI_INSTALLER_HEAD = r'''#!/usr/bin/env bash
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
# Generowany: tools/build-templates.py (instalator routera) — nie edytuj ręcznie.
#
# Szablon Cacti „Router VPP BIRD” w jednym pliku: zapisuje zapytania SNMP do <cacti>/resource/snmp_queries/
# i importuje szablon (zapytania, szablony danych i wykresów, szablon urządzenia) przez cli/import_template.php.
# Cacti 1.2.20 lub nowsze. Uruchom na serwerze Cacti jako root (albo użytkownik z prawem zapisu do katalogu Cacti):
#
#   bash install-cacti-router-vpp.sh                    # katalog Cacti wykrywany sam
#   bash install-cacti-router-vpp.sh /var/www/html/cacti
#   bash install-cacti-router-vpp.sh --preview          # tylko podgląd: co zostanie dodane/zmienione
#
# Ponowne uruchomienie (np. po aktualizacji routera) aktualizuje te same obiekty, nie tworzy kopii.
set -euo pipefail
preview=""
dir=""
for a in "$@"; do
  case $a in
    --preview) preview="--preview" ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) dir=$a ;;
  esac
done
if [[ -z $dir ]]; then
  for d in /usr/share/cacti/site /usr/share/cacti /var/www/html/cacti /var/www/cacti /srv/www/htdocs/cacti /opt/cacti; do
    [[ -f $d/cli/import_template.php ]] && { dir=$d; break; }
  done
fi
[[ -n $dir && -f $dir/cli/import_template.php ]] || { echo "Nie znaleziono Cacti (cli/import_template.php). Podaj katalog: bash $0 /ścieżka/do/cacti" >&2; exit 1; }
php=$(command -v php || true)
[[ -n $php ]] || { echo "Brak polecenia php" >&2; exit 1; }
q=$dir/resource/snmp_queries
[[ -d $q ]] || { echo "Brak katalogu $q" >&2; exit 1; }
owner=$(stat -c %U:%G "$q" 2>/dev/null || stat -f %Su:%Sg "$q")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Cacti: $dir"

put() {   # put <plik w resource/snmp_queries> — treść ze stdin
  cat >"$tmp/$1"
  if [[ -n $preview ]]; then
    if [[ ! -f $q/$1 ]]; then echo "  nowy:       $q/$1"
    elif cmp -s "$tmp/$1" "$q/$1"; then echo "  bez zmian:  $q/$1"
    else echo "  zmieniony:  $q/$1"; fi
    return
  fi
  install -m 644 "$tmp/$1" "$q/$1"
  chown "$owner" "$q/$1" 2>/dev/null || true
  echo "  zapisano:   $q/$1"
}
'''

CACTI_INSTALLER_TAIL = r'''
echo "Import szablonu${preview:+ (podgląd)}:"
# import_template.php wypisuje wynik jako HTML — zostawiamy sam tekst: [success] nazwa [new|updated|unchanged]
"$php" -d error_reporting=E_ERROR -d display_errors=stderr "$dir/cli/import_template.php" --filename="$tmp/template.xml" $preview \
  | sed -e 's/<[^>]*>//g' -e 's/&quot;/"/g' -e "s/&#039;/'/g" | grep -v '^[[:space:]]*$'
if [[ -z $preview ]]; then
  cat <<'EOT'

Gotowe. Dalej w Cacti:
  1. Management → Devices → Add: adres loop0 routera, SNMP v2c, community z /etc/router/router.env,
     Device Template: „Router VPP BIRD”.
  2. W urządzeniu: Create Graphs for this Device — zaznacz wykresy (skalarne od razu, sesje BGP, porty,
     dyski itd. z listy zapytań). Zapytania można sprawdzić opcją „Verbose Query”.
EOT
fi
'''


def cacti_installer(resources, template):
    o = [CACTI_INSTALLER_HEAD]
    for fname, text in resources:
        o.append("put %s <<'ROUTER_VPP_XML'\n%sROUTER_VPP_XML\n" % (fname, text))
    o.append("cat >\"$tmp/template.xml\" <<'ROUTER_VPP_XML'\n%sROUTER_VPP_XML\n" % template)
    o.append(CACTI_INSTALLER_TAIL)
    return "".join(o)


def oid_list():
    o = ["# Obiekty SNMP routera (router-snmp)", "",
         "Generowany: `tools/build-templates.py`. Wartości skalarne mają sufiks `.0`, kolumny tablic — indeks wiersza.",
         "Typy: int = Integer32, gauge = Gauge32, counter = Counter32, counter64 = Counter64 "
         "(rośnie, NMS liczy na sekundę).",
         "", "| OID | Nazwa | Typ | Jedn. | Opis |", "|---|---|---|---|---|"]
    for oid, name, typ, unit, desc, _g in RS.objects():
        o.append("| `%s` | %s | %s | %s | %s |" % (oid, name, typ, unit, desc))
    o += ["", "## BGP4-MIB (`.1.3.6.1.2.1.15`, standard, sesje IPv4)", "",
          "bgpVersion, bgpLocalAs, bgpIdentifier oraz bgpPeerTable (indeks = adres IPv4 sąsiada): stan, AdminStatus,",
          "adresy, AS (4-bajtowe jako 23456), FsmEstablishedTransitions, FsmEstablishedTime. Liczniki komunikatów = 0",
          "(BIRD ich nie podaje). Sesje IPv6 i prefiksy: rvBgpPeerTable.", ""]
    return "\n".join(o)


def outputs():
    det, disc = librenms()
    files = {"mib/ROUTER-VPP-MIB.txt": mib(),
             "zabbix/router_vpp_bird_snmp.yaml": zabbix() + "\n",
             "librenms/os_detection/vpprouter.yaml": det,
             "librenms/os_discovery/vpprouter.yaml": disc,
             "librenms/mibs/vpprouter/ROUTER-VPP-MIB": mib(),
             "OID-LIST.md": oid_list()}
    resources = []
    for tname, fname, title in CACTI:
        files["cacti/resource/snmp_queries/%s.xml" % fname] = cacti(tname, title)
        resources.append(("%s.xml" % fname, files["cacti/resource/snmp_queries/%s.xml" % fname]))
    files["cacti/" + CACTI_FILE] = cacti_template()
    files["cacti/" + CACTI_INSTALLER] = cacti_installer(resources, files["cacti/" + CACTI_FILE])
    return files


def main():
    check_names()
    check = "--check" in sys.argv[1:]
    stale = []
    for rel, text in sorted(outputs().items()):
        path = os.path.join(OUT, rel)
        try:
            with open(path, encoding="utf-8") as f:
                same = f.read() == text
        except OSError:
            same = False
        if same:
            continue
        stale.append(rel)
        if not check:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            if path.endswith(".sh"):
                os.chmod(path, 0o755)
            print("zapisano templates/%s" % rel)
    if check and stale:
        print("nieaktualne (uruchom: python3 tools/build-templates.py): %s" % ", ".join(stale))
        return 1
    if not stale:
        print("templates/ aktualne")
    return 0


if __name__ == "__main__":
    sys.exit(main())
