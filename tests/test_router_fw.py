#!/usr/bin/env python3
"""Testy router-fw: parser, kompilator ACL, plan zmian oraz polecenia na symulatorze VPP (tests/fakevpp.py).

  python3 tests/test_router_fw.py            (bez VPP i bez roota; działa na macOS i Linuksie)
"""
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("ROUTER_FW_SRC") or os.path.join(HERE, "..", "build", "router-fw")
FAKE = os.path.join(HERE, "fakevpp.py")
os.environ.setdefault("ROUTER_FW_ROOT", tempfile.mkdtemp())     # pomija sprawdzanie roota przy imporcie


def load():
    loader = importlib.machinery.SourceFileLoader("router_fw", SRC)
    spec = importlib.util.spec_from_loader("router_fw", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


fw = load()
PATHS = {n: getattr(fw, n)[len(fw.ROOT):] for n in
         ("CONF", "LASTGOOD", "PREV", "REJECTED", "STATE", "BLOCKS", "PENDING", "LOGDIR", "LOG", "MONLOG", "LOCK", "NOTIFY")
         if hasattr(fw, n)}

SAMPLE = """\
zone hu0.100 internet   # Transit
zone hu0.200 internet
zone hu0.300 clients
list smtp-ok 203.0.113.25/32 203.0.113.26/32
internet-> deny any 192.0.2.0/24 any any any bogony
internet-> deny tcp any any any 445 SMB
->internet permit tcp @smtp-ok any any 25 serwery poczty
->internet deny tcp any any any 25 blokada SMTP
"""


def use_root(root):
    fw.ROOT = root
    for name, suffix in PATHS.items():
        setattr(fw, name, root + suffix)


def parse(text):
    conf, errs = fw.parse_conf(text)
    return conf, errs


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        use_root(self.root)


class TestSmoke(Base):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, SRC] + list(args), env=dict(os.environ, ROUTER_FW_ROOT=self.root),
                              capture_output=True, text=True)

    def test_help_and_unknown_command(self):
        r = self.run_cli("--help")
        self.assertEqual(r.returncode, 0)
        self.assertIn("router-fw", r.stdout)
        r = self.run_cli("nonsens")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("nieznane polecenie", r.stderr)

    def test_event_writes_cisco_style_line(self):
        line = fw.event(5, "APPLIED", "test", mail=False)
        self.assertEqual(line, "%FW-5-APPLIED: test")
        with open(fw.MONLOG) as f:
            self.assertIn("%FW-5-APPLIED: test", f.read())


class TestParser(Base):
    def test_sample_ok(self):
        conf, errs = parse(SAMPLE)
        self.assertEqual(errs, [])
        self.assertEqual(conf.zones, {"hu0.100": "internet", "hu0.200": "internet", "hu0.300": "clients"})
        self.assertEqual(len(conf.rules), 4)
        r = conf.rules[3]
        self.assertEqual((r.direction, r.action, r.proto, r.dport), (("internet", "out"), "deny", 6, [(25, 25)]))
        self.assertEqual(r.desc, "blokada SMTP")

    def test_ports_lists_and_ranges(self):
        conf, errs = parse("zone a internet\ninternet-> deny udp any 1024-65535 any 3784,4784 x\n")
        self.assertEqual(errs, [])
        self.assertEqual(conf.rules[0].sport, [(1024, 65535)])
        self.assertEqual(conf.rules[0].dport, [(3784, 3784), (4784, 4784)])

    def test_comment_used_as_description(self):
        conf, errs = parse("zone a internet\ninternet-> deny tcp any any any 23   # telnet\n")
        self.assertEqual(errs, [])
        self.assertEqual(conf.rules[0].desc, "telnet")

    def test_errors_are_collected_with_line_numbers(self):
        _c, errs = parse("zone a internet\ninternet-> block tcp any any any 25\n"
                         "internet-> deny tcp any any any 99999\ninternet-> deny tcp any any any 25 x\n"
                         "internet-> deny foo any any any 25 x\ninternet-> deny tcp 1.2.3 any any 25 x\n"
                         "internet-> deny tcp @nie-ma any any 25 x\nclients-> deny tcp any any any 25 x\n")
        text = "\n".join(errs)
        for want in ("linia 2", "linia 3", "linia 5", "linia 6", "linia 7", "linia 8"):
            self.assertIn(want, text)
        self.assertEqual(len(errs), 6)

    def test_ports_only_for_tcp_udp(self):
        _c, errs = parse("zone a internet\ninternet-> deny icmp any any any 25 x\n")
        self.assertIn("porty", errs[0])

    def test_family_mismatch_is_error(self):
        _c, errs = parse("zone a internet\ninternet-> deny tcp 10.0.0.0/8 any 2001:db8::/32 25 x\n")
        self.assertIn("nic nie obejmuje", errs[0])

    def test_duplicate_zone_and_bad_names(self):
        _c, errs = parse("zone a internet\nzone a clients\nzone b zbyt-dluga-nazwa-strefy-ponad-24\n")
        self.assertEqual(len(errs), 2)

    def test_list_include_file(self):
        os.makedirs(self.root + "/etc/router/fw-lists")
        with open(self.root + "/etc/router/fw-lists/bogony.list", "w") as f:
            f.write("# bogony\n10.0.0.0/8\n192.168.0.0/16   # prywatne\n")
        conf, errs = parse("list bogony include /etc/router/fw-lists/bogony.list\n")
        self.assertEqual(errs, [])
        self.assertEqual([str(n) for n in conf.lists["bogony"]], ["10.0.0.0/8", "192.168.0.0/16"])
        _c, errs = parse("list x include /nie/ma/takiego\n")
        self.assertIn("nie można czytać", errs[0])

    def test_set_counters(self):
        conf, errs = parse("set counters off\n")
        self.assertEqual((errs, conf.settings["counters"]), ([], "off"))
        _c, errs = parse("set punt-limit 1000\n")
        self.assertIn("znane ustawienie", errs[0])


class TestCompile(Base):
    def groups(self, text=SAMPLE, blocks=()):
        conf, errs = parse(text)
        self.assertEqual(errs, [])
        return fw.build_groups(conf, blocks)

    def test_groups_and_default_permit(self):
        g = self.groups()
        self.assertEqual(sorted(g), ["internet:in", "internet:out"])
        self.assertEqual(g["internet:in"].ifaces, ["hu0.100", "hu0.200"])
        self.assertEqual(g["internet:in"].texts, [
            "deny src 192.0.2.0/24 dst 0.0.0.0/0",
            "deny src 0.0.0.0/0 dst 0.0.0.0/0 proto 6 dport 445",
            "deny src ::/0 dst ::/0 proto 6 dport 445",
            "permit src 0.0.0.0/0 dst 0.0.0.0/0",
            "permit src ::/0 dst ::/0",
        ])

    def test_whitelist_order_and_list_expansion(self):
        t = self.groups()["internet:out"].texts
        self.assertEqual(t[0], "permit src 203.0.113.25/32 dst 0.0.0.0/0 proto 6 dport 25")
        self.assertEqual(t[1], "permit src 203.0.113.26/32 dst 0.0.0.0/0 proto 6 dport 25")
        self.assertTrue(t[2].startswith("deny src 0.0.0.0/0 dst 0.0.0.0/0 proto 6 dport 25"))

    def test_icmp_families(self):
        t = self.groups("zone a internet\ninternet-> deny icmp any any any any x\n"
                        "internet-> deny icmp6 any any any any x\n")["internet:in"].texts
        self.assertEqual(t[0], "deny src 0.0.0.0/0 dst 0.0.0.0/0 proto 1")
        self.assertEqual(t[1], "deny src ::/0 dst ::/0 proto 58")

    def test_port_range_and_single(self):
        t = self.groups("zone a internet\ninternet-> deny udp any 1024-65535 any 53 x\n")["internet:in"].texts
        self.assertEqual(t[0], "deny src 0.0.0.0/0 dst 0.0.0.0/0 proto 17 sport 1024-65535 dport 53")

    def test_blocks_go_first_in_internet_in(self):
        g = self.groups(blocks=[{"net": "198.51.100.7/32"}, {"net": "2001:db8::/32"}])
        self.assertEqual(g["internet:in"].texts[:2], ["deny src 198.51.100.7/32 dst 0.0.0.0/0",
                                                       "deny src 2001:db8::/32 dst ::/0"])
        self.assertEqual(g["internet:in"].flat[0].parent, "block")

    def test_blocks_only_group_exists_without_rules(self):
        g = self.groups("zone a internet\n", blocks=[{"net": "198.51.100.7/32"}])
        self.assertEqual(sorted(g), ["internet:in"])

    def test_tag_changes_with_content_and_has_prefix(self):
        a = self.groups()["internet:in"]
        b = self.groups(SAMPLE + "internet-> deny tcp any any any 23 x\n")["internet:in"]
        self.assertTrue(a.tag.startswith("rfw:internet:in:"))
        self.assertNotEqual(a.tag, b.tag)
        self.assertLess(len(a.tag), 64)

    def test_acl_command(self):
        g = self.groups("zone a internet\ninternet-> deny tcp any any any 25 x\n")["internet:in"]
        self.assertEqual(g.acl_command(), "set acl-plugin acl deny src 0.0.0.0/0 dst 0.0.0.0/0 proto 6 dport 25, "
                         "deny src ::/0 dst ::/0 proto 6 dport 25, permit src 0.0.0.0/0 dst 0.0.0.0/0, "
                         "permit src ::/0 dst ::/0 tag " + g.tag)
        self.assertIn(" index 7 ", g.acl_command(7))


class TestAnalyze(Base):
    def warns(self, text):
        conf, errs = parse(text)
        self.assertEqual(errs, [])
        return fw.analyze(conf)

    def test_shadowed_rule(self):
        w = self.warns("zone a internet\ninternet-> deny tcp any any any 20-30 x\ninternet-> deny tcp any any any 25 y\n")
        self.assertEqual(len(w), 1)
        self.assertIn("linia 3 jest zacieniona przez linię 2", w[0])

    def test_whitelist_before_deny_is_not_shadowed(self):
        w = self.warns("zone a internet\n->internet permit tcp 1.1.1.1/32 any any 25 x\n->internet deny tcp any any any 25 y\n")
        self.assertEqual(w, [])

    def test_broad_deny_without_ports_is_quiet(self):
        w = self.warns("zone a internet\ninternet-> deny any 10.0.0.0/8 any any any bogony\n")
        self.assertEqual(w, [])

    def test_bgp_bfd_warnings(self):
        w = self.warns("zone a internet\ninternet-> deny tcp any any any 179 x\ninternet-> deny udp any any any 3784-4784 y\n")
        self.assertEqual(len(w), 3)
        self.assertIn("BGP", w[0])

    def test_deny_all_warns(self):
        w = self.warns("zone a internet\ninternet-> deny any any any any any x\n")
        self.assertIn("całego ruchu", w[0])


class TestPlan(Base):
    def setUp(self):
        super().setUp()
        conf, errs = parse(SAMPLE)
        self.assertEqual(errs, [])
        self.groups = fw.build_groups(conf)

    def actual(self, acls=None, binds=None, ifaces=("hu0.100", "hu0.200", "hu0.300"), extra=()):
        a = fw.Actual()
        a.ifaces = {n: i + 1 for i, n in enumerate(ifaces)}
        a.acls, a.binds, a.extra = acls or {}, binds or {}, list(extra)
        return a

    def human(self, steps):
        return [s.human() for s in steps]

    def test_empty_vpp_creates_and_binds(self):
        steps = fw.plan(self.groups, self.actual())
        self.assertEqual([s.op for s in steps], ["create", "create"] + ["bind"] * 4)
        self.assertIn("+ internet:in: wejście na hu0.100", self.human(steps))
        self.assertIn("+ internet:out: wyjście na hu0.200", self.human(steps))

    def test_converged_vpp_has_no_steps(self):
        g = self.groups
        a = self.actual({"internet:in": (3, g["internet:in"].tag), "internet:out": (4, g["internet:out"].tag)},
                        {("hu0.100", "in"): [3], ("hu0.200", "in"): [3], ("hu0.100", "out"): [4],
                         ("hu0.200", "out"): [4]})
        self.assertEqual(fw.plan(g, a), [])

    def test_changed_content_replaces_in_place(self):
        g = self.groups
        a = self.actual({"internet:in": (3, "rfw:internet:in:00000000"), "internet:out": (4, g["internet:out"].tag)},
                        {("hu0.100", "in"): [3], ("hu0.200", "in"): [3], ("hu0.100", "out"): [4],
                         ("hu0.200", "out"): [4]})
        steps = fw.plan(g, a)
        self.assertEqual([(s.op, s.key, s.index) for s in steps], [("replace", "internet:in", 3)])
        self.assertIn("index 3 ", steps[0].command({}))

    def test_foreign_acl_untouched(self):
        a = self.actual({}, {("hu0.100", "in"): [9]})
        self.assertFalse([s for s in fw.plan(self.groups, a) if s.op in ("unbind", "delete")])

    def test_removed_zone_unbinds_then_deletes(self):
        conf, _e = parse("zone hu0.100 internet\ninternet-> deny tcp any any any 25 x\n")
        g = fw.build_groups(conf)
        a = self.actual({"internet:in": (3, g["internet:in"].tag), "clients:in": (5, "rfw:clients:in:abcd1234")},
                        {("hu0.100", "in"): [3], ("hu0.300", "in"): [5]})
        steps = fw.plan(g, a)
        self.assertEqual([(s.op, s.key) for s in steps], [("unbind", "clients:in"), ("delete", "clients:in")])
        self.assertEqual(steps[0].command({}), "set acl-plugin interface hu0.300 input acl 5 del")
        self.assertEqual(steps[1].command({}), "delete acl-plugin acl index 5")

    def test_interface_moved_between_directions_and_missing_iface_skipped(self):
        a = self.actual(ifaces=("hu0.100",))
        steps = fw.plan(self.groups, a)
        self.assertEqual({s.iface for s in steps if s.op == "bind"}, {"hu0.100"})

    def test_duplicate_acls_after_interrupted_apply_are_removed(self):
        g = self.groups
        a = self.actual({"internet:in": (6, g["internet:in"].tag), "internet:out": (4, g["internet:out"].tag)},
                        {("hu0.100", "in"): [3, 6], ("hu0.200", "in"): [6], ("hu0.100", "out"): [4],
                         ("hu0.200", "out"): [4]}, extra=[(3, "rfw:internet:in:deadbeef")])
        steps = fw.plan(g, a)
        self.assertEqual([(s.op, s.index) for s in steps], [("unbind", 3), ("delete", 3)])


class Cli(Base):
    """Polecenia router-fw uruchamiane jako proces na symulatorze VPP."""
    def setUp(self):
        super().setUp()
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.bin)
        os.symlink(FAKE, os.path.join(self.bin, "fakevppctl"))
        os.chmod(FAKE, 0o755)
        self.env = dict(os.environ, ROUTER_FW_ROOT=self.root, ROUTER_FW_VPPCTL=os.path.join(self.bin, "fakevppctl"),
                        FAKEVPP_STATE=os.path.join(self.root, "vpp.json"), ROUTER_FW_SYSTEMD="0",
                        ROUTER_FW_STATS_JSON=os.path.join(self.root, "stats.json"), ROUTER_FW_NO_PAPI="1",
                        PATH=self.bin + os.pathsep + os.environ["PATH"])
        os.makedirs(self.root + "/etc/router")
        for name in ("hu0.100", "hu0.200", "hu0.300"):
            self.vpp("create sub-interfaces hu0 %s dot1q %s exact-match" % (name.split(".")[1], name.split(".")[1]))
        self.write_conf(SAMPLE)

    def write_conf(self, text):
        with open(self.root + "/etc/router/firewall.conf", "w") as f:
            f.write(text)

    def vpp(self, cmd):
        return subprocess.run([os.path.join(self.bin, "fakevppctl")] + cmd.split(), env=self.env,
                              capture_output=True, text=True).stdout

    def fw(self, *args, stdin=None):
        r = subprocess.run([sys.executable, SRC] + list(args), env=self.env, capture_output=True, text=True,
                           input=stdin or "")
        return r.returncode, r.stdout + r.stderr

    def log_text(self):
        try:
            with open(self.root + "/var/log/router-monitor/router-monitor.log") as f:
                return f.read()
        except OSError:
            return ""

    def stats(self, data):
        with open(self.root + "/stats.json", "w") as f:
            json.dump(data, f)


class TestApply(Cli):
    def test_diff_apply_idempotent(self):
        rc, out = self.fw("diff")
        self.assertEqual(rc, 1, out)
        self.assertIn("+ ACL internet:in", out)
        rc, out = self.fw("apply", "-y")
        self.assertEqual(rc, 0, out)
        acl, ifc = self.vpp("show acl-plugin acl"), self.vpp("show acl-plugin interface")
        self.assertIn("tag {rfw:internet:in:", acl)
        self.assertIn("deny src 0.0.0.0/0 dst 0.0.0.0/0 proto 6 dport 445", acl)
        self.assertEqual(ifc.count("input acl(s): 0"), 2)
        self.assertIn("output acl(s): 1", ifc)
        self.assertEqual(self.fw("diff")[0], 0)
        self.assertIn("Brak zmian", self.fw("apply", "-y")[1])
        self.assertIn("%FW-5-APPLIED", self.log_text())
        self.assertTrue(os.path.exists(self.root + "/var/lib/router/fw.last-good.conf"))

    def test_rule_change_replaces_acl_in_place(self):
        self.fw("apply", "-y")
        self.write_conf(SAMPLE + "internet-> deny tcp any any any 23 telnet\n")
        rc, out = self.fw("apply", "-y")
        self.assertEqual(rc, 0, out)
        self.assertIn("~ ACL internet:in", out)
        acl = self.vpp("show acl-plugin acl")
        self.assertEqual(acl.count("acl-index"), 2)
        self.assertIn("dport 23", acl)

    def test_rule_removed_zone_removed(self):
        self.fw("apply", "-y")
        self.write_conf("zone hu0.100 internet\ninternet-> deny tcp any any any 25 x\n")
        rc, out = self.fw("apply", "-y")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.vpp("show acl-plugin acl").count("acl-index"), 1)
        self.assertEqual(self.vpp("show acl-plugin interface").count("sw_if_index"), 1)

    def test_errors_change_nothing(self):
        self.write_conf("zone hu0.100 internet\ninternet-> deny tcp any any any 99999 x\n")
        rc, out = self.fw("apply", "-y")
        self.assertEqual(rc, 2)
        self.assertIn("linia 2", out)
        self.assertEqual(self.vpp("show acl-plugin acl").strip(), "")

    def test_empty_conf_is_noop(self):
        self.write_conf("# nic tu nie ma\n")
        rc, out = self.fw("apply", "-y")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.vpp("show acl-plugin acl").strip(), "")

    def test_oversized_acl_is_refused(self):
        items = " ".join("10.%d.%d.0/24" % (i // 256, i % 256) for i in range(3000))
        self.write_conf("zone hu0.100 internet\nlist big %s\ninternet-> deny tcp @big any any 25 x\n" % items)
        rc, out = self.fw("apply", "-y")
        self.assertEqual(rc, 2, out)
        self.assertIn("za długa", out)
        self.assertEqual(self.vpp("show acl-plugin acl").strip(), "")

    def test_unknown_interface_is_error_on_apply_but_not_on_boot(self):
        self.write_conf(SAMPLE + "zone hu9.9 internet\n")
        rc, out = self.fw("apply", "-y")
        self.assertEqual(rc, 2)
        self.assertIn("hu9.9", out)
        rc, out = self.fw("boot", "--timeout", "3")
        self.assertEqual(rc, 0, out)
        self.assertIn("IFACE_MISSING", self.log_text())
        self.assertIn("tag {rfw:internet:in:", self.vpp("show acl-plugin acl"))

    def test_boot_restores_after_vpp_restart_and_falls_back_to_last_good(self):
        self.fw("apply", "-y")
        os.remove(self.root + "/vpp.json")
        for name in ("hu0.100", "hu0.200", "hu0.300"):
            self.vpp("create sub-interfaces hu0 %s dot1q %s exact-match" % (name.split(".")[1], name.split(".")[1]))
        self.assertEqual(self.vpp("show acl-plugin acl").strip(), "")
        self.write_conf("to nie jest poprawny plik\n")
        rc, out = self.fw("boot", "--timeout", "3")
        self.assertEqual(rc, 0, out)
        self.assertIn("tag {rfw:internet:in:", self.vpp("show acl-plugin acl"))
        self.assertIn("%FW-2-CONFIG_ERROR", self.log_text())
        self.assertIn("%FW-6-RESTORED", self.log_text())

    def test_foreign_acl_survives(self):
        self.vpp("set acl-plugin acl permit src 10.0.0.0/8 dst 0.0.0.0/0 tag cudzy")
        self.vpp("set acl-plugin interface hu0.100 input acl 0")
        self.assertEqual(self.fw("apply", "-y")[0], 0)
        self.write_conf("zone hu0.100 internet\n")
        self.assertEqual(self.fw("apply", "-y")[0], 0)
        self.assertIn("tag {cudzy}", self.vpp("show acl-plugin acl"))
        self.assertIn("input acl(s): 0", self.vpp("show acl-plugin interface"))


class TestCheckShow(Cli):
    def test_check_detects_and_clears_drift(self):
        self.fw("apply", "-y")
        self.assertEqual(self.fw("check")[0], 0)
        self.vpp("set acl-plugin interface hu0.100 input acl 0 del")
        rc, out = self.fw("check", "--log")
        self.assertEqual(rc, 1, out)
        self.assertIn("%FW-4-DRIFT", self.log_text())
        self.fw("check", "--log")
        self.assertEqual(self.log_text().count("%FW-4-DRIFT"), 1)
        self.assertEqual(self.fw("apply", "-y")[0], 0)
        self.assertEqual(self.fw("check", "--log")[0], 0)
        self.assertIn("%FW-5-DRIFT_END", self.log_text())

    def test_check_reports_file_errors_and_warnings(self):
        self.write_conf("zone hu0.100 internet\ninternet-> deny tcp any any any 179 bgp\n")
        rc, out = self.fw("check")
        self.assertEqual(rc, 0, out)
        self.assertIn("BGP", out)
        self.write_conf("zone hu0.100 internet\ninternet-> deny tcp any any any x y\n")
        self.assertEqual(self.fw("check")[0], 2)

    def test_check_after_empty_conf_is_clean(self):
        self.write_conf("# nic tu nie ma\n")
        self.assertEqual(self.fw("apply", "-y")[0], 0)
        self.assertEqual(self.fw("check")[0], 0)

    def test_show(self):
        self.fw("apply", "-y")
        rc, out = self.fw("show")
        self.assertEqual(rc, 0, out)
        self.assertIn("internet:in", out)
        self.assertIn("ACL 0 w VPP", out)
        self.assertIn("hu0.100 hu0.200", out)


class TestConfirm(Cli):
    def test_confirm_keeps_change(self):
        self.fw("apply", "-y")
        self.write_conf(SAMPLE + "internet-> deny tcp any any any 23 telnet\n")
        rc, out = self.fw("apply", "-y", "--confirm", "120")
        self.assertEqual(rc, 0, out)
        self.assertIn("router-fw confirm", out)
        self.assertTrue(os.path.exists(self.root + "/var/lib/router/fw.pending.json"))
        rc, out = self.fw("confirm")
        self.assertEqual(rc, 0, out)
        self.assertFalse(os.path.exists(self.root + "/var/lib/router/fw.pending.json"))
        self.assertIn("dport 23", self.vpp("show acl-plugin acl"))
        self.assertEqual(self.fw("rollback")[0], 0)
        self.assertIn("dport 23", self.vpp("show acl-plugin acl"))

    def test_rollback_restores_previous_config(self):
        self.fw("apply", "-y")
        self.write_conf(SAMPLE + "internet-> deny tcp any any any 23 telnet\n")
        self.fw("apply", "-y", "--confirm", "120")
        self.assertIn("dport 23", self.vpp("show acl-plugin acl"))
        rc, out = self.fw("rollback")
        self.assertEqual(rc, 0, out)
        self.assertNotIn("dport 23", self.vpp("show acl-plugin acl"))
        self.assertFalse(os.path.exists(self.root + "/var/lib/router/fw.pending.json"))
        self.assertIn("%FW-4-ROLLBACK", self.log_text())
        self.assertEqual(self.fw("check")[0], 0)

    def test_rollback_from_empty_removes_everything(self):
        rc, out = self.fw("apply", "-y", "--confirm", "120")
        self.assertEqual(rc, 0, out)
        self.assertIn("tag {rfw:", self.vpp("show acl-plugin acl"))
        self.assertEqual(self.fw("rollback")[0], 0)
        self.assertEqual(self.vpp("show acl-plugin acl").strip(), "")


class TestBlocks(Cli):
    def test_block_unblock_roundtrip(self):
        self.fw("apply", "-y")
        rc, out = self.fw("block", "198.51.100.7", "2h")
        self.assertEqual(rc, 0, out)
        self.assertIn("deny src 198.51.100.7/32 dst 0.0.0.0/0", self.vpp("show acl-plugin acl"))
        self.assertIn("198.51.100.7/32", self.fw("blocks")[1])
        self.assertIn("%FW-5-BLOCK", self.log_text())
        rc, out = self.fw("unblock", "198.51.100.7")
        self.assertEqual(rc, 0, out)
        self.assertNotIn("198.51.100.7", self.vpp("show acl-plugin acl"))
        self.assertIn("Brak blokad", self.fw("blocks")[1])

    def test_block_survives_boot_and_check_is_clean(self):
        self.fw("apply", "-y")
        self.fw("block", "2001:db8::/32")
        self.assertEqual(self.fw("check")[0], 0)
        os.remove(self.root + "/vpp.json")
        for name in ("hu0.100", "hu0.200", "hu0.300"):
            self.vpp("create sub-interfaces hu0 %s dot1q %s exact-match" % (name.split(".")[1], name.split(".")[1]))
        self.assertEqual(self.fw("boot", "--timeout", "3")[0], 0)
        self.assertIn("deny src 2001:db8::/32 dst ::/0", self.vpp("show acl-plugin acl"))

    def test_expire_removes_only_expired(self):
        self.fw("apply", "-y")
        self.fw("block", "198.51.100.7", "1h")
        self.fw("block", "198.51.100.8", "1h")
        path = self.root + "/var/lib/router/fw-blocks.json"
        with open(path) as f:
            data = json.load(f)
        for b in data:
            if b["net"] == "198.51.100.7/32":
                b["expires"] = int(time.time()) - 5
        with open(path, "w") as f:
            json.dump(data, f)
        rc, out = self.fw("expire")
        self.assertEqual(rc, 0, out)
        acl = self.vpp("show acl-plugin acl")
        self.assertNotIn("198.51.100.7", acl)
        self.assertIn("198.51.100.8", acl)
        self.assertIn("%FW-5-BLOCK_EXPIRED", self.log_text())
        self.assertEqual(self.fw("expire")[0], 0)

    def test_bad_input(self):
        self.assertEqual(self.fw("block", "nie-ip")[0], 2)
        self.assertEqual(self.fw("block", "1.2.3.4", "2x")[0], 2)
        self.assertEqual(self.fw("unblock", "1.2.3.4")[0], 1)

    def test_block_without_internet_zone_is_refused(self):
        self.write_conf("zone hu0.300 clients\nclients-> deny tcp any any any 25 x\n")
        self.fw("apply", "-y")
        rc, out = self.fw("block", "198.51.100.7")
        self.assertEqual(rc, 2, out)
        self.assertIn("internet", out)

    def test_host_bits_are_normalized_in_block(self):
        self.fw("apply", "-y")
        rc, out = self.fw("block", "198.51.100.7/24")
        self.assertEqual(rc, 0, out)
        self.assertIn("198.51.100.0/24", self.fw("blocks")[1])
        self.assertIn("%FW-5-BLOCK: blokada 198.51.100.0/24", self.log_text())

    def test_parse_duration(self):
        self.assertEqual([fw.parse_duration(x) for x in ("90", "30s", "30m", "2h", "1d")], [90, 30, 1800, 7200, 86400])
        with self.assertRaises(ValueError):
            fw.parse_duration("abc")


class TestCounters(Cli):
    def test_counters_map_acl_rules_to_file_lines(self):
        self.fw("apply", "-y")
        self.fw("block", "198.51.100.7")
        # internet:in = ACL 0 (blokada, bogony, SMB v4, SMB v6, domyślne v4, domyślne v6)
        self.stats({"0": [[5, 500], [1204551, 88200000], [9000, 1100000], [32, 3000], [10, 1000], [1, 100]],
                    "1": [[41020, 2000000], [0, 0], [7812, 500000], [0, 0], [3, 300], [0, 0]]})
        rc, out = self.fw("counters")
        self.assertEqual(rc, 0, out)
        self.assertIn("internet->", out)
        self.assertIn("blokada", out)
        self.assertIn("1 204 551", out)
        self.assertIn("88.2 MB", out)
        self.assertIn("9 032", out)               # SMB: v4 9000 + v6 32 = jedna reguła z pliku
        self.assertIn("->internet", out)
        self.assertIn("41 020", out)
        self.assertIn("domyślna", out)

    def test_clear_sets_baseline_and_apply_resets_changed_acl_only(self):
        self.fw("apply", "-y")
        self.stats({"0": [[100, 1000]] * 5, "1": [[7, 70]] * 5})
        self.assertEqual(self.fw("counters", "clear")[0], 0)
        self.stats({"0": [[150, 1500]] * 5, "1": [[7, 70]] * 5})
        out = self.fw("counters")[1]
        self.assertIn(" 50 ", out)
        self.assertNotIn("150", out)
        self.write_conf(SAMPLE + "internet-> deny tcp any any any 23 telnet\n")
        self.fw("apply", "-y")
        with open(self.root + "/var/lib/router/fw.state.json") as f:
            baseline = json.load(f)["baseline"]
        self.assertEqual(len(baseline), 1)          # zostały tylko liczniki niezmienionej listy internet:out
        self.assertTrue(list(baseline)[0].startswith("rfw:internet:out:"))

    def test_counters_when_acl_missing_in_vpp(self):
        self.fw("apply", "-y")
        os.remove(self.root + "/vpp.json")
        rc, out = self.fw("counters")
        self.assertEqual(rc, 0, out)
        self.assertIn("brak w VPP", out)

    def test_counters_before_first_apply(self):
        rc, out = self.fw("counters")
        self.assertEqual(rc, 3)
        self.assertIn("nie był jeszcze stosowany", out)

    def test_rate_from_two_samples(self):
        self.fw("apply", "-y")
        self.stats({"0": [[0, 0]] * 5, "1": [[0, 0]] * 5})
        conf, _e = fw.parse_conf(SAMPLE)
        groups = fw.build_groups(conf)
        act = fw.Actual()
        act.acls = {"internet:in": (0, groups["internet:in"].tag), "internet:out": (1, groups["internet:out"].tag)}
        os.environ["ROUTER_FW_STATS_JSON"] = self.root + "/stats.json"
        fw.STATS_JSON = os.environ["ROUTER_FW_STATS_JSON"]
        try:
            s1 = fw.counter_rows(fw.raw_counters(groups, act), conf, {})
            self.stats({"0": [[0, 0], [2000, 0], [0, 0], [0, 0], [0, 0], [0, 0]], "1": [[0, 0]] * 5})
            s2 = fw.counter_rows(fw.raw_counters(groups, act), conf, {})
            buf = io.StringIO()
            with redirect_stdout(buf):
                fw.print_counters(s2, s1, dt=2.0)
            self.assertIn("1 000", buf.getvalue())
        finally:
            fw.STATS_JSON = ""


class TestReviewFixes(Cli):
    """Poprawki z recenzji końcowej: każdy test odtwarza jedno znalezisko."""
    UNAPPROVED = SAMPLE + "internet-> deny tcp any any any 23 telnet-niezatwierdzony\n"

    def pending_path(self):
        return self.root + "/var/lib/router/fw.pending.json"

    def reboot_vpp(self):
        os.remove(self.root + "/vpp.json")
        for name in ("hu0.100", "hu0.200", "hu0.300"):
            self.vpp("create sub-interfaces hu0 %s dot1q %s exact-match" % (name.split(".")[1], name.split(".")[1]))

    # C1 -------------------------------------------------------------------------------------------------
    def test_block_deploys_last_applied_config_not_unapproved_edit(self):
        self.fw("apply", "-y")
        self.write_conf(self.UNAPPROVED)
        rc, out = self.fw("block", "198.51.100.7")
        self.assertEqual(rc, 0, out)
        acl = self.vpp("show acl-plugin acl")
        self.assertIn("deny src 198.51.100.7/32", acl)
        self.assertNotIn("dport 23", acl)
        with open(self.root + "/var/lib/router/fw.last-good.conf") as f:
            self.assertNotIn("telnet", f.read())

    def test_expire_deploys_last_applied_config_not_unapproved_edit(self):
        self.fw("apply", "-y")
        self.fw("block", "198.51.100.7", "1h")
        path = self.root + "/var/lib/router/fw-blocks.json"
        with open(path) as f:
            data = json.load(f)
        data[0]["expires"] = int(time.time()) - 5
        with open(path, "w") as f:
            json.dump(data, f)
        self.write_conf(self.UNAPPROVED)
        self.assertEqual(self.fw("expire")[0], 0)
        acl = self.vpp("show acl-plugin acl")
        self.assertNotIn("198.51.100.7", acl)
        self.assertNotIn("dport 23", acl)

    # C2 -------------------------------------------------------------------------------------------------
    def test_rollback_restores_include_list_contents(self):
        os.makedirs(self.root + "/etc/router/fw-lists")
        lst = self.root + "/etc/router/fw-lists/b.list"
        with open(lst, "w") as f:
            f.write("10.0.0.0/8\n")
        self.write_conf("zone hu0.100 internet\nlist bogony include /etc/router/fw-lists/b.list\n"
                        "internet-> deny any @bogony any any any bogony\n")
        self.assertEqual(self.fw("apply", "-y")[0], 0)
        with open(lst, "a") as f:
            f.write("203.0.113.0/24\n")
        self.assertEqual(self.fw("check")[0], 0)                    # edycja include bez apply to nie rozjazd
        self.assertEqual(self.fw("apply", "-y", "--confirm", "120")[0], 0)
        self.assertIn("203.0.113.0/24", self.vpp("show acl-plugin acl"))
        self.assertEqual(self.fw("rollback")[0], 0)
        acl = self.vpp("show acl-plugin acl")
        self.assertNotIn("203.0.113.0/24", acl)
        self.assertIn("10.0.0.0/8", acl)

    # C3 -------------------------------------------------------------------------------------------------
    def test_apply_confirm_refused_when_timer_cannot_be_armed(self):
        import shutil
        self.env.update(ROUTER_FW_SYSTEMD="1", ROUTER_FW_SYSTEMD_RUN=shutil.which("false"))
        rc, out = self.fw("apply", "-y", "--confirm", "60")
        self.assertEqual(rc, 4, out)
        self.assertEqual(self.vpp("show acl-plugin acl").strip(), "")
        self.assertFalse(os.path.exists(self.pending_path()))

    def test_second_apply_refused_while_change_waits_for_confirmation(self):
        self.fw("apply", "-y")
        self.write_conf(self.UNAPPROVED)
        self.assertEqual(self.fw("apply", "-y", "--confirm", "120")[0], 0)
        rc, out = self.fw("apply", "-y", "--confirm", "120")
        self.assertEqual(rc, 1, out)
        self.assertIn("czeka na potwierdzenie", out)
        rc, out = self.fw("apply", "-y")
        self.assertEqual(rc, 1, out)

    # I1 -------------------------------------------------------------------------------------------------
    def test_rollback_also_restores_firewall_conf_file(self):
        self.fw("apply", "-y")
        self.write_conf(self.UNAPPROVED)
        self.fw("apply", "-y", "--confirm", "120")
        self.assertEqual(self.fw("rollback")[0], 0)
        with open(self.root + "/etc/router/firewall.conf") as f:
            self.assertNotIn("telnet", f.read())
        with open(self.root + "/var/lib/router/fw.rejected.conf") as f:
            self.assertIn("telnet-niezatwierdzony", f.read())
        self.reboot_vpp()
        self.assertEqual(self.fw("boot", "--timeout", "3")[0], 0)
        self.assertNotIn("dport 23", self.vpp("show acl-plugin acl"))

    def test_boot_with_unconfirmed_change_reverts_it(self):
        self.fw("apply", "-y")
        self.write_conf(self.UNAPPROVED)
        self.fw("apply", "-y", "--confirm", "120")
        self.reboot_vpp()
        rc, out = self.fw("boot", "--timeout", "3")
        self.assertEqual(rc, 0, out)
        self.assertNotIn("dport 23", self.vpp("show acl-plugin acl"))
        self.assertFalse(os.path.exists(self.pending_path()))
        self.assertIn("%FW-4-ROLLBACK", self.log_text())

    def test_rollback_failure_is_reported_as_failure(self):
        self.fw("apply", "-y")
        self.write_conf(self.UNAPPROVED)
        self.fw("apply", "-y", "--confirm", "120")
        self.env["ROUTER_FW_VPPCTL"] = "/nie/ma/vppctl"
        rc, out = self.fw("rollback")
        self.assertNotEqual(rc, 0, out)
        self.assertIn("%FW-2-ROLLBACK_FAIL", self.log_text())

    # I2 / I3 --------------------------------------------------------------------------------------------
    def test_parallel_blocks_are_all_recorded(self):
        self.fw("apply", "-y")
        procs = [subprocess.Popen([sys.executable, SRC, "block", "198.51.100.%d" % i], env=self.env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for i in range(1, 17)]
        self.assertEqual([p.wait(timeout=120) for p in procs], [0] * 16)
        acl = self.vpp("show acl-plugin acl")
        for i in range(1, 17):
            self.assertIn("deny src 198.51.100.%d/32" % i, acl)
        self.assertEqual(self.fw("blocks")[1].count("198.51.100."), 16)

    def test_block_not_left_in_file_when_it_cannot_be_deployed(self):
        self.env["ROUTER_FW_MAX_CMD"] = "700"
        self.fw("apply", "-y")
        last = None
        for i in range(1, 40):
            rc, out = self.fw("block", "198.51.100.%d" % i)
            if rc != 0:
                last = (i, rc, out)
                break
        self.assertIsNotNone(last, "limit długości listy nie zadziałał")
        self.assertEqual(last[1], 2, last[2])
        self.assertNotIn("198.51.100.%d/32" % last[0], self.fw("blocks")[1])
        self.assertEqual(self.fw("boot", "--timeout", "3")[0], 0)         # firewall nadal się odtwarza
        self.assertEqual(self.fw("check")[0], 0)

    def test_block_works_even_if_other_zone_interface_is_missing(self):
        self.write_conf(SAMPLE + "zone hu9.9 clients\nclients-> deny tcp any any any 25 x\n")
        self.assertEqual(self.fw("boot", "--timeout", "3")[0], 0)
        rc, out = self.fw("block", "198.51.100.7")
        self.assertEqual(rc, 0, out)
        self.assertIn("deny src 198.51.100.7/32", self.vpp("show acl-plugin acl"))

    def test_failed_block_keeps_earlier_blocks_file_intact(self):
        self.write_conf("zone hu0.300 clients\nclients-> deny tcp any any any 25 x\n")
        self.fw("apply", "-y")
        self.assertEqual(self.fw("block", "198.51.100.7")[0], 2)
        self.assertIn("Brak blokad", self.fw("blocks")[1])

    # I4 -------------------------------------------------------------------------------------------------
    def test_prompt_does_not_hold_the_lock(self):
        import builtins
        from types import SimpleNamespace
        self.fw("apply", "-y")
        self.write_conf(self.UNAPPROVED)
        os.environ["FAKEVPP_STATE"] = self.env["FAKEVPP_STATE"]
        saved = (fw.VPPCTL, fw.sys.stdin, builtins.input)
        got = {}

        class Tty:
            def isatty(self):
                return True

        def fake_input(_prompt=""):
            t0 = time.time()
            got["rc"], _out = self.fw("block", "198.51.100.7")
            got["secs"] = time.time() - t0
            return "t"

        fw.VPPCTL, fw.sys.stdin, builtins.input = self.env["ROUTER_FW_VPPCTL"], Tty(), fake_input
        try:
            with redirect_stdout(io.StringIO()):
                rc = fw.do_apply(SimpleNamespace(yes=False, confirm=0, timeout=3))
        finally:
            fw.VPPCTL, fw.sys.stdin, builtins.input = saved
        self.assertEqual(got["rc"], 0)
        self.assertLess(got["secs"], 30)
        self.assertEqual(rc, 1)                      # stan zmienił się w trakcie pytania — apply nic nie robi
        self.assertNotIn("dport 23", self.vpp("show acl-plugin acl"))

    # I5 -------------------------------------------------------------------------------------------------
    def test_blanket_deny_of_protocol_warns_about_bgp_bfd(self):
        conf, errs = parse("zone a internet\ninternet-> deny udp any any any any ddos\ninternet-> deny tcp any any any any ddos2\n")
        self.assertEqual(errs, [])
        text = "\n".join(fw.analyze(conf))
        self.assertIn("BFD", text)
        self.assertIn("BGP", text)

    def test_restricted_deny_with_any_ports_stays_quiet(self):
        conf, _e = parse("zone a internet\ninternet-> deny tcp 10.0.0.0/8 any any any x\ninternet-> deny tcp any any any 25 y\n")
        self.assertEqual(fw.analyze(conf), [])

    # I6 -------------------------------------------------------------------------------------------------
    def test_apply_tells_vpp_whether_counters_should_be_on(self):
        from types import SimpleNamespace
        os.environ["FAKEVPP_STATE"] = self.env["FAKEVPP_STATE"]
        calls, saved = [], (fw.VPPCTL, fw.enable_counters)
        fw.VPPCTL, fw.enable_counters = self.env["ROUTER_FW_VPPCTL"], lambda on: calls.append(on) or True
        try:
            with redirect_stdout(io.StringIO()):
                self.assertEqual(fw.do_apply(SimpleNamespace(yes=True, confirm=0, timeout=3)), 0)
                self.write_conf("set counters off\n" + SAMPLE)
                self.assertEqual(fw.do_apply(SimpleNamespace(yes=True, confirm=0, timeout=3)), 0)
        finally:
            fw.VPPCTL, fw.enable_counters = saved
        self.assertEqual(calls, [True, False])

    def test_counters_command_reports_when_counters_are_off(self):
        self.write_conf("set counters off\n" + SAMPLE)
        self.fw("apply", "-y")
        rc, out = self.fw("counters")
        self.assertEqual(rc, 0, out)
        self.assertIn("wyłączone", out)

    def test_counters_read_failure_is_a_message_not_a_traceback(self):
        self.fw("apply", "-y")
        del self.env["ROUTER_FW_STATS_JSON"]
        rc, out = self.fw("counters")
        self.assertEqual(rc, 3, out)
        self.assertNotIn("Traceback", out)
        self.assertIn("nie można odczytać liczników", out)

    # I7 / M1 --------------------------------------------------------------------------------------------
    def test_counters_skip_acl_whose_content_differs_from_applied_config(self):
        self.fw("apply", "-y")
        tag = "rfw:internet:in:00000000"
        self.vpp("set acl-plugin acl index 0 permit src 10.0.0.0/8 dst 0.0.0.0/0 tag " + tag)
        self.stats({"0": [[777, 7770]] * 6, "1": [[5, 50]] * 6})
        rc, out = self.fw("counters")
        self.assertEqual(rc, 0, out)
        self.assertIn("różni się", out)
        self.assertNotIn("777", out)
        self.assertIn("->internet", out)

    def test_counters_after_vpp_restart_never_negative(self):
        self.fw("apply", "-y")
        self.stats({"0": [[100, 1000]] * 6, "1": [[100, 1000]] * 6})
        self.fw("counters", "clear")
        self.stats({"0": [[3, 30]] * 6, "1": [[4, 40]] * 6})          # VPP wystartował od zera
        rc, out = self.fw("counters")
        self.assertEqual(rc, 0, out)
        self.assertNotIn(" -", out)

    def test_expired_block_awaiting_expire_is_not_drift(self):
        self.fw("apply", "-y")
        self.fw("block", "198.51.100.7", "1h")
        path = self.root + "/var/lib/router/fw-blocks.json"
        with open(path) as f:
            data = json.load(f)
        data[0]["expires"] = int(time.time()) - 5
        with open(path, "w") as f:
            json.dump(data, f)
        self.assertEqual(self.fw("check")[0], 0)
        self.assertNotIn("%FW-4-DRIFT", self.log_text())


if __name__ == "__main__":
    unittest.main(verbosity=1)
