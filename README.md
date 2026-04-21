# ChillPill

A macOS menu bar app that shows internal temperatures and (eventually) controls fan speed.

> **Status:** early alpha. Temperature monitoring works on Apple Silicon. Fan control is in progress — the shippable privileged-helper architecture is tracked in [#1](https://github.com/Snoww3d/ChillPill/issues/1).

## Requirements

- macOS 13 (Ventura) or newer — tested on macOS 26 (Tahoe)
- Apple Silicon (M-series) — Intel Macs are untested
- Xcode Command Line Tools (`xcode-select --install`)

That's it. No Xcode project, no CocoaPods, no Homebrew dependencies.

## Build & run

```sh
git clone https://github.com/Snoww3d/ChillPill.git
cd ChillPill
swift run ChillPill
```

A thermometer icon will appear in the menu bar with the hottest CPU-adjacent temperature. Click it for the full sensor list.

## How it works

- **Temperatures**: queried via `IOHIDEventSystemClient` against the `AppleVendor / TemperatureSensor` usage page. This is a private IOKit API that Apple's own system tools use; we forward-declare the symbols in a small C shim (`Sources/CChillPillIOKit`).
- **Fan speed**: reads via the `AppleSMC` userclient (planned). Writes require root privileges on Apple Silicon and will be handled by a bundled privileged helper.

## Project layout

```
ChillPill/
├── Package.swift                    # SPM manifest
├── Sources/
│   ├── CChillPillIOKit/             # C shim for private IOKit symbols
│   └── ChillPill/                   # Swift menu bar app
└── LICENSE
```

## Contributing

PRs welcome. Please run `swift build` cleanly before opening one. Opening an issue first is appreciated for any non-trivial change.

## Disclaimer

Fan-control software pokes at undocumented hardware interfaces. Bugs here can in principle cause overheating or odd thermal behavior. Use at your own risk — there is no warranty (see [LICENSE](LICENSE)).

## License

[MIT](LICENSE)
