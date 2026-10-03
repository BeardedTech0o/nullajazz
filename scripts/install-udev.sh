#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
sudo install -m 0644 "$here/udev/40-ajazz-akp03e.rules" /etc/udev/rules.d/40-ajazz-akp03e.rules
sudo udevadm control --reload-rules
# Only re-trigger the device we care about, not everything on the system.
sudo udevadm trigger --subsystem-match=usb --subsystem-match=hidraw --attr-match=idVendor=0300
echo "Done. Unplug and replug the AKP03E, then restart OpenDeck."
