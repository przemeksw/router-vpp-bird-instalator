#!/usr/bin/env python3
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
"""Testy router-snmp: parsery (VPP, BIRD, system), kolektor na atrapach poleceń, protokół pass_persist,
prawdziwy snmpd (gdy jest w systemie) oraz aktualność szablonów w templates/.

  python3 tests/test_router_snmp.py            (bez VPP, BIRD i roota; działa na macOS i Linuksie)
"""
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOP = os.path.dirname(HERE)
SRC = os.environ.get("ROUTER_SNMP_SRC") or os.path.join(TOP, "build", "router-snmp")


def load():
    loader = importlib.machinery.SourceFileLoader("router_snmp", SRC)
    spec = importlib.util.spec_from_loader("router_snmp", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


rs = load()
BASE = rs.BASE

SHOW_INTERFACE = """\
              Name               Idx    State  MTU (L3/IP4/IP6/MPLS)     Counter          Count
hu0                               1      up          1500/0/0/0     rx packets             123456
                                                                    rx bytes             98765432
                                                                    drops                      17
                                                                    punt                        5
                                                                    rx-miss                    42
                                                                    rx-no-buf                   3
                                                                    rx-error                    1
hu1                               2     down         1500/0/0/0
hu0.100                           3      up           0/0/0/0       rx packets                100
                                                                    drops                       2
local0                            0     down          0/0/0/0
loop0                             4      up          9000/0/0/0     tx-error                    9
"""
SHOW_HW = """\
              Name                Idx   Link  Hardware
hu0                                1     up   hu0
  Link speed: 100 Gbps
  Ethernet address 0c:42:a1:00:00:01
    rx_discards_phy                          12
    tx_discards_phy                          99
    rx_out_of_buffer                          3
hu1                                2    down  hu1
local0                             0    down  local0
"""
SHOW_ERRORS = """\
   Count                  Node                              Reason               Severity
        12             ip4-input                    ip4 ttl <= 1                    error
         7             ip4-glean                 address overflow drops             warn
         3             ip4-input                    ip4 ttl <= 1                    error
       500        synack-guard-in4                      Checked                     info
"""
SHOW_BUFFERS = """\
Pool Name            Index NUMA  Size  Data Size  Total  Avail  Cached   Used
default-numa-0         0     0   2496     2048   100000  80000   5000    15000
default-numa-1         1     1   2496     2048   100000  90000   5000     5000
"""
FIB4 = """\
ipv4-VRF:0, fib_index:0, flow hash:[src dst sport dport proto flowlabel ] epoch:0 flags:none locks:[default-route:1, ]
    Prefix length         Count
                   0               1
                  24          949000
                  32              50
ipv4-VRF:10, fib_index:1, flow hash:[src dst sport dport proto flowlabel ] epoch:0 flags:none locks:[]
    Prefix length         Count
                  32               9
"""
FIB6 = """\
ipv6-VRF:0, fib_index:0, flow hash:[src dst sport dport proto flowlabel ] epoch:0 flags:none locks:[]
    Prefix length         Count
                  48          200000
"""
BIRD_PROTOCOLS = """\
BIRD 3.1.0 ready.
Name       Proto      Table      State  Since         Info
device1    Device     ---        up     2026-10-12 08:00:00

epix4      BGP        ---        up     2026-10-12 10:00:00  Established
  Description:    Transit: EPIX
  BGP state:          Established
    Neighbor address: 192.0.2.1
    Neighbor AS:      62081
    Local AS:         4200000001
    Neighbor ID:      192.0.2.254
    Source address:   192.0.2.2
    Hold timer:       180.000/240
  Channel ipv4
    State:          UP
    Table:          master4
    Import limit:   1000000
      Action:       restart
    Routes:         950000 imported, 12 filtered, 2 exported, 949000 preferred

epix6      BGP        ---        start  2026-10-12 11:00:00  Active        Socket: Connection refused
  Description:    Transit: EPIX v6
  BGP state:          Active
    Neighbor address: 2001:db8::1
    Neighbor AS:      62081
    Local AS:         4200000001
    Last error:       Socket: Connection refused
  Channel ipv6
    State:          DOWN
    Routes:         0 imported, 0 exported, 0 preferred

old        BGP        ---        down   2026-10-01
  BGP state:          Down
    Neighbor address: 198.51.100.1
    Neighbor AS:      65010
  Channel ipv4
    State:          DOWN

rpki1      RPKI       ---        up     2026-10-12 09:00:00  Established
  Cache server:     127.0.0.1
  Status:           Established
  Channel roa4
    State:          UP
    Routes:         450000 imported, 0 exported, 450000 preferred
  Channel roa6
    State:          UP
    Routes:         120000 imported, 0 exported, 120000 preferred
"""
SYSTEMCTL_SHOW = """\
Type=notify
Result=success
LoadState=loaded
ActiveState=active
SubState=running
UnitFileState=enabled
ConditionResult=yes
Id=vpp.service

Type=simple
Result=success
LoadState=loaded
ActiveState=active
SubState=running
UnitFileState=enabled
ConditionResult=yes
Id=bird.service

Type=oneshot
Result=success
LoadState=loaded
ActiveState=inactive
SubState=dead
UnitFileState=enabled
ConditionResult=yes
Id=router-ifaces.service

Type=oneshot
Result=success
LoadState=loaded
ActiveState=inactive
SubState=dead
UnitFileState=enabled
ConditionResult=no
Id=router-fw.service

Type=simple
Result=exit-code
LoadState=loaded
ActiveState=failed
SubState=failed
UnitFileState=enabled
ConditionResult=yes
Id=hsflowd.service

Type=simple
Result=success
LoadState=not-found
ActiveState=inactive
SubState=dead
UnitFileState=
Id=bird3.service

Type=simple
Result=success
LoadState=loaded
ActiveState=inactive
SubState=dead
UnitFileState=disabled
ConditionResult=yes
Id=sshd-dataplane.service
"""
MDSTAT = """\
Personalities : [raid1]
md0 : active raid1 sdb2[1] sda2[0]
      468717568 blocks super 1.2 [2/2] [UU]
      bitmap: 2/4 pages [8KB], 65536KB chunk

md1 : active raid1 sda3[0]
      1048576 blocks super 1.2 [2/1] [U_]
      [===>.................]  recovery = 17.3% (181440/1048576) finish=0.5min speed=30240K/sec

unused devices: <none>
"""
SMART_SCAN = {"devices": [{"name": "/dev/sda", "type": "sat"}, {"name": "/dev/nvme0", "type": "nvme"}]}
SMART_SDA = {"model_name": "SSDSC2KB480G8R", "serial_number": "PHYF123", "smart_status": {"passed": True},
             "temperature": {"current": 31}, "power_on_time": {"hours": 12345},
             "ata_smart_attributes": {"table": [{"id": 5, "raw": {"value": 2}}, {"id": 197, "raw": {"value": 0}}]},
             "ata_device_statistics": {"pages": [{"table": [{"name": "Percentage Used Endurance Indicator", "value": 4}]}]}}
SMART_NVME = {"model_name": "Dell Ent NVMe", "serial_number": "S4X", "smart_status": {"passed": False},
              "temperature": {"current": 44}, "power_on_time": {"hours": 100},
              "nvme_smart_health_information_log": {"percentage_used": 81}}


def write(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


class TestParsers(unittest.TestCase):
    def test_show_interface(self):
        ifs = rs.parse_show_interface(SHOW_INTERFACE)
        self.assertEqual(ifs["hu0"]["rx-miss"], 42)
        self.assertEqual(ifs["hu0"]["rx bytes"], 98765432)
        self.assertEqual(ifs["hu1"], {})
        self.assertEqual(ifs["hu0.100"]["drops"], 2)
        self.assertEqual(ifs["loop0"]["tx-error"], 9)
        self.assertTrue(rs.phys_if("hu0"))
        self.assertFalse(rs.phys_if("hu0.100") or rs.phys_if("loop0") or rs.phys_if("local0") or rs.phys_if("tap1"))

    def test_hw_xstats_ignores_tx(self):
        self.assertEqual(rs.parse_hw_xstats(SHOW_HW), {"hu0": 15, "hu1": 0, "local0": 0})

    def test_show_errors_sums_threads(self):
        errs = sorted(rs.parse_show_errors(SHOW_ERRORS))
        self.assertIn((15, "ip4-input", "ip4 ttl <= 1", "error"), errs)
        self.assertIn((7, "ip4-glean", "address overflow drops", "warn"), errs)
        self.assertEqual(len(errs), 3)

    def test_buffers_and_fib(self):
        self.assertEqual(rs.parse_show_buffers(SHOW_BUFFERS), (200000, 170000, 10000, 20000))
        self.assertIsNone(rs.parse_show_buffers("unknown input"))
        self.assertEqual(rs.parse_fib_summary(FIB4), 949051)
        self.assertEqual(rs.parse_fib_summary(FIB6), 200000)

    def test_bird_protocols(self):
        now = time.mktime((2026, 10, 12, 12, 0, 0, 0, 0, -1))
        ps = {p["name"]: p for p in rs.parse_bird_protocols(BIRD_PROTOCOLS, now)}
        self.assertEqual(sorted(ps), ["device1", "epix4", "epix6", "old", "rpki1"])
        e4 = ps["epix4"]
        self.assertEqual((e4["proto"], e4["state"], e4["bgp_state"], e4["neighbor"], e4["remote_as"], e4["local_as"]),
                         ("BGP", "up", "Established", "192.0.2.1", 62081, 4200000001))
        self.assertEqual(e4["desc"], "Transit: EPIX")
        self.assertEqual(now - e4["since"], 7200)
        self.assertEqual(e4["channels"]["ipv4"], {"imported": 950000, "exported": 2, "filtered": 12, "limit": 1000000,
                                                  "up": True})
        self.assertEqual(ps["epix6"]["last_error"], "Socket: Connection refused")
        self.assertEqual(ps["old"]["state"], "down")
        self.assertEqual(ps["rpki1"]["channels"]["roa6"]["imported"], 120000)

    def test_since_formats(self):
        now = time.mktime((2026, 10, 12, 12, 0, 0, 0, 0, -1))
        self.assertEqual(now - rs.parse_since("11:30:00.123", now), 1800)
        self.assertEqual(now - rs.parse_since("13:00:00", now), 86400 - 3600)        # wczoraj
        self.assertEqual(now - rs.parse_since("2026-10-12", now), 12 * 3600)
        self.assertIsNone(rs.parse_since("wczoraj", now))

    def test_route_count_and_router_id(self):
        self.assertEqual(rs.parse_route_count("949000 of 1898000 routes for 949000 networks in table master4"), 949000)
        self.assertIsNone(rs.parse_route_count("syntax error"))
        self.assertEqual(rs.parse_router_id("BIRD 3.1.0\nRouter ID is 10.10.10.10\n"), "10.10.10.10")

    def test_mdstat(self):
        md = {m["name"]: m for m in rs.parse_mdstat(MDSTAT)}
        self.assertEqual((md["md0"]["degraded"], md["md0"]["state"], md["md0"]["sync"], md["md0"]["level"]),
                         (False, "UU", 100, "raid1"))
        self.assertEqual((md["md1"]["degraded"], md["md1"]["sync"]), (True, 17))

    def test_alarms(self):
        now = time.mktime((2026, 10, 12, 12, 0, 0, 0, 0, -1))
        lines = ["2026-10-12 09:00:00 %VPP-2-RX_MISS: stare",
                 "2026-10-12 11:30:00 %VPP-4-LOAD_HIGH: worker 1",
                 "2026-10-12 11:31:00 %VPP-5-LOAD_NORMAL: koniec",
                 "2026-10-12 11:40:00 %MD-1-DEGRADED: md0",
                 "2026-10-12 11:50:00 %FW-5-BLOCK: blokada",
                 "2026-10-12 11:55:00 %MD-5-RECOVERED: md0", "śmieci"]
        warn, crit, last = rs.parse_alarms(lines, now)
        self.assertEqual((warn, crit), (2, 1))
        self.assertIn("%MD-1-DEGRADED", last)

    def test_services(self):
        us = {u["Id"]: u for u in rs.parse_systemctl_show(SYSTEMCTL_SHOW)}
        self.assertEqual(rs.service_up(us["vpp.service"]), 1)
        self.assertEqual(rs.service_up(us["router-ifaces.service"]), 1)     # oneshot zakończony sukcesem
        self.assertEqual(rs.service_up(us["router-fw.service"]), 1)         # celowo nieaktywny (warunek)
        self.assertEqual(rs.service_up(us["hsflowd.service"]), 0)

    def test_smart(self):
        r = rs.smart_row(SMART_SDA)
        self.assertEqual((r["rvDiskHealthOk"], r["rvDiskTemp"], r["rvDiskRealloc"], r["rvDiskPending"],
                          r["rvDiskPowerOnHours"], r["rvDiskWearPct"]), (1, 31, 2, 0, 12345, 4))
        self.assertEqual(r["rvDiskModel"], "SSDSC2KB480G8R PHYF123")
        r = rs.smart_row(SMART_NVME)
        self.assertEqual((r["rvDiskHealthOk"], r["rvDiskWearPct"]), (0, 81))
        self.assertEqual(rs.smart_row({})["rvDiskWearPct"], 0)

    def test_clamp(self):
        self.assertEqual(rs.clamp("gauge", -5), 0)
        self.assertEqual(rs.clamp("gauge", 2 ** 40), 2 ** 32 - 1)
        self.assertEqual(rs.clamp("counter", 2 ** 32 + 7), 7)
        self.assertEqual(rs.clamp("counter64", 2 ** 64 + 1), 1)
        self.assertEqual(rs.clamp("string", "a\nb"), "a b")
        self.assertEqual(rs.as16(4200000001), 23456)


class Fake:
    """Katalog z atrapami poleceń (vppctl, birdc, systemctl, smartctl, router-fw, router-guard) i drzewem ROOT."""

    def __init__(self):
        self.dir = tempfile.mkdtemp()
        self.root = os.path.join(self.dir, "root")
        self.fix = os.path.join(self.dir, "fix")
        self.bin = os.path.join(self.dir, "bin")
        os.makedirs(self.fix)
        os.makedirs(self.bin)
        fake = '#!/bin/sh\nf="%s/$(basename "$0")_$(echo "$*" | tr " /" "__")"\n[ -f "$f" ] || exit 1\ncat "$f"\n' % self.fix
        for name in ("vppctl", "birdc", "smartctl", "router-fw", "router-guard"):
            write(os.path.join(self.bin, name), fake, 0o755)
        write(os.path.join(self.bin, "systemctl"), '#!/bin/sh\ncat "%s/systemctl_show"\n' % self.fix, 0o755)
        self.env = {"ROUTER_SNMP_ROOT": self.root, "ROUTER_SNMP_VPPCTL": os.path.join(self.bin, "vppctl"),
                    "ROUTER_SNMP_BIRDC": os.path.join(self.bin, "birdc"),
                    "ROUTER_SNMP_SYSTEMCTL": os.path.join(self.bin, "systemctl"),
                    "ROUTER_SNMP_SMARTCTL": os.path.join(self.bin, "smartctl"),
                    "ROUTER_SNMP_FW": os.path.join(self.bin, "router-fw"),
                    "ROUTER_SNMP_GUARD": os.path.join(self.bin, "router-guard")}

    def cmd(self, prog, args, out):
        write(os.path.join(self.fix, "%s_%s" % (prog, args.replace(" ", "_").replace("/", "_"))), out)

    def standard(self):
        self.cmd("vppctl", "show version", "vpp v26.06\n")
        self.cmd("vppctl", "show interface", SHOW_INTERFACE)
        self.cmd("vppctl", "show hardware-interfaces", SHOW_HW)
        self.cmd("vppctl", "show errors", SHOW_ERRORS)
        self.cmd("vppctl", "show buffers", SHOW_BUFFERS)
        self.cmd("vppctl", "show ip fib summary", FIB4)
        self.cmd("vppctl", "show ip6 fib summary", FIB6)
        self.cmd("birdc", "show protocols all", BIRD_PROTOCOLS)
        self.cmd("birdc", "show status", "BIRD 3.1.0 ready.\nRouter ID is 10.10.10.10\n")
        self.cmd("birdc", "show route count table master4",
                 "949000 of 1898000 routes for 949000 networks in table master4\n")
        self.cmd("birdc", "show route count table master6", "190000 of 190000 routes for 190000 networks in table master6\n")
        self.cmd("smartctl", "--scan -j", json.dumps(SMART_SCAN))
        self.cmd("smartctl", "-j -a /dev/sda -d sat", json.dumps(SMART_SDA))
        self.cmd("smartctl", "-j -a /dev/nvme0 -d nvme", json.dumps(SMART_NVME))
        self.cmd("router-fw", "json", json.dumps({"enabled": True, "drift": False, "blocks": 2, "rules": 9, "acls": 4,
                                                  "deny_pkts": 1000, "deny_bytes": 64000, "permit_pkts": 5,
                                                  "permit_bytes": 500, "block_pkts": 7}))
        self.cmd("router-guard", "json", json.dumps({"active": True, "mode": "enforce", "prefixes": 3, "drift": True,
                                                     "loaded": True, "used4": 450, "size4": 1000, "used6": 0, "size6": 0,
                                                     "counters": {"checked": 10, "dropped": 4, "violations": 4}}))
        write(os.path.join(self.fix, "systemctl_show"), SYSTEMCTL_SHOW)
        r = self.root
        write(r + "/run/router-monitor/state.json", json.dumps({
            "time": time.time(), "vector_max": 71.6, "vector_per_worker": [71.6, 3.2], "punt_pps": 120.4,
            "rx_miss_pps": 0.0, "nic_discard_pps": 2.0, "hk_cpu_max": 35.5}))
        write(r + "/etc/router/router.env", 'INST_WORKERS="5,7"\n')
        write(r + "/etc/router/version", "SCRIPT_VERSION=1.5.0\nINSTALLED=2026-10-12\n")
        write(r + "/var/lib/router/ifaces.state.json", json.dumps({"drift": "hu0.999"}))
        write(r + "/etc/bird/rpki-mode.conf", "define RPKI_ENFORCE = 1;\n")
        write(r + "/var/lib/router/rpki.state.json", json.dumps({"checked": time.time() - 100, "validator": True,
                                                                 "invalid": 42}))
        write(r + "/proc/mdstat", MDSTAT)
        write(r + "/sys/class/hwmon/hwmon1/name", "coretemp\n")
        write(r + "/sys/class/hwmon/hwmon1/temp1_label", "Package id 0\n")
        write(r + "/sys/class/hwmon/hwmon1/temp1_input", "54000\n")
        write(r + "/sys/class/hwmon/hwmon1/temp1_crit", "98000\n")
        write(r + "/sys/class/hwmon/hwmon1/temp2_label", "Core 0\n")
        write(r + "/sys/class/hwmon/hwmon1/temp2_input", "50000\n")
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 60))
        write(r + "/var/log/router/alarmy.log", "%s %%VPP-2-RX_MISS: hu0 12 pkt/s\n" % stamp)

    def collect(self):
        p = subprocess.run([sys.executable, SRC, "collect", "--once"], env=dict(os.environ, **self.env),
                           capture_output=True, text=True, timeout=60)
        if p.returncode:
            raise AssertionError(p.stdout + p.stderr)
        with open(self.root + "/run/router-snmp/cache.json") as f:
            return json.load(f)

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def by(table, col, value, data):
    return next(r for r in data["t"][table].values() if r[col] == value)


class TestCollector(unittest.TestCase):
    def setUp(self):
        self.f = Fake()
        self.f.standard()

    def tearDown(self):
        self.f.cleanup()

    def test_full_collect(self):
        d = self.f.collect()
        s = d["s"]
        self.assertEqual((s["rvVppUp"], s["rvVppVectorMax"], s["rvVppWorkers"], s["rvVppPuntPps"], s["rvVppHkCpuMax"]),
                         (1, 72, 2, 120, 36))
        self.assertEqual((s["rvVppBufAvail"], s["rvVppBufCached"], s["rvVppBufUsed"], s["rvVppBufFreePct"]),
                         (170000, 10000, 20000, 90))
        self.assertEqual((s["rvVppDrops"], s["rvVppRxMiss"], s["rvVppPunt"], s["rvVppErrors"]), (19, 45, 5, 15))
        self.assertEqual((s["rvFib4Routes"], s["rvBird4Routes"], s["rvFib6Routes"], s["rvBird6Routes"]),
                         (949051, 949000, 200000, 190000))
        self.assertEqual(s["rvFibDiffPct"], 5)                     # IPv6: 10000 / 190000
        self.assertEqual((s["rvIfacesDrift"], s["rvVersion"]), (1, "1.5.0"))
        self.assertEqual((s["rvAlarmsHour"], s["rvAlarmsCritHour"]), (1, 1))
        self.assertIn("RX_MISS", s["rvLastAlarm"])
        self.assertEqual((s["rvFwEnabled"], s["rvFwDrift"], s["rvFwBlocks"], s["rvFwDenyPkts"], s["rvFwBlockPkts"]),
                         (1, 0, 2, 1000, 7))
        self.assertEqual((s["rvGuardActive"], s["rvGuardMode"], s["rvGuardDrift"], s["rvGuardTable4Pct"],
                          s["rvGuardDropped"]), (1, 2, 1, 45, 4))
        self.assertNotIn("rvGuardTable6Pct", s)                    # brak tablicy IPv6 = brak wartości, nie 0 %
        self.assertEqual((s["rvRpkiEnforce"], s["rvRpkiInvalid"], s["rvRpkiValidatorUp"]), (1, 42, 1))
        self.assertGreaterEqual(s["rvRpkiCheckAge"], 100)
        t = d["t"]
        self.assertEqual(t["rvWorkerTable"]["1"]["rvWorkerName"], "worker 1 cpu 5")
        self.assertEqual(sorted(r["rvPortName"] for r in t["rvPortTable"].values()), ["hu0", "hu1"])
        hu0 = by("rvPortTable", "rvPortName", "hu0", d)
        self.assertEqual((hu0["rvPortRxMiss"], hu0["rvPortRxNoBuf"], hu0["rvPortHwDiscards"]), (42, 3, 15))
        e4 = by("rvBgpPeerTable", "rvBgpPeerName", "epix4", d)
        self.assertEqual((e4["rvBgpPeerState"], e4["rvBgpPeerEnabled"], e4["rvBgpPeerImported"], e4["rvBgpPeerFiltered"],
                          e4["rvBgpPeerImportLimit"], e4["rvBgpPeerAfi"]), (6, 1, 950000, 12, 1000000, "ipv4"))
        self.assertGreater(e4["rvBgpPeerUptime"], 0)
        e6 = by("rvBgpPeerTable", "rvBgpPeerName", "epix6", d)
        self.assertEqual((e6["rvBgpPeerState"], e6["rvBgpPeerUptime"], e6["rvBgpPeerLastError"]),
                         (3, 0, "Socket: Connection refused"))
        old = by("rvBgpPeerTable", "rvBgpPeerName", "old", d)
        self.assertEqual((old["rvBgpPeerEnabled"], old["rvBgpPeerState"]), (0, 1))
        rp = by("rvRpkiTable", "rvRpkiName", "rpki1", d)
        self.assertEqual((rp["rvRpkiUp"], rp["rvRpkiVrp4"], rp["rvRpkiVrp6"]), (1, 450000, 120000))
        svc = {r["rvServiceName"]: r["rvServiceUp"] for r in t["rvServiceTable"].values()}
        self.assertEqual(svc, {"vpp.service": 1, "bird.service": 1, "router-ifaces.service": 1, "router-fw.service": 1,
                               "hsflowd.service": 0})
        self.assertEqual(s["rvServicesDown"], 1)
        self.assertEqual(by("rvRaidTable", "rvRaidName", "md1", d)["rvRaidDegraded"], 1)
        self.assertEqual(by("rvDiskTable", "rvDiskName", "nvme0", d)["rvDiskHealthOk"], 0)
        self.assertEqual(list(t["rvTempTable"].values()), [{"rvTempIndex": 1, "rvTempName": "Package id 0",
                                                            "rvTempValue": 54, "rvTempCrit": 98}])
        b4 = d["bgp4"]
        self.assertEqual((b4["local_as"], b4["router_id"]), (4200000001, "10.10.10.10"))
        self.assertEqual(sorted(p["addr"] for p in b4["peers"]), ["192.0.2.1", "198.51.100.1"])

    def test_indexes_are_stable_and_flaps_counted(self):
        d1 = self.f.collect()
        i4 = by("rvBgpPeerTable", "rvBgpPeerName", "epix4", d1)["rvBgpPeerIndex"]
        self.f.cmd("birdc", "show protocols all", BIRD_PROTOCOLS.replace(
            "epix4      BGP        ---        up     2026-10-12 10:00:00  Established",
            "epix4      BGP        ---        start  2026-10-12 12:00:00  Idle").replace(
            "BGP state:          Established\n    Neighbor address: 192.0.2.1", "BGP state:          Idle\n"
            "    Neighbor address: 192.0.2.1").replace("epix6      BGP", "a_new      BGP"))
        d2 = self.f.collect()
        e4 = by("rvBgpPeerTable", "rvBgpPeerName", "epix4", d2)
        self.assertEqual((e4["rvBgpPeerIndex"], e4["rvBgpPeerState"], e4["rvBgpPeerFlaps"], e4["rvBgpPeerUptime"]),
                         (i4, 1, 1, 0))
        new = by("rvBgpPeerTable", "rvBgpPeerName", "a_new", d2)
        self.assertNotIn(new["rvBgpPeerIndex"], [r["rvBgpPeerIndex"] for r in d1["t"]["rvBgpPeerTable"].values()])

    def test_vpp_down_and_missing_tools(self):
        os.remove(os.path.join(self.f.fix, "vppctl_show_version"))
        for f in ("router-fw_json", "router-guard_json", "birdc_show_protocols_all"):
            os.remove(os.path.join(self.f.fix, f))
        d = self.f.collect()
        self.assertEqual(d["s"]["rvVppUp"], 0)
        self.assertNotIn("rvPortTable", d["t"])
        self.assertNotIn("rvFwDrift", d["s"])
        self.assertNotIn("rvBgpPeerTable", d["t"])
        self.assertIn("rvServiceTable", d["t"])


class TestPass(unittest.TestCase):
    def setUp(self):
        self.f = Fake()
        self.f.standard()
        self.f.collect()
        self.old = rs.CACHE
        rs.CACHE = self.f.root + "/run/router-snmp/cache.json"

    def tearDown(self):
        rs.CACHE = self.old
        self.f.cleanup()

    def talk(self, text, prefix=None):
        out = io.StringIO()
        rs.Tree.__init__.__defaults__ = (rs.CACHE,)
        rs.cmd_pass([prefix] if prefix else [], io.StringIO(text), out)
        return out.getvalue().splitlines()

    def test_ping_get_set(self):
        out = self.talk("PING\nget\n.%s.2.1.0\nget\n.%s.2.99.0\nset\n.%s.2.1.0\ninteger 0\n" % (BASE, BASE, BASE))
        self.assertEqual(out, ["PONG", ".%s.2.1.0" % BASE, "integer", "1", "NONE", "not-writable"])

    def test_counter64_and_string(self):
        out = self.talk("get\n.%s.2.12.0\nget\n.%s.1.2.0\n" % (BASE, BASE))
        self.assertEqual(out[1:3], ["counter64", "19"])
        self.assertEqual(out[4:6], ["string", "1.5.0"])

    def test_walk_is_ordered_and_stays_in_subtree(self):
        oids, cur = [], "." + BASE
        for _ in range(5000):
            out = self.talk("getnext\n%s\n" % cur, BASE)
            if out == ["NONE"]:
                break
            cur = out[0]
            oids.append(rs.oid_key(cur))
        self.assertEqual(oids, sorted(set(oids)))
        self.assertTrue(all(o[:len(rs.oid_key(BASE))] == rs.oid_key(BASE) for o in oids))
        names = {rs.oid_key(o) for o, n, *_ in rs.objects() if n == "rvDataAge"}
        self.assertTrue(names & set(oids))
        self.assertGreater(len(oids), 150)

    def test_bgp4_mib(self):
        b = rs.BGP4
        out = self.talk("get\n.%s.2.0\nget\n.%s.3.1.2.192.0.2.1\nget\n.%s.3.1.3.198.51.100.1\nget\n.%s.4.0\n"
                        "getnext\n.%s.3.1.24.198.51.100.1\ngetnext\n.%s.4.0\n" % (b, b, b, b, b, b), b)
        self.assertEqual(out[:12], [".%s.2.0" % b, "integer", "23456", ".%s.3.1.2.192.0.2.1" % b, "integer", "6",
                                    ".%s.3.1.3.198.51.100.1" % b, "integer", "1", ".%s.4.0" % b, "ipaddress",
                                    "10.10.10.10"])
        self.assertEqual(out[12:15], [".%s.4.0" % b, "ipaddress", "10.10.10.10"])   # po tablicy: bgpIdentifier
        self.assertEqual(out[15:], ["NONE"])                        # koniec BGP4-MIB, nie skok do gałęzi routera

    def test_stale_cache_hides_values_but_keeps_age(self):
        with open(rs.CACHE) as f:
            d = json.load(f)
        d["time"] -= 3600
        with open(rs.CACHE, "w") as f:
            json.dump(d, f)
        out = self.talk("get\n.%s.1.1.0\nget\n.%s.2.1.0\n" % (BASE, BASE))
        self.assertEqual(out[1], "gauge")
        self.assertGreaterEqual(int(out[2]), 3600)
        self.assertEqual(out[3:], ["NONE"])


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


SNMPD = shutil.which("snmpd") or ("/usr/sbin/snmpd" if os.path.exists("/usr/sbin/snmpd") else None)


@unittest.skipUnless(SNMPD and shutil.which("snmpwalk") and shutil.which("snmpget"), "brak snmpd / snmpwalk")
class TestRealSnmpd(unittest.TestCase):
    """Prawdziwy snmpd (bez roota, wysoki port) z pass_persist router-snmp — typy i kolejność jak na routerze."""

    @classmethod
    def setUpClass(cls):
        cls.f = Fake()
        cls.f.standard()
        cls.f.collect()
        cls.port = free_port()
        d = cls.f.dir
        wrapper = os.path.join(d, "router-snmp-pass")
        envs = "".join("export %s='%s'\n" % kv for kv in cls.f.env.items())
        write(wrapper, "#!/bin/sh\n%sexec '%s' '%s' \"$@\"\n" % (envs, sys.executable, SRC), 0o755)
        conf = os.path.join(d, "snmpd.conf")
        # rocommunity: net-snmp na Linuksie; com2sec: snmpd z macOS (bez VACM) — nieznana linia to tylko ostrzeżenie
        write(conf, "rocommunity test 127.0.0.1\ncom2sec local 127.0.0.1 test\n"
                    "pass_persist .%s %s pass .%s\npass_persist .%s %s pass .%s\n"
              % (BASE, wrapper, BASE, rs.BGP4, wrapper, rs.BGP4))
        env = dict(os.environ, SNMP_PERSISTENT_DIR=os.path.join(d, "persist"), MIBS="")
        cls.proc = subprocess.Popen([SNMPD, "-f", "-Lo", "-C", "-c", conf, "-p", os.path.join(d, "snmpd.pid"),
                                     "-I", "-smux,mteTrigger,mteTriggerConf", "udp:127.0.0.1:%d" % cls.port],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for _ in range(20):
            if cls.proc.poll() is not None:
                break
            if cls.snmp("snmpget", ".1.3.6.1.2.1.1.5.0", 1)[0] == 0:
                return
            time.sleep(0.3)
        out = cls.proc.stdout.read() if cls.proc.poll() is not None else ""
        cls.tearDownClass()
        raise unittest.SkipTest("snmpd nie wystartował w tym środowisku: %s" % out[-300:])

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        try:
            cls.proc.wait(5)
        except subprocess.TimeoutExpired:
            cls.proc.kill()
        cls.f.cleanup()

    @classmethod
    def snmp(cls, tool, oid, timeout=3):
        p = subprocess.run([tool, "-v2c", "-c", "test", "-On", "-t", str(timeout), "-r", "1", "-M", "/dev/null",
                            "127.0.0.1:%d" % cls.port, oid], capture_output=True, text=True, timeout=60)
        return p.returncode, p.stdout + p.stderr

    def test_walk_router_tree(self):
        rc, out = self.snmp("snmpwalk", "." + BASE)
        self.assertEqual(rc, 0, out)
        self.assertIn(".%s.2.1.0 = INTEGER: 1" % BASE, out)
        self.assertIn(".%s.2.12.0 = Counter64: 19" % BASE, out)
        self.assertIn(".%s.2.8.0 = Gauge32: 170000" % BASE, out)
        self.assertIn('STRING: "Transit: EPIX"', out)
        self.assertIn("Counter32: 0", out)                                      # rvBgpPeerFlaps
        self.assertNotIn("No Such", out)
        self.assertGreater(out.count("\n"), 150)

    def test_walk_bgp4_mib(self):
        rc, out = self.snmp("snmpwalk", "." + rs.BGP4)
        self.assertEqual(rc, 0, out)
        self.assertIn(".%s.2.0 = INTEGER: 23456" % rs.BGP4, out)
        self.assertIn(".%s.3.1.2.192.0.2.1 = INTEGER: 6" % rs.BGP4, out)
        self.assertIn(".%s.3.1.7.192.0.2.1 = IpAddress: 192.0.2.1" % rs.BGP4, out)
        self.assertIn(".%s.3.1.14.192.0.2.1 = Hex-STRING: 00 00" % rs.BGP4, out)
        self.assertNotIn(BASE, out)


class TestTemplates(unittest.TestCase):
    def test_templates_up_to_date(self):
        p = subprocess.run([sys.executable, os.path.join(TOP, "tools", "build-templates.py"), "--check"],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_cli_help_and_oids(self):
        out = subprocess.run([sys.executable, SRC, "--help"], capture_output=True, text=True).stdout
        self.assertIn("PHU VIPHOST", out)
        out = subprocess.run([sys.executable, SRC, "oids"], capture_output=True, text=True).stdout
        self.assertIn("rvBgpPeerState", out)
        self.assertEqual(len(out.splitlines()), len(rs.objects()))


if __name__ == "__main__":
    unittest.main()
