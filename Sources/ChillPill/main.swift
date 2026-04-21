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

        if let button = statusItem.button, let h = hottest {
            button.title = String(format: " %.0f°", h.celsius)
        }

        let menu = NSMenu()
        if readings.isEmpty {
            menu.addItem(NSMenuItem(title: "No sensors found", action: nil, keyEquivalent: ""))
        } else {
            for r in readings {
                let title = String(format: "%-28s %5.1f°C", (r.name as NSString).utf8String ?? "", r.celsius)
                menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
