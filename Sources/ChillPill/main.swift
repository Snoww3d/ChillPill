import AppKit
import ServiceManagement
import ChillPillShared

/// Filename of the launchd plist inside `Contents/Library/LaunchDaemons/`.
/// Must match the file committed at `Resources/dev.chillpill.helper.plist`
/// and the name copied by the Makefile into the .app bundle.
private let helperPlistName = "dev.chillpill.helper.plist"

/// Carries the target we want to apply when a fan preset menu item is clicked.
final class FanAction: NSObject {
    enum Scope {
        case one(Int)
        case all
    }
    let scope: Scope
    /// .one: absolute RPM (nil = auto).  .all: percentage 0-100 (nil = auto).
    let value: Double?

    init(scope: Scope, value: Double?) {
        self.scope = scope
        self.value = value
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?

    /// Count of currently-open menus (root + submenus). Non-zero means we
    /// should skip menu rebuilds to avoid dismissing what the user is
    /// tracking.
    private var menuOpenCount = 0

    /// When non-nil and in the future, refresh() leaves the status-bar title
    /// alone so a transient toast stays visible.
    private var suppressTitleUpdateUntil: Date?

    /// Gate so both SIGTERM and SIGINT can't both invoke the shutdown path.
    private var fatalSignalFired = false

    /// Latest snapshots returned by the helper. The refresh() method fires
    /// two XPC calls and the replies populate these independently; the menu
    /// rebuild runs whenever either one arrives.
    private var latestFans: [FanDTO] = []
    private var latestTemps: [TemperatureDTO] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "ChillPill")
            button.imagePosition = .imageLeft
            button.title = " --°"
        }

        installSignalHandlers()
        autoRegisterHelperIfNeeded()
        refresh()

        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort: tell the helper to restore auto. The helper also runs
        // its own signal handler so this is belt-and-braces.
        let sem = DispatchSemaphore(value: 0)
        HelperClient.shared.prepareForShutdown { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 1.0)
    }

    // MARK: - Signals

    private func installSignalHandlers() {
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
        let sem = DispatchSemaphore(value: 0)
        HelperClient.shared.prepareForShutdown { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 1.0)
        exit(0)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuOpenCount += 1
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpenCount = max(0, menuOpenCount - 1)
    }

    // MARK: - Helper lifecycle (SMAppService)

    /// True when running from a proper `.app` bundle — SMAppService can only
    /// register daemons bundled inside an app. `swift run` from the repo
    /// root will return false; in that mode we can still talk to a
    /// manually-launched helper but can't register one.
    private var runningFromAppBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    private func helperService() -> SMAppService {
        SMAppService.daemon(plistName: helperPlistName)
    }

    /// On first launch, attempt to register the helper automatically. macOS
    /// will show a "Background Items Added" notification; the user still
    /// has to flip the switch in System Settings → Login Items.
    private func autoRegisterHelperIfNeeded() {
        guard runningFromAppBundle else { return }
        let service = helperService()
        if service.status == .notRegistered {
            try? service.register()
        }
    }

    @objc private func installHelper(_ sender: NSMenuItem) {
        guard runningFromAppBundle else {
            showAlert(
                title: "Not running from a .app bundle",
                message: "SMAppService can only register helpers that are bundled inside an app. Build with `make` and open `build/ChillPill.app` instead."
            )
            return
        }
        do {
            try helperService().register()
            showAlert(
                title: "Helper registered",
                message: "Finish the install by opening System Settings → Login Items & Extensions and turning ChillPill on."
            )
        } catch {
            showAlert(
                title: "Install failed",
                message: error.localizedDescription
            )
        }
        refresh()
    }

    @objc private func uninstallHelper(_ sender: NSMenuItem) {
        do {
            try helperService().unregister()
            showAlert(
                title: "Helper uninstalled",
                message: "The ChillPill helper daemon has been unregistered. Fan control is disabled until you re-install."
            )
        } catch {
            showAlert(
                title: "Uninstall failed",
                message: error.localizedDescription
            )
        }
        refresh()
    }

    @objc private func openLoginItemsSettings(_ sender: NSMenuItem) {
        // URL scheme Apple documents for the Login Items pane.
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func helperStatusLine() -> String {
        guard runningFromAppBundle else {
            return "Helper: running outside .app bundle (SMAppService disabled)"
        }
        switch helperService().status {
        case .notRegistered:     return "Helper: not installed"
        case .enabled:           return "Helper: running"
        case .requiresApproval:  return "Helper: awaiting approval in Settings"
        case .notFound:          return "Helper: plist not found in bundle"
        @unknown default:        return "Helper: unknown status"
        }
    }

    // MARK: - Refresh (XPC-driven)

    private func refresh() {
        HelperClient.shared.fans { [weak self] fans in
            self?.latestFans = fans
            self?.rebuildMenu()
        }
        HelperClient.shared.temperatures { [weak self] temps in
            self?.latestTemps = temps
            self?.rebuildMenu()
        }
    }

    private func rebuildMenu() {
        let now = Date()
        if let deadline = suppressTitleUpdateUntil, now < deadline {
            // Toast still showing; leave title alone.
        } else {
            suppressTitleUpdateUntil = nil
            updateStatusTitle()
        }

        if menuOpenCount > 0 { return }

        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(sectionHeader("ChillPill"))
        menu.addItem(disabled("  " + helperStatusLine()))
        appendHelperLifecycleItems(to: menu)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(sectionHeader("Fans"))
        if latestFans.isEmpty {
            menu.addItem(disabled("  No fans reported"))
        } else {
            menu.addItem(allFansMenuItem(fans: latestFans))
            for f in latestFans {
                menu.addItem(fanMenuItem(for: f))
            }
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(sectionHeader("Temperatures"))
        if latestTemps.isEmpty {
            menu.addItem(disabled("  No sensors found"))
        } else {
            for (group, list) in groupedTemps(latestTemps) {
                menu.addItem(temperatureGroupItem(group: group, readings: list))
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit ChillPill",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateStatusTitle() {
        guard let hottest = hottestCPU(latestTemps) else {
            statusItem.button?.title = " --°"
            return
        }
        statusItem.button?.title = String(format: " %.0f°", hottest.celsius)
    }

    /// Headline CPU temperature: hottest P-core > hottest .cpu sensor > hottest overall.
    private func hottestCPU(_ temps: [TemperatureDTO]) -> TemperatureDTO? {
        let pCores = temps.filter { $0.rawName.hasPrefix("pACC ") }
        if let hot = pCores.max(by: { $0.celsius < $1.celsius }) { return hot }
        let cpuish = temps.filter { $0.group == .cpu }
        return (cpuish.isEmpty ? temps : cpuish).max { $0.celsius < $1.celsius }
    }

    private func groupedTemps(_ temps: [TemperatureDTO]) -> [(SensorGroup, [TemperatureDTO])] {
        let byGroup = Dictionary(grouping: temps, by: { $0.group })
        return SensorGroup.allCases.compactMap { g in
            guard let list = byGroup[g], !list.isEmpty else { return nil }
            return (g, list.sorted { $0.displayName < $1.displayName })
        }
    }

    // MARK: - Fan menu items

    private func allFansMenuItem(fans: [FanDTO]) -> NSMenuItem {
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

    private func temperatureGroupItem(group: SensorGroup, readings: [TemperatureDTO]) -> NSMenuItem {
        let avg = readings.map { $0.celsius }.reduce(0, +) / Double(readings.count)
        let title = String(format: "%@ — %.1f°C avg (%d sensor%@)",
                           group.rawValue, avg, readings.count,
                           readings.count == 1 ? "" : "s")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        for r in readings {
            submenu.addItem(disabled(String(format: "%@  %.1f°C", r.displayName, r.celsius)))
        }
        item.submenu = submenu
        return item
    }

    private func fanMenuItem(for f: FanDTO) -> NSMenuItem {
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

    private func modeLabelFor(_ f: FanDTO) -> String {
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
            return String(format: "forced (range %.0f/%.0f)", mn, mx)
        case .some(let m):
            return "mode \(m)"
        case .none:
            return "?"
        }
    }

    private func buildFanSubmenu(for f: FanDTO) -> NSMenu {
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
        let handler: (String?) -> Void = { [weak self] errMessage in
            if let msg = errMessage { self?.notifyWriteRejected(reason: msg) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.refresh()
            }
        }
        switch action.scope {
        case .one(let idx):
            if let rpm = action.value {
                HelperClient.shared.setFanTarget(index: idx, rpm: rpm, completion: handler)
            } else {
                HelperClient.shared.setFanAuto(index: idx, completion: handler)
            }
        case .all:
            if let pct = action.value {
                HelperClient.shared.setAllFansTarget(pct: pct, completion: handler)
            } else {
                HelperClient.shared.setAllFansAuto(completion: handler)
            }
        }
    }

    private func notifyWriteRejected(reason: String) {
        guard let button = statusItem.button else { return }
        button.title = " ⚠︎ \(reason)"
        let expiry: TimeInterval = 2.5
        suppressTitleUpdateUntil = Date().addingTimeInterval(expiry)
        DispatchQueue.main.asyncAfter(deadline: .now() + expiry + 0.05) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Helper lifecycle menu items

    private func appendHelperLifecycleItems(to menu: NSMenu) {
        guard runningFromAppBundle else {
            return  // SPM dev mode — no SMAppService actions available
        }
        switch helperService().status {
        case .notRegistered:
            let install = NSMenuItem(title: "Install Helper…",
                                     action: #selector(installHelper(_:)),
                                     keyEquivalent: "")
            install.target = self
            menu.addItem(install)
        case .requiresApproval:
            let openSettings = NSMenuItem(title: "Open Login Items Settings…",
                                          action: #selector(openLoginItemsSettings(_:)),
                                          keyEquivalent: "")
            openSettings.target = self
            menu.addItem(openSettings)
            let uninstall = NSMenuItem(title: "Uninstall Helper",
                                       action: #selector(uninstallHelper(_:)),
                                       keyEquivalent: "")
            uninstall.target = self
            menu.addItem(uninstall)
        case .enabled:
            let uninstall = NSMenuItem(title: "Uninstall Helper",
                                       action: #selector(uninstallHelper(_:)),
                                       keyEquivalent: "")
            uninstall.target = self
            menu.addItem(uninstall)
        case .notFound:
            menu.addItem(disabled("  Plist missing — rebuild the .app bundle"))
        @unknown default:
            break
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
