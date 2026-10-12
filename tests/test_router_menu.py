#!/usr/bin/env python3
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
"""Testy polecenia `router` (menu zarządzania): nawigacja numerami, parametry, potwierdzenia, pliki konfiguracyjne.

  python3 tests/test_router_menu.py            (bez roota i bez VPP; narzędzia zastąpione atrapami)
"""
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "build", "router")
INSTALLER = os.path.join(HERE, "..", "install-router.sh")
TOOLS = ("router-ifaces", "router-fw", "router-guard", "router-top", "router-notify", "install-router",
         "install-uefi-mdadm", "router-fw-update", "birdc", "vppctl", "systemctl", "tail", "git", "bash", "ss", "ip")


class Base(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.bin = os.path.join(self.d, "bin")
        os.makedirs(self.bin)
        self.log = os.path.join(self.d, "calls.log")
        for t in TOOLS:
            p = os.path.join(self.bin, t)
            with open(p, "w") as f:
                f.write('#!/bin/sh\necho "FAKE $(basename "$0") $*" >> "%s"\necho "FAKE $(basename "$0") $*"\n' % self.log)
            os.chmod(p, 0o755)
        self.env = dict(os.environ, ROUTER_MENU_BIN=self.bin, ROUTER_MENU_ROOT=self.d, TERM="dumb", NO_COLOR="1")

    def run_menu(self, keys, *args):
        r = subprocess.run([sys.executable, SRC] + list(args), env=self.env, input=keys, capture_output=True, text=True,
                           timeout=20)
        return r.returncode, r.stdout + r.stderr

    def calls(self):
        try:
            with open(self.log) as f:
                return f.read().splitlines()
        except OSError:
            return []


class TestMenu(Base):
    def test_main_menu_lists_areas_with_numbers(self):
        rc, out = self.run_menu("q\n")
        self.assertEqual(rc, 0, out)
        for want in ("1  Interfejsy", "2  Firewall", "3  Ochrona przed odbiciami", "Pliki konfiguracyjne", "q  Wyjście"):
            self.assertIn(want, out)
        nums = re.findall(r"^\s{1,3}(\d)\s{2}", out, re.M)
        self.assertEqual(nums, [str(i) for i in range(1, len(nums) + 1)])           # kolejne numery bez dziur
        self.assertGreaterEqual(len(nums), 8)
        self.assertIn("PHU VIPHOST Przemysław Świderski <biuro@viphost.it>", out)           # autor w menu głównym

    def test_submenu_shows_description_and_command_for_each_action(self):
        rc, out = self.run_menu("1\n0\nq\n")
        self.assertEqual(rc, 0, out)
        self.assertIn("1  Pokaż interfejsy", out)
        self.assertIn("2  Podgląd zmian", out)
        self.assertIn("router-ifaces diff", out)                                     # wywołanie pod opisem
        self.assertIn("/etc/router/ifaces.conf", out)                                # plik konfiguracyjny obszaru
        self.assertEqual(self.calls(), [])                                           # samo wejście niczego nie uruchamia

    def test_read_action_runs_the_tool(self):
        rc, out = self.run_menu("1\n2\n\n0\nq\n")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.calls(), ["FAKE router-ifaces diff"])
        self.assertIn("router-ifaces diff", out)

    def test_write_action_shows_preview_and_asks(self):
        rc, out = self.run_menu("1\n3\nn\n\n0\nq\n")                                 # Zastosuj → podgląd → „n”
        self.assertEqual(self.calls(), ["FAKE router-ifaces diff"], out)
        self.assertIn("Przerwano", out)
        self.log_reset()
        rc, out = self.run_menu("1\n3\nt\n\n0\nq\n")
        self.assertEqual(self.calls(), ["FAKE router-ifaces diff", "FAKE router-ifaces apply -y"], out)

    def log_reset(self):
        if os.path.exists(self.log):
            os.remove(self.log)

    def test_parameters_are_prompted_and_validated(self):
        # Firewall → Zablokuj adres: puste = ponowne pytanie, potem adres i czas
        rc, out = self.run_menu("2\n%s\n\n198.51.100.7\n2h\n\n0\nq\n" % self.action_number("2", "Zablokuj adres"))
        self.assertEqual(rc, 0, out)
        self.assertIn("wymagane", out)
        self.assertEqual(self.calls(), ["FAKE router-fw block 198.51.100.7 2h"], out)

    def test_optional_parameter_can_be_skipped(self):
        rc, out = self.run_menu("2\n%s\n198.51.100.7\n\n\n0\nq\n" % self.action_number("2", "Zablokuj adres"))
        self.assertEqual(self.calls(), ["FAKE router-fw block 198.51.100.7"], out)

    def test_guard_on_with_flags(self):
        n = self.action_number("3", "Włącz ochronę z przejściem na enforce")
        rc, out = self.run_menu("3\n%s\nweb\n2h\n\n0\nq\n" % n)
        self.assertEqual(self.calls(), ["FAKE router-guard on web --enforce --for 2h"], out)

    def test_firewall_apply_with_auto_rollback_uses_seconds_parameter(self):
        n = self.action_number("2", "automatycznym cofnięciem")
        rc, out = self.run_menu("2\n%s\n90\nt\n\n0\nq\n" % n)
        self.assertEqual(self.calls(), ["FAKE router-fw diff", "FAKE router-fw apply -y --confirm 90"], out)

    def test_invalid_choice_is_reported(self):
        rc, out = self.run_menu("99\nx\nq\n")
        self.assertEqual(rc, 0, out)
        self.assertGreaterEqual(out.count("Nieprawidłowy wybór"), 2)

    def test_eof_and_ctrl_c_leave_cleanly(self):
        rc, out = self.run_menu("")
        self.assertEqual(rc, 0, out)
        self.assertNotIn("Traceback", out)
        rc, out = self.run_menu("1\n")
        self.assertEqual(rc, 0, out)
        self.assertNotIn("Traceback", out)

    def action_number(self, area, title_part):
        """Numer akcji w podmenu obszaru (wyciągnięty z wypisanego menu, więc test nie zależy od kolejności)."""
        _rc, out = self.run_menu("%s\n0\nq\n" % area)
        for m in re.finditer(r"^\s{1,3}(\d+)\s{2}(.*)$", out, re.M):
            if title_part in m.group(2):
                return m.group(1)
        self.fail("brak akcji '%s' w obszarze %s:\n%s" % (title_part, area, out))


class TestWorkersAction(Base):
    def test_changing_worker_count_prompts_previews_and_confirms(self):
        _rc, out = self.run_menu("8\n0\nq\n")
        n = next(mm.group(1) for mm in re.finditer(r"^\s{1,3}(\d+)\s{2}(.*)$", out, re.M) if "Zmień liczbę workerów" in mm.group(2))
        self.assertIn("install-router set_workers LICZBA", out)
        rc, out = self.run_menu("8\n%s\n16\nt\n\n0\nq\n" % n)
        self.assertEqual(self.calls(), ["FAKE install-router set_workers 16 --dry-run", "FAKE install-router set_workers 16 --yes"], out)

    def test_declined_change_does_nothing_but_the_preview(self):
        _rc, out = self.run_menu("8\n0\nq\n")
        n = next(mm.group(1) for mm in re.finditer(r"^\s{1,3}(\d+)\s{2}(.*)$", out, re.M) if "Zmień liczbę workerów" in mm.group(2))
        self.run_menu("8\n%s\n16\nn\n\n0\nq\n" % n)
        self.assertEqual(self.calls(), ["FAKE install-router set_workers 16 --dry-run"])

    def test_layout_action_shows_current_and_maximum(self):
        _rc, out = self.run_menu("8\n0\nq\n")
        n = next(mm.group(1) for mm in re.finditer(r"^\s{1,3}(\d+)\s{2}(.*)$", out, re.M) if "Układ rdzeni" in mm.group(2))
        self.run_menu("8\n%s\n\n0\nq\n" % n)
        self.assertEqual(self.calls(), ["FAKE install-router set_workers --dry-run"])


class TestFilesAndCli(Base):
    def test_files_screen_lists_every_config_file_with_its_tool(self):
        rc, out = self.run_menu("", "files")
        self.assertEqual(rc, 0, out)
        for path, tool in (("/etc/router/ifaces.conf", "router-ifaces"), ("/etc/router/firewall.conf", "router-fw"),
                           ("/etc/router/synack-guard.conf", "router-guard"), ("/etc/router/notify.conf", "router-notify"),
                           ("/etc/router/router-monitor.conf", "router-monitor"), ("/etc/vpp/startup.conf", "VPP"),
                           ("/etc/bird/bird.conf", "BIRD"), ("/etc/snmp/snmpd.conf", "snmpd"),
                           ("/etc/hsflowd.conf", "hsflowd"), ("/etc/ssh/sshd_config_dataplane", "sshd")):
            self.assertIn(path, out)
            line = [l for l in out.splitlines() if path in l]
            self.assertTrue(line and tool in "\n".join(self.block(out, path)), (path, tool))

    def block(self, out, path):
        lines = out.splitlines()
        i = next(k for k, l in enumerate(lines) if path in l)
        return lines[i:i + 4]

    def test_files_filtered_by_area(self):
        rc, out = self.run_menu("", "files", "fw")
        self.assertIn("/etc/router/firewall.conf", out)
        self.assertNotIn("/etc/router/ifaces.conf", out)

    def test_every_registered_path_exists_in_the_installer(self):
        rc, out = self.run_menu("", "files")
        with open(INSTALLER, encoding="utf-8") as f:
            text = f.read()
        paths = set(re.findall(r"(/(?:etc|var|opt|usr)/[\w./\-*]+)", out))
        self.assertGreater(len(paths), 15)
        missing = []
        for p in sorted(paths):
            base = p.rstrip("*").rstrip("/")
            if "*" in p:
                base = p.split("*")[0].rstrip("/")
            if base not in text:
                missing.append(p)
        self.assertEqual(missing, [])

    def test_passthrough_runs_the_tool_directly(self):
        rc, out = self.run_menu("", "ifaces", "diff")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.calls(), ["FAKE router-ifaces diff"])
        self.log_reset()
        rc, out = self.run_menu("", "guard", "on", "web", "--monitor")
        self.assertEqual(self.calls(), ["FAKE router-guard on web --monitor"])

    def log_reset(self):
        if os.path.exists(self.log):
            os.remove(self.log)

    def test_unknown_command_and_help(self):
        rc, out = self.run_menu("", "nieistnieje")
        self.assertEqual(rc, 2, out)
        rc, out = self.run_menu("", "help")
        self.assertEqual(rc, 0, out)
        for want in ("ifaces", "fw", "guard", "files"):
            self.assertIn(want, out)

    def test_missing_tool_is_reported_not_crashed(self):
        os.remove(os.path.join(self.bin, "router-ifaces"))
        self.env["PATH"] = os.path.join(self.d, "pusty")
        rc, out = self.run_menu("1\n2\n\n0\nq\n")
        self.assertEqual(rc, 0, out)
        self.assertNotIn("Traceback", out)
        self.assertIn("nie znaleziono", out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
