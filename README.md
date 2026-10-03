# nullajazz

Run an Ajazz AKP03E on Linux, with your own plugins. Home Assistant works today. Hue and PC control are next.

The deck itself is driven by [OpenDeck](https://github.com/nekename/OpenDeck) and the community
[AKP03 driver plugin](https://github.com/4ndv/opendeck-akp03). nullajazz adds the parts around them: an
installer that finds your deck, a small SDK for writing plugins, and plugins of its own. See
[`SECURITY.md`](./SECURITY.md).

Built with Node.js and Bash. Settings panels use the Nullobj design system.

## Features

One command setup, USB detection (no product ID lookup), udev rules for only the deck it finds, a dependency
free plugin SDK for Node 22+, a Home Assistant plugin (call any service, show entity state on the key), settings
panels in light and dark, safe helpers for plugin authors (no shell commands, capped and timed out requests,
key press guard), a dry run mode, and tests that need no hardware.

## Before you start

You need a Linux desktop with systemd (the USB rules rely on logind), `curl`, `unzip` and `bash` 4 or newer. Node.js
22 or newer is needed to run the plugins in this repo. Check with `node --version`.

Nothing here has been tested on a real AKP03E yet. The code was checked against fakes and reviewed for security,
not run on the hardware. If something breaks on yours, the log paths under Troubleshooting will tell you where.

## Setup

### 1. Get the code

```bash
git clone https://github.com/BeardedTech0o/nullajazz.git && cd nullajazz
```

### 2. Look before you run

```bash
./install.sh --dry-run
```

This prints every step and changes nothing. You should see your deck named, for example
`Found Ajazz AKP03E rev. 2 (0300:3002)`. If it says no deck was detected, check the cable (it must carry data, not
just power) and try again.

### 3. Install

```bash
./install.sh
```

It asks before each step that changes your system.

1. **USB rules.** Detects the deck and installs a udev rule for that one device (uses `sudo`). Nobody needs to look
   up a product ID. No deck plugged in yet? `scripts/install-udev.sh --all` installs rules for every supported model.
2. **OpenDeck.** If it is missing, the script can fetch OpenDeck's own installer. That installer runs as you and may
   use `sudo`, so you get to read it first.
3. **Driver plugin.** Shows the release tag and the exact download URL, then asks.
4. **Plugins in this repo.** Copies each one into OpenDeck's plugins folder, bundled with the SDK.

`--yes` answers yes to the safe questions only. Steps that download and run someone else's code are never approved
by `--yes`. They need their own flags, so you opt in on purpose:

```bash
./install.sh --yes --run-opendeck-installer --trust-latest-driver
```

Neither download is pinned or checksum verified, because there is no hash in this repo to check against. Use those
flags only if you trust the upstream projects. You can also skip any step with `--skip-udev`, `--skip-opendeck`,
`--skip-driver` or `--skip-plugins`.

If the driver step cannot find or download the release, it says so. Download the zip from the
[driver releases page](https://github.com/4ndv/opendeck-akp03/releases) and use OpenDeck, Plugins, Install from file.

### 4. Replug and restart

Unplug the deck, plug it back in, then start (or restart) OpenDeck. Your deck should appear in the device menu in
the top right. The plugins show up in the Plugins tab.

## Home Assistant

### Get a token

In Home Assistant, open your profile, then Security, then Long-lived access tokens, and create one. Copy it now.
Home Assistant shows it only once.

### Set up a key

1. In OpenDeck, drag **Call Service** from the Home Assistant group onto a key.
2. Click the key to open its settings.
3. Under Connection, enter your base URL (for example `https://homeassistant.local:8123`) and paste the token.
   These are shared by every Home Assistant key, so you do this once.
4. Under This key, fill in the service and the entity.

| Field | Example | Notes |
|---|---|---|
| Service | `light.toggle` | `domain.service`, lowercase letters, digits and underscores only |
| Entity ID | `light.desk` | Same format. Find it in Settings, Devices and services, Entities |
| Extra data | `{"brightness_pct": 50}` | Optional. Must be a JSON object |
| Label | `Desk` | Optional, 40 characters at most |
| Show state | on | Polls Home Assistant every 5 seconds and shows the state on the key |

Press the key. A green tick means Home Assistant accepted the call. A red cross means it did not, and the plugin
log says why.

Use `https` if you can. With plain `http` the token crosses your network unencrypted.

## Writing your own plugin

A plugin is a folder ending in `.sdPlugin` inside `plugins/`. It holds a `manifest.json`, a script, and optionally a
settings page. OpenDeck starts the script and talks to it over a local WebSocket using the Stream Deck plugin
protocol. Use `plugins/homeassistant.sdPlugin` as your reference.

```
plugins/
  _sdk/                      shared SDK and stylesheet, copied into every plugin at install time
  homeassistant.sdPlugin/
    manifest.json
    plugin.js
    pi.html                  settings panel (optional)
```

The SDK needs no `npm install`:

```js
const sdk = require('./_sdk/sdk');

sdk.connect({
  keyDown(ev, deck) {
    const s = sdk.settings(ev);            // untrusted settings, always a plain object
    deck.setTitle(ev.context, sdk.str(s.label, 40));
  },
});
```

Handlers you can define include `willAppear`, `willDisappear`, `keyDown`, `keyUp`, `didReceiveSettings` and
`didReceiveGlobalSettings`. The `deck` object can `setTitle`, `setImage`, `setState`, `setSettings`,
`setGlobalSettings`, `getGlobalSettings`, `showOk`, `showAlert` and `log`.

Helpers that exist so you do not have to write the risky parts yourself:

| Helper | What it does |
|---|---|
| `sdk.settings(ev)` | Returns the action's settings as a plain object, or `{}` |
| `sdk.str(v, max)` | Returns a string capped at `max`, or `''` |
| `sdk.baseUrl(raw)` | Parses a URL. Allows only http and https, rejects embedded credentials |
| `sdk.fetchLimited(url, init, opts)` | Fetch with a timeout, no redirects and a size cap |
| `sdk.run(file, args)` | Runs a program with an argument array and no shell |
| `sdk.guard(ms)` | Ignores a key press while one is running, and enforces a gap between presses |

Three rules. Settings travel inside shareable profiles, so treat them as untrusted input. Keep tokens in global
settings, never in per-key settings. Never build a shell string from settings: use `sdk.run`.

Settings panels load `_sdk/nullobj.css` and use its `.field`, `.input`, `.btn` and `.section` classes, so every
plugin matches. After adding a plugin, run `./install.sh --skip-udev --skip-opendeck --skip-driver` to copy it into
OpenDeck, or build a zip with `./scripts/package.sh` and use OpenDeck, Plugins, Install from file.

## Configuration

`OPENDECK_CONFIG` (overrides where plugins are installed, defaults to `~/.config/opendeck`, or the Flatpak folder
if only the Flatpak app is installed). `XDG_CONFIG_HOME` is honoured if it is an absolute path. The udev rules
destination is fixed at `/etc/udev/rules.d/40-ajazz-deck.rules` and cannot be changed from the environment.

## Updating

```bash
cd nullajazz && git pull && ./install.sh --skip-udev --skip-opendeck --skip-driver
```

That refreshes your plugins. Restart OpenDeck afterwards. To pick up a newer driver release, run the full
`./install.sh` again.

The udev step replaces the rules file each time. If you run it for a second deck, plug in both first, or use `--all`.

## Uninstalling

```bash
sudo rm /etc/udev/rules.d/40-ajazz-deck.rules && sudo udevadm control --reload-rules
rm -rf ~/.config/opendeck/plugins/homeassistant.sdPlugin
```

Remove the driver plugin from OpenDeck's Plugins tab, or delete its folder from the same plugins directory.

## Troubleshooting

**The deck does not appear in OpenDeck.** Replug it, then restart OpenDeck. Check that the rules file exists and the
deck is visible with `ls /dev/hidraw*`. USB access comes from `uaccess`, which needs a logged in systemd session. Over
plain SSH or without logind it will not apply.

**The installer finds no deck.** Use a data cable. Run `./scripts/install-udev.sh --dry-run` to see the detection on its
own. If it reports an unsupported ID starting with `0300`, open an issue with that ID and your model.

**Which revision do I have?** The AKP03E ships as `0300:1002` (original) or `0300:3002` (rev 2). Rev 2 reports key
release as well as press, which long press and push to talk need.

**A key shows a red cross.** The service call failed. Check the base URL and token, and that the service and entity
exist. Plugin logs are in `~/.local/share/opendeck/logs/`, with one file per plugin under `plugins/`.

**A key shows `?` instead of a state.** Home Assistant is unreachable, or the entity ID is wrong.

**Plugins do not load.** Check `node --version` prints 22 or newer. Then restart OpenDeck.

**Plugins landed in the wrong folder.** On Flatpak the config lives under `~/.var/app/me.amankhanna.opendeck/`. Set
`OPENDECK_CONFIG` to the folder that contains `plugins/` and rerun.

## Development

```bash
node test/mock-opendeck.js        # fake OpenDeck and fake Home Assistant, runs the plugin end to end
test/install-udev.test.sh         # USB detection against a fake /sys
test/install.test.sh              # full installer against fakes (needs zip and python3)
./scripts/package.sh              # builds dist/*.zip for OpenDeck's Install from file
```

None of the tests touch your real `/etc` or your real OpenDeck folder.

## Roadmap

Done: USB detection, installer, plugin SDK, Home Assistant plugin, shared settings styling.

Planned: Philips Hue plugin, PC control plugin (volume, media, launch apps, run commands), knob support, pinned and
checksum verified driver downloads.

Not yet done: testing on a real AKP03E, and the font's license file (see `plugins/_sdk/fonts/NOTICE.md`).

[![Buy Me a Coffee](https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=&slug=nullobj&button_colour=FFDD00&font_colour=000000&font_family=Cookie&outline_colour=000000&coffee_colour=ffffff)](https://www.buymeacoffee.com/nullobj)
