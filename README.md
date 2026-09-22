# Menu bar widgets

Three small macOS menu bar widgets, each installed to start at login.

| Widget | Menu bar | Click for |
|---|---|---|
| **stats** (`SysMeter`) | `CPU 12%  RAM 58%  battery 79%` | Tabs for CPU (history, user/system, per-core bars, efficiency vs performance cores, load, uptime, top processes), Memory (app/wired/compressed/cached, pressure, swap, top processes) and Battery (status, time left, health, cycles, temperature, power draw, voltage, capacity). Checkboxes pick what shows in the menu bar. |
| **monitor** (`MonitorBrightness`) | ☀︎ | A brightness slider for each external monitor. The keyboard brightness keys also control the monitor when the pointer is on it. |
| **prayer** | `Maghrib 5:31 PM - 41m` | Today's five prayer times. |

## Install

    ./install.sh                # all three
    ./install.sh stats monitor  # only some

- **stats** and **monitor** are native Swift apps. They're compiled with `swiftc` (needs Xcode or the Command Line Tools), installed to `~/Applications`, and started at login by LaunchAgents in `~/Library/LaunchAgents`.
- **prayer** is a [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin. The installer adds SwiftBar with Homebrew if needed, copies the plugin to `~/.swiftbar-plugins/`, and adds SwiftBar to your login items.
- Rerun `./install.sh <widget>` after editing its code.

To remove everything, run `./uninstall.sh`, or `./uninstall.sh monitor` to remove one widget.

Choosing **Quit** in a widget's menu keeps it closed until the next login. To start it again sooner, run
`launchctl kickstart gui/$(id -u)/com.syed.SysMeter`, or `com.syed.MonitorBrightness`.

## Brightness keys need Accessibility permission

monitor asks for this the first time it runs. The permission is tied to the exact build, and the app is ad-hoc signed, so **every reinstall of monitor resets it**. System Settings may still show the switch on after a reinstall; that switch belongs to the old build. To turn the keys back on:

1. Open System Settings → Privacy & Security → Accessibility.
2. Select MonitorBrightness and click **−**.
3. Choose **Allow in Accessibility…** from the ☀︎ menu, or click **+** and add `~/Applications/MonitorBrightness.app`.
4. Switch it on.

The keys start working within a couple of seconds, with no restart needed.

## How they work

**monitor** sends DDC/CI commands (VCP `0x10`, brightness) to the monitor over the display cable, using Apple Silicon's private `IOAVService` I²C calls. This changes the monitor's actual backlight rather than dimming the picture. Writes run on a background queue, and while you drag the slider only the newest value is sent. It re-detects monitors after plugging in or waking; **Re-detect monitors** in the menu forces it. If there are several external monitors, they're matched to DDC services in order.

**stats** reads everything from macOS directly, with no helper and no root:
- CPU from `host_statistics` / `host_processor_info`
- Core types from the device tree
- Memory from `host_statistics64` and `sysctl`
- Battery from IOKit power sources and `AppleSmartBattery`
- Top processes from `/bin/ps`, only while the menu is open

The dropdown only updates while it's open. At idle stats uses about 0.5% of one CPU core and 25 MB of memory; monitor uses about 0.1% and 16 MB.

**prayer** runs once a minute. Times come from the [Aladhan API](https://aladhan.com/prayer-times-api) for Doha, using the Qatar method (method 10). A month is fetched at a time and cached in `~/.cache/prayer-times/`, so it only needs internet about once a month. To change the city or method, edit the constants at the top of `prayer/prayer.1m.py`.

## Layout

    stats/     SysMeter: Readers.swift (data), Model.swift, PopoverView.swift (SwiftUI dropdown), main.swift (menu bar)
    monitor/   MonitorBrightness: DDC.swift, Displays.swift, Keys.swift (brightness key event tap), HUD.swift, main.swift
    prayer/    prayer.1m.py (SwiftBar plugin, system Python, no packages)
