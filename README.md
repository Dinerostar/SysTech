# SysTech

A lightweight macOS menu bar app that shows live system stats: CPU load, CPU and GPU temperature, memory, GPU usage, network speed, disk space, battery and fan speed.

You choose which stats appear in the menu bar with a switch on each metric. Click the menu bar item to open a panel with details and history graphs for everything.

## Features

| Metric | Menu bar | Panel details |
| --- | --- | --- |
| CPU | Usage % | History graph, per-core bars, user/system split, P/E core count |
| CPU temperature | Average °C/°F | Hottest sensor |
| Memory | Usage % | Used/total, pressure, app, wired, compressed, cached, swap |
| GPU | Usage % | History graph |
| GPU temperature | Average °C/°F | Hottest sensor |
| Network | ↑/↓ speed | Download/upload graph, totals since boot |
| Disk | Usage % | Free and used space on the startup disk |
| Battery | Level % | Charging state, time remaining, cycle count, temperature |
| Fans | RPM | Per-fan speed vs. maximum |

Metrics your Mac doesn't have, such as fans on a MacBook Air or a battery on a desktop, are hidden automatically.

**Settings** (gear button in the panel):

- Refresh interval: 1, 2 or 5 seconds
- Menu bar style: **Icons** (SF Symbol + value) or **Labels** (small caption above the value)
- Temperature unit: °C or °F
- Launch at login

By default the menu bar shows CPU, CPU temperature and memory.

## Requirements

- macOS 26.5 or later
- Xcode 26 to build
- Apple Silicon or Intel Mac (temperature sensors are discovered at runtime; so far tested on an M4 MacBook Air)

## Building and running

1. Open `SysTech.xcodeproj` in Xcode.
2. Select your development team under **Signing & Capabilities** if needed.
3. Press **⌘R**.

Or from the command line:

```bash
xcodebuild -project SysTech.xcodeproj -scheme SysTech -configuration Release -derivedDataPath build/DerivedData build
```

The built app is at `build/DerivedData/Build/Products/Release/SysTech.app`. Copy it to `/Applications` before turning on **Launch at login**.

The app has no Dock icon or main window. Look for it in the menu bar, and quit it from the panel (**Quit** or **⌘Q**).

## How it works

- **CPU**: per-core tick counters from `host_processor_info`, compared between samples.
- **Memory**: `host_statistics64`, using the same breakdown as Activity Monitor's "Memory Used" (app + wired + compressed). Pressure and swap come from `sysctl`.
- **Temperatures and fans**: read from the System Management Controller (SMC) over IOKit. At launch the app lists all SMC keys and keeps those that report plausible values: `Tp*`/`Te*` (CPU cores) and `Tg*` (GPU) on Apple Silicon, `TC*`/`TG*` on Intel. If no SMC CPU sensors are found, it falls back to the IOHID `PMU tdie*` sensors.
- **GPU usage**: `PerformanceStatistics` of the `IOAccelerator` service in the IORegistry.
- **Network**: 64-bit interface counters from `sysctl` (`NET_RT_IFLIST2`), limited to physical interfaces (`en*`, `pdp_ip*`) so VPN traffic isn't counted twice.
- **Battery**: IOKit power source APIs, plus cycle count from `AppleSmartBattery`.

All reads run in a background actor (`SystemSampler`). The menu bar strip is drawn with SwiftUI's `ImageRenderer` into a template image, because `MenuBarExtra` labels can only show a single image and text. A template image also adapts to light and dark menu bars.

## Project layout

```
SysTech/
├── SysTechApp.swift            App entry point (MenuBarExtra)
├── Monitoring/
│   ├── SystemSampler.swift     Reads all metrics (background actor)
│   ├── SystemSnapshot.swift    One sample of every metric
│   └── SystemMonitor.swift     Refresh loop, history, machine info
├── Sensors/
│   └── SensorsBridge.h/.c      SMC and IOHID sensor access in C
├── Settings/
│   └── AppSettings.swift       Metric definitions and saved preferences
├── Views/
│   ├── MenuBarLabel.swift      Menu bar strip
│   ├── MonitorPanel.swift      Drop-down panel, charts, settings screen
│   └── Formatting.swift        Number, byte and temperature formatting
└── SysTech-Bridging-Header.h
```

## Notes

- **App Sandbox is disabled.** The sandbox blocks access to the SMC, which the app needs for temperatures and fan speeds. So the app can't be distributed through the Mac App Store; ship it directly (signed and notarized) or via Homebrew.
- **Private interfaces.** The SMC keys and IOHID temperature functions are undocumented Apple interfaces. Future macOS versions or new chips may change them, which would mainly affect the temperature and fan readings.
