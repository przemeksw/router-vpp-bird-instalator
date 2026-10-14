#!/usr/bin/env bash
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
# Kontrola przed wysłaniem na router: składnia bash, shellcheck, składnia Pythona, flake8.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
rc=0
step() { printf '\n== %s\n' "$*"; }
step "bash -n install-router.sh"
bash -n install-router.sh && echo OK || rc=1
step "shellcheck"
if command -v shellcheck >/dev/null; then shellcheck -S warning install-router.sh tools/*.sh tests/*.sh && echo OK || rc=1
else echo "brak shellcheck (macOS: brew install shellcheck)"; fi
step "programy osadzone (build/)"
bash tools/extract.sh || rc=1
for f in build/router-ifaces build/router-monitor build/router-notify build/router-fw build/router-guard build/router-top build/router-snmp build/router-rpki build/router; do
  python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" && echo "OK  $f" || rc=1
done
step "flake8"
if python3 -m flake8 --version >/dev/null 2>&1; then
  python3 -m flake8 --max-line-length 125 build/router-ifaces build/router-fw build/router-guard build/router-top build/router-snmp build/router-rpki build/router && echo OK || rc=1
else echo "brak flake8 (pip3 install flake8)"; fi
exit $rc
