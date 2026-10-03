#!/usr/bin/env bash
# One-command setup for an Ajazz AKP03-family deck on Linux.
#
#   ./install.sh                 interactive: asks before each step that changes the system
#   ./install.sh --yes           answer yes to every question
#   ./install.sh --dry-run       show what would happen, change nothing
#   ./install.sh --skip-opendeck --skip-driver --skip-udev --skip-plugins
#
# Steps: 1) udev rules for the deck it finds  2) OpenDeck app  3) AKP03 driver plugin  4) the plugins in this repo.
# Needs bash 4+, curl, unzip. The plugins in this repo need Node.js 22+.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
YES=0; DRY=0; DO_UDEV=1; DO_OD=1; DO_DRIVER=1; DO_PLUGINS=1
for a in "$@"; do
  case "$a" in
    --yes|-y) YES=1 ;;
    --dry-run) DRY=1 ;;
    --skip-udev) DO_UDEV=0 ;;
    --skip-opendeck) DO_OD=0 ;;
    --skip-driver) DO_DRIVER=0 ;;
    --skip-plugins) DO_PLUGINS=0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

info() { printf '[*] %s\n' "$*"; }
ok()   { printf '[ok] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  [ "$YES" = 1 ] && return 0
  local ans; printf '%s [y/N]: ' "$1"
  if [ -r /dev/tty ]; then read -r ans </dev/tty; else read -r ans || ans=n; fi
  [[ "$ans" =~ ^[yY]([eE][sS])?$ ]]
}
# Runs a command, or just prints it under --dry-run.
act() { if [ "$DRY" = 1 ]; then printf '    (dry run) %s\n' "$*"; else "$@"; fi; }

[ "$(uname -s)" = Linux ] || die "This installer is for Linux."
[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash 4 or newer is required."
[ "$(id -u)" -ne 0 ] || [ "$DRY" = 1 ] || [ "${NULLAJAZZ_ALLOW_ROOT:-}" = 1 ] || die "Run as your normal user, not root. It uses sudo only where needed."

# Where OpenDeck reads plugins. Flatpak keeps its own copy of the config dir.
find_plugins_dir() {
  if [ -n "${OPENDECK_CONFIG:-}" ]; then echo "$OPENDECK_CONFIG/plugins"; return; fi
  local native="${XDG_CONFIG_HOME:-$HOME/.config}/opendeck"
  local flat="$HOME/.var/app/me.amankhanna.opendeck/config/opendeck"
  if [ -d "$native" ]; then echo "$native/plugins"
  elif [ -d "$flat" ]; then echo "$flat/plugins"
  else echo "$native/plugins"; fi
}
PLUGINS_DIR="$(find_plugins_dir)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Copies a plugin folder into OpenDeck. Refuses symlinks, so a bad archive can't point outside the folder.
install_plugin_dir() {
  local src="$1" name; name="$(basename "$src")"
  [ -f "$src/manifest.json" ] || { warn "$name has no manifest.json, skipped"; return 1; }
  if [ -n "$(find "$src" -type l -print -quit)" ]; then warn "$name contains symlinks, skipped"; return 1; fi
  act mkdir -p "$PLUGINS_DIR"
  act rm -rf "${PLUGINS_DIR:?}/$name"
  act cp -r "$src" "$PLUGINS_DIR/$name"
  ok "installed $name"
}

# 1) USB access ---------------------------------------------------------------
if [ "$DO_UDEV" = 1 ]; then
  info "Step 1/4: USB access for the deck"
  if [ "$DRY" = 1 ]; then "$here/scripts/install-udev.sh" --dry-run || true
  elif "$here/scripts/install-udev.sh" --dry-run >/dev/null 2>&1; then
    confirm "Install udev rules for the deck(s) found? (uses sudo)" && "$here/scripts/install-udev.sh" || warn "udev step skipped"
  else
    warn "No deck detected. Plug it in and rerun, or install rules for every supported model now."
    if confirm "Install rules for every supported model? (uses sudo)"; then "$here/scripts/install-udev.sh" --all; else warn "udev step skipped"; fi
  fi
fi

# 2) OpenDeck -----------------------------------------------------------------
if [ "$DO_OD" = 1 ]; then
  info "Step 2/4: OpenDeck app"
  if have opendeck || { have flatpak && flatpak info me.amankhanna.opendeck >/dev/null 2>&1; }; then
    ok "OpenDeck is already installed"
  else
    url="https://raw.githubusercontent.com/nekename/OpenDeck/main/install_opendeck.sh"
    echo "    OpenDeck's own installer will be downloaded to a file first: $url"
    if confirm "Download it, then run it?"; then
      if [ "$DRY" = 1 ]; then echo "    (dry run) curl -fsSL $url -o <file>; bash <file>"
      else
        have curl || die "curl is required"
        curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$tmp/install_opendeck.sh"
        echo "    Saved to $tmp/install_opendeck.sh ($(wc -l < "$tmp/install_opendeck.sh") lines)."
        confirm "Run it now? (read it first in another terminal if you like)" && bash "$tmp/install_opendeck.sh" || warn "OpenDeck install skipped"
      fi
    else warn "OpenDeck skipped. Install it from https://github.com/nekename/OpenDeck/releases and rerun."; fi
  fi
fi

# 3) Driver plugin ------------------------------------------------------------
if [ "$DO_DRIVER" = 1 ]; then
  info "Step 3/4: AKP03 driver plugin for OpenDeck"
  if [ -n "${AKP03_ZIP:-}" ]; then zip="$AKP03_ZIP"   # local file, used by the tests
  else
    api="https://api.github.com/repos/4ndv/opendeck-akp03/releases/latest"
    echo "    Source: $api"
    if confirm "Download the latest driver plugin release?"; then
      if [ "$DRY" = 1 ]; then echo "    (dry run) would download the release zip and install it"; zip=""
      else
        have curl || die "curl is required"
        asset="$(curl -fsSL --proto '=https' "$api" | grep -Eo 'https://github\.com/4ndv/opendeck-akp03/releases/download/[^" ]+\.zip' | head -n1 || true)"
        [ -n "$asset" ] || { warn "Could not find a release zip. Install it by hand: OpenDeck > Plugins > Install from file."; asset=""; }
        zip=""
        if [ -n "$asset" ]; then curl -fL --proto '=https' --tlsv1.2 "$asset" -o "$tmp/driver.zip" && zip="$tmp/driver.zip"; fi
      fi
    else zip=""; warn "Driver plugin skipped."; fi
  fi
  if [ -n "${zip:-}" ]; then
    have unzip || die "unzip is required"
    mkdir -p "$tmp/driver"
    unzip -q "$zip" -d "$tmp/driver"
    # The zip holds either the plugin folder or its contents. Find the manifest.
    mf="$(find "$tmp/driver" -maxdepth 2 -name manifest.json -print -quit)"
    if [ -z "$mf" ]; then warn "No manifest.json in the driver zip. Use OpenDeck > Plugins > Install from file."
    else
      d="$(dirname "$mf")"
      if [ "$d" = "$tmp/driver" ]; then mv "$tmp/driver" "$tmp/st.lynx.plugins.opendeck-akp03.sdPlugin"; d="$tmp/st.lynx.plugins.opendeck-akp03.sdPlugin"; fi
      install_plugin_dir "$d" || true
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
    install_plugin_dir "$stage" && n=$((n + 1)) || true
  done
  [ "$n" -gt 0 ] || [ "$DRY" = 1 ] || warn "no plugins installed"
fi

echo
ok "Done. Unplug and replug the deck, then (re)start OpenDeck. Plugins show up in its Plugins tab."
