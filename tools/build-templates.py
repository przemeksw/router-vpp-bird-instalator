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
    for tname, fname, title in CACTI:
        files["cacti/resource/snmp_queries/%s.xml" % fname] = cacti(tname, title)
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
            print("zapisano templates/%s" % rel)
    if check and stale:
        print("nieaktualne (uruchom: python3 tools/build-templates.py): %s" % ", ".join(stale))
        return 1
    if not stale:
        print("templates/ aktualne")
    return 0


if __name__ == "__main__":
    sys.exit(main())
