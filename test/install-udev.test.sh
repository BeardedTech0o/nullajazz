#!/usr/bin/env bash
# Runs the installer in --dry-run against a fake /sys tree.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mk() { mkdir -p "$t/$1"; printf '%s\n' "$2" > "$t/$1/idVendor"; printf '%s\n' "$3" > "$t/$1/idProduct"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
run() { SYSFS_USB="$t" "$here/scripts/install-udev.sh" --dry-run "$@" 2>&1; }

mk 1-1 8087 0024            # unrelated hub
out="$(run)" && fail "should exit 1 with no deck" || true
echo "$out" | grep -q "No supported deck" || fail "no-deck message"

mk 1-2 0300 3002            # AKP03E rev 2
mk 1-3 0300 3002            # duplicate, must dedupe
mk 1-4 0300 ABCD            # unknown 0300 device, should warn
out="$(run)" || fail "should succeed with a deck"
echo "$out" | grep -q "Ajazz AKP03E rev. 2 (0300:3002)" || fail "detection"
[ "$(echo "$out" | grep -c 'idProduct}=="3002"')" = 2 ] || fail "dedupe (expected exactly 2 rules for 3002)"
echo "$out" | grep -q "0300:abcd" || fail "unknown-0300 warning"
echo "$out" | grep -q 'idProduct}=="abcd"' && fail "unknown ID must not get a rule"

mk 1-5 0300 '3002"; RUN+="/bin/evil"'   # hostile sysfs value
out="$(run)"; echo "$out" | grep -q evil && fail "injection"

out="$(run --all)"; [ "$(echo "$out" | grep -c 'SUBSYSTEM=="hidraw"')" = 13 ] || fail "--all count"
echo PASS
