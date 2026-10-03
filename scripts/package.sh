#!/usr/bin/env bash
# Zips every plugin in plugins/ into dist/, ready for OpenDeck > Plugins > Install from file.
set -euo pipefail
shopt -s nullglob
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$here/dist"
cd "$here/plugins"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
built=0
for p in *.sdPlugin; do
  rm -f "$here/dist/$p.zip"
  rm -rf "${tmp:?}/$p"
  cp -r "$p" "$tmp/$p"
  cp -r _sdk "$tmp/$p/_sdk"
  # Refuse symlinks: zip would follow them and embed whatever they point at.
  if [ -n "$(find "$tmp/$p" -type l -print -quit)" ]; then
    echo "error: $p contains a symlink, refusing to package" >&2; exit 1
  fi
  (cd "$tmp" && zip -qr "$here/dist/$p.zip" "$p" -x '*/.*' '*/node_modules/*' '*.log' '*~')
  echo "built dist/$p.zip"
  built=$((built + 1))
done
[ "$built" -gt 0 ] || { echo "no plugins found" >&2; exit 1; }
