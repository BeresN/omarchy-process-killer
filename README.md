# Process Killer for Omarchy

A small bar widget for the [Omarchy](https://omarchy.org) shell that lists your
running apps and heavy background processes, each with an **X** button to kill
it — no more hunting for PIDs in a terminal.

<img width="447" height="545" alt="image" src="https://github.com/user-attachments/assets/839b83b9-7740-4819-8acf-cf3aa1a2b109" />

## Features

- **Windows**: every app that owns a Hyprland window (browser, terminal, editor…).
- **Background**: processes without a window that use at least 50 MB of RAM
  (configurable), sorted by memory.
- One row per app: Chromium/Electron helper processes are folded into their
  main process, so a browser with 14 processes is a single row with the total
  memory.
- **X** sends `SIGTERM` to the app's main process; if the app is still alive
  after 3 seconds, every process of the app gets `SIGKILL`.
- Session-critical processes are never listed (Hyprland, Xwayland,
  quickshell, systemd, D-Bus, PipeWire, WirePlumber, portals, Omarchy
  helpers…), so you can't take your desktop down by accident.
- Safe to click fast: rows keep their order while the list refreshes, a row
  being killed stays greyed out until it is gone, and clicks are ignored for a
  moment after the list changes, so a double click never hits the next row.
- No background cost: the list is only collected (every 2 s) while the panel
  is open. The plugin writes no files.

## Install

```bash
omarchy plugin add https://github.com/BeresN/omarchy-process-killer --enable
```

The widget appears in the right section of the bar. Move it with, for example:

```bash
omarchy bar move io.github.beresn.process-killer --after omarchy.tray
```

## Usage

Click the memory-chip icon in the bar to open the panel.

| Action            | Mouse            | Keyboard        |
|-------------------|------------------|-----------------|
| Select a row      | hover            | `j` / `k`, arrows |
| Kill selected app | click **X**      | `x`             |
| Close the panel   | click outside    | `Esc`           |

## Configure

Set the memory threshold for background processes (apps with a window are
always listed):

```bash
omarchy bar set io.github.beresn.process-killer minMemoryMB 100
```

This writes `"minMemoryMB": 100` to the widget's entry in
`~/.config/omarchy/shell.json`; the default is 50.

## Requirements

Everything ships with Omarchy: `bash`, `ps` (procps-ng) and `hyprctl`.
Processes are only listed and killed for the current user; no root access is
used.

## Remove

```bash
omarchy plugin remove io.github.beresn.process-killer
```

## Development

The process grouping and filtering logic lives in `Model.js` and has plain
Node tests:

```bash
node tests/model.test.js
```

## License

[MIT](LICENSE)
