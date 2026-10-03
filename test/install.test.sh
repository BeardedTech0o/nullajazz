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
for c in sudo tee chmod udevadm curl; do
  cat > "$t/bin/$c" <<SH
#!/usr/bin/env bash
echo "$c \$*" >> "$log"
if [ "$c" = tee ]; then cat > "$t/written.rules"; fi
if [ "$c" = sudo ]; then exec "\$@"; fi
if [ "$c" = curl ]; then exit 22; fi
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

grep -q 'ENV{DEVTYPE}=="usb_device"' "$t/written.rules" || fail "DEVTYPE rule missing"
[ -z "$(grep "udevadm trigger" "$log" | grep -v "attr-match=idProduct" || true)" ] || fail "untargeted udevadm trigger"

# --yes must not download or run anything (curl stub logs any call and fails)
: > "$log"
env PATH="$t/bin:$PATH" HOME="$t/home" OPENDECK_CONFIG="$t/cfg2" SYSFS_USB="$t/sys" NULLAJAZZ_ALLOW_ROOT=1 \
    "$here/install.sh" --yes --skip-udev --skip-plugins > "$t/out2.txt" 2>&1 || true
grep -q "does not run downloaded installers" "$t/out2.txt" || fail "--yes should refuse to run the OpenDeck installer"
grep -q "install_opendeck" "$log" && fail "OpenDeck installer was fetched under --yes"

# hostile zips are rejected
bad() { # name, python snippet building the zip at $1
  python3 - "$t/$1.zip" "$2" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], 'w')
kind = sys.argv[2]
if kind == 'dotdot':
    z.writestr('../evil.txt', 'x'); z.writestr('p.sdPlugin/manifest.json', '{}')
elif kind == 'abs':
    z.writestr('/tmp/evil.txt', 'x'); z.writestr('p.sdPlugin/manifest.json', '{}')
elif kind == 'symlink':
    i = zipfile.ZipInfo('p.sdPlugin/link'); i.create_system = 3; i.external_attr = 0o120777 << 16
    z.writestr(i, '/etc/passwd'); z.writestr('p.sdPlugin/manifest.json', '{}')
z.close()
PY
}
for kind in dotdot abs symlink; do
  bad "bad-$kind" "$kind"
  rm -rf "$t/cfg3"
  env PATH="$t/bin:$PATH" HOME="$t/home" OPENDECK_CONFIG="$t/cfg3" AKP03_ZIP="$t/bad-$kind.zip" NULLAJAZZ_ALLOW_ROOT=1 \
      "$here/install.sh" --yes --skip-udev --skip-opendeck --skip-plugins > "$t/out3.txt" 2>&1 && fail "$kind zip should make the installer exit non-zero"
  [ ! -e "$t/cfg3/plugins" ] || fail "$kind zip was installed"
  grep -Eq "unsafe paths|symlinks" "$t/out3.txt" || fail "$kind zip rejected for the wrong reason"
done

# top-level manifest layout (zip holds the plugin contents, not a folder)
mkdir -p "$t/flat"; echo '{"Name":"flat"}' > "$t/flat/manifest.json"; (cd "$t/flat" && zip -qr "$t/flat.zip" .)
rm -rf "$t/cfg4"
env PATH="$t/bin:$PATH" HOME="$t/home" OPENDECK_CONFIG="$t/cfg4" AKP03_ZIP="$t/flat.zip" NULLAJAZZ_ALLOW_ROOT=1 \
    "$here/install.sh" --yes --skip-udev --skip-opendeck --skip-plugins >/dev/null 2>&1 || fail "flat zip failed"
[ -f "$t/cfg4/plugins/st.lynx.plugins.opendeck-akp03.sdPlugin/manifest.json" ] || fail "flat zip layout not installed"

# dry run must change nothing
rm -rf "$t/cfg/plugins"; : > "$log"
env PATH="$t/bin:$PATH" HOME="$t/home" OPENDECK_CONFIG="$t/cfg" SYSFS_USB="$t/sys" "$here/install.sh" --dry-run --yes >/dev/null 2>&1
[ ! -e "$t/cfg/plugins" ] || fail "dry run created plugins dir"
[ ! -s "$log" ] || fail "dry run called sudo/tee/udevadm"
echo PASS
