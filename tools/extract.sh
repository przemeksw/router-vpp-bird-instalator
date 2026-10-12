#!/usr/bin/env bash
# Wyciąga programy osadzone w install-router.sh do build/ (do czytania, lintowania, testów).
# Źródłem prawdy zostaje install-router.sh — zmiany rób tam, nie w build/.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
extract() {   # extract <znacznik heredoc> <plik wynikowy>
  awk -v m="$1" '$0 ~ "<<'"'"'" m "'"'"'$" {f=1; next} $0 == m {f=0} f' install-router.sh >"build/$2"
  [[ -s build/$2 ]] || { echo "nie znaleziono bloku $1" >&2; exit 1; }
  chmod 755 "build/$2"
  echo "build/$2  ($(wc -l <"build/$2" | tr -d ' ') linii)"
}
extract RIFEOF            router-ifaces
extract ROUTER_MONITOR_PY router-monitor
extract ROUTER_NOTIFY_PY  router-notify
extract ROUTER_FW_PY      router-fw
extract ROUTER_GUARD_PY   router-guard
mkdir -p build/synack_guard
extract GUARD_CORE_H      synack_guard/synack_guard_core.h
extract GUARD_PLUGIN_C    synack_guard/synack_guard.c
extract GUARD_CMAKE       synack_guard/CMakeLists.txt
