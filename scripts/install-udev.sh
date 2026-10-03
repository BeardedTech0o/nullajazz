#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sudo cp "$here/udev/40-ajazz-akp03e.rules" /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
echo "Done. Unplug and replug the AKP03E, then restart OpenDeck."
