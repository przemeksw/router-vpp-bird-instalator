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
        self.assertEqual(mon.CFG["WK_PREEMPT"], 5.0)
        self.assertEqual(mon.CFG["WK_WINDOW"], 60)
        self.assertEqual(mon.CFG["SMI_PER_S"], 5.0)

    def test_input_nodes_from_show_runtime(self):
        rt = ("Thread 1 vpp_wk_0 (lcore 5)\n"
              "Time 10.0, 1.000000 sec internal node vector rate 1.22 loops/sec 2847774.90\n"
              "             Name                 State         Calls          Vectors        Suspends         Clocks       Vectors/Call\n"
              "dpdk-input                       polling         28477749          259720               0          1.23e3            .01\n"
              "ethernet-input                   active             85000          259720               0          1.10e2           3.05\n"
              "unix-epoll-input                 polling         28477749               0               0          2.00e1            0.00\n"
              "rdma-input                  interrupt wait              0               0               0          0.00e0            0.00\n")
        self.assertEqual(mon.input_nodes(rt), {"dpdk-input", "unix-epoll-input", "rdma-input"})

    def test_busy_from_nodes_low_mid_and_saturated(self):
        """lodz2-vpp 16.11 (wk_0): 3,1% czasu w grafie, 82,8% w odbiorze, graf w 0,3% obiegów → ~3,9%, a nie ~50%
        ze starej metody (1 − pętle/s ÷ wyuczone maksimum)."""
        inp = [True, False, False, True]
        self.assertEqual(mon.busy_from_nodes([900, 0, 0, 100], [1000, 0, 0, 1000], inp), 0.0)        # bez ruchu
        self.assertEqual(mon.busy_from_nodes([818, 16, 15, 10], [1000, 3, 3, 1000], inp), 3.9)
        self.assertEqual(mon.busy_from_nodes([400, 300, 300, 0], [1000, 500, 500, 1000], inp), 80.0)
        self.assertEqual(mon.busy_from_nodes([100, 500, 400, 0], [1000, 1000, 1000, 1000], inp), 100.0)  # pakiety w każdym obiegu
        self.assertEqual(mon.busy_from_nodes([10, 50, 40, 0], [10, 30, 30, 10], inp), 100.0)   # graf częściej niż obiegi: ucięte
        self.assertIsNone(mon.busy_from_nodes([5, 5, 5, 5], [0, 1, 1, 0], inp))               # brak obiegów

    def test_node_busy_from_stats_deltas(self):
        class St(dict):
            pass
        names = ["dpdk-input", "ethernet-input", "ip4-lookup"]
        calls = {"n": 0}

        def rt():
            calls["n"] += 1
            return "dpdk-input   polling  1 0 0 0 0\nethernet-input  active 1 1 0 0 1\n"
        nb = mon.NodeBusy(rt)
        st = St({"/sys/node/names": names,
                 "/sys/node/clocks": [[0, 0, 0], [1000, 0, 0], [5000, 100, 100]],
                 "/sys/node/calls": [[0, 0, 0], [100, 0, 0], [500, 0, 0]]})
        self.assertEqual(nb.sample(st, [1, 2], 0.0), [None, None])       # pierwsza próbka: brak przyrostu
        st["/sys/node/clocks"] = [[0, 0, 0], [2000, 0, 0], [5500, 350, 350]]
        st["/sys/node/calls"] = [[0, 0, 0], [200, 0, 0], [600, 50, 50]]
        self.assertEqual(nb.sample(st, [1, 2], 1.0), [0.0, 75.0])        # w = 500/1000, graf w 50% obiegów
        self.assertEqual(nb.sample(st, [1, 2], 2.0), [0.0, 75.0])        # statseg jeszcze nie odświeżył: ostatni wynik
        st["/sys/node/clocks"] = [[0, 0, 0], [10, 0, 0], [10, 0, 0]]     # restart VPP: liczniki od zera
        self.assertEqual(nb.sample(st, [1, 2], 3.0), [0.0, 75.0])
        self.assertEqual(calls["n"], 1)                                  # show runtime raz na instancję VPP
        nb.reset()
        self.assertEqual(nb.sample(St({}), [1], 4.0), [None])            # per-node-counters off
        self.assertIn("per-node-counters on", nb.note)

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
            "/sys/node/names": ["dpdk-input", "ethernet-input", "ip4-lookup"],
            "/sys/node/clocks": [[0, 0, 0], [n * 1000, 0, 0], [n * 400, n * 300, n * 300]],
            "/sys/node/calls": [[0, 0, 0], [n * 100, 0, 0], [n * 100, n * 50, n * 50]],
            "/if/rx": _Counter([0, n * 1000, n * 500]), "/if/tx": _Counter([0, n * 1000, n * 500]),
            "/if/rx-miss": _Counter([0, 0, 0]), "/if/rx-no-buf": _Counter([0, 0, 0]),
            "/if/punt": _Counter([0, 0, 0]),
        }[key]


class TestMissExplain(unittest.TestCase):
    """Przyczyna RX_MISS. VPP przepisuje rx-miss z karty co ~10 s (dpdk-process), więc strata mogła być do
    MISS_WINDOW s przed skokiem licznika — przyczyny szukamy w całym oknie, nie w ostatnich 3 s (lodz2-vpp 6.11:
    "SMI" i "burst" przypisywane przypadkiem, strata 435 tys. pakietów opisana jak burst jednego przepływu)."""

    def setUp(self):
        self.saved = mon.CFG["MISS_WINDOW"]
        mon.CFG["MISS_WINDOW"] = 13

    def tearDown(self):
        mon.CFG["MISS_WINDOW"] = self.saved

    def test_ring_capacity_from_startup_conf(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
            f.write("dpdk {\n  dev 0000:82:00.0 { name hu0 num-rx-queues 12 num-rx-desc 16384 num-tx-desc 4096"
                    " devargs rxq_pkt_pad_en=1,rxq_cqe_comp_en=0 }\n"
                    "  dev 0000:82:00.1 { name hu1 num-rx-queues 12 num-rx-desc 8192 }\n"
                    "  dev 0000:03:00.0 { name xe0 }\n}\n")
        # bez "ethernet { default-mtu }" VPP buduje kolejki dla MTU 9000: (9000 + 18) / 2048 B → 5 → 8 buforów na
        # pakiet (lodz2-vpp 6.11: rx burst mode Scalar), więc pierścień mieści 8× mniej pakietów niż deskryptorów
        self.assertEqual(mon.ring_capacity(f.name), {"hu0": 24576, "hu1": 12288})
        self.assertEqual(mon.ring_capacity(f.name + ".brak"), {})
        with open(f.name, "a") as g:
            g.write("buffers {\n  buffers-per-numa 262144\n  default data-size 2048\n}\nethernet {\n  default-mtu 1500\n}\n")
        self.assertEqual(mon.ring_capacity(f.name), {"hu0": 196608, "hu1": 98304})

    def test_ring_segments_per_packet(self):
        self.assertEqual(mon.rx_segments(9000, 2048), 8)
        self.assertEqual(mon.rx_segments(1500, 2048), 1)
        self.assertEqual(mon.rx_segments(4000, 2048), 2)
        self.assertEqual(mon.rx_segments(9000, 9216), 1)

    def test_nothing_in_window_is_single_flow_burst(self):
        why, ev = mon.explain_miss(100.0, {"hu0": 43}, [(95.0, 1.0, 0, 0)], {"hu0": 196608})
        self.assertIn("burst jednego przepływu", why)
        self.assertIn("bez SMI", why)
        self.assertIn("w ostatnich 13 s", ev)

    def test_smi_ten_seconds_before_counter_jump_is_found(self):
        hist = [(90.0, 1.0, 0, 1)] + [(90.0 + i, 1.0, 0, 0) for i in range(1, 11)]
        why, ev = mon.explain_miss(100.0, {"hu0": 300}, hist, {})
        self.assertIn("SMI", why)
        self.assertIn("SMI +1", ev)

    def test_events_older_than_window_are_ignored(self):
        why, _ev = mon.explain_miss(100.0, {"hu0": 300}, [(80.0, 200.0, 3, 2)], {})
        self.assertIn("burst jednego przepływu", why)

    def test_overload_then_preemption_take_precedence(self):
        why, _ = mon.explain_miss(100.0, {"hu0": 9}, [(95.0, 180.0, 2, 1)], {})
        self.assertIn("przeciążony (wektor 180)", why)
        why, _ = mon.explain_miss(100.0, {"hu0": 9}, [(95.0, 3.0, 2, 1)], {})
        self.assertIn("wywłaszczony", why)

    def test_loss_bigger_than_all_rings_is_a_stall_not_a_burst(self):
        why, _ = mon.explain_miss(100.0, {"hu0": 435200}, [(95.0, 1.0, 0, 0)], {"hu0": 196608})
        self.assertNotIn("burst", why)
        self.assertIn("wszystkie pierścienie RX", why)
        why, _ = mon.explain_miss(100.0, {"hu0": 435200}, [(95.0, 1.0, 0, 1)], {"hu0": 196608})
        self.assertIn("SMI", why)
        self.assertIn("wszystkie pierścienie RX", why)

    def test_smi_not_measured_is_not_claimed_absent(self):
        why, ev = mon.explain_miss(100.0, {"hu0": 43}, [(95.0, 1.0, 0, None)], {})
        self.assertNotIn("bez SMI", why)
        self.assertIn("SMI ?", ev)


class _MissStats(_FakeStats):
    """Jak _FakeStats, ale rx-miss na hu0 skacze o 1000 raz (jak licznik karty odświeżany przez VPP co ~10 s)."""

    def __getitem__(self, key):
        if key == "/if/rx-miss":
            _FakeStats.t += 1
            return _Counter([0, 1000 if _FakeStats.t > 20 else 0, 0])
        return super().__getitem__(key)


class TestMainLoop(unittest.TestCase):
    """Kilka obiegów prawdziwej pętli main() na sztucznym VPP: żadnego %VPP-2-DOWN z błędu w kodzie monitora
    (1.5.35: zmienna 'idle' nadpisana liczbą → "'int' object has no attribute 'learn'" co sekundę)."""

    def run_loop(self, stats_cls):
        import sys
        import tempfile
        import types
        from unittest import mock
        _FakeStats.t = 0
        tmp = tempfile.mkdtemp()
        papi = types.ModuleType("vpp_papi")
        stats_mod = types.ModuleType("vpp_papi.vpp_stats")
        stats_mod.VPPStats = stats_cls
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
                    mock.patch.object(mon, "runtime_text", lambda: "dpdk-input  polling 1 0 0 0 0\n"), \
                    mock.patch.object(mon, "PROC", tmp), mock.patch.object(mon, "SPOOL", tmp + "/spool"), \
                    mock.patch.object(mon, "STARTUP", tmp + "/startup.conf"), \
                    mock.patch.object(mon, "read_proc_stat", lambda: {}), \
                    mock.patch.object(mon, "emit", lambda fac, sev, mnem, msg, mail=True: emitted.append((mnem, msg))), \
                    mock.patch.object(mon.time, "sleep", fake_sleep), mock.patch.object(sys, "argv", ["router-monitor"]):
                with self.assertRaises(KeyboardInterrupt):
                    mon.main()
        finally:
            mon.CFG.update(saved)
        return tmp, emitted

    def test_rx_miss_reports_packets_and_window(self):
        _tmp, emitted = self.run_loop(_MissStats)
        miss = [m for n, m in emitted if n == "RX_MISS"]
        self.assertEqual(len(miss), 1, emitted)
        self.assertIn("hu0 1.0k pkt ", miss[0])          # pakiety od poprzedniego odczytu karty, nie pkt/s
        self.assertNotIn("pkt/s", miss[0].split(";")[0])
        self.assertIn("w ostatnich 13 s", miss[0])
        self.assertIn("burst jednego przepływu", miss[0])

    def test_loop_runs_without_internal_errors(self):
        tmp, emitted = self.run_loop(_FakeStats)
        self.assertEqual([e for e in emitted if e[0] in ("DOWN", "UP")], [])
        with open(tmp + "/state.json") as f:
            st = json.load(f)
        self.assertEqual(st["worker_busy"], [0.0, 80.0])             # worker 2: 60% cykli w grafie, graf w 50% obiegów
        self.assertEqual(st["worker_busy_max"], 80.0)
        self.assertEqual(st["alarms"], [])                         # bez zdarzeń: pusta lista aktywnych alarmów


if __name__ == "__main__":
    unittest.main(verbosity=1)
