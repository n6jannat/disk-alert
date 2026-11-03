#!/usr/bin/env bash
# Simple tests for disk-alert.sh. Run: ./tests/test.sh
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/disk-alert.sh"
pass=0; fail=0

check() {  # check "<name>" <expected-exit> <args...>
    local name="$1" expected="$2"; shift 2
    "$SCRIPT" "$@" >/dev/null 2>&1
    local got=$?
    if [[ "$got" == "$expected" ]]; then
        echo "PASS  $name"; pass=$((pass + 1))
    else
        echo "FAIL  $name (expected exit $expected, got $got)"; fail=$((fail + 1))
    fi
}

check "help exits 0"                    0 --help
check "version exits 0"                 0 --version
check "unknown option is an error"      3 --bogus
check "threshold over 100 is an error"  3 -w 150
check "warn above crit is an error"     3 -w 95 -c 90
check "bad mount is an error"           3 -m /does/not/exist
check "high thresholds report OK"       0 -m / -w 100 -c 100 -n
check "0% warn triggers warning"        1 -m / -w 0 -c 100 -n
check "0% crit triggers critical"       2 -m / -w 0 -c 0 -n

echo; echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
