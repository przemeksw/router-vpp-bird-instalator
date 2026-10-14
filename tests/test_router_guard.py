#!/usr/bin/env python3
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
"""Testy router-guard: plik konfiguracyjny, włączanie/wyłączanie na żądanie, tryby, wygasanie, odtwarzanie po restarcie
VPP, wykrywanie rozjazdu i liczniki — na symulatorze VPP (tests/fakevpp.py).

  python3 tests/test_router_guard.py          (bez VPP i bez roota; działa na macOS i Linuksie)
"""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("ROUTER_GUARD_SRC") or os.path.join(HERE, "..", "build", "router-guard")
FAKE = os.path.join(HERE, "fakevpp.py")
os.environ.setdefault("ROUTER_GUARD_ROOT", tempfile.mkdtemp())

CONF_TEXT = """\
in-if    hu0.100 hu0.200
out-if   hu0.300
group web     203.0.113.0/24
group hosting 198.51.100.0/24 2001:db8:100::/48
ttl 60
udp-ttl 30
warmup 60
max-on 6h
"""


def load():
    loader = importlib.machinery.SourceFileLoader("router_guard", SRC)
    spec = importlib.util.spec_from_loader("router_guard", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


gd = load()
PATHS = {n: getattr(gd, n)[len(gd.ROOT):] for n in ("CONF", "STATE", "LOGDIR", "LOG", "MONLOG", "LOCK", "NOTIFY")}


def use_root(root):
    gd.ROOT = root
    for name, suffix in PATHS.items():
        setattr(gd, name, root + suffix)


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        use_root(self.root)


class TestConfig(Base):
    def test_ok(self):
        conf, errs = gd.parse_conf(CONF_TEXT)
        self.assertEqual(errs, [])
        self.assertEqual((conf.in_if, conf.out_if), (["hu0.100", "hu0.200"], ["hu0.300"]))
        self.assertEqual(sorted(conf.groups), ["hosting", "web"])
        self.assertEqual([str(n) for n in conf.groups["hosting"]], ["198.51.100.0/24", "2001:db8:100::/48"])
        self.assertEqual((conf.ttl, conf.udp_ttl, conf.warmup, conf.max_on), (60, 30, 60, 6 * 3600))
        self.assertEqual((conf.tcp_rst, conf.udp, conf.check_isn, conf.udp_frags), ("pass", "on", "on", "pass"))
        self.assertEqual(conf.udp_ports[:3], [19, 53, 111])

    def test_defaults_when_only_interfaces(self):
        conf, errs = gd.parse_conf("in-if a\nout-if b\n")
        self.assertEqual(errs, [])
        self.assertEqual((conf.ttl, conf.udp_ttl, conf.warmup, conf.default_mode), (60, 30, 60, "monitor"))

    def test_errors(self):
        for text, want in (("out-if b\n", "in-if"), ("in-if a\n", "out-if"), ("in-if a b\nout-if b\n", "wspólny"),
                           ("in-if a\nout-if b\nttl x\n", "linia 3"), ("in-if a\nout-if b\ngroup g 1.2.3\n", "linia 3"),
                           ("in-if a\nout-if b\nfoo 1\n", "nieznane słowo"),
                           ("in-if a\nout-if b\ntcp-rst zle\n", "tcp-rst"),
                           ("in-if a\nout-if b\nudp-ports 53 70000\n", "port"),
                           ("in-if a\nout-if b\ndefault-mode off\n", "default-mode")):
            _c, errs = gd.parse_conf(text)
            self.assertTrue(any(want in e for e in errs), (text, errs))

    def test_reply_rst_defaults_and_parsing(self):
        conf, errs = gd.parse_conf("in-if a\nout-if b\n")
        self.assertEqual(errs, [])
        self.assertEqual((conf.reply_rst, conf.reply_rst_pps), ("off", 10000))
        conf, errs = gd.parse_conf("in-if a\nout-if b\nreply-rst on\nreply-rst-pps 500\n")
        self.assertEqual(errs, [])
        self.assertEqual((conf.reply_rst, conf.reply_rst_pps), ("on", 500))
        self.assertIn("reply-rst on reply-rst-pps 500", gd.config_cmd(conf, with_tables=False))
        _c, errs = gd.parse_conf("in-if a\nout-if b\nreply-rst tak\n")
        self.assertTrue(any("reply-rst" in e for e in errs), errs)

    def test_duration(self):
        self.assertEqual([gd.parse_duration(x) for x in ("90", "30s", "30m", "2h", "1d")], [90, 30, 1800, 7200, 86400])
        with self.assertRaises(ValueError):
            gd.parse_duration("x")


class Cli(Base):
    def setUp(self):
        super().setUp()
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.bin)
        os.symlink(FAKE, os.path.join(self.bin, "fakevppctl"))
        os.chmod(FAKE, 0o755)
        self.env = dict(os.environ, ROUTER_GUARD_ROOT=self.root, ROUTER_GUARD_VPPCTL=os.path.join(self.bin, "fakevppctl"),
                        FAKEVPP_STATE=os.path.join(self.root, "vpp.json"), ROUTER_GUARD_SYSTEMD="0",
                        PATH=self.bin + os.pathsep + os.environ["PATH"])
        os.makedirs(self.root + "/etc/router")
        self.make_ifaces()
        self.write_conf(CONF_TEXT)

    def make_ifaces(self):
        for name in ("hu0.100", "hu0.200", "hu0.300"):
            self.vpp("create sub-interfaces hu0 %s dot1q %s exact-match" % (name.split(".")[1], name.split(".")[1]))

    def write_conf(self, text):
        with open(self.root + "/etc/router/synack-guard.conf", "w") as f:
            f.write(text)

    def vpp(self, cmd):
        return subprocess.run([os.path.join(self.bin, "fakevppctl")] + cmd.split(), env=self.env,
                              capture_output=True, text=True).stdout

    def guard(self, *args):
        r = subprocess.run([sys.executable, SRC] + list(args), env=self.env, capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    def state(self):
        with open(self.root + "/var/lib/router/guard.state.json") as f:
            return json.load(f)

    def set_state(self, **kw):
        s = self.state()
        s.update(kw)
        with open(self.root + "/var/lib/router/guard.state.json", "w") as f:
            json.dump(s, f)

    def read(self, name):
        try:
            with open(self.root + "/var/log/router/" + name) as f:
                return f.read()
        except OSError:
            return ""

    def log_text(self):
        """Wszystkie zdarzenia: alarmy.log (tylko ostrzeżenia i groźniejsze) plus własny log narzędzia (komplet)."""
        return self.read("alarmy.log") + self.read("guard.log")

    def show(self):
        return self.vpp("show synack-guard")

    def reboot_vpp(self):
        os.remove(self.root + "/vpp.json")
        self.make_ifaces()


class TestOn(Cli):
    def test_on_prefix_attaches_interfaces_and_starts_in_monitor(self):
        rc, out = self.guard("on", "203.0.113.0/24")
        self.assertEqual(rc, 0, out)
        sh = self.show()
        self.assertIn("mode: monitor", sh)
        self.assertIn("prefix: 203.0.113.0/24", sh)
        for line in ("interface: hu0.100 in", "interface: hu0.200 in", "interface: hu0.300 out"):
            self.assertIn(line, sh)
        self.assertIn("ttl 60", sh)
        st = self.state()
        self.assertTrue(st["active"])
        self.assertEqual((st["mode"], st["target_mode"]), ("monitor", "monitor"))
        self.assertGreater(st["expires"], time.time() + 5 * 3600)          # max-on 6h
        self.assertIn("%GUARD-5-ON", self.log_text())

    def test_on_ip_group_and_list_are_normalized(self):
        rc, out = self.guard("on", "web,198.51.100.7,2001:db8::1")
        self.assertEqual(rc, 0, out)
        sh = self.show()
        for p in ("203.0.113.0/24", "198.51.100.7/32", "2001:db8::1/128"):
            self.assertIn("prefix: " + p, sh)
        self.assertEqual(self.guard("on", "198.51.100.9/24")[0], 0)
        self.assertIn("prefix: 198.51.100.0/24", self.show())

    def test_on_enforce_waits_for_warmup_then_expire_switches(self):
        rc, out = self.guard("on", "web", "--enforce")
        self.assertEqual(rc, 0, out)
        st = self.state()
        self.assertEqual((st["mode"], st["target_mode"]), ("monitor", "enforce"))
        self.assertGreater(st["enforce_at"], time.time())
        self.assertIn("mode: monitor", self.show())
        self.assertEqual(self.guard("expire")[0], 0)                         # jeszcze nie czas
        self.assertIn("mode: monitor", self.show())
        self.set_state(enforce_at=int(time.time()) - 1)
        self.assertEqual(self.guard("expire")[0], 0)
        self.assertIn("mode: enforce", self.show())
        self.assertEqual(self.state()["mode"], "enforce")
        self.assertIn("%GUARD-5-MODE", self.log_text())

    def test_enforce_and_monitor_commands(self):
        self.assertEqual(self.guard("enforce")[0], 2)                         # nic nie jest włączone
        self.guard("on", "web")
        self.assertEqual(self.guard("enforce")[0], 0)
        self.assertIn("mode: enforce", self.show())
        self.assertEqual(self.state()["enforce_at"], 0)
        self.assertEqual(self.guard("monitor")[0], 0)
        self.assertIn("mode: monitor", self.show())

    def test_adding_prefix_in_enforce_goes_back_to_monitor_for_warmup(self):
        self.guard("on", "web")
        self.guard("enforce")
        rc, out = self.guard("on", "hosting")
        self.assertEqual(rc, 0, out)
        self.assertIn("mode: monitor", self.show())
        st = self.state()
        self.assertEqual(st["target_mode"], "enforce")
        self.assertGreater(st["enforce_at"], time.time())
        self.assertEqual(len(st["prefixes"]), 3)

    def test_for_is_capped_by_max_on(self):
        self.guard("on", "web", "--for", "100d")
        self.assertLess(self.state()["expires"], time.time() + 6 * 3600 + 60)
        self.guard("on", "web", "--for", "30m")
        self.assertLess(self.state()["expires"], time.time() + 1900)

    def test_plugin_missing_changes_nothing(self):
        self.env["FAKEVPP_NO_GUARD"] = "1"
        rc, out = self.guard("on", "web")
        self.assertEqual(rc, 3, out)
        self.assertIn("nie jest załadowana", out)
        self.assertFalse(os.path.exists(self.root + "/var/lib/router/guard.state.json"))

    def test_bad_input_and_config_errors(self):
        self.assertEqual(self.guard("on")[0], 2)
        self.assertEqual(self.guard("on", "nie-ip")[0], 2)
        self.assertEqual(self.guard("on", "web", "--for", "x")[0], 2)
        self.write_conf("in-if hu0.100\n")
        rc, out = self.guard("on", "1.2.3.4")
        self.assertEqual(rc, 2, out)
        self.assertIn("out-if", out)
        self.assertIn("mode: off", self.show() or "mode: off")

    def test_missing_interface_is_an_error(self):
        self.write_conf("in-if hu0.100 hu9.9\nout-if hu0.300\n")
        rc, out = self.guard("on", "1.2.3.4")
        self.assertEqual(rc, 2, out)
        self.assertIn("hu9.9", out)


class TestJson(Cli):
    def test_json_for_snmp(self):
        rc, out = self.guard("json")
        self.assertEqual(rc, 0, out)
        d = json.loads(out)
        self.assertEqual((d["active"], d["mode"], d["prefixes"]), (False, "off", 0))
        self.guard("on", "203.0.113.0/24")
        d = json.loads(self.guard("json")[1])
        self.assertEqual((d["active"], d["mode"], d["prefixes"], d["loaded"]), (True, "monitor", 1, True))
        self.assertIn("checked", d["counters"])
        self.assertIn("size4", d)


class TestSignature(Base):
    def test_author_footer_only_on_a_terminal(self):
        import io
        from contextlib import redirect_stdout

        class Tty(io.StringIO):
            def isatty(self):
                return True

        for stream, want in ((Tty(), True), (io.StringIO(), False)):
            with redirect_stdout(stream):
                gd.signature()
            self.assertEqual("PHU VIPHOST Przemysław Świderski" in stream.getvalue(), want)


class TestAlarmLog(Cli):
    def test_alarm_log_has_only_warnings_but_tool_log_has_everything(self):
        self.guard("on", "web")
        self.assertIn("%GUARD-5-ON", self.read("guard.log"))
        self.assertNotIn("%GUARD-5-ON", self.read("alarmy.log"))
        self.vpp("synack-guard prefix 203.0.113.0/24 del")
        self.guard("check", "--log")
        self.assertIn("%GUARD-4-DRIFT", self.read("alarmy.log"))


class TestOff(Cli):
    def test_off_all_detaches_and_clears(self):
        self.guard("on", "web", "--enforce")
        rc, out = self.guard("off")
        self.assertEqual(rc, 0, out)
        sh = self.show()
        self.assertIn("mode: off", sh)
        self.assertNotIn("interface:", sh)
        self.assertNotIn("prefix:", sh)
        st = self.state()
        self.assertFalse(st["active"])
        self.assertEqual(st["enforce_at"], 0)
        self.assertIn("%GUARD-5-OFF", self.log_text())
        self.assertEqual(self.guard("off")[0], 0)                             # drugi raz: nic do roboty

    def test_off_one_prefix_keeps_the_rest(self):
        self.guard("on", "web,hosting")
        self.assertEqual(self.guard("off", "web")[0], 0)
        sh = self.show()
        self.assertNotIn("203.0.113.0/24", sh)
        self.assertIn("198.51.100.0/24", sh)
        self.assertIn("mode: monitor", sh)
        self.assertEqual(self.guard("off", "hosting")[0], 0)
        self.assertIn("mode: off", self.show())

    def test_expire_after_deadline(self):
        self.guard("on", "web", "--for", "30m")
        self.set_state(expires=int(time.time()) - 5)
        self.assertEqual(self.guard("expire")[0], 0)
        self.assertIn("mode: off", self.show())
        self.assertFalse(self.state()["active"])
        self.assertIn("%GUARD-5-EXPIRED", self.log_text())


class TestBoot(Cli):
    def test_boot_restores_in_monitor_and_schedules_enforce(self):
        self.guard("on", "web,hosting")
        self.guard("enforce")
        self.reboot_vpp()
        self.assertIn("mode: off", self.show())
        rc, out = self.guard("boot", "--timeout", "3")
        self.assertEqual(rc, 0, out)
        sh = self.show()
        self.assertIn("mode: monitor", sh)
        self.assertIn("prefix: 203.0.113.0/24", sh)
        self.assertIn("interface: hu0.300 out", sh)
        st = self.state()
        self.assertEqual(st["target_mode"], "enforce")
        self.assertGreater(st["enforce_at"], time.time())
        self.assertIn("%GUARD-6-RESTORED", self.log_text())
        self.set_state(enforce_at=int(time.time()) - 1)
        self.guard("expire")
        self.assertIn("mode: enforce", self.show())

    def test_boot_when_inactive_or_expired(self):
        self.assertEqual(self.guard("boot", "--timeout", "3")[0], 0)
        self.assertIn("mode: off", self.show())
        self.guard("on", "web")
        self.set_state(expires=int(time.time()) - 5)
        self.reboot_vpp()
        self.assertEqual(self.guard("boot", "--timeout", "3")[0], 0)
        self.assertIn("mode: off", self.show())
        self.assertFalse(self.state()["active"])


class TestCheckStatus(Cli):
    ERR_IN = "synack-guard-in-ip4|Violation (no flow)"

    def test_check_detects_and_clears_drift(self):
        self.guard("on", "web")
        self.assertEqual(self.guard("check")[0], 0)
        self.vpp("synack-guard prefix 203.0.113.0/24 del")
        rc, out = self.guard("check", "--log")
        self.assertEqual(rc, 1, out)
        self.assertIn("%GUARD-4-DRIFT", self.log_text())
        self.guard("check", "--log")
        self.assertEqual(self.read("alarmy.log").count("%GUARD-4-DRIFT"), 1)
        self.assertEqual(self.guard("on", "web")[0], 0)                       # ponowne „on” naprawia
        self.assertEqual(self.guard("check", "--log")[0], 0)
        self.assertIn("%GUARD-5-DRIFT_END", self.log_text())

    def test_check_reports_config_errors(self):
        self.write_conf("zle\n")
        self.assertEqual(self.guard("check")[0], 2)

    def test_check_log_is_silent_when_guard_is_off_and_unconfigured(self):
        self.write_conf("# wszystko w komentarzach\n#in-if hu0.100\n")
        for _ in range(2):
            rc, out = self.guard("check", "--log")
            self.assertEqual(rc, 0, out)
        self.assertNotIn("CONFIG_ERROR", self.log_text())
        self.assertEqual(self.guard("check")[0], 2)                           # ręczny check nadal zgłasza brak konfiguracji

    def test_check_log_reports_config_errors_when_guard_is_on(self):
        self.guard("on", "web")
        self.write_conf("zle\n")
        self.assertEqual(self.guard("check", "--log")[0], 2)
        self.assertIn("%GUARD-2-CONFIG_ERROR", self.log_text())

    def test_status_shows_state_and_counters(self):
        self.guard("on", "web")
        self.vpp("fake guard-errors " + json.dumps({self.ERR_IN: 120, "synack-guard-in-ip4|Checked": 1000}))
        rc, out = self.guard("status")
        self.assertEqual(rc, 0, out)
        for want in ("monitor", "203.0.113.0/24", "hu0.100", "1 000", "120"):
            self.assertIn(want, out)
        rc, out = self.guard("status")
        self.assertEqual(rc, 0, out)

    def test_status_shows_rst_counters(self):
        self.guard("on", "web")
        self.vpp("fake guard-errors " + json.dumps({"synack-guard-in-ip4|RST sent": 321,
                                                    "synack-guard-in-ip4|RST would be sent": 77,
                                                    "synack-guard-in-ip4|RST rate limited": 5}))
        rc, out = self.guard("status")
        self.assertEqual(rc, 0, out)
        for want in ("RST wysłane", "321", "RST do wysłania", "77", "RST pominięte", "5"):
            self.assertIn(want, out)

    def test_on_sends_reply_rst_config_to_vpp(self):
        self.write_conf(CONF_TEXT + "reply-rst on\nreply-rst-pps 2000\n")
        self.assertEqual(self.guard("on", "web")[0], 0)
        self.assertIn("reply-rst on reply-rst-pps 2000", self.show())

    def test_status_when_off(self):
        rc, out = self.guard("status")
        self.assertEqual(rc, 0, out)
        self.assertIn("wyłączona", out)

    def test_violations_alarm_uses_rate_between_checks(self):
        self.guard("on", "web")
        self.write_conf(CONF_TEXT + "alarm-pps 100\n")
        self.vpp("fake guard-errors " + json.dumps({self.ERR_IN: 0}))
        self.guard("check", "--log")
        self.vpp("fake guard-errors " + json.dumps({self.ERR_IN: 50000}))
        s = self.state()
        s["snapshot"]["ts"] -= 10                                              # poprzedni odczyt sprzed 10 s
        self.set_state(snapshot=s["snapshot"])
        self.guard("check", "--log")
        self.assertIn("%GUARD-4-VIOLATIONS", self.log_text())
        self.assertRegex(self.log_text(), r"[45] \d{3} pkt/s")                  # 50 000 / ok. 10 s

    def test_table_full_switches_enforce_to_monitor(self):
        self.guard("on", "web")
        self.guard("enforce")
        self.vpp("fake guard-used 4 3800000")
        self.guard("check", "--log")
        self.assertIn("%GUARD-2-TABLE_FULL", self.log_text())
        self.assertIn("mode: monitor", self.show())
        self.assertEqual(self.state()["mode"], "monitor")


if __name__ == "__main__":
    unittest.main(verbosity=1)
