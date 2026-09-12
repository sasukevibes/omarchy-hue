# Philips Hue for Omarchy

A [Philips Hue](https://www.philips-hue.com/) control plugin for the
[Omarchy](https://omarchy.org/) shell (Quickshell). Opens as a floating
desktop window — not a bar dropdown — with room and per-light control, and
is fully keyboard-navigable.

<p align="center">
  <img src="docs/room-list.png" width="45%" alt="Room list" />
  <img src="docs/room-detail.png" width="45%" alt="Room detail with individual light control" />
</p>

## Features

- **Floating window**, not a bar popover — click the `HUE` bar button or use
  a keybinding, both open the same normal desktop window.
- **Per-room control** — power, brightness, colour, and scenes for a whole
  room.
- **Per-light control** — drill into a room to power, dim, and colour each
  bulb individually, not just the room as a whole.
- **Fully keyboard-native** — `↑↓`/`jk` to navigate, `←→`/`hl` to nudge
  brightness, `Space` to toggle power, `1`–`6` to apply a colour, `Enter` to
  open a room, `Esc` to back out/close. No mouse required. See
  [Keyboard reference](#keyboard-reference).
- **No cloud, no account.** Talks directly to your bridge on the local
  network over the Hue v1 local API. Nothing leaves your LAN.
- **Zero dependencies** — the backend is a single dependency-free Python 3
  script using only the standard library.

## Requirements

- [Omarchy](https://omarchy.org/) with the Quickshell-based shell
  (`omarchy-shell`).
- Python 3 (already present on any Omarchy install).
- A Philips Hue Bridge on the same local network.

## Install

```bash
git clone https://github.com/sasukevibes/omarchy-hue.git ~/.config/omarchy/plugins/ashton.hue
omarchy-shell shell rescanPlugins
```

> The plugin directory name (`ashton.hue`) doubles as its Omarchy plugin id.
> If you rename the folder, update the `id` in `manifest.json` and every
> `moduleName`/`ipcTarget`/`IpcHandler target` string in the `.qml` files to
> match, or the widget won't register correctly.

Add the `HUE` widget to your bar with `omarchy bar move ashton.hue --section
right` (or edit `~/.config/omarchy/shell.json` directly), then add a
keybinding in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + H", "Philips Hue", "omarchy-shell ashton.hue toggle")
```

## First run — pairing

1. Open the widget (bar button or keybinding). It searches the local network
   for a bridge via mDNS, SSDP, and the Hue discovery endpoint.
2. Press the physical link button on top of your Hue Bridge.
3. Click **Pair with `<bridge name>`** in the window within about 30 seconds.

The bridge issues a local API token on pairing, stored at
`~/.local/state/omarchy/hue.json` with owner-only (`0600`) permissions. This
token is the credential that controls your lights — see
[SECURITY.md](SECURITY.md) before sharing logs, screen recordings, or that
file with anyone.

## Keyboard reference

| Key | Action |
|---|---|
| `↑`/`↓` or `j`/`k` | Move the cursor between rooms, or between lights inside a room |
| `←`/`→` or `h`/`l` | Nudge brightness of whatever's focused, ~10% per press |
| `Space` | Toggle power of whatever's focused |
| `1`–`6` | Apply that colour swatch to whatever's focused |
| `Enter` | Open the focused room |
| `Esc` | Step back a level, then close the window |
| `r` | Refresh |

Moving the cursor onto a light auto-reveals its own brightness/colour
controls — no extra keypress needed to see or adjust it.

## How it works

- `hue.py` is a small, dependency-free Python 3 client for the Hue Bridge
  [v1 local API](https://developers.meethue.com/develop/hue-api/). It's
  invoked as a subprocess by the QML UI and talks JSON over stdout.
- `manifest.json`, `BarWidget.qml`, `Panel.qml`, and `HueControls.qml` are the
  Omarchy/Quickshell plugin — see the
  [Omarchy plugin docs](https://omarchy.org/) for the shell plugin model.

## Security

This plugin controls hardware on your home network and stores a bridge
credential on disk. Please read [SECURITY.md](SECURITY.md) for the threat
model, known limitations inherent to the Hue v1 API, and how to report a
vulnerability — **before** filing a bug report that might include your
`hue.json` contents.

## Contributing

PRs are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). All contributions
go through pull requests with required review; nothing merges to `main`
without an approval.

## License

[MIT](LICENSE)
