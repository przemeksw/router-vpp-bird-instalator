#!/usr/bin/env bash
# Testy logiki synack-guard niezależnej od VPP (build/synack_guard/synack_guard_core.h, wyciągany z install-router.sh) — kompilator C na hoście.
#   bash tests/test-guard-core.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
CC=${CC:-cc}
bash tools/extract.sh >/dev/null || exit 1
echo "9. synack-guard: rdzeń (C)"
if ! "$CC" -std=c11 -Wall -Wextra -Werror -O1 -fsanitize=address,undefined -o "$W/guard_core_test" tests/guard_core_test.c 2>"$W/cc.log"; then
  cat "$W/cc.log"; echo "BŁĄD  kompilacja guard_core_test.c"; exit 1
fi
"$W/guard_core_test"
