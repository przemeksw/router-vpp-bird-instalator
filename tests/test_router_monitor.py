#!/usr/bin/env python3
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
"""Testy filtra alarmy.log w router-monitor: w pliku tylko ostrzeżenia i groźniejsze (plus zakończenia alarmów)."""
import importlib.machinery
import importlib.util
import json
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


def fake_task(base, tid, comm, cpu, invol=None, ticks=0):
    """Wątek w sztucznym /proc: comm, stat (pole 14 = utime, 39 = procesor), sched (nr_involuntary_switches)."""
    d = os.path.join(base, str(tid))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "comm"), "w") as f:
        f.write(comm + "\n")
    fields = ["S", "1", "1", "1", "0", "-1", "4194560"] + ["0"] * 29 + [str(cpu), "0", "0"]
    fields[11] = str(ticks)
    with open(os.path.join(d, "stat"), "w") as f:
        f.write("%d (%s) %s\n" % (tid, comm, " ".join(fields)))
    if invol is not None:
        with open(os.path.join(d, "sched"), "w") as f:
            f.write("%s (%d, #threads: 1)\nnr_switches                 :  %d\nnr_voluntary_switches       :  0\n"
                    "nr_involuntary_switches     :  %d\n" % (comm, tid, invol, invol))


class TestWorkerPreempt(unittest.TestCase):
    """Wywłaszczenia workerów: PID VPP po nazwie wątku, liczniki z /proc/<pid>/task, kto siedzi na rdzeniu."""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp()
        self.saved = mon.PROC
        mon.PROC = self.tmp
        fake_task(self.tmp, 1, "systemd", 0)
        fake_task(self.tmp, 1526, "vpp_main", 3)
        fake_task(self.tmp, 1526, "vpp_main", 3)
        tasks = os.path.join(self.tmp, "1526", "task")
        fake_task(tasks, 1526, "vpp_main", 3, 1203, ticks=50)
        fake_task(tasks, 1644, "vpp_wk_0", 5, 21991, ticks=1000)
        fake_task(tasks, 1645, "vpp_wk_1", 7, 2, ticks=1000)
        fake_task(tasks, 1650, "dpdk-intr", 3, 0)
        for pid, comm, cpu in ((344, "kcompactd1", 5), (20, "ksoftirqd/5", 5), (21, "kworker/5:1-mm_percpu_wq", 5),
                               (22, "kworker/15:0-events", 5), (900, "bird", 35)):
            fake_task(self.tmp, pid, comm, cpu)
            fake_task(os.path.join(self.tmp, str(pid), "task"), pid, comm, cpu, ticks=30)
        fake_task(os.path.join(self.tmp, "900", "task"), 901, "bird", 37, ticks=20)   # drugi wątek BIRD

    def test_proc_cpu_skips_threads_on_isolated_cores(self):
        procs = mon.read_proc_cpu({5, 7})
        self.assertEqual(procs[1526], ("vpp_main", 50))      # bez workerów (2 × 1000 ticków)
        self.assertEqual(procs[900], ("bird", 50))           # suma wątków procesu
        self.assertEqual(mon.read_proc_cpu()[1526], ("vpp_main", 2050))
        prev = {1526: ("vpp_main", 0), 900: ("bird", 0)}
        top = mon.top_procs(prev, procs, 1.0)
        self.assertTrue(top.startswith("vpp_main(1526)") or top.startswith("bird(900)"), top)

    def tearDown(self):
        import shutil
        mon.PROC = self.saved
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_find_vpp_pid_by_thread_name(self):
        self.assertEqual(mon.find_vpp_pid(), 1526)

    def test_read_worker_preempt(self):
        self.assertEqual(mon.read_worker_preempt(1526), {0: (5, 21991), 1: (7, 2)})

    def test_tasks_on_cpu_skips_vpp_and_percpu_kthreads(self):
        # ksoftirqd/5 i kworker/5:… to stałe wątki tego rdzenia; kworker/15:0 na cpu 5 to już obcy
        self.assertEqual(mon.tasks_on_cpu(5, 1526), "kcompactd1, kworker/15:0-events")
        self.assertEqual(mon.tasks_on_cpu(35, 1526), "bird")

    def test_alarm_category_and_threshold(self):
        self.assertEqual(mon.CFG["WK_PREEMPT"], 1.0)
        self.assertEqual(mon.CFG["SMI_PER_S"], 5.0)

    def test_idle_loops_learning_and_busy(self):
        path = os.path.join(self.tmp, "idle", "vpp-idle-loops.json")
        il = mon.IdleLoops(path)
        self.assertIsNone(il.busy(1, 1000))                     # nic nie zmierzone: nieznane, nie 0%
        il.learn([0.0, 1.0, 50.0], [100, 4000000, 20000])       # worker 2 pod obciążeniem: nie uczy się
        self.assertEqual(il.busy(1, 2000000), 50.0)
        self.assertEqual(il.busy(2, 1000000), 75.0)              # mediana innych workerów (4 M)
        il.learn([0.0, 1.0, 1.0], [100, 3000000, 4200000])      # mniejsza wartość nie obniża maksimum
        self.assertEqual(il.base(1), 4000000)
        self.assertEqual(il.busy(2, 0), 100.0)
        il.save()
        self.assertEqual(mon.IdleLoops(path).base(2), 4200000)  # przetrwa restart router-monitor
        il2 = mon.IdleLoops(path)
        il2.learn([0.0, 1.0], [100, 3900000])                   # inna liczba wątków: od nowa
        self.assertEqual(il2.idle, [100.0, 3900000.0])

    def test_read_smi_from_msr(self):
        dev = os.path.join(self.tmp, "dev")
        for cpu, count in ((5, 17), (7, 0)):
            os.makedirs(os.path.join(dev, "cpu", str(cpu)))
            with open(os.path.join(dev, "cpu", str(cpu), "msr"), "wb") as f:
                f.write(b"\0" * mon.MSR_SMI_COUNT + count.to_bytes(8, "little"))
        saved = mon.DEV
        mon.DEV = dev
        try:
            self.assertEqual(mon.read_smi([5, 7, 9]), {5: 17, 7: 0})     # cpu 9 bez pliku msr: pomijany
            mon.DEV = os.path.join(self.tmp, "nodev")
            self.assertEqual(mon.read_smi([5]), {})                       # brak modułu msr / AMD: pusto, bez wyjątku
        finally:
            mon.DEV = saved


class _Col:
    """Kolumna licznika VPP: rx[:, i].sum_packets() / .sum_octets() / .sum()."""
    def __init__(self, v):
        self.v = v

    def sum_packets(self):
        return self.v

    def sum_octets(self):
        return self.v * 1000

    def sum(self):
        return self.v


class _Counter:
    def __init__(self, vals):
        self.vals = vals

    def __getitem__(self, key):
        return _Col(self.vals[key[1]])


class _FakeStats:
    """Segment statystyk VPP z rosnącymi licznikami — każde wywołanie to kolejna sekunda."""
    t = 0

    def __init__(self, socketname=None, timeout=None):
        pass

    def connect(self):
        pass

    def ls(self, _patterns):
        return []

    def __getitem__(self, key):
        _FakeStats.t += 1
        n = _FakeStats.t
        return {
            "/sys/heartbeat": n,
            "/if/names": ["local0", "hu0", "hu1"],
            "/sys/vector_rate_per_worker": [[0.0, 1.0, 3.0]],
            "/sys/loops_per_worker": [[100000.0, 4000000.0, 2000000.0]],
            "/if/rx": _Counter([0, n * 1000, n * 500]), "/if/tx": _Counter([0, n * 1000, n * 500]),
            "/if/rx-miss": _Counter([0, 0, 0]), "/if/rx-no-buf": _Counter([0, 0, 0]),
            "/if/punt": _Counter([0, 0, 0]),
        }[key]


class TestMainLoop(unittest.TestCase):
    """Kilka obiegów prawdziwej pętli main() na sztucznym VPP: żadnego %VPP-2-DOWN z błędu w kodzie monitora
    (1.5.35: zmienna 'idle' nadpisana liczbą → "'int' object has no attribute 'learn'" co sekundę)."""

    def test_loop_runs_without_internal_errors(self):
        import sys
        import tempfile
        import types
        from unittest import mock
        tmp = tempfile.mkdtemp()
        papi = types.ModuleType("vpp_papi")
        stats_mod = types.ModuleType("vpp_papi.vpp_stats")
        stats_mod.VPPStats = _FakeStats
        papi.vpp_stats = stats_mod
        saved = {k: mon.CFG[k] for k in ("LOGFILE", "STATEFILE", "ENVFILE", "XSTATS_EVERY", "MD_EVERY", "SMI_PER_S")}
        mon.CFG.update(LOGFILE=tmp + "/alarmy.log", STATEFILE=tmp + "/state.json", ENVFILE=tmp + "/router.env",
                       XSTATS_EVERY=0, MD_EVERY=10 ** 9, SMI_PER_S=0)
        emitted = []
        loops = {"n": 0}

        def fake_sleep(_s):
            loops["n"] += 1
            if loops["n"] >= 4:
                raise KeyboardInterrupt

        try:
            with mock.patch.dict(sys.modules, {"vpp_papi": papi, "vpp_papi.vpp_stats": stats_mod}), \
                    mock.patch.object(mon, "IDLE_FILE", tmp + "/idle.json"), \
                    mock.patch.object(mon, "PROC", tmp), mock.patch.object(mon, "SPOOL", tmp + "/spool"), \
                    mock.patch.object(mon, "read_proc_stat", lambda: {}), \
                    mock.patch.object(mon, "emit", lambda fac, sev, mnem, msg, mail=True: emitted.append((mnem, msg))), \
                    mock.patch.object(mon.time, "sleep", fake_sleep), mock.patch.object(sys, "argv", ["router-monitor"]):
                with self.assertRaises(KeyboardInterrupt):
                    mon.main()
        finally:
            mon.CFG.update(saved)
        self.assertEqual([e for e in emitted if e[0] in ("DOWN", "UP")], [])
        with open(tmp + "/state.json") as f:
            st = json.load(f)
        self.assertEqual(st["worker_busy"], [0.0, 50.0])             # worker 2: 2 M z 4 M pętli (mediana luzu)
        self.assertEqual(st["worker_busy_max"], 50.0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
