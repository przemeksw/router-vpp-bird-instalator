#!/usr/bin/env python3
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
"""Testy router-rpki na atrapach birdc / bird / systemctl: przełącznik odrzucania, wycofanie przy błędzie,
alarmy walidatora, liczba tras INVALID, stan dla router-snmp.

  python3 tests/test_router_rpki.py            (bez BIRD, Routinatora i roota)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("ROUTER_RPKI_SRC") or os.path.join(HERE, "..", "build", "router-rpki")

PROTO_UP = """\
BIRD 3.1.0 ready.
Name       Proto      Table      State  Since         Info
rpki_routinator RPKI  ---        up     2026-10-13 10:00:00  Established
  Cache server:     169.254.31.1
  Status:           Established
  Channel roa4
    State:          UP
    Routes:         450000 imported, 0 exported, 450000 preferred
  Channel roa6
    State:          UP
    Routes:         120000 imported, 0 exported, 120000 preferred
"""
PROTO_DOWN = """\
BIRD 3.1.0 ready.
Name       Proto      Table      State  Since         Info
rpki_routinator RPKI  ---        start  2026-10-13 10:00:00  Connect       Connection refused
  Channel roa4
    State:          UP
    Routes:         450000 imported, 0 exported, 450000 preferred
  Channel roa6
    State:          UP
    Routes:         120000 imported, 0 exported, 120000 preferred
"""
COUNT = ("BIRD 3.1.0 ready.\n37 of 1898000 routes for 37 networks in table master4\n"
         "5 of 220000 routes for 5 networks in table master6\n")


class Base(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.root = os.path.join(self.d, "root")
        self.bin = os.path.join(self.d, "bin")
        os.makedirs(self.bin)
        os.makedirs(self.root + "/etc/bird")
        self.calls = os.path.join(self.d, "calls.log")
        # birdc: odpowiedź z pliku wybranego po argumentach; "configure" → Reconfigured albo błąd (plik flagi)
        self.write(self.bin + "/birdc", """#!/bin/sh
echo "birdc $*" >>"%(d)s/calls.log"
case "$*" in
  "show protocols all rpki_routinator") cat "%(d)s/proto" ;;
  configure) if [ -f "%(d)s/configure_fail" ]; then echo "/etc/bird/bird.conf:3:1 syntax error"
             else echo "Reading configuration from /etc/bird/bird.conf"; echo Reconfigured; fi ;;
  *count*) cat "%(d)s/count" ;;
  *) echo "BIRD 3.1.0 ready."; echo "192.0.2.0/24  unicast [t1_a 10:00:00] * (100) [AS64500i]" ;;
esac
""" % {"d": self.d}, 0o755)
        self.write(self.bin + "/bird", '#!/bin/sh\necho "bird $*" >>"%s/calls.log"\n'
                   '[ -f "%s/parse_fail" ] && { echo "syntax error"; exit 1; }\nexit 0\n' % (self.d, self.d), 0o755)
        self.write(self.bin + "/systemctl", '#!/bin/sh\ncat "%s/validator"\n' % self.d, 0o755)
        self.write(self.bin + "/logger", "#!/bin/sh\nexit 0\n", 0o755)
        self.write(self.d + "/proto", PROTO_UP)
        self.write(self.d + "/count", COUNT)
        self.write(self.d + "/validator", "active\n")
        self.write(self.root + "/etc/bird/rpki-mode.conf", "define RPKI_ENFORCE = 0;\n")
        self.env = dict(os.environ, ROUTER_RPKI_ROOT=self.root, ROUTER_RPKI_BIRDC=self.bin + "/birdc",
                        ROUTER_RPKI_BIRD=self.bin + "/bird", ROUTER_RPKI_SYSTEMCTL=self.bin + "/systemctl",
                        ROUTER_RPKI_STATUS_URL="http://127.0.0.1:9/brak", PATH=self.bin + os.pathsep + os.environ["PATH"])

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    @staticmethod
    def write(path, text, mode=0o644):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
        os.chmod(path, mode)

    def rpki(self, *args):
        p = subprocess.run([sys.executable, SRC] + list(args), env=self.env, capture_output=True, text=True, timeout=60)
        return p.returncode, p.stdout + p.stderr

    def calls_text(self):
        with open(self.calls) as f:
            return f.read()

    def mode(self):
        with open(self.root + "/etc/bird/rpki-mode.conf") as f:
            return f.read()

    def alarms(self):
        try:
            with open(self.root + "/var/log/router/alarmy.log") as f:
                return f.read()
        except OSError:
            return ""

    def state(self):
        with open(self.root + "/var/lib/router/rpki.state.json") as f:
            return json.load(f)


class TestMode(Base):
    def test_default_status_is_preview_only(self):
        rc, out = self.rpki()
        self.assertEqual(rc, 0, out)
        self.assertIn("WYŁĄCZONE (tylko podgląd)", out)
        self.assertIn("VRP: IPv4 450000, IPv6 120000", out)

    def test_enable_and_disable(self):
        rc, out = self.rpki("enable")
        self.assertEqual(rc, 0, out)
        self.assertIn("define RPKI_ENFORCE = 1;", self.mode())
        self.assertIn("birdc configure", self.calls_text())
        self.assertIn("%RPKI-5-ENFORCE_ON", self.alarms())
        self.assertTrue(self.state()["enforce"])
        self.assertIn("już WŁĄCZONE", self.rpki("enable")[1])
        rc, out = self.rpki("disable")
        self.assertEqual(rc, 0, out)
        self.assertIn("define RPKI_ENFORCE = 0;", self.mode())
        self.assertIn("%RPKI-5-ENFORCE_OFF", self.alarms())

    def test_parse_error_changes_nothing(self):
        self.write(self.d + "/parse_fail", "")
        rc, out = self.rpki("enable")
        self.assertEqual(rc, 2, out)
        self.assertIn("define RPKI_ENFORCE = 0;", self.mode())
        self.assertNotIn("birdc configure", self.calls_text())

    def test_configure_error_restores_previous_mode(self):
        self.write(self.d + "/configure_fail", "")
        rc, out = self.rpki("enable")
        self.assertEqual(rc, 3, out)
        self.assertIn("define RPKI_ENFORCE = 0;", self.mode())
        self.assertNotIn("ENFORCE_ON", self.alarms())

    def test_enable_warns_when_validator_unreachable(self):
        self.write(self.d + "/proto", PROTO_DOWN)
        rc, out = self.rpki("enable")
        self.assertEqual(rc, 0, out)
        self.assertIn("nie ma teraz połączenia z walidatorem", out)


class TestInvalid(Base):
    def test_count_and_list(self):
        rc, out = self.rpki("invalid", "--count")
        self.assertEqual((rc, out.strip()), (0, "42"))
        rc, out = self.rpki("invalid", "t1_a")
        self.assertEqual(rc, 0, out)
        self.assertIn("birdc show route protocol t1_a where rpki_invalid()", self.calls_text())
        self.assertEqual(self.rpki("invalid", "zła;nazwa")[0], 2)

    def test_missing_function_is_reported(self):
        self.write(self.d + "/count", "BIRD 3.1.0 ready.\nsyntax error, unexpected CF_SYM_UNDEFINED\n")
        self.assertEqual(self.rpki("invalid", "--count")[0], 3)


class TestCheck(Base):
    def test_down_and_up_alarms_once(self):
        self.assertEqual(self.rpki("check", "--log")[0], 0)
        self.assertEqual(self.alarms(), "")
        self.write(self.d + "/validator", "failed\n")
        self.write(self.d + "/proto", PROTO_DOWN)
        self.assertEqual(self.rpki("check", "--log")[0], 1)
        self.assertEqual(self.rpki("check", "--log")[0], 1)
        self.assertEqual(self.alarms().count("%RPKI-3-DOWN"), 1)
        self.assertIn("Routinator nie działa", self.alarms())
        self.assertIn("przepuszcza wszystko", self.alarms())
        self.write(self.d + "/validator", "active\n")
        self.write(self.d + "/proto", PROTO_UP)
        self.assertEqual(self.rpki("check", "--log")[0], 0)
        self.assertIn("%RPKI-5-UP", self.alarms())
        st = self.state()
        self.assertEqual((st["invalid"], st["vrp4"], st["validator"], st["enforce"]), (42, 450000, True, False))

    def test_first_download_is_not_an_alarm_but_later_loss_is(self):
        empty = PROTO_UP.replace("450000 imported", "0 imported").replace("120000 imported", "0 imported")
        self.write(self.d + "/proto", empty)
        self.assertEqual(self.rpki("check", "--log")[0], 0)
        self.assertEqual(self.alarms(), "")
        self.write(self.d + "/proto", PROTO_UP)
        self.rpki("check", "--log")
        self.write(self.d + "/proto", empty)
        self.assertEqual(self.rpki("check", "--log")[0], 1)
        self.assertIn("%RPKI-3-DOWN", self.alarms())

    def test_json(self):
        self.rpki("check", "--log")
        d = json.loads(self.rpki("json")[1])
        self.assertEqual((d["ok"], d["invalid"], d["enforce"]), (True, 42, False))

    def test_help_has_author(self):
        self.assertIn("PHU VIPHOST", self.rpki("--help")[1])


if __name__ == "__main__":
    unittest.main()
