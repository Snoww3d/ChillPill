# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ChillPill is a macOS menu bar app (Swift / AppKit) that displays thermal sensor readings and (target state) controls fan speed. Apple Silicon is the primary target.

## Build / run

Pure Swift Package Manager — no Xcode project.

```sh
swift build                    # compile
swift run ChillPill            # build + launch (menu bar icon appears)
swift build -c release         # optimized
pkill -f ChillPill             # stop a running instance
```

Launching from `swift run` attaches the app to the terminal; Ctrl-C quits it. For daily use the user would open the built `.app` bundle, but we don't produce one yet.

## Architecture

Two SPM targets:

- **`CChillPillIOKit`** (`Sources/CChillPillIOKit/`) — a C shim that forward-declares private `IOHIDEventSystemClient` symbols (exported by `IOKit.framework` but absent from public headers). Keeping these in a C target lets the Swift side call them through normal CF bridging without a framework-private import.
- **`ChillPill`** (`Sources/ChillPill/`) — the executable. `main.swift` owns the `NSStatusItem` + refresh timer; `Sensors.swift` wraps the HID thermal query.

The app uses `setActivationPolicy(.accessory)` instead of an `Info.plist` with `LSUIElement`, so the SPM executable runs as a menu bar app without an app bundle.

## How sensor reads work

Temperatures come from `IOHIDEventSystemClient`, matching services with `PrimaryUsagePage = 0xFF00` (`kHIDPage_AppleVendor`) and `PrimaryUsage = 0x0005` (`kHIDUsage_AppleVendor_TemperatureSensor`). For each service we copy an event of type `15` (`kIOHIDEventTypeTemperature`) and read field `15 << 16` (`kIOHIDEventFieldTemperatureLevel`). This is the same path `stats`, `TG Pro`, and `iStatistica` use on Apple Silicon.

Fan reads/writes will go through the `AppleSMC` userclient (not HID) — writes are root-gated and will live behind a privileged helper tool.

## CF bridging notes

The private `IOHIDEventSystem*` Create/Copy functions return `CFTypeRef` without `CF_RETURNS_RETAINED` annotations, so Swift imports them as `Unmanaged<CFTypeRef>?`. Call `.takeRetainedValue()` on the result and let ARC manage lifetime — don't call `CFRelease` manually.

## Privilege model (planned)

- Reads (temps, fan RPM) — no elevated privileges.
- Writes (fan target RPM, mode) — require root on Apple Silicon. Path is a bundled helper registered via `SMAppService.daemon(plistName:)`, talking to the UI via XPC. Not implemented yet.

## Git workflow

Honor the global rules in `~/.claude/CLAUDE.md`. Concretely for this repo: feature branches (`feature/…`), PRs into `main`, `Closes #N` in PR bodies. The initial scaffold commit is the only one on main.
