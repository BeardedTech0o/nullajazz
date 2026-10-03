#!/usr/bin/env bash
# Runs the real install path against fakes: stubbed sudo/tee/chmod/udevadm, a fake /sys, a fake HOME and a fake driver zip.
# Nothing here touches the real /etc.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$t/bin" "$t/sys/1-2" "$t/home" "$t/cfg"
printf '0300\n' > "$t/sys/1-2/idVendor"; printf '3002\n' > "$t/sys/1-2/idProduct"
log="$t/calls.log"; : > "$log"
for c in sudo tee chmod udevadm; do
  cat > "$t/bin/$c" <<SH
#!/usr/bin/env bash
echo "$c \$*" >> "$log"
if [ "$c" = tee ]; then cat > "$t/written.rules"; fi
if [ "$c" = sudo ]; then exec "\$@"; fi
SH
  chmod +x "$t/bin/$c"
done

# fake driver release: plugin folder with a manifest
mkdir -p "$t/zipsrc/st.lynx.test.sdPlugin"; echo '{"Name":"driver"}' > "$t/zipsrc/st.lynx.test.sdPlugin/manifest.json"
(cd "$t/zipsrc" && zip -qr "$t/driver.zip" .)

env PATH="$t/bin:$PATH" HOME="$t/home" OPENDECK_CONFIG="$t/cfg" SYSFS_USB="$t/sys" AKP03_ZIP="$t/driver.zip" \
    NULLAJAZZ_ALLOW_ROOT=1 RULES_FILE=/etc/passwd TMPDIR="$t" \
    "$here/install.sh" --yes --skip-opendeck > "$t/out.txt" 2>&1 || { cat "$t/out.txt"; fail "installer exited non-zero"; }

grep -q "Found Ajazz AKP03E rev. 2" "$t/out.txt" || fail "deck not detected"
grep -q "tee -- /etc/udev/rules.d/40-ajazz-deck.rules" "$log" || fail "rules not written to the fixed path"
grep -q "/etc/passwd" "$log" && fail "RULES_FILE override was honoured"
grep -q "idProduct}==\"3002\"" "$t/written.rules" || fail "rules content"
grep -q "attr-match=idProduct=3002" "$log" || fail "targeted trigger"
[ -f "$t/cfg/plugins/st.lynx.test.sdPlugin/manifest.json" ] || fail "driver plugin not installed"
[ -f "$t/cfg/plugins/homeassistant.sdPlugin/manifest.json" ] || fail "repo plugin not installed"
[ -f "$t/cfg/plugins/homeassistant.sdPlugin/_sdk/sdk.js" ] || fail "SDK not bundled into plugin"
[ -f "$t/cfg/plugins/homeassistant.sdPlugin/_sdk/nullobj.css" ] || fail "stylesheet not bundled"

# dry run must change nothing
rm -rf "$t/cfg/plugins"; : > "$log"
env PATH="$t/bin:$PATH" HOME="$t/home" OPENDECK_CONFIG="$t/cfg" SYSFS_USB="$t/sys" "$here/install.sh" --dry-run --yes --skip-opendeck --skip-driver >/dev/null 2>&1
[ ! -e "$t/cfg/plugins" ] || fail "dry run created plugins dir"
[ ! -s "$log" ] || fail "dry run called sudo/tee/udevadm"
echo PASS
