#!/usr/bin/env bash
# One-command setup for an Ajazz AKP03-family deck on Linux.
#
#   ./install.sh                         interactive: asks before each step that changes the system
#   ./install.sh --yes                  answer yes to the safe questions (see below)
#   ./install.sh --dry-run              show what would happen, change nothing
#   ./install.sh --skip-udev --skip-opendeck --skip-driver --skip-plugins
#
# Steps: 1) udev rules for the deck it finds  2) OpenDeck app  3) AKP03 driver plugin  4) the plugins in this repo.
#
# Downloaded code is never approved by --yes. Two steps fetch third-party code that runs as you, and
# nothing here pins or checksums it, so each needs its own explicit flag:
#   --run-opendeck-installer   download and run OpenDeck's own install script (reads from its main branch)
#   --trust-latest-driver      install the newest opendeck-akp03 release (a native binary)
# Without those flags, --yes skips the step and prints how to do it by hand. Interactive runs ask instead.
#
# Needs bash 4+, curl, unzip. The plugins in this repo need Node.js 22+.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
YES=0; DRY=0; DO_UDEV=1; DO_OD=1; DO_DRIVER=1; DO_PLUGINS=1; RUN_OD=0; TRUST_DRIVER=0; FAILED=0
for a in "$@"; do
  case "$a" in
    --yes|-y) YES=1 ;;
    --dry-run) DRY=1 ;;
    --skip-udev) DO_UDEV=0 ;;
    --skip-opendeck) DO_OD=0 ;;
    --skip-driver) DO_DRIVER=0 ;;
    --skip-plugins) DO_PLUGINS=0 ;;
    --run-opendeck-installer) RUN_OD=1 ;;
    --trust-latest-driver) TRUST_DRIVER=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

info() { printf '[*] %s\n' "$*"; }
ok()   { printf '[ok] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
fail() { FAILED=1; warn "$*"; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Asks a question. Under --yes it answers yes. Use ask_manual for anything that fetches code.
confirm() {
  [ "$YES" = 1 ] && return 0
  ask_manual "$1"
}
# Always needs a real answer at the keyboard, even under --yes.
ask_manual() {
  local ans=
  printf '%s [y/N]: ' "$1"
  if [ -t 0 ] || { [ -r /dev/tty ] && : </dev/tty 2>/dev/null; }; then
    if [ -t 0 ]; then read -r ans || ans=n; else read -r ans </dev/tty 2>/dev/null || ans=n; fi
  else echo "(no terminal)"; ans=n; fi
  [[ "$ans" =~ ^[yY]([eE][sS])?$ ]]
}
# Runs a command, or just prints it under --dry-run.
act() { if [ "$DRY" = 1 ]; then printf '    (dry run) %s\n' "$*"; else "$@"; fi; }
# Download helper: https only, including redirects, with size and time caps.
fetch() { curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --max-time 120 --max-filesize "${3:-52428800}" "$1" -o "$2"; }

[ "$(uname -s)" = Linux ] || die "This installer is for Linux."
[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash 4 or newer is required."
[ "$(id -u)" -ne 0 ] || [ "$DRY" = 1 ] || [ "${NULLAJAZZ_ALLOW_ROOT:-}" = 1 ] || die "Run as your normal user, not root. It uses sudo only where needed."
[ -d "$here/plugins/_sdk" ] || die "plugins/_sdk is missing. Run this from a full checkout of the repo."

# Where OpenDeck reads plugins. Resolved at install time, because step 2 may create it.
# Flatpak keeps its own config dir. XDG_CONFIG_HOME is only honoured if it is an absolute path.
plugins_dir() {
  if [ -n "${OPENDECK_CONFIG:-}" ]; then echo "$OPENDECK_CONFIG/plugins"; return; fi
  local xdg="${XDG_CONFIG_HOME:-}"; [[ "$xdg" == /* ]] || xdg="$HOME/.config"
  local native="$xdg/opendeck" flat="$HOME/.var/app/me.amankhanna.opendeck/config/opendeck"
  if [ -d "$native" ]; then echo "$native/plugins"
  elif [ -d "$flat" ] || { have flatpak && flatpak info me.amankhanna.opendeck >/dev/null 2>&1 && ! have opendeck; }; then echo "$flat/plugins"
  else echo "$native/plugins"; fi
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Copies a plugin folder into OpenDeck. Refuses odd names and symlinks. Swaps in atomically so a failed copy keeps the old version.
install_plugin_dir() {
  local src="$1" name dest dir; name="$(basename "$src")"
  [[ "$name" =~ ^[A-Za-z0-9._-]+\.sdPlugin$ ]] || { fail "$name is not a valid plugin folder name, skipped"; return 1; }
  [ -f "$src/manifest.json" ] || { fail "$name has no manifest.json, skipped"; return 1; }
  if [ -n "$(find "$src" -type l -print -quit)" ]; then fail "$name contains symlinks, skipped"; return 1; fi
  dir="$(plugins_dir)"; dest="$dir/$name"
  act mkdir -p "$dir"
  act rm -rf "${dir:?}/.$name.new"
  act cp -r "$src" "$dir/.$name.new"
  act rm -rf "${dest:?}"
  act mv "$dir/.$name.new" "$dest"
  if [ "$DRY" = 1 ]; then ok "would install $name into $dir"; else ok "installed $name into $dir"; fi
}

# Checks a zip before extracting it: no absolute paths, no .., no symlinks.
zip_is_safe() {
  local z="$1"
  unzip -Z1 "$z" | grep -Eq '(^/|(^|/)\.\.(/|$))' && { fail "zip contains unsafe paths"; return 1; }
  unzip -Z "$z" | grep -q '^l' && { fail "zip contains symlinks"; return 1; }
  return 0
}

# 1) USB access ---------------------------------------------------------------
if [ "$DO_UDEV" = 1 ]; then
  info "Step 1/4: USB access for the deck"
  if [ "$DRY" = 1 ]; then "$here/scripts/install-udev.sh" --dry-run || true
  elif "$here/scripts/install-udev.sh" --dry-run >/dev/null 2>&1; then
    if confirm "Install udev rules for the deck(s) found? (uses sudo)"; then "$here/scripts/install-udev.sh" || fail "udev step failed"; else warn "udev step skipped"; fi
  else
    warn "No deck detected. Plug it in and rerun, or install rules for every supported model now."
    if confirm "Install rules for every supported model? (uses sudo)"; then "$here/scripts/install-udev.sh" --all || fail "udev step failed"; else warn "udev step skipped"; fi
  fi
fi

# 2) OpenDeck -----------------------------------------------------------------
if [ "$DO_OD" = 1 ]; then
  info "Step 2/4: OpenDeck app"
  url="https://raw.githubusercontent.com/nekename/OpenDeck/main/install_opendeck.sh"
  if have opendeck || { have flatpak && flatpak info me.amankhanna.opendeck >/dev/null 2>&1; }; then
    ok "OpenDeck is already installed"
  elif [ "$DRY" = 1 ]; then
    echo "    (dry run) would offer OpenDeck's installer: $url"
  else
    manual() { warn "OpenDeck not installed by this script. Get it from https://github.com/nekename/OpenDeck/releases or Flathub (me.amankhanna.opendeck)."; }
    go=0
    if [ "$RUN_OD" = 1 ]; then go=1
    elif [ "$YES" = 1 ]; then manual; warn "(--yes does not run downloaded installers. Add --run-opendeck-installer to allow it.)"
    elif ask_manual "Download OpenDeck's installer from $url and run it?"; then go=1
    else manual; fi
    if [ "$go" = 1 ]; then
      have curl || die "curl is required"
      if fetch "$url" "$tmp/install_opendeck.sh" 1048576; then
        echo "    Saved to $tmp/install_opendeck.sh ($(wc -l < "$tmp/install_opendeck.sh") lines). It runs as you and may use sudo."
        if [ "$RUN_OD" = 1 ] || ask_manual "Run it now? (open it in another terminal first if you like)"; then bash "$tmp/install_opendeck.sh" || fail "OpenDeck installer failed"; else manual; fi
      else fail "could not download OpenDeck's installer"; fi
    fi
  fi
fi

# 3) Driver plugin ------------------------------------------------------------
if [ "$DO_DRIVER" = 1 ]; then
  info "Step 3/4: AKP03 driver plugin for OpenDeck"
  zip=""
  manual_driver() { warn "Driver not installed by this script. Download the zip from https://github.com/4ndv/opendeck-akp03/releases and use OpenDeck > Plugins > Install from file."; }
  if [ -n "${AKP03_ZIP:-}" ]; then
    zip="$AKP03_ZIP"; warn "Using local driver zip from AKP03_ZIP: $zip"
  elif [ "$DRY" = 1 ]; then
    echo "    (dry run) would look up the latest opendeck-akp03 release and show its tag and URL before installing"
  else
    have curl || die "curl is required"
    api="https://api.github.com/repos/4ndv/opendeck-akp03/releases/latest"
    if fetch "$api" "$tmp/release.json" 4194304; then
      tag="$(grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' "$tmp/release.json" | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')"
      mapfile -t assets < <(grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"https://github\.com/4ndv/opendeck-akp03/releases/download/[^" ]+\.zip"' "$tmp/release.json" | sed -E 's/.*"(https[^"]+)"$/\1/')
      if [ "${#assets[@]}" -ne 1 ]; then fail "expected exactly one release zip, found ${#assets[@]}."; manual_driver
      else
        echo "    Release: ${tag:-unknown}"; echo "    Asset:   ${assets[0]}"
        echo "    This is a native program that runs as you. It is not checksum-verified or pinned."
        ok_go=0
        if [ "$TRUST_DRIVER" = 1 ]; then ok_go=1
        elif [ "$YES" = 1 ]; then warn "(--yes does not install unpinned downloads. Add --trust-latest-driver to allow it.)"
        elif ask_manual "Install this release?"; then ok_go=1; fi
        if [ "$ok_go" = 1 ]; then fetch "${assets[0]}" "$tmp/driver.zip" && zip="$tmp/driver.zip" || fail "driver download failed"; else manual_driver; fi
      fi
    else fail "could not reach the GitHub API (rate limit or no network?)"; manual_driver; fi
  fi
  if [ -n "$zip" ]; then
    have unzip || die "unzip is required"
    if zip_is_safe "$zip"; then
      mkdir -p "$tmp/driver"; unzip -q "$zip" -d "$tmp/driver"
      # The zip holds either the plugin folder or its contents. A top-level manifest wins.
      if [ -f "$tmp/driver/manifest.json" ]; then
        mv "$tmp/driver" "$tmp/st.lynx.plugins.opendeck-akp03.sdPlugin"; d="$tmp/st.lynx.plugins.opendeck-akp03.sdPlugin"
      else
        mf="$(find "$tmp/driver" -mindepth 2 -maxdepth 2 -name manifest.json -print | sort | head -n1)"
        d="${mf:+$(dirname "$mf")}"
      fi
      if [ -n "${d:-}" ]; then install_plugin_dir "$d" || true; else fail "no manifest.json in the driver zip"; fi
    fi
  fi
fi

# 4) Plugins from this repo ---------------------------------------------------
if [ "$DO_PLUGINS" = 1 ]; then
  info "Step 4/4: plugins from this repo"
  if have node && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]; then ok "Node $(node --version) found"
  else warn "Node.js 22 or newer is needed to run these plugins. Install it from your distro or https://nodejs.org, then restart OpenDeck."; fi
  shopt -s nullglob
  n=0
  for p in "$here"/plugins/*.sdPlugin; do
    stage="$tmp/stage/$(basename "$p")"; mkdir -p "$tmp/stage"
    cp -r "$p" "$stage"; cp -r "$here/plugins/_sdk" "$stage/_sdk"   # each plugin carries its own copy of the SDK
    if install_plugin_dir "$stage"; then n=$((n + 1)); fi
  done
  [ "$n" -gt 0 ] || [ "$DRY" = 1 ] || fail "no plugins installed"
fi

echo
if [ "$FAILED" = 1 ]; then warn "Finished with problems. See the [!] lines above."; exit 1; fi
ok "Done. Unplug and replug the deck, then (re)start OpenDeck. Plugins show up in its Plugins tab."
