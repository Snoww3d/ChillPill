import AppKit

/// Carries the target we want to apply when a fan preset menu item is clicked.
/// Stored on `NSMenuItem.representedObject`.
///
/// `scope == .one(i)`: `value` is an absolute target RPM for fan `i`
/// (or nil for "return fan i to auto").
///
/// `scope == .all`: `value` is a percentage (0–100) applied against each
/// fan's *own* [Min, Max] range (or nil for "all fans to auto").
final class FanAction: NSObject {
    enum Scope {
        case one(Int)
        case all
    }
    let scope: Scope
    let value: Double?

    init(scope: Scope, value: Double?) {
        self.scope = scope
        self.value = value
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    /// Strong refs keep the DispatchSourceSignal alive beyond
    /// applicationDidFinishLaunching.
    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?

    /// Count of currently-open menus (root + any submenu). Non-zero means
    /// something is tracking and we should skip menu rebuilds. A plain Bool
    /// wouldn't work: NSMenuDelegate fires on each menu, so walking between
    /// submenus emits didClose+willOpen pairs that would flip a bool to false
    /// while the root is still open.
    private var menuOpenCount = 0

    /// When non-nil and in the future, the status-bar title update in refresh()
    /// is skipped so a transient toast stays visible.
    private var suppressTitleUpdateUntil: Date?

    /// Set once a fatal-signal handler has started running, so a second
    /// signal (or a hypothetical refactor that removes the main-queue
    /// serialization) can't re-enter the shutdown path.
    private var fatalSignalFired = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "ChillPill")
            button.imagePosition = .imageLeft
            button.title = " --°"
        }

        installSignalHandlers()
        refresh()

        // Schedule on .common so the timer keeps firing while the menu is
        // open (and therefore in .eventTracking mode). We separately skip
        // the *menu* rebuild during tracking — only the status-bar title
        // updates live.
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func applicationWillTerminate(_ notification: Notification) {
        Fans.restoreAllToAuto()
    }

    // MARK: - Signal handling
    //
    // AppKit only invokes applicationWillTerminate for graceful shutdowns
    // (Quit menu, NSApp.terminate, logout). A plain `kill` / `pkill` / Ctrl-C
    // on `sudo swift run` sends SIGTERM or SIGINT, which would normally
    // bypass AppKit's terminate path entirely — leaving the fans stuck at
    // whatever forced target was last applied. We catch those signals with
    // DispatchSource and restore auto before exiting.

    private func installSignalHandlers() {
        // Ignore the default disposition so libdispatch's signal sources
        // actually receive the signal.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in self?.handleFatalSignal() }
        term.resume()
        sigtermSource = term

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in self?.handleFatalSignal() }
        sigint.resume()
        sigintSource = sigint
    }

    private func handleFatalSignal() {
        guard !fatalSignalFired else { return }
        fatalSignalFired = true
        Fans.restoreAllToAuto()
        exit(0)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuOpenCount += 1
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpenCount = max(0, menuOpenCount - 1)
    }

    // MARK: - Menu build

    private func refresh() {
        let readings = Sensors.readThermal()
        let hottest = Sensors.hottestCPU(readings)
        let now = Date()
        if let deadline = suppressTitleUpdateUntil, now < deadline {
            // Toast still showing; leave the title alone.
        } else {
            suppressTitleUpdateUntil = nil
            if let button = statusItem.button, let h = hottest {
                button.title = String(format: " %.0f°", h.celsius)
            }
        }

        if menuOpenCount > 0 { return }

        let fans = Fans.readAll()
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(sectionHeader("Fans"))
        if fans.isEmpty {
            menu.addItem(disabled("  No fans reported"))
        } else {
            menu.addItem(allFansMenuItem(fans: fans))
            for f in fans {
                menu.addItem(fanMenuItem(for: f))
            }
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(sectionHeader("Temperatures"))
        if readings.isEmpty {
            menu.addItem(disabled("  No sensors found"))
        } else {
            for (group, list) in Sensors.grouped(readings) {
                menu.addItem(temperatureGroupItem(group: group, readings: list))
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ChillPill",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// The "All Fans" header row. Shows a summary (avg actual RPM across
    /// reporting fans) and opens a submenu with Auto + preset percentages
    /// applied uniformly.
    private func allFansMenuItem(fans: [FanReading]) -> NSMenuItem {
        let rpms = fans.map { $0.actualRPM }
        let avgRPM = rpms.isEmpty ? 0 : rpms.reduce(0, +) / Double(rpms.count)
        let allAuto = fans.allSatisfy { $0.mode == 0 }
        let summary = allAuto
            ? String(format: "All fans: %.0f RPM avg — auto", avgRPM)
            : String(format: "All fans: %.0f RPM avg", avgRPM)
        let item = NSMenuItem(title: summary, action: nil, keyEquivalent: "")

        let submenu = NSMenu()
        submenu.delegate = self

        let auto = NSMenuItem(title: "Auto",
                              action: #selector(applyFanAction(_:)),
                              keyEquivalent: "")
        auto.target = self
        auto.representedObject = FanAction(scope: .all, value: nil)
        auto.state = allAuto ? .on : .off
        submenu.addItem(auto)

        submenu.addItem(NSMenuItem.separator())

        for pct in [0, 25, 50, 75, 100] {
            let label: String = {
                switch pct {
                case 0:   return "Min"
                case 100: return "Max"
                default:  return "\(pct)%"
                }
            }()
            let padded = label.padding(toLength: 5, withPad: " ", startingAt: 0)
            let title = String(format: "%@  %d%%", padded, pct)
            let itm = NSMenuItem(title: title,
                                 action: #selector(applyFanAction(_:)),
                                 keyEquivalent: "")
            itm.target = self
            itm.representedObject = FanAction(scope: .all, value: Double(pct))
            submenu.addItem(itm)
        }
        item.submenu = submenu
        return item
    }

    /// A temperature group: the parent row shows the group name, sensor
    /// count, and average; the submenu lists every individual sensor.
    private func temperatureGroupItem(group: SensorGroup, readings: [ThermalReading]) -> NSMenuItem {
        let avg = readings.map { $0.celsius }.reduce(0, +) / Double(readings.count)
        let title = String(format: "%@ — %.1f°C avg (%d sensor%@)",
                           group.rawValue, avg, readings.count, readings.count == 1 ? "" : "s")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        for r in readings {
            submenu.addItem(disabled(String(format: "%@  %.1f°C", r.name, r.celsius)))
        }
        item.submenu = submenu
        return item
    }

    private func fanMenuItem(for f: FanReading) -> NSMenuItem {
        let modeLabel = modeLabelFor(f)
        let rangeStr: String = {
            if let mn = f.minRPM, let mx = f.maxRPM {
                return String(format: " [%.0f–%.0f]", mn, mx)
            }
            return ""
        }()
        let title = String(
            format: "Fan %d: %.0f RPM%@ — %@",
            f.index, f.actualRPM, rangeStr, modeLabel
        )
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = buildFanSubmenu(for: f)
        submenu.delegate = self
        item.submenu = submenu
        return item
    }

    private func modeLabelFor(_ f: FanReading) -> String {
        switch f.mode {
        case 0:
            return "auto"
        case 1:
            guard let t = f.targetRPM, let mn = f.minRPM, let mx = f.maxRPM else {
                return "forced"
            }
            if mx > mn {
                let pct = (t - mn) / (mx - mn) * 100.0
                return String(format: "%.0f%%", pct)
            }
            // Advertised range is degenerate — show both so the weirdness
            // isn't hidden.
            return String(format: "forced (range %.0f/%.0f)", mn, mx)
        case .some(let m):
            return "mode \(m)"
        case .none:
            return "?"
        }
    }

    private func buildFanSubmenu(for f: FanReading) -> NSMenu {
        let submenu = NSMenu()

        let auto = NSMenuItem(title: "Auto",
                              action: #selector(applyFanAction(_:)),
                              keyEquivalent: "")
        auto.target = self
        auto.representedObject = FanAction(scope: .one(f.index), value: nil)
        auto.state = (f.mode == 0) ? .on : .off
        submenu.addItem(auto)

        submenu.addItem(NSMenuItem.separator())

        if let mn = f.minRPM, let mx = f.maxRPM, mx > mn {
            for pct in [0, 25, 50, 75, 100] {
                let rpm = mn + (mx - mn) * Double(pct) / 100.0
                let label: String = {
                    switch pct {
                    case 0:   return "Min"
                    case 100: return "Max"
                    default:  return "\(pct)%"
                    }
                }()
                let padded = label.padding(toLength: 5, withPad: " ", startingAt: 0)
                let title = String(format: "%@  %.0f RPM", padded, rpm)
                let item = NSMenuItem(title: title,
                                      action: #selector(applyFanAction(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = FanAction(scope: .one(f.index), value: rpm)
                submenu.addItem(item)
            }
        } else if let mn = f.minRPM, let mx = f.maxRPM {
            submenu.addItem(disabled(String(format: "  Min/Max invalid: %.0f/%.0f", mn, mx)))
        } else {
            submenu.addItem(disabled("  Min/Max not reported"))
        }
        return submenu
    }

    // MARK: - Actions

    @objc private func applyFanAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? FanAction else { return }
        let ok: Bool
        switch action.scope {
        case .one(let idx):
            if let rpm = action.value {
                ok = Fans.setTarget(idx, rpm: rpm)
            } else {
                ok = Fans.setAuto(idx)
            }
        case .all:
            if let pct = action.value {
                ok = Fans.setAllTargets(pct: pct)
            } else {
                Fans.restoreAllToAuto()
                ok = true
            }
        }
        if !ok {
            notifyWriteRejected()
        }
        // SMC propagation delay: the key readback right after a write often
        // still shows the pre-write value. Wait a beat so the next menu open
        // reflects the just-applied mode/target.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refresh()
        }
    }

    private func notifyWriteRejected() {
        guard let button = statusItem.button else { return }
        button.title = " ⚠︎ need sudo"
        let expiry: TimeInterval = 2.0
        suppressTitleUpdateUntil = Date().addingTimeInterval(expiry)
        // Schedule an explicit refresh once the toast window ends so the title
        // returns to the temperature promptly, instead of lingering until the
        // next 2-second timer tick happens to align.
        DispatchQueue.main.asyncAfter(deadline: .now() + expiry + 0.05) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Menu helpers

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
