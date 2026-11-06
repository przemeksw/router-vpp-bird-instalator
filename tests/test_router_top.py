#!/usr/bin/env python3
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
"""Testy router-top: ekrany interfejsów, firewalla i guarda na symulatorze VPP (tests/fakevpp.py)."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

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
            f.write("hu0 - - - Trunk 100G\nhu0 100 192.0.2.2/30 - netflow Transit: EPIX\n"
                    "hu0 300 10.0.0.1/30 - nonetflow Core: BNG\n")
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
        descs = top.read_descs()
        self.assertEqual(descs["hu0.100"], ("netflow", "Transit: EPIX"))      # znacznik osobno, nie w opisie
        self.assertEqual(descs["hu0.300"], ("nonetflow", "Core: BNG"))
        self.assertNotIn("local0", text)
        self.assertNotIn("tap4096", text)
        self.assertLess(text.index("hu0 "), text.index("└ hu0.100"))
        self.assertLess(text.index("└ hu0.100"), text.index("└ hu0.300"))

    def test_rx_queues_screen(self):
        hw = ("              Name                Idx   Link  Hardware\n"
              "hu0                                1     up   hu0\n"
              "  Link speed: 100 Gbps\n"
              "    rx_q0_packets                       1000\n"
              "    rx_q1_packets                       1000\n"
              "    rx_q2_packets                       1000\n"
              "    rx_q0_bytes                       100000\n"
              "    rx_q1_bytes                       100000\n"
              "    rx_q2_bytes                       100000\n"
              "    rx_out_of_buffer                     307\n"
              "    rx_discards_phy                        0\n"
              "hu1                                2    down  hu1\n"
              "    rx_q0_packets                          0\n"
              "local0                             0    down  local0\n")
        prev = top.parse_hw_queues(hw)
        self.assertEqual(prev["hu0"]["q"], {0: (1000, 100000), 1: (1000, 100000), 2: (1000, 100000)})
        self.assertEqual((prev["hu0"]["oob"], prev["hu0"]["disc"]), (307, 0))
        self.assertNotIn("local0", prev)
        cur = top.parse_hw_queues(hw.replace("rx_q2_packets                       1000", "rx_q2_packets                      21000")
                                  .replace("rx_out_of_buffer                     307", "rx_out_of_buffer                     649"))
        with open(self.root + "/router.env", "w") as f:
            f.write('INST_WORKERS="5,7,9"\n')
        top.ENV_FILE = self.root + "/router.env"
        text = "\n".join(t for t, _s in top.screen_queues(cur, prev, 1.0))
        self.assertIn("rx_out_of_buffer 342/s", text)           # 649 - 307 w tej sekundzie
        self.assertIn("q2", text)
        self.assertIn("skupienie ruchu", text)                   # 20k z 20k = 100% na jednej kolejce
        self.assertIn("100.0%", text)
        self.assertIn(" 9", text)                                # rdzeń workera kolejki q2
        quiet = "\n".join(t for t, _s in top.screen_queues(prev, prev, 1.0))
        self.assertIn("bez przepełnień", quiet)
        self.assertNotIn("skupienie", quiet)
        self.assertIn("Kolejki RX", top.header(5, False))

    def test_alarms_screen(self):
        st = self.root + "/state.json"
        now = time.time()
        with open(st, "w") as f:
            json.dump({"time": now, "alarms": [{"fac": "VPP", "sev": 2, "mnem": "RX_MISS", "since": int(now) - 90,
                                                 "text": "utrata pakietów na wejściu: hu0 342 pkt/s"}]}, f)
        log = self.root + "/alarmy.log"
        t = lambda sec: time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now - sec))  # noqa: E731
        with open(log, "w") as f:
            f.write("%s %%IFACE-4-DRIFT: VPP różni się od ifaces.conf\n" % t(3600))
            f.write("%s %%IFACE-5-DRIFT_END: VPP znów zgodny\n" % t(3000))
            f.write("%s %%IFACE-3-OPTICS: hu0 [ALARM] RX tor 2 -inf dBm\n" % t(600))
            f.write("%s %%FW-5-BLOCK: blokada 1.2.3.4\n" % t(300))
            f.write("%s %%RPKI-3-DOWN: walidator nie odpowiada\n" % t(200))
            f.write("%s %%RPKI-5-UP: walidator wrócił\n" % t(100))
            f.write("%s %%VPP-2-RX_MISS: stare, z logu\n" % t(90000))   # starsze niż doba: poza historią
            f.write("śmieci bez formatu\n")
        with mock.patch.object(top, "MON_STATE", st), mock.patch.object(top, "ALARM_LOG", log):
            lines = top.screen_alarms(top.AlarmView().sample(), {}, 1.0)
        text = "\n".join(x for x, _s in lines)
        act = text.split("OSTATNIE ZDARZENIA")[0]
        self.assertIn("VPP-RX_MISS", act)                       # z router-monitora (na żywo)
        self.assertIn("1m 30s", act)
        self.assertIn("IFACE-OPTICS", act)                      # z logu: otwarte, bez OPTICS_END
        self.assertNotIn("IFACE-DRIFT", act)                    # zamknięte DRIFT_END
        self.assertNotIn("RPKI-DOWN", act)                      # zamknięte UP
        self.assertNotIn("FW-BLOCK", act)                       # jednorazowe — tylko w historii
        hist = text.split("OSTATNIE ZDARZENIA")[1]
        self.assertIn("%FW-5-BLOCK", hist)
        self.assertNotIn("stare, z logu", hist)
        self.assertLess(hist.index("RPKI-5-UP"), hist.index("FW-5-BLOCK"))   # najnowsze na górze
        styles = {x.split()[2]: s for x, s in lines if "VPP-RX_MISS" in x or "IFACE-OPTICS" in x}
        self.assertEqual(styles, {"VPP-RX_MISS": "miss", "IFACE-OPTICS": "deny"})
        # router-monitor nie działa: ostrzeżenie zamiast cichego "brak alarmów"
        with mock.patch.object(top, "MON_STATE", self.root + "/brak.json"), mock.patch.object(top, "ALARM_LOG", log):
            text = "\n".join(x for x, _s in top.screen_alarms(top.AlarmView().sample(), {}, 1.0))
        self.assertIn("router-monitor nie działa", text)
        self.assertIn("Alarmy", top.header(6, False))

    def test_vpp_load_per_worker(self):
        with open(self.root + "/etc/router/router.env", "w") as f:
            f.write('INST_WORKERS=5,6,7\n')
        top.ENV_FILE = self.root + "/etc/router/router.env"
        top.MONITOR_CONF = self.root + "/nie-ma"
        top.IDLE_FILE = self.root + "/nie-ma-idle.json"
        top.IDLE_LOCAL = []
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
        self.assertIn("wektor: najwyżej 200.0", text)
        w1 = [t for t, _s in lines if t.startswith("  worker 1 ")][0]
        self.assertIn("?%", w1)                               # bez pomiaru luzu zajętość nieznana, nie zgadywana
        self.assertIn("router-monitor jeszcze nie zmierzył", text)
        self.assertIn("RUCH ŁĄCZNIE", text)
        self.assertNotIn("OBCIĄŻENIE", "\n".join(t for t, _s in top.screen_ifaces(cur, cur, 1.0)))

    def test_worker_busy_percent_from_loops(self):
        top.ENV_FILE = self.root + "/nie-ma"
        top.MONITOR_CONF = self.root + "/nie-ma"
        top.IDLE_LOCAL = []
        top.IDLE_FILE = self.root + "/idle.json"
        with open(top.IDLE_FILE, "w") as f:                    # router-monitor zmierzył luz: 4 M pętli/s
            json.dump({"v": 2, "idle": [100000, 4000000, 4000000, 0]}, f)
        cur = {"__workers__": [[1.0, 90000], [1.0, 2000000], [1.0, 400000], [2.0, 3000000]]}
        lines = top.screen_load(cur["__workers__"], 50000)
        rows = {t.split("(")[0].strip(): (t, st) for t, st in lines if t.startswith("  worker ")}
        self.assertIn(" 50%", rows["worker 1"][0])            # 2 M z 4 M pętli = połowa czasu na pakietach
        self.assertIn(" 90%", rows["worker 2"][0])            # wektor wciąż 1.0, a worker prawie pełny
        self.assertEqual(rows["worker 2"][1], "miss")         # stan liczy też zajętość, nie tylko wektor
        self.assertIn(" 25%", rows["worker 3"][0])            # bez własnego pomiaru: mediana innych workerów
        self.assertIn("█" * 12, rows["worker 1"][0])          # pasek = zajętość (50% z 24 znaków)
        self.assertIn("zajętość: najwyżej 90%", "\n".join(t for t, _s in lines))
        # zmiana liczby workerów (set_workers): stary plik nie pasuje — uczymy się od nowa z próbki na luzie
        top.IDLE_LOCAL = []
        lines = top.screen_load([[1.0, 50000], [1.0, 3500000]], 0)
        self.assertIn("?%", [t for t, _s in lines if t.startswith("  worker 1 ")][0])   # bez ruchu: nie uczy się
        lines = top.screen_load([[1.0, 50000], [1.0, 3500000]], 50000)
        self.assertIn("  0%", [t for t, _s in lines if t.startswith("  worker 1 ")][0])

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
        self.assertIn("PHU VIPHOST Przemysław Świderski", out)                              # autor widoczny także w wyniku --once

    def test_curses_bottom_line_always_shows_the_author(self):
        self.assertIn("PHU VIPHOST Przemysław Świderski", top.footer_line(""))
        both = top.footer_line("  ↑↓ PgUp PgDn — wiersze 1–10 z 40")
        self.assertIn("wiersze 1–10 z 40", both)
        self.assertIn("PHU VIPHOST Przemysław Świderski", both)


class TestUi(unittest.TestCase):
    def test_ctrl_c_exits_quietly(self):
        out = mock.MagicMock()
        out.isatty.return_value = True
        with mock.patch.object(top.sys, "argv", ["router-top"]), mock.patch.object(top.sys, "stdout", out), \
                mock.patch.object(top.curses, "wrapper", side_effect=KeyboardInterrupt):
            self.assertEqual(top.main(), 0)

    def test_poller_never_blocks_the_ui(self):
        class SlowApp:
            def lines(self, n):
                time.sleep(0.4)                          # np. vppctl, który czeka na barierę
                return [("ekran %d" % n, "")]

        p = top.Poller(SlowApp())
        p.select(2)
        t0 = time.time()
        self.assertIsNone(p.get(2))                      # jeszcze nie ma danych, ale odczyt nie czeka
        self.assertLess(time.time() - t0, 0.1)
        p.start()
        try:
            end = time.time() + 3
            while p.get(2) is None and time.time() < end:
                time.sleep(0.05)
            self.assertEqual(p.get(2), [("ekran 2", "")])
            p.select(3)
            t0 = time.time()
            p.get(3)
            self.assertLess(time.time() - t0, 0.1)       # przełączenie karty też nie blokuje
            end = time.time() + 3
            while p.get(3) is None and time.time() < end:
                time.sleep(0.05)
            self.assertEqual(p.get(3), [("ekran 3", "")])
        finally:
            p.stop = True
            p.wake.set()

    def test_poller_survives_errors_in_a_screen(self):
        class BadApp:
            calls = 0

            def lines(self, n):
                BadApp.calls += 1
                raise RuntimeError("vppctl nie odpowiada")

        p = top.Poller(BadApp())
        p.select(1)
        p.start()
        try:
            end = time.time() + 3
            while p.get(1) is None and time.time() < end:
                time.sleep(0.05)
            self.assertIn("vppctl nie odpowiada", p.get(1)[0][0])
        finally:
            p.stop = True
            p.wake.set()


if __name__ == "__main__":
    unittest.main(verbosity=1)
