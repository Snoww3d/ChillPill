import AppKit

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

    private func refresh() {
        let readings = Sensors.readThermal()
        let hottest = Sensors.hottestCPU(readings)
        let fans = Fans.readAll()

        if let button = statusItem.button, let h = hottest {
            button.title = String(format: " %.0f°", h.celsius)
        }

        let menu = NSMenu()

        // Fans section
        if fans.isEmpty {
            menu.addItem(sectionHeader("Fans"))
            menu.addItem(disabled("  No fans reported"))
        } else {
            menu.addItem(sectionHeader("Fans"))
            for f in fans {
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
                    format: "  Fan %d: %.0f RPM%@ — %@",
                    f.index, f.actualRPM, rangeStr, modeLabel
                )
                menu.addItem(disabled(title))
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Sensors section
        menu.addItem(sectionHeader("Temperatures"))
        if readings.isEmpty {
            menu.addItem(disabled("  No sensors found"))
        } else {
            for r in readings {
                let title = String(format: "  %@  %.1f°C", r.name, r.celsius)
                menu.addItem(disabled(title))
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ChillPill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

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
