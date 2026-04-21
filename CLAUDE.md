# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ChillPill is a macOS menu bar app (Swift / AppKit) that displays thermal sensor readings and controls fan speed on Apple Silicon. The UI is an unprivileged user process; a separate bundled helper daemon owns all SMC access and is installed via `SMAppService`.

## Build / run

SPM for code, Makefile for bundling.

```sh
make                  # debug build → build/ChillPill.app (ad-hoc signed)
make release          # release build (same, -c release)
make run              # make && open build/ChillPill.app
make install          # copy release build to ~/Applications/
make clean            # drop .build/ and build/
swift build           # compile only — no bundle; for quick syntax checks
```

`swift run ChillPill` still works for the UI but can't register the helper (SMAppService requires a .app bundle). Use `make run` for the full experience.

## Architecture

Three SPM targets:

- **`ChillPillShared`** (`Sources/ChillPillShared/`) — the XPC protocol and Codable DTOs. Imported by both UI and helper.
- **`ChillPillHelper`** (`Sources/ChillPillHelper/`) — the privileged daemon. Owns `SMC.shared`, `Fans` control, sensor enumeration (HID + SMC), XPC listener. Runs under launchd as root. Installs SIGTERM/SIGINT handlers that restore fans to auto before exit.
- **`ChillPill`** (`Sources/ChillPill/`) — UI. `HelperClient` wraps `NSXPCConnection`; `main.swift` builds menus from DTOs returned over XPC. No IOKit / SMC code here.

Plus `CChillPillIOKit` — a C shim that forward-declares private `IOHIDEventSystemClient` symbols. Imported by the helper only.

## XPC contract

Defined in `Sources/ChillPillShared/Protocol.swift` as `@objc protocol ChillPillHelperProtocol`. Array-typed return values are JSON-encoded `Data` blobs to sidestep `NSSecureCoding` class whitelisting; overhead is microseconds.

Writes return `NSError?` — `nil` on success. Errors use `ChillPillHelperErrorDomain` with numeric codes from `ChillPillHelperErrorCode`.

## Trust boundary

All input validation lives in the helper:
- Fan index bounds checked against `Fans.count()`.
- `rpm.isFinite` enforced; non-finite rejected.
- `setTarget` clamps to the fan's advertised `[Min, Max]` range (or refuses if the range is unknown).
- `setTarget` rolls back `F{n}Md` to 0 if the `F{n}Tg` write fails after the mode flip.
- SMC writes are restricted at the API level to `F{n}Md` and `F{n}Tg` — the helper does not expose a generic "write this key" surface.

## Lifecycle

- UI registers the daemon via `SMAppService.daemon(plistName: "dev.chillpill.helper.plist")` on first launch (`applicationDidFinishLaunching` → `autoRegisterHelperIfNeeded`).
- Status (`.notRegistered`/`.requiresApproval`/`.enabled`) is reflected in the menu's top "ChillPill" section.
- Menu offers Install / Open Login Items Settings / Uninstall as appropriate.
- On UI quit: `applicationWillTerminate` calls the helper's `prepareForShutdown` to restore auto, with a 1-second semaphore timeout so a dead helper doesn't block quit.
- On SIGTERM/SIGINT to the UI: same path.

## App bundle layout

Produced by `make`. `SMAppService` requires the daemon plist at this exact path inside the bundle:

```
build/ChillPill.app/
├── Contents/
│   ├── Info.plist                               ← Resources/Info.plist
│   ├── MacOS/
│   │   ├── ChillPill                            ← .build/*/ChillPill
│   │   └── ChillPillHelper                      ← .build/*/ChillPillHelper
│   └── Library/
│       └── LaunchDaemons/
│           └── dev.chillpill.helper.plist       ← Resources/…
```

Ad-hoc signing (`codesign --sign -`) is enough for SMAppService to accept the daemon locally. Distribution-quality signing (Developer ID) is a future concern, not required for open-source "clone and build" use.

## Things to know

- **`swift run` limitations:** only the UI works; the helper can't connect because its Mach service isn't registered with launchd. The UI detects this via `Bundle.main.bundlePath.hasSuffix(".app")` and suppresses the install/uninstall menu.
- **CF bridging in SMC.swift:** private `IOHIDEventSystem*` APIs return `Unmanaged<CFTypeRef>?`; call `.takeRetainedValue()` and let ARC manage lifetimes. Don't call `CFRelease` manually.
- **Menu tracking:** `menuOpenCount` (incremented in `menuWillOpen`, decremented in `menuDidClose` across root + submenus) gates the 2-second timer's menu rebuild so the open menu isn't dismissed mid-browse.
- **Byte order:** the SMC kernel stores `UInt32 key` and `keyInfo.dataType` in native byte order, so on LE hosts the FourCC bytes appear reversed in memory. The `writeLE32` / `readLE32` helpers round-trip correctly; see the comments in `SMC.swift`.

## Git workflow

Honor the rules in `~/.claude/CLAUDE.md`. Feature branches (`feature/…`), PRs into `main`, `Closes #N` in PR bodies. No commits directly to main except the initial scaffold.
