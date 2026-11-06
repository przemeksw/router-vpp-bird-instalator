#!/usr/bin/env python3
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
"""Testy stałego ifIndex (router_ifindex): trwała tabela nazw, przepisywanie IPFIX, poprawka vpp-snmp-agent."""
import importlib.machinery
import importlib.util
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "build", "router_ifindex.py")
INSTALLER = os.path.join(HERE, "..", "install-router.sh")


def load():
    loader = importlib.machinery.SourceFileLoader("router_ifindex", SRC)
    spec = importlib.util.spec_from_loader("router_ifindex", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


ri = load()


class TestResolve(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        ri.MAP = os.path.join(self.tmp, "lib", "snmp-ifindex.json")
        ri._cache.update(mtime=None, map={})

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_first_fill_keeps_old_numbering(self):
        # wdrożenie nie może niczego przesunąć: pierwsze wypełnienie = 1000 + sw_if_index (jak dotąd agent)
        self.assertEqual(ri.resolve(["local0", "hu0", "hu1", "", "hu0.100"]), [1000, 1001, 1002, None, 1004])

    def test_stable_after_vpp_restart_with_new_order(self):
        ri.resolve(["local0", "hu0", "hu1", "hu0.100", "tap4096", "hu0.300"])
        # restart VPP, VLAN 200 dopisany w środku: sw_if_index wszystkich dalszych się przesuwa
        got = ri.resolve(["local0", "hu0", "hu1", "hu0.100", "tap4096", "hu0.200", "tap4097", "hu0.300"])
        self.assertEqual(got[:5], [1000, 1001, 1002, 1003, 1004])
        self.assertEqual(got[7], 1005)                       # hu0.300 zachował numer mimo innej pozycji
        self.assertEqual(sorted(got[5:7]), [1006, 1007])     # nowe nazwy: kolejne wolne numery

    def test_numbers_never_reused(self):
        ri.resolve(["local0", "hu0", "hu0.100"])
        ri.resolve(["local0", "hu0", "hu0.200"])             # hu0.100 usunięty, VPP dał jego sw_if_index nowemu
        self.assertEqual(ri.resolve(["local0", "hu0", "hu0.200"])[2], 1003)
        self.assertEqual(ri.resolve(["local0", "hu0", "hu0.100"])[2], 1002)   # wraca ze swoim numerem

    def test_shared_between_processes(self):
        ri.resolve(["local0", "hu0"])
        ri._cache.update(mtime=None, map={})                 # drugi proces (router-netflow) czyta ten sam plik
        self.assertEqual(ri.resolve(["local0", "hu0", "loop0"]), [1000, 1001, 1002])


def ipfix(dom, sets):
    body = b"".join(sets)
    return struct.pack("!HHIII", 10, 16 + len(body), 0, 1, dom) + body


def tset(tid, fields):
    rec = struct.pack("!HH", tid, len(fields)) + b"".join(struct.pack("!HH", ie, ln) for ie, ln in fields)
    return struct.pack("!HH", 2, 4 + len(rec)) + rec


def dset(tid, records):
    body = b"".join(records)
    return struct.pack("!HH", tid, 4 + len(body)) + body


class TestIpfixRewrite(unittest.TestCase):
    FIELDS = [(8, 4), (12, 4), (10, 4), (14, 4), (1, 8)]          # src, dst, in, out, octets

    def rec(self, src, inn, out):
        return struct.pack("!IIIIQ", src, 0x0A000001, inn, out, 1500)

    def test_rewrites_ingress_and_egress(self):
        tpl = {}
        pkt = ipfix(7, [tset(256, self.FIELDS), dset(256, [self.rec(1, 3, 5), self.rec(2, 5, 0)])])
        out = ri.ipfix_rewrite(pkt, tpl, {3: 1003, 5: 1009})
        r1 = struct.unpack_from("!IIIIQ", out, 16 + 4 + 4 + 4 * 5 + 4)
        r2 = struct.unpack_from("!IIIIQ", out, 16 + 4 + 4 + 4 * 5 + 4 + 24)
        self.assertEqual((r1[2], r1[3]), (1003, 1009))
        self.assertEqual((r2[2], r2[3]), (1009, 0))                  # 0 = nieznany interfejs, bez zmian
        self.assertEqual(r1[4], 1500)                                # inne pola nietknięte
        self.assertEqual(len(out), len(pkt))

    def test_template_from_earlier_packet_and_unknown_template(self):
        tpl = {}
        ri.ipfix_rewrite(ipfix(7, [tset(300, self.FIELDS)]), tpl, {})
        data = ipfix(7, [dset(300, [self.rec(1, 3, 3)])])
        self.assertEqual(struct.unpack_from("!I", ri.ipfix_rewrite(data, tpl, {3: 1003}), 16 + 4 + 8)[0], 1003)
        other_domain = ipfix(8, [dset(300, [self.rec(1, 3, 3)])])
        self.assertEqual(ri.ipfix_rewrite(other_domain, tpl, {3: 1003}), other_domain)

    def test_variable_length_template_and_garbage_left_alone(self):
        tpl = {}
        ri.ipfix_rewrite(ipfix(7, [tset(301, [(10, 4), (82, 0xFFFF), (14, 4)])]), tpl, {})
        self.assertNotIn((7, 301), tpl)
        for junk in (b"", b"\x00\x05" + b"x" * 30, b"\x00\x0a\x00\x10" + b"\x00" * 3):
            self.assertEqual(ri.ipfix_rewrite(junk, tpl, {1: 2}), junk)

    def test_padding_after_records_ignored(self):
        tpl = {}
        pkt = ipfix(7, [tset(256, self.FIELDS), dset(256, [self.rec(1, 3, 3) + b"\x00\x00\x00"])])
        out = ri.ipfix_rewrite(pkt, tpl, {3: 1003})
        self.assertEqual(out[-3:], b"\x00\x00\x00")


AGENT_SNIPPET = '''#!/usr/bin/env python3
# vpp-snmp-agent (fragment do testu)
from agentx.agent import Agent
import logging


class MyAgent:
    def update(self):
        ds = None
        for i in range(len(self.vppstat["/if/names"])):
            ifname = self.vppstat["/if/names"][i]
            idx = 1000 + i

            ds.set("1.3.6.1.2.1.2.2.1.1.%u" % (idx), "int", idx)
'''


class TestAgentPatch(unittest.TestCase):
    def setUp(self):
        with open(INSTALLER, encoding="utf-8") as f:
            m = re.search(r"python3 - \"\$f\" <<'PATCH'\n(.*?)\nPATCH\n", f.read(), re.S)
        self.patch = m.group(1).replace("\\\\n", "\\n")
        self.tmp = tempfile.mkdtemp()
        self.f = os.path.join(self.tmp, "vpp-snmp-agent.py")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_patch(self, text):
        with open(self.f, "w") as f:
            f.write(text)
        return subprocess.run([sys.executable, "-c", self.patch, self.f], capture_output=True, text=True)

    def test_patch_applies_to_expected_code(self):
        r = self.run_patch(AGENT_SNIPPET)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.f + ".new") as f:
            out = f.read()
        self.assertIn("idx = _rv_idx[i] or (1000 + i)", out)
        self.assertIn("_rv_idx = router_ifindex.resolve(", out)
        self.assertLess(out.index("import router_ifindex"), out.index("from agentx.agent import Agent"))
        compile(out, "agent", "exec")

    def test_patch_refuses_unknown_agent_version(self):
        r = self.run_patch(AGENT_SNIPPET.replace("idx = 1000 + i", "idx = 2000 + i"))
        self.assertEqual(r.returncode, 2)
        self.assertFalse(os.path.exists(self.f + ".new"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
