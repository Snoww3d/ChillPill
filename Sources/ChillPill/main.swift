import AppKit

/// Carries the target we want to apply when a fan preset menu item is clicked.
/// Stored on `NSMenuItem.representedObject`.
final class FanAction: NSObject {
    let fanIndex: Int
    /// nil means "return to auto".
    let targetRPM: Double?

    init(fanIndex: Int, targetRPM: Double?) {
        self.fanIndex = fanIndex
        self.targetRPM = targetRPM
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "ChillPill")
            button.imagePosition = .imageLeft
            button.title = " --°"
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Fans.restoreAllToAuto()
    }

    // MARK: - Menu build

    private func refresh() {
        let readings = Sensors.readThermal()
        let hottest = Sensors.hottestCPU(readings)
        let fans = Fans.readAll()

        if let button = statusItem.button, let h = hottest {
            button.title = String(format: " %.0f°", h.celsius)
        }

        let menu = NSMenu()

        menu.addItem(sectionHeader("Fans"))
        if fans.isEmpty {
            menu.addItem(disabled("  No fans reported"))
        } else {
            for f in fans {
                menu.addItem(fanMenuItem(for: f))
            }
            menu.addItem(NSMenuItem.separator())
            let restoreAll = NSMenuItem(title: "Restore all fans to Auto",
                                        action: #selector(restoreAllAuto(_:)),
                                        keyEquivalent: "")
            restoreAll.target = self
            menu.addItem(restoreAll)
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(sectionHeader("Temperatures"))
        if readings.isEmpty {
            menu.addItem(disabled("  No sensors found"))
        } else {
            for r in readings {
                menu.addItem(disabled(String(format: "  %@  %.1f°C", r.name, r.celsius)))
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ChillPill",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func fanMenuItem(for f: FanReading) -> NSMenuItem {
        let modeLabel: String = {
            switch f.mode {
            case 0: return "auto"
            case 1: return "forced"
            case .some(let m): return "mode \(m)"
            case .none: return "?"
            }
        }()
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
        item.submenu = buildFanSubmenu(for: f)
        return item
    }

    private func buildFanSubmenu(for f: FanReading) -> NSMenu {
        let submenu = NSMenu()

        let auto = NSMenuItem(title: "Auto",
                              action: #selector(applyFanAction(_:)),
                              keyEquivalent: "")
        auto.target = self
        auto.representedObject = FanAction(fanIndex: f.index, targetRPM: nil)
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
                let title = String(format: "%-5s  %.0f RPM", (label as NSString).utf8String ?? "", rpm)
                let item = NSMenuItem(title: title,
                                      action: #selector(applyFanAction(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = FanAction(fanIndex: f.index, targetRPM: rpm)
                submenu.addItem(item)
            }
        } else {
            submenu.addItem(disabled("  Min/Max not reported"))
        }
        return submenu
    }

    // MARK: - Actions

    @objc private func applyFanAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? FanAction else { return }
        let ok: Bool
        if let rpm = action.targetRPM {
            ok = Fans.setTarget(action.fanIndex, rpm: rpm)
        } else {
            ok = Fans.setAuto(action.fanIndex)
        }
        if !ok {
            notifyWriteRejected()
        }
        refresh()
    }

    @objc private func restoreAllAuto(_ sender: NSMenuItem) {
        Fans.restoreAllToAuto()
        refresh()
    }

    private func notifyWriteRejected() {
        guard let button = statusItem.button else { return }
        let original = button.title
        button.title = " ⚠︎ need sudo"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if let b = self?.statusItem.button, b.title == " ⚠︎ need sudo" {
                b.title = original
            }
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
