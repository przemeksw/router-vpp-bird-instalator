#!/usr/bin/env python3
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
"""Testy filtra alarmy.log w router-monitor: w pliku tylko ostrzeżenia i groźniejsze (plus zakończenia alarmów)."""
import importlib.machinery
import importlib.util
import logging
import os
import unittest

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "router-monitor")


def load():
    loader = importlib.machinery.SourceFileLoader("router_monitor", SRC)
    spec = importlib.util.spec_from_loader("router_monitor", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


mon = load()


class TestAlarmLogFilter(unittest.TestCase):
    def setUp(self):
        self.saved = mon.CFG["LOG_MAX_SEV"]

    def tearDown(self):
        mon.CFG["LOG_MAX_SEV"] = self.saved

    def test_default_keeps_only_warnings_and_worse(self):
        self.assertEqual(mon.CFG["LOG_MAX_SEV"], 4)
        for sev in (1, 2, 3, 4):
            self.assertTrue(mon.alarm_log_allowed(sev, "LOAD_HIGH"), sev)
        for sev, mnem in ((5, "START"), (5, "SCRIPTS_UPGRADED"), (6, "STATS"), (5, "BOOT_OK")):
            self.assertFalse(mon.alarm_log_allowed(sev, mnem), (sev, mnem))

    def test_alarm_endings_are_kept_so_durations_stay_visible(self):
        for mnem in ("LOAD_NORMAL", "RX_MISS_END", "RECOVERED", "UP"):
            self.assertTrue(mon.alarm_log_allowed(5, mnem), mnem)

    def test_threshold_is_configurable(self):
        mon.CFG["LOG_MAX_SEV"] = 6
        self.assertTrue(mon.alarm_log_allowed(6, "STATS"))

    def test_file_handler_filter_uses_record_attributes(self):
        f = mon.AlarmFilter()
        mk = lambda sev, mnem: logging.LogRecord("x", logging.INFO, "", 0, "m", None, None, extra=None) or None  # noqa: E731
        rec = logging.LogRecord("x", logging.INFO, "", 0, "%s", ("l",), None)
        rec.sev, rec.mnem = 5, "START"
        self.assertFalse(f.filter(rec))
        rec.sev, rec.mnem = 2, "RX_MISS"
        self.assertTrue(f.filter(rec))
        del mk


if __name__ == "__main__":
    unittest.main(verbosity=1)
