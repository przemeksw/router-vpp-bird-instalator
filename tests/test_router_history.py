#!/usr/bin/env python3
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
"""Testy router-history: lista zmian /etc z datami, podgląd pliku z przeszłości, diff, wyciągnięcie kopii,
przegląd interaktywny (na prawdziwym gicie, bez atrap) — bez roota, działa na macOS i Linuksie.

  python3 tests/test_router_history.py
"""
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("ROUTER_HISTORY_SRC") or os.path.join(HERE, "..", "build", "router-history")


class Base(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.root = os.path.join(self.d, "root")
        self.etc = os.path.join(self.root, "etc")
        os.makedirs(self.etc)
        self.git("init", "--quiet")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.git("config", "commit.gpgsign", "false")
        self.env = dict(os.environ, ROUTER_HISTORY_ROOT=self.root)
        # trzy wersje jednego pliku, każda innego dnia, i jedna zmiana w drugim pliku
        self.h1 = self.commit("router/firewall.conf", "zone internet\n", "m1: pierwsza wersja", 1735700000)
        self.h2 = self.commit("router/firewall.conf", "zone internet\nzone clients\n", "m2: dodano strefę", 1735800000)
        self.h3 = self.commit("router/ifaces.conf", "hu0 - - - Trunk\n", "m3: inny plik", 1735900000)
        self.h4 = self.commit("router/firewall.conf", "zone internet\nzone clients\nzone transit\n",
                               "m4: kolejna strefa", 1736000000)

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def git(self, *args):
        subprocess.run(["git", "-C", self.etc] + list(args), check=True, capture_output=True, text=True)

    def commit(self, path, content, message, ts):
        full = os.path.join(self.etc, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(content)
        env = dict(os.environ, GIT_AUTHOR_DATE="@%d +0000" % ts, GIT_COMMITTER_DATE="@%d +0000" % ts)
        subprocess.run(["git", "-C", self.etc, "add", path], check=True, capture_output=True, text=True)
        subprocess.run(["git", "-C", self.etc, "commit", "-m", message, "--quiet"], check=True, env=env)
        p = subprocess.run(["git", "-C", self.etc, "log", "-1", "--pretty=format:%H"], capture_output=True, text=True,
                            check=True)
        return p.stdout.strip()

    def run_history(self, *args, input_text=None):
        p = subprocess.run([sys.executable, SRC] + list(args), env=self.env, input=input_text, capture_output=True,
                            text=True, timeout=30)
        return p.returncode, p.stdout + p.stderr


class TestLog(Base):
    def test_log_without_path_lists_all_files_newest_first(self):
        rc, out = self.run_history("log")
        self.assertEqual(rc, 0, out)
        lines = [l for l in out.splitlines() if l.strip()]
        self.assertEqual(len(lines), 4, out)
        self.assertIn("m4: kolejna strefa", lines[0])
        self.assertIn("m1: pierwsza wersja", lines[3])
        self.assertIn(self.h4[:7], lines[0])

    def test_log_with_path_filters_to_that_file_only(self):
        rc, out = self.run_history("log", "router/firewall.conf")
        self.assertEqual(rc, 0, out)
        lines = [l for l in out.splitlines() if l.strip()]
        self.assertEqual(len(lines), 3, out)                               # bez m3 (inny plik)
        self.assertNotIn("m3: inny plik", out)

    def test_log_accepts_absolute_and_etc_prefixed_paths(self):
        rc1, out1 = self.run_history("log", "/etc/router/firewall.conf")
        rc2, out2 = self.run_history("log", self.etc + "/router/firewall.conf")
        self.assertEqual((rc1, rc2), (0, 0), (out1, out2))
        self.assertEqual(out1, out2)
        self.assertIn("m4: kolejna strefa", out1)

    def test_no_git_repo_reports_error_not_crash(self):
        empty = os.path.join(self.d, "puste")
        os.makedirs(os.path.join(empty, "etc"))
        env = dict(self.env, ROUTER_HISTORY_ROOT=empty)
        p = subprocess.run([sys.executable, SRC, "log"], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(p.returncode, 1)
        self.assertIn("Brak historii", p.stdout + p.stderr)
        self.assertNotIn("Traceback", p.stdout + p.stderr)


class TestShowAndDiff(Base):
    def test_show_returns_file_content_at_that_commit(self):
        rc, out = self.run_history("show", self.h1, "router/firewall.conf")
        self.assertEqual(rc, 0, out)
        self.assertEqual(out, "zone internet\n")

    def test_show_latest_matches_current_file(self):
        rc, out = self.run_history("show", self.h4, "router/firewall.conf")
        self.assertEqual(rc, 0, out)
        self.assertEqual(out, "zone internet\nzone clients\nzone transit\n")

    def test_show_unknown_commit_reports_error(self):
        rc, out = self.run_history("show", "0" * 40, "router/firewall.conf")
        self.assertEqual(rc, 1, out)
        self.assertIn("nie można odczytać", out)

    def test_diff_shows_added_line(self):
        rc, out = self.run_history("diff", self.h2, "router/firewall.conf")
        self.assertEqual(rc, 0, out)
        self.assertIn("+zone clients", out)

    def test_diff_for_commit_not_touching_file_says_so(self):
        rc, out = self.run_history("diff", self.h3, "router/firewall.conf")
        self.assertEqual(rc, 0, out)
        self.assertIn("nie zmienił", out)

    def test_missing_arguments_show_usage(self):
        rc, out = self.run_history("show", self.h1)
        self.assertEqual(rc, 2, out)
        self.assertIn("użycie", out)


class TestExtract(Base):
    @staticmethod
    def extracted_path(out):
        return out.split("zapisano:", 1)[1].splitlines()[0].strip()

    def test_extract_writes_copy_named_with_date_and_hash(self):
        outdir = os.path.join(self.d, "kopie")
        rc, out = self.run_history("extract", self.h2, "router/firewall.conf", outdir)
        self.assertEqual(rc, 0, out)
        self.assertIn("zapisano:", out)
        dest = self.extracted_path(out)
        self.assertTrue(dest.startswith(outdir))
        self.assertTrue(os.path.basename(dest).startswith("firewall.conf."))
        self.assertIn(self.h2[:7], os.path.basename(dest))
        with open(dest) as f:
            self.assertEqual(f.read(), "zone internet\nzone clients\n")
        # oryginał w /etc zostaje nietknięty (ostatnia wersja, nie ta wyciągnięta)
        with open(os.path.join(self.etc, "router/firewall.conf")) as f:
            self.assertEqual(f.read(), "zone internet\nzone clients\nzone transit\n")

    def test_extract_default_directory_when_not_given(self):
        rc, out = self.run_history("extract", self.h1, "router/firewall.conf")
        self.assertEqual(rc, 0, out)
        dest = self.extracted_path(out)
        self.assertTrue(dest.startswith(os.path.join(self.root, "root", "router-kopie")))

    def test_extract_file_and_new_directory_are_locked_down(self):
        outdir = os.path.join(self.d, "kopie-prywatne")
        rc, out = self.run_history("extract", self.h2, "router/firewall.conf", outdir)
        self.assertEqual(rc, 0, out)
        dest = self.extracted_path(out)
        self.assertEqual(stat_mode_bits(dest), 0o600)                      # kopia: tylko właściciel
        self.assertEqual(stat_mode_bits(outdir), 0o700)                    # nowy katalog: tylko właściciel

    def test_extract_does_not_tighten_a_preexisting_directory(self):
        outdir = os.path.join(self.d, "juz-istniejacy")
        os.makedirs(outdir, mode=0o755)
        os.chmod(outdir, 0o755)                                            # makedirs honoruje umask, wymuś 0755
        rc, _out = self.run_history("extract", self.h2, "router/firewall.conf", outdir)
        self.assertEqual(rc, 0)
        self.assertEqual(stat_mode_bits(outdir), 0o755)                    # katalog zastany — nietknięty

    def test_extract_refuses_world_writable_directory_without_sticky_bit(self):
        outdir = os.path.join(self.d, "wspolny")
        os.makedirs(outdir)
        os.chmod(outdir, 0o777)                                            # world-writable, bez sticky bitu
        rc, out = self.run_history("extract", self.h2, "router/firewall.conf", outdir)
        self.assertEqual(rc, 1, out)
        self.assertIn("wpisywalny przez innych", out)
        self.assertEqual(os.listdir(outdir), [])                           # niczego nie zapisano

    def test_extract_allows_world_writable_directory_with_sticky_bit(self):
        outdir = os.path.join(self.d, "tmp-jak")
        os.makedirs(outdir)
        os.chmod(outdir, 0o777 | stat.S_ISVTX)                             # jak /tmp
        rc, out = self.run_history("extract", self.h2, "router/firewall.conf", outdir)
        self.assertEqual(rc, 0, out)


def stat_mode_bits(path):
    return stat.S_IMODE(os.stat(path).st_mode)


class TestUnknownCommand(Base):
    def test_unknown_subcommand(self):
        rc, out = self.run_history("frobnicate")
        self.assertEqual(rc, 2, out)
        self.assertIn("nieznane polecenie", out)

    def test_help_and_version(self):
        rc, out = self.run_history("--help")
        self.assertEqual(rc, 0, out)
        self.assertIn("router-history", out)
        rc, out = self.run_history("--version")
        self.assertEqual(rc, 0, out)


class TestInteractiveMenu(Base):
    def test_menu_lists_files_then_dates_then_shows_preview(self):
        # przegląd bez argumentów: wybór pliku (1 = ostatnio zmieniany), wybór zmiany (1 = najnowsza), podgląd, wyjście
        rc, out = self.run_history(input_text="1\n1\np\n\n\n")
        self.assertEqual(rc, 0, out)
        self.assertIn("Ostatnio zmieniane pliki", out)
        self.assertIn("router/firewall.conf", out)
        self.assertIn("m4: kolejna strefa", out)                           # najnowsza zmiana tego pliku
        self.assertIn("zone internet\nzone clients\nzone transit", out)    # podgląd treści

    def test_menu_extract_prompts_for_directory(self):
        outdir = os.path.join(self.d, "wyciag")
        rc, out = self.run_history(input_text="1\n1\ne\n%s\n\n\n" % outdir)
        self.assertEqual(rc, 0, out)
        self.assertIn("zapisano:", out)
        created = [f for f in os.listdir(outdir)] if os.path.isdir(outdir) else []
        self.assertEqual(len(created), 1, out)

    def test_menu_empty_history_reports_clearly(self):
        empty = os.path.join(self.d, "drugi", "etc")
        os.makedirs(empty)
        subprocess.run(["git", "-C", empty, "init", "--quiet"], check=True)
        subprocess.run(["git", "-C", empty, "config", "user.email", "test@example.com"], check=True)
        subprocess.run(["git", "-C", empty, "config", "user.name", "Test"], check=True)
        env = dict(self.env, ROUTER_HISTORY_ROOT=os.path.dirname(empty))
        p = subprocess.run([sys.executable, SRC], env=env, input="", capture_output=True, text=True, timeout=10)
        self.assertEqual(p.returncode, 0)
        self.assertIn("pusta", p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
