#!/usr/bin/env python3
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
"""Testy router-kthreads: wątki kernela z dostępem do rdzeni VPP (kcompactd/kswapd) → rdzenie systemowe tego samego węzła."""
import importlib.machinery
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "router-kthreads")


def load():
    loader = importlib.machinery.SourceFileLoader("router_kthreads", SRC)
    spec = importlib.util.spec_from_loader("router_kthreads", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


kt = load()
PF_KTHREAD = 0x00200000


def fake_proc(root, pid, comm, cpu, allowed, kthread=True):
    d = os.path.join(root, str(pid))
    os.makedirs(d, exist_ok=True)
    flags = (0x00200040 if kthread else 0x00400100)
    fields = ["S", "2", "0", "0", "0", "-1", str(flags)] + ["0"] * 29 + [str(cpu), "0", "0"]
    with open(os.path.join(d, "stat"), "w") as f:
        f.write("%d (%s) %s\n" % (pid, comm, " ".join(fields)))
    with open(os.path.join(d, "status"), "w") as f:
        f.write("Name:\t%s\nPid:\t%d\nCpus_allowed_list:\t%s\n" % (comm, pid, allowed))


class TestPlan(unittest.TestCase):
    def test_cpulist_and_fmt(self):
        self.assertEqual(kt.cpulist("1,3,5-7"), {1, 3, 5, 6, 7})
        self.assertEqual(kt.fmt({1, 2, 3, 5, 29, 31}), "1-3,5,29,31")
        self.assertEqual(kt.cpulist(""), set())

    def test_node_affine_kthread_moves_to_hk_cores_of_same_node(self):
        present = set(range(40))
        isolated = {3, 5, 7, 9, 11}
        node1 = set(range(1, 40, 2))
        threads = [
            (344, "kcompactd1", 5, node1),             # cały węzeł 1, siedzi na rdzeniu workera
            (360, "kswapd1", 15, node1),               # cały węzeł 1, na razie na rdzeniu systemowym — i tak zawężamy
            (20, "ksoftirqd/5", 5, {5}),               # per-CPU: pomijany
            (21, "kworker/5:1-mm_percpu_wq", 5, {5}),  # per-CPU: pomijany
            (2, "kthreadd", 0, present),               # pełna maska, na rdzeniu systemowym: bez zmian (chyba że --all)
            (500, "vhost-1526", 7, present),           # pełna maska, ale STOI na izolowanym rdzeniu: przepiąć
            (343, "kcompactd0", 0, set(range(0, 40, 2))),   # węzeł 0 bez izolowanych rdzeni: bez zmian
        ]
        got = {pid: (old, new) for pid, _, old, new in kt.plan(threads, isolated, present)}
        self.assertEqual(set(got), {344, 360, 500})
        self.assertEqual(got[344][1], node1 - isolated)
        self.assertEqual(got[360][1], node1 - isolated)
        self.assertEqual(got[500][1], present - isolated)
        allp = {pid for pid, _, _, _ in kt.plan(threads, isolated, present, everything=True)}
        self.assertEqual(allp, {344, 360, 500, 2})

    def test_empty_intersection_falls_back_to_all_hk(self):
        present, isolated = set(range(8)), {2, 3}
        got = kt.plan([(9, "foo", 2, {2, 3})], isolated, present)
        self.assertEqual(got[0][3], present - isolated)


def fake_irq(proc, n, actions, affinity, effective=None):
    d = os.path.join(proc, "irq", str(n))
    os.makedirs(d, exist_ok=True)
    for a in actions:
        os.makedirs(os.path.join(d, a), exist_ok=True)
    with open(os.path.join(d, "smp_affinity_list"), "w") as f:
        f.write(affinity + "\n")
    if effective is not None:
        with open(os.path.join(d, "effective_affinity_list"), "w") as f:
            f.write(effective + "\n")


class TestProcScan(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.proc = os.path.join(self.tmp, "proc")
        self.sys = os.path.join(self.tmp, "sys")
        self.log = os.path.join(self.tmp, "alarmy.log")
        os.makedirs(os.path.join(self.sys, "devices", "system", "cpu"))
        with open(os.path.join(self.sys, "devices", "system", "cpu", "isolated"), "w") as f:
            f.write("3,5,7\n")
        with open(os.path.join(self.sys, "devices", "system", "cpu", "present"), "w") as f:
            f.write("0-9\n")
        fake_proc(self.proc, 1, "systemd", 0, "0-9", kthread=False)
        fake_proc(self.proc, 344, "kcompactd1", 5, "1,3,5,7,9")
        fake_proc(self.proc, 20, "ksoftirqd/5", 5, "5")
        fake_proc(self.proc, 1526, "vpp_main", 3, "3,5,7", kthread=False)   # proces użytkownika: nietykalny
        os.makedirs(os.path.join(self.proc, "self"))                          # nie-liczbowy wpis: pomijany
        fake_irq(self.proc, 33, ["mlx5_async@pci:0000:82:00.0"], "5")        # wektor na rdzeniu workera
        fake_irq(self.proc, 40, ["eth2-rx-0"], "0-2,4,6,8,9")                 # poprawny
        fake_irq(self.proc, 50, [], "0-9")                                    # bez sterownika: pomijany
        fake_irq(self.proc, 60, ["ahci[0000:00:1f.2]"], "0-9")                # pełna maska obejmuje izolowane → zawęzić
        fake_irq(self.proc, 70, ["mpt3sas0-msix5"], "5", effective="1")       # managed: kernel dostarcza na cpu 1 — OK
        self.env = dict(os.environ, ROUTER_KTHREADS_PROC=self.proc, ROUTER_KTHREADS_SYS=self.sys,
                        ROUTER_KTHREADS_LOG=self.log, ROUTER_KTHREADS_NOTIFY="/nonexistent/router-notify")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_kthreads_reads_only_kernel_threads(self):
        kt.PROC = self.proc
        got = {pid: (name, cpu, allowed) for pid, name, cpu, allowed in kt.kthreads()}
        self.assertEqual(set(got), {344, 20})
        self.assertEqual(got[344], ("kcompactd1", 5, {1, 3, 5, 7, 9}))

    def test_irqs_and_plan(self):
        kt.PROC = self.proc
        got = {n: (name, allowed) for n, name, allowed in kt.irqs()}
        self.assertEqual(set(got), {33, 40, 60, 70})
        self.assertEqual(got[70][1], {1})                                      # efektywna maska, nie deklarowana
        self.assertEqual(got[33], ("mlx5_async@pci:0000:82:00.0", {5}))
        plan = {n: new for n, _, _, new in kt.plan_irqs(kt.irqs(), {3, 5, 7}, set(range(10)))}
        self.assertEqual(plan, {33: {0, 1, 2, 4, 6, 8, 9}, 60: {0, 1, 2, 4, 6, 8, 9}})

    def test_dry_run_lists_and_returns_1(self):
        r = subprocess.run([sys.executable, "-I", SRC, "-n"], capture_output=True, text=True, env=self.env)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("kcompactd1", r.stdout)
        self.assertIn("1,3,5,7,9 → 1,9", r.stdout)
        self.assertIn("mlx5_async", r.stdout)
        self.assertIn("irq 33", r.stdout)
        self.assertNotIn("irq 40", r.stdout)
        self.assertNotIn("irq 50", r.stdout)
        self.assertNotIn("irq 70", r.stdout)                                   # wektor zarządzany: nie fałszywy alarm
        self.assertNotIn("ksoftirqd", r.stdout)
        self.assertNotIn("vpp_main", r.stdout)
        self.assertIn("do przepięcia: 3", r.stdout)

    def test_quiet_mode_fixes_irqs_and_logs_isol_fix(self):
        r = subprocess.run([sys.executable, "-I", SRC, "--quiet"], capture_output=True, text=True, env=self.env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout, "")
        with open(os.path.join(self.proc, "irq", "33", "smp_affinity_list")) as f:
            self.assertEqual(f.read().strip(), "0-2,4,6,8-9")
        with open(self.log) as f:
            log = f.read()
        self.assertIn("%SYS-4-ISOL_FIX", log)
        self.assertIn("irq 33 mlx5_async", log)
        self.assertIn("irq 60 ahci", log)
        # drugi przebieg: przerwania już czyste → bez nowego wpisu (wątek kcompactd bez roota/na macOS się nie przepnie)
        subprocess.run([sys.executable, "-I", SRC, "--quiet"], capture_output=True, text=True, env=self.env)
        with open(self.log) as f:
            self.assertEqual(f.read().count("ISOL_FIX"), 1)

    def test_no_isolated_cores_is_noop(self):
        with open(os.path.join(self.sys, "devices", "system", "cpu", "isolated"), "w") as f:
            f.write("\n")
        r = subprocess.run([sys.executable, "-I", SRC, "-n"], capture_output=True, text=True, env=self.env)
        self.assertEqual(r.returncode, 0)
        self.assertIn("brak izolowanych", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
