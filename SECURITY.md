# Security

## What runs, and as whom

- `install.sh` runs as you. It uses `sudo` only to write one udev rules file and reload udev.
- OpenDeck runs each plugin as a process under your user. A plugin can do anything you can.
- Plugins talk to OpenDeck over a WebSocket on `127.0.0.1`.

## Design choices

- **Rules are narrow.** Only the vendor and product IDs of a detected (or listed) deck get access, through
  `uaccess`, so the logged in user can open it. No groups, no world writable devices.
- **The rules path is fixed.** It is never taken from the environment, because it is passed to `sudo`.
- **No temp file for the rules.** They are written through `sudo tee`, so another process cannot swap the contents.
- **Downloaded code is opt in.** `--yes` never approves running OpenDeck's installer or installing the driver
  release. Each needs its own flag. Interactive runs ask at the keyboard.
- **Downloads are limited.** HTTPS only, including redirects, with size and time caps. The driver URL must be one zip
  under `github.com/4ndv/opendeck-akp03/releases/download/`.
- **Zips are checked before extraction.** Absolute paths, `..` paths and symlinks are rejected. Plugin folder names
  must match a strict pattern.
- **Plugin helpers avoid common mistakes.** `sdk.run` uses no shell. `sdk.fetchLimited` refuses redirects and caps
  size. `sdk.baseUrl` allows only http and https. Per-key settings are treated as untrusted because they travel in
  shared profiles.
- **Home Assistant plugin.** Service and entity names are validated and URL encoded. The token only goes to the base
  URL you configured. The settings panel only saves the token after the stored value has loaded, so it cannot blank it.

## Known limits

- **Third party downloads are not pinned or checksummed.** The OpenDeck installer is read from its `main` branch and
  the driver is the latest release. A compromise of either upstream would run code as you. Pinning needs a reviewed
  version and hash committed here, which does not exist yet.
- **Tokens are stored in plain text** in OpenDeck's global settings. Any local process that learns the plugin's port
  and UUID can read them. The Stream Deck protocol has no better store. Use a Home Assistant token with only the
  access you need.
- **Plain `http` base URLs send the token unencrypted.** Use `https`.
- **`--all` and generic vendor IDs.** Several supported IDs are generic and may be reused by unrelated products. A rule
  grants the logged in user raw access to any device with that ID. Prefer detection over `--all`.
- **Not run on real hardware.** Tests use fakes. Treat the first run on a deck as untested.
- **Plugins are code.** Only install plugins you wrote or have read.

## Reporting a problem

Open an issue on the repository. If it involves a token or another secret, describe where it appears and do not paste
the value.
