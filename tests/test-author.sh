#!/usr/bin/env bash
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
# Kontrola: autor jest widoczny przy wywołaniu poleceń (--help, --version, baner), nie tylko w komentarzach kodu.
#   bash tests/test-author.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
bash tools/extract.sh >/dev/null || exit 1
A="PHU VIPHOST Przemysław Świderski <biuro@viphost.it>"
pass=0 fail=0
chk() {   # chk <opis> <polecenie...>
  local name=$1 out; shift
  out=$("$@" 2>&1 </dev/null)
  if grep -qF -- "$A" <<<"$out"; then pass=$((pass + 1)); printf '  OK    %s\n' "$name"
  else fail=$((fail + 1)); printf '  BŁĄD  %s — brak autora w wyniku\n' "$name"; fi
}
echo "10. autor widoczny przy wywołaniu"
chk "install-router.sh --version"       bash install-router.sh --version
chk "install-router.sh --help"          bash install-router.sh --help
chk "router-ifaces --help"              python3 build/router-ifaces --help
chk "router-ifaces --version"           python3 build/router-ifaces --version
chk "router-fw --help"                  python3 build/router-fw --help
chk "router-fw --version"               python3 build/router-fw --version
chk "router-guard --help"               python3 build/router-guard --help
chk "router-guard --version"            python3 build/router-guard --version
chk "router-top --help"                 python3 build/router-top --help
chk "router-top --version"              python3 build/router-top --version
chk "router --version"                  python3 build/router --version
chk "router help"                       python3 build/router help
chk "router-notify --version"           python3 build/router-notify --version
chk "router-monitor --version"          python3 build/router-monitor --version
chk "install-uefi-mdadm.sh --help"      bash install-uefi-mdadm.sh --help
printf '\nWynik: %d OK, %d błędów\n' "$pass" "$fail"
((fail == 0))
