import AppKit
import ServiceManagement
import os.log
import ChillPillShared

/// Filename of the launchd plist inside `Contents/Library/LaunchDaemons/`.
private let helperPlistName = "dev.chillpill.helper.plist"

/// UserDefaults key: set when the user has explicitly uninstalled the
/// helper. Suppresses the auto-register-on-launch behavior so re-launch
/// doesn't surprise the user with a second "Background Items Added" prompt.
private let uninstallFlagKey = "ChillPill.UserDidUninstallHelper"

/// Describes exactly one action the menu can request. Each case carries the
/// data its XPC call needs — no overloaded `Double?` whose meaning depends
/// on a sibling enum, so the `applyFanAction` switch is exhaustive and
/// unit-safe (RPM vs percent can't be confused).
enum FanAction {
    case setAuto(index: Int)
    case setTargetRPM(index: Int, rpm: Double)
    case setAllAuto
    case setAllPercent(Double)
}

/// Box for `NSMenuItem.representedObject` — NSMenuItem requires a reference
/// type, so we wrap the enum.
final class FanActionBox: NSObject {
    let action: FanAction
    init(_ action: FanAction) { self.action = action }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let log = OSLog(subsystem: "dev.chillpill", category: "App")

    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?

    private var menuOpenCount = 0

    private var suppressTitleUpdateUntil: Date?
    private var fatalSignalFired = false

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
        // Fire-and-forget — blocking on a DispatchSemaphore here would
        // deadlock the main queue against its own async reply. The helper
        // has its own SIGTERM handler that restores fans, so this is a
        // secondary safety net at best.
        HelperClient.shared.prepareForShutdown()
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
        HelperClient.shared.prepareForShutdown()
        // Give the XPC message a brief moment to depart the socket before
        // we exit — no semaphore, no deadlock.
        Thread.sleep(forTimeInterval: 0.1)
        exit(0)
    }

    // MARK: - Helper lifecycle (SMAppService)

    /// True when running from a proper `.app` bundle — SMAppService can only
    /// register daemons bundled inside an app. `swift run` and bare
    /// executables return false; in that mode we can talk to a
    /// manually-launched helper but can't auto-register one.
    private var runningFromAppBundle: Bool {
        Bundle.main.bundleIdentifier == "dev.chillpill.ChillPill"
    }

    private var userDidUninstall: Bool {
        get { UserDefaults.standard.bool(forKey: uninstallFlagKey) }
        set { UserDefaults.standard.set(newValue, forKey: uninstallFlagKey) }
    }

    private func helperService() -> SMAppService {
        SMAppService.daemon(plistName: helperPlistName)
    }

    /// On first launch (or any launch when the helper has never been
    /// registered), kick off `register()`. macOS then shows the
    /// "Background Items Added" banner; the user approves in Settings.
    ///
    /// Skipped if the user has explicitly uninstalled — re-installing
    /// requires them to click the menu item explicitly.
    private func autoRegisterHelperIfNeeded() {
        guard runningFromAppBundle else { return }
        guard !userDidUninstall else { return }
        let service = helperService()
        // Register when the system hasn't seen the daemon yet. Both
        // .notRegistered and .notFound mean "no current registration" — the
        // Apple docs describe them as separate states, but in practice a
        // fresh app install starts in .notFound and transitions to
        // .requiresApproval after a successful register() call (the
        // "Operation not permitted" NSError it throws in that case is
        // actually the "waiting on the user to flip the Login Items switch"
        // signal, not a hard failure).
        guard service.status == .notRegistered || service.status == .notFound else {
            return
        }
        do {
            try service.register()
            os_log("SMAppService register() succeeded; status now %{public}d",
                   log: log, type: .info, service.status.rawValue)
        } catch let e as NSError {
            // code=1 ("Operation not permitted") is the expected result when
            // the user has not yet approved the daemon in Login Items; the
            // registration itself is accepted and status moves to
            // .requiresApproval. Treat any other error as a real failure.
            if e.domain == "SMAppServiceErrorDomain", e.code == 1 {
                os_log("SMAppService register queued for user approval",
                       log: log, type: .info)
            } else {
                os_log("SMAppService register failed: %{public}@",
                       log: log, type: .error, e.localizedDescription)
            }
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
        userDidUninstall = false
        do {
            try helperService().register()
            showAlert(
                title: "Helper registered",
                message: "Open System Settings → Login Items & Extensions and turn ChillPill on to finish the install."
            )
        } catch let e as NSError {
            if e.domain == "SMAppServiceErrorDomain", e.code == 1 {
                // Expected — registration was accepted, user approval pending.
                showAlert(
                    title: "Helper installed — approval required",
                    message: "Open System Settings → Login Items & Extensions and turn ChillPill on to finish the install."
                )
            } else {
                os_log("manual helper install failed: %{public}@",
                       log: log, type: .error, e.localizedDescription)
                showAlert(
                    title: "Install failed",
                    message: e.localizedDescription
                )
            }
        }
        refresh()
    }

    @objc private func uninstallHelper(_ sender: NSMenuItem) {
        do {
            try helperService().unregister()
            userDidUninstall = true
            showAlert(
                title: "Helper uninstalled",
                message: "The ChillPill helper daemon has been unregistered. Fan control is disabled until you re-install."
            )
        } catch {
            os_log("helper uninstall failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            showAlert(
                title: "Uninstall failed",
                message: error.localizedDescription
            )
        }
        refresh()
    }

    @objc private func openLoginItemsSettings(_ sender: NSMenuItem) {
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
        case .notFound:          return "Helper: not installed"
        @unknown default:        return "Helper: unknown status"
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuOpenCount += 1
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpenCount = max(0, menuOpenCount - 1)
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

    private func hottestCPU(_ temps: [TemperatureDTO]) -> TemperatureDTO? {
        // Prefer a raw P-core reading — hottest Firestorm/Avalanche/etc.
        // sensor is the best headline number under CPU load.
        let pCores = temps.filter { $0.rawName.hasPrefix("pACC ") }
        if let hot = pCores.max(by: { $0.celsius < $1.celsius }) { return hot }
        // Fall back through any CPU-adjacent group before going to all temps.
        let cpuGroups: Set<SensorGroup> = [.pcore, .ecore, .soc, .cpu]
        let cpuish = temps.filter { cpuGroups.contains($0.group) }
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
        auto.representedObject = FanActionBox(.setAllAuto)
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
            itm.representedObject = FanActionBox(.setAllPercent(Double(pct)))
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
        auto.representedObject = FanActionBox(.setAuto(index: f.index))
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
                item.representedObject = FanActionBox(.setTargetRPM(index: f.index, rpm: rpm))
                submenu.addItem(item)
            }
        } else if let mn = f.minRPM, let mx = f.maxRPM {
            submenu.addItem(disabled(String(format: "  Min/Max invalid: %.0f/%.0f", mn, mx)))
        } else {
            submenu.addItem(disabled("  Min/Max not reported"))
        }
        return submenu
    }

    // MARK: - Helper lifecycle menu items

    private func appendHelperLifecycleItems(to menu: NSMenu) {
        guard runningFromAppBundle else {
            return
        }
        switch helperService().status {
        case .notRegistered, .notFound:
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
        @unknown default:
            break
        }
    }

    // MARK: - Actions

    @objc private func applyFanAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? FanActionBox else { return }
        let handler: (NSError?) -> Void = { [weak self] err in
            if let err = err {
                self?.notifyWriteRejected(reason: err.localizedDescription)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.refresh()
            }
        }
        switch box.action {
        case .setAuto(let index):
            HelperClient.shared.setFanAuto(index: index, completion: handler)
        case .setTargetRPM(let index, let rpm):
            HelperClient.shared.setFanTarget(index: index, rpm: rpm, completion: handler)
        case .setAllAuto:
            HelperClient.shared.setAllFansAuto(completion: handler)
        case .setAllPercent(let pct):
            HelperClient.shared.setAllFansTarget(pct: pct, completion: handler)
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
