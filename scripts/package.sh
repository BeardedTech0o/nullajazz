#!/usr/bin/env bash
# Zips every plugin in plugins/ into dist/, ready for OpenDeck > Plugins > Install from file.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$here/dist"
cd "$here/plugins"
for p in *.sdPlugin; do
  rm -f "$here/dist/$p.zip"
  # _sdk is copied in so each plugin is self-contained once installed.
  tmp="$(mktemp -d)"; cp -r "$p" "$tmp/$p"; cp -r _sdk "$tmp/$p/_sdk"
  (cd "$tmp" && zip -qr "$here/dist/$p.zip" "$p")
  rm -rf "$tmp"
  echo "built dist/$p.zip"
done
