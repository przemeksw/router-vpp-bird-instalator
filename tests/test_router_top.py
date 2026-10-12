#!/usr/bin/env python3
"""Testy router-top: ekrany interfejsów, firewalla i guarda na symulatorze VPP (tests/fakevpp.py)."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "..", "build")
SRC = os.path.join(BUILD, "router-top")
FAKE = os.path.join(HERE, "fakevpp.py")


def load():
    loader = importlib.machinery.SourceFileLoader("router_top", SRC)
    spec = importlib.util.spec_from_loader("router_top", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


top = load()


class TestIfacesScreen(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.makedirs(self.root + "/etc/router")
        with open(self.root + "/etc/router/ifaces.conf", "w") as f:
            f.write("hu0 - - - Trunk 100G\nhu0 100 192.0.2.2/30 - Transit: EPIX\nhu0 300 10.0.0.1/30 - Core: BNG\n")
        top.IFACES_CONF = self.root + "/etc/router/ifaces.conf"

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_rates_per_port_and_vlan(self):
        prev = {"hu0": (0, 0, 0, 0, 0), "hu0.100": (0, 0, 0, 0, 0), "hu0.300": (0, 0, 0, 0, 0),
                "local0": (0, 0, 0, 0, 0), "tap4096": (0, 0, 0, 0, 0)}
        cur = {"hu0": (2000000, 1250000000, 1000000, 500000000, 5), "hu0.100": (1500000, 1000000000, 0, 0, 0),
               "hu0.300": (500000, 250000000, 1000000, 500000000, 0), "local0": (9, 9, 9, 9, 0),
               "tap4096": (9, 9, 9, 9, 0)}
        text = "\n".join(t for t, _s in top.screen_ifaces(cur, prev, 1.0))
        self.assertIn("10.00 Gb/s", text)                    # hu0 RX: 1.25 GB/s = 10 Gb/s
        self.assertIn("8.00 Gb/s", text)                     # hu0.100 RX
        self.assertIn("2.00 M", text)                        # hu0 RX pkt/s
        self.assertIn("└ hu0.100", text)                     # VLAN pod portem
        self.assertIn("Transit: EPIX", text)                 # opis z ifaces.conf
        self.assertNotIn("local0", text)
        self.assertNotIn("tap4096", text)
        self.assertLess(text.index("hu0 "), text.index("└ hu0.100"))
        self.assertLess(text.index("└ hu0.100"), text.index("└ hu0.300"))

    def test_vpp_load_per_worker(self):
        with open(self.root + "/etc/router/router.env", "w") as f:
            f.write('INST_WORKERS=5,6,7\n')
        top.ENV_FILE = self.root + "/etc/router/router.env"
        top.MONITOR_CONF = self.root + "/nie-ma"
        cur = {"hu0": (0, 0, 0, 0, 0), "__workers__": [[0.0, 0], [2.0, 9000000], [80.0, 40000], [200.0, 5000]]}
        lines = top.screen_vpp(cur, cur, 1.0)
        text = "\n".join(t for t, _s in lines)
        self.assertIn("OBCIĄŻENIE VPP", text)
        self.assertIn("worker 1 (rdzeń 5)", text)
        self.assertIn("worker 3 (rdzeń 7)", text)
        self.assertNotIn("wątek główny", text)                # są workery — wątek główny pominięty
        styles = {t.split("(")[0].strip(): st for t, st in lines if t.startswith("  worker ")}
        self.assertEqual(styles, {"worker 1": "dim", "worker 2": "warn", "worker 3": "miss"})
        self.assertIn("NASYCENIE", text)
        self.assertIn("najwyżej: 200.0", text)
        self.assertIn("RUCH ŁĄCZNIE", text)
        self.assertNotIn("OBCIĄŻENIE", "\n".join(t for t, _s in top.screen_ifaces(cur, cur, 1.0)))

    def test_scrolling_keeps_table_header(self):
        lines = [("naglowek", "head")] + [("wiersz %d" % i, "") for i in range(100)]
        shown, off, foot = top.visible(lines, 0, 20)
        self.assertEqual(shown[0][0], "naglowek")
        self.assertEqual(len(shown), 19)                               # + 1 wiersz stopki = 20
        self.assertIn("wiersze 1–18 z 100", foot)
        shown, off, foot = top.visible(lines, 50, 20)
        self.assertEqual((shown[0][0], shown[1][0]), ("naglowek", "wiersz 50"))
        shown, off, foot = top.visible(lines, 10 ** 9, 20)        # End: przycięte do końca
        self.assertEqual(shown[-1][0], "wiersz 99")
        self.assertEqual(off, 82)
        shown, off, foot = top.visible(lines[:10], 5, 20)          # mieści się: bez przewijania
        self.assertEqual((len(shown), off, foot), (10, 0, ""))

    def test_units(self):
        self.assertEqual(top.fmt_bps(12.5e9), "12.50 Gb/s")
        self.assertEqual(top.fmt_bps(850e6), "850.00 Mb/s")
        self.assertEqual(top.fmt_pps(1234), "1.2 k")


class Cli(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.bin)
        os.symlink(FAKE, os.path.join(self.bin, "fakevppctl"))
        os.chmod(FAKE, 0o755)
        self.vctl = os.path.join(self.bin, "fakevppctl")
        self.env = dict(os.environ, FAKEVPP_STATE=os.path.join(self.root, "vpp.json"), ROUTER_TOP_INTERVAL="0.1",
                        ROUTER_TOP_ROOT=self.root, ROUTER_FW_ROOT=self.root, ROUTER_FW_VPPCTL=self.vctl,
                        ROUTER_FW_SYSTEMD="0", ROUTER_FW_NO_PAPI="1",
                        ROUTER_FW_STATS_JSON=os.path.join(self.root, "stats.json"),
                        ROUTER_GUARD_ROOT=self.root, ROUTER_GUARD_VPPCTL=self.vctl, ROUTER_GUARD_SYSTEMD="0",
                        ROUTER_TOP_FW=os.path.join(BUILD, "router-fw"),
                        ROUTER_TOP_GUARD=os.path.join(BUILD, "router-guard"),
                        ROUTER_TOP_STATS_JSON=os.path.join(self.root, "ifstats.json"),
                        ROUTER_TOP_ERR_JSON=os.path.join(self.root, "err.json"))
        with open(self.root + "/err.json", "w") as f:
            json.dump({}, f)
        os.makedirs(self.root + "/etc/router")
        for v in ("100", "300"):
            self.vpp("create sub-interfaces hu0 %s dot1q %s exact-match" % (v, v))

    def tearDown(self):
        shutil.rmtree(self.root)

    def vpp(self, cmd):
        return subprocess.run([self.vctl] + cmd.split(), env=self.env, capture_output=True, text=True).stdout

    def vpp_raw(self, *args):
        return subprocess.run([self.vctl] + list(args), env=self.env, capture_output=True, text=True).stdout

    def top(self, n):
        r = subprocess.run([sys.executable, SRC, "--once", str(n)], env=self.env, capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr


class TestFwScreen(Cli):
    def test_shows_rule_descriptions_and_counters(self):
        with open(self.root + "/etc/router/firewall.conf", "w") as f:
            f.write('zone hu0.100 internet\ninternet-> deny tcp any any any 445 "SMB z internetu"\n')
        r = subprocess.run([sys.executable, os.path.join(BUILD, "router-fw"), "apply", "-y"], env=self.env,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(self.root + "/stats.json", "w") as f:
            json.dump({"0": [[123456, 7890000], [5, 500], [1, 100], [0, 0]]}, f)
        rc, out = self.top(3)
        self.assertEqual(rc, 0, out)
        self.assertIn("SMB z internetu", out)
        self.assertIn("123 461", out)                       # v4 + v6 jednej reguły
        self.assertIn("NIEAKTYWNY", out)                    # bez router-fw enable

    def test_before_first_apply(self):
        rc, out = self.top(3)
        self.assertEqual(rc, 0, out)
        self.assertIn("nie był jeszcze stosowany", out)


class TestGuardScreen(Cli):
    def test_events_and_counters(self):
        self.vpp("synack-guard mode enforce")
        with open(self.root + "/err.json", "w") as f:       # liczniki węzłów z segmentu statystyk (suma po węzłach)
            json.dump({"Checked": 5000, "Dropped": 4321, "RST sent": 99, "Violation no flow": 4321}, f)
        self.vpp_raw("fake", "guard-events", json.dumps([
            "999.500 198.51.100.7 443 203.0.113.5 40000 syn-ack no-flow dropped+rst",
            "999.000 198.51.100.7 443 203.0.113.6 40001 syn-ack no-flow dropped",
            "998.000 192.0.2.53 53 203.0.113.5 5353 udp no-flow passed"]))
        rc, out = self.top(4)
        self.assertEqual(rc, 0, out)
        for want in ("198.51.100.7:443", "203.0.113.5:40000", "ODRZUCONY + RST", "PRZESZEDŁ (monitor)",
                     "brak SYN", "brak zapytania", "4 321", "najczęstsze źródła: 198.51.100.7 (2)", "0.5s"):
            self.assertIn(want, out)

    def test_no_events(self):
        rc, out = self.top(4)
        self.assertEqual(rc, 0, out)
        self.assertIn("brak naruszeń", out)


class TestIfacesCli(Cli):
    def test_once_runs_without_vpp_papi(self):
        with open(self.root + "/ifstats.json", "w") as f:
            json.dump({"hu0": [1, 2, 3, 4, 0], "hu0.100": [1, 2, 3, 4, 0]}, f)
        rc, out = self.top(2)
        self.assertEqual(rc, 0, out)
        self.assertIn("RAZEM", out)
        rc, out = self.top(1)
        self.assertEqual(rc, 0, out)
        self.assertIn("RUCH ŁĄCZNIE (porty fizyczne: 1, VLAN-y: 1)", out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
