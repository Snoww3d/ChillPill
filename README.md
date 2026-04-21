# ChillPill

A macOS menu bar app that shows internal temperatures and controls fan speed, without hard-coded elevated privileges for the UI.

> **Status:** alpha — the core read/write path works end-to-end on an M1 Pro 14" MacBook Pro. Tracked open issues: [#3](https://github.com/Snoww3d/ChillPill/issues/3) (split CPU group into P-cores / E-cores).

## Requirements

- macOS 13 (Ventura) or newer — tested on macOS 26 (Tahoe)
- Apple Silicon (M-series) — Intel Macs are untested
- Xcode Command Line Tools (`xcode-select --install`)

No Homebrew dependencies. No Xcode project (SPM-driven).

## Build & run

```sh
git clone https://github.com/Snoww3d/ChillPill.git
cd ChillPill
make
open build/ChillPill.app
```

On first launch macOS shows a "Background Items Added" banner.
To enable fan control, go to **System Settings → Login Items & Extensions**
and toggle **ChillPill** on. This approves the bundled helper daemon —
after that, no password prompts, including across reboots.

To install to your user applications folder:

```sh
make install          # copies the release build to ~/Applications/
open ~/Applications/ChillPill.app
```

## How it works

The project is split across three SPM targets:

| Target             | Role                                            | Runs as |
|---|---|---|
| `ChillPill`        | Menu bar UI; no IOKit / SMC code                | user    |
| `ChillPillHelper`  | SMC read/write, fan control, sensor enumeration | root    |
| `ChillPillShared`  | XPC protocol + `Codable` DTOs                   | n/a     |

The UI and helper communicate over an `NSXPCConnection` against a
registered Mach service. Fan control commands carry only indices and
target RPMs — the helper validates input bounds, clamps to the
advertised `[min, max]` range, and only ever writes the `F{n}Md` and
`F{n}Tg` SMC keys (enforced by construction — no generic "write any
key" method exists on the XPC surface).

**Temperatures** come from two sources which the helper merges:
- `IOHIDEventSystemClient` → per-die sensors (P-cores, E-cores, GPU,
  SoC, PMIC, ANE, ISP, battery, NAND). Friendly names from the
  research in `Sources/ChillPillHelper/Sensors.swift`.
- `AppleSMC` FourCC keys → location-based thermistors (palm rest,
  airflow intakes, wireless, SSD area). Discovered at startup by
  enumerating the SMC key table.

## Uninstalling

From the menu: **ChillPill → Uninstall Helper** — calls
`SMAppService.daemon.unregister()`, which removes the launchd job.
Or, manually, in System Settings → Login Items & Extensions, toggle
ChillPill off.

## Disclaimer

Fan-control software pokes at undocumented hardware interfaces. Bugs
here could in principle cause overheating or odd thermal behaviour.
Use at your own risk — no warranty (see [LICENSE](LICENSE)). On app
quit (including SIGTERM / SIGINT), the helper restores all fans to
auto as a belt-and-braces safety net; `kill -9` bypasses this.

## License

[MIT](LICENSE).
