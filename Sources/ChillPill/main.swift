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

/// UserDefaults key: JSON-encoded `DisplaySensor` driving the menu-bar
/// title temperature. Absent / unreadable falls back to `.auto`.
private let displaySensorKey = "ChillPill.DisplaySensor"

/// Which temperature drives the menu-bar title number. `.auto` keeps the
/// legacy heuristic (hottest P-core, fall back through CPU-adjacent
/// groups, then any temp). `.selector` defers to a `SensorSelector` —
/// max or avg of a named group, mirroring the controller's picker.
enum DisplaySensor: Codable, Equatable {
    case auto
    case selector(SensorSelector)
}

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

/// Same reason as `FanActionBox` — `SensorSelector` is a value type and
/// NSMenuItem.representedObject needs an `AnyObject`.
final class SensorSelectorBox: NSObject {
    let selector: SensorSelector
    init(_ selector: SensorSelector) { self.selector = selector }
}

/// Same reason as `FanActionBox` — `DisplaySensor` is a value type.
final class DisplaySensorBox: NSObject {
    let choice: DisplaySensor
    init(_ choice: DisplaySensor) { self.choice = choice }
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
    private var hasShownApprovalPromptThisLaunch = false
    /// Flipped true once `maybeShowApprovalPromptOnce` has had its first
    /// chance to run (whether or not it actually showed the alert). Gates
    /// the `⚠︎` status-bar badge so it doesn't flicker on between app
    /// launch and the deferred main-queue block that evaluates state.
    private var launchApprovalCheckComplete = false

    /// Counts consecutive `refresh()` cycles where `SMAppService` says the
    /// helper is `.enabled` but the XPC proxy is erroring or unavailable.
    /// This is the signature of a stale launchd registration from a
    /// reinstall — issue #8, and specifically the `copy_bundle_path` spawn
    /// loop variant — that the system won't recover from on its own.
    private var consecutiveXPCFailuresWhileEnabled: Int = 0
    /// Threshold before auto-recovery fires. At 2-second refresh cadence,
    /// 7 cycles = 14 seconds — past a typical first-spawn window, past
    /// wake-from-sleep where the XPC connection is briefly interrupted,
    /// and still well under "user notices and files a bug." launchd's
    /// own retry interval in the spawn-loop case is ~10 s.
    private static let staleHelperFailureThreshold = 7
    /// One-shot per launch — a recovery attempt either works (next refresh
    /// succeeds and the counter resets) or it doesn't, in which case we
    /// don't want to keep nagging the user with the same modal.
    private var hasAttemptedStaleHelperRecoveryThisLaunch = false

    private var latestFans: [FanDTO] = []
    private var latestTemps: [TemperatureDTO] = []
    private var latestControlState: ControlStateDTO?

    /// User's choice of which sensor drives the menu-bar title. Loaded
    /// from UserDefaults at launch; mutated only via `applyDisplaySensor`.
    private var displaySensor: DisplaySensor = .auto

    /// CPU-family sensor groups that nest under a single "CPU" parent in
    /// the menu. `.cpu` is the Intel-era / miscellaneous fallback; under
    /// the parent it's relabelled "Other" to avoid a "CPU → CPU" row.
    private static let cpuFamilyGroups: Set<SensorGroup> = [.pcore, .ecore, .soc, .cpu]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "ChillPill")
            button.imagePosition = .imageLeft
            button.title = " --°"
        }

        installSignalHandlers()
        loadDisplaySensor()
        autoRegisterHelperIfNeeded()
        refresh()

        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Deferred so launch finishes (status bar drawn, timer scheduled)
        // before the modal alert blocks the main queue. One-shot per launch.
        DispatchQueue.main.async { [weak self] in
            self?.maybeShowApprovalPromptOnce()
        }
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
        openLoginItemsSettings()
    }

    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows a modal alert when the helper is stuck in `.requiresApproval` on
    /// launch. Fires at most once per launch, honors the explicit-uninstall
    /// flag, and is a no-op outside the .app bundle (swift run, etc.).
    private func maybeShowApprovalPromptOnce() {
        // Always mark the launch check as complete before returning, so the
        // status-bar badge can start honoring state updates regardless of
        // whether this specific evaluation decided to show the alert.
        defer { launchApprovalCheckComplete = true }
        guard runningFromAppBundle,
              !userDidUninstall,
              !hasShownApprovalPromptThisLaunch,
              helperService().status == .requiresApproval
        else { return }
        hasShownApprovalPromptThisLaunch = true

        let alert = NSAlert()
        alert.messageText = "ChillPill needs approval to read temperatures"
        alert.informativeText = "Open System Settings → Login Items & Extensions and turn ChillPill on. Until then, the menu bar icon will show ⚠︎ and no temperatures will be available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            openLoginItemsSettings()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    /// Detects the stale-registration failure mode described in issue #8:
    /// `SMAppService` reports `.enabled` but XPC calls keep failing because
    /// launchd's bundle-UUID → path mapping is orphaned (typically after a
    /// reinstall at a different path or with a new ad-hoc signature). We
    /// can't see launchd's spawn-loop directly from the UI process, but we
    /// can see its signature: approved status + persistent XPC failures.
    private func checkHelperHealth() {
        guard runningFromAppBundle, !userDidUninstall else {
            consecutiveXPCFailuresWhileEnabled = 0
            return
        }
        let smStatus = helperService().status
        guard smStatus == .enabled else {
            // Any non-`.enabled` state is already surfaced via the ⚠︎ badge
            // and the existing approval-prompt flow; don't attribute those
            // cases to stale registration.
            consecutiveXPCFailuresWhileEnabled = 0
            // Re-fire the approval modal if the user is stuck in
            // `.requiresApproval` and the launch-time one-shot has been
            // rearmed (which `attemptStaleHelperRecovery` does so the user
            // isn't left with a silent ⚠︎ if they dismiss Login Items
            // without approving). Gated on `launchApprovalCheckComplete`
            // so the deferred launch-time prompt in
            // `applicationDidFinishLaunching` always wins first — the
            // synchronous `refresh()` there would otherwise race this
            // path and block app startup on a modal.
            // `maybeShowApprovalPromptOnce` is itself guarded against
            // double-firing via `hasShownApprovalPromptThisLaunch`.
            if smStatus == .requiresApproval,
               launchApprovalCheckComplete,
               !hasShownApprovalPromptThisLaunch,
               menuOpenCount == 0 {
                maybeShowApprovalPromptOnce()
            }
            return
        }
        switch HelperClient.shared.lastStatus {
        case .running:
            consecutiveXPCFailuresWhileEnabled = 0
        case .error, .notInstalled:
            consecutiveXPCFailuresWhileEnabled += 1
            if consecutiveXPCFailuresWhileEnabled >= Self.staleHelperFailureThreshold,
               !hasAttemptedStaleHelperRecoveryThisLaunch {
                // Don't fire the modal while the user has the menu bar
                // dropdown open — NSAlert.runModal steals focus and
                // dismisses any active menu tracking session, which is
                // jarring mid-interaction. Stay at the threshold and
                // retry on the next refresh (the one-shot guard is
                // tripped only when we *actually* show the alert).
                guard menuOpenCount == 0 else { return }
                hasAttemptedStaleHelperRecoveryThisLaunch = true
                os_log("helper appears stuck (enabled + %d XPC failures) — offering recovery",
                       log: log, type: .error, consecutiveXPCFailuresWhileEnabled)
                showStaleHelperRecoveryAlert()
            }
        case .unknown:
            // Pre-first-call window — don't penalize the grace period.
            break
        }
    }

    private func showStaleHelperRecoveryAlert() {
        let alert = NSAlert()
        alert.messageText = "ChillPill's helper isn't responding"
        alert.informativeText = """
            The helper is approved in Login Items, but it isn't answering. \
            This usually means the app was replaced (e.g. via a new build) \
            and the background registration is stale.

            Click "Reset" to unregister and re-register the helper. You'll \
            need to approve it once more in Login Items & Extensions.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        attemptStaleHelperRecovery()
    }

    private func attemptStaleHelperRecovery() {
        let service = helperService()
        // `unregister()` may throw if state is ambiguous; swallow — the
        // register call below is the real recovery and tolerates either
        // "was registered, now isn't" or "wasn't registered to begin with".
        do {
            try service.unregister()
        } catch {
            os_log("stale-helper recovery: unregister warning: %{public}@",
                   log: log, type: .info, error.localizedDescription)
        }
        do {
            try service.register()
            os_log("stale-helper recovery: register() succeeded; status=%d",
                   log: log, type: .info, service.status.rawValue)
        } catch let e as NSError {
            // Expected path — register throws code=1 while the user has not
            // yet flipped the Login Items switch; the service transitions
            // to .requiresApproval and our existing status-bar ⚠︎ plus the
            // Login Items deep-link below carry the rest of the recovery.
            if e.domain == "SMAppServiceErrorDomain", e.code == 1 {
                os_log("stale-helper recovery: awaiting user approval",
                       log: log, type: .info)
            } else {
                os_log("stale-helper recovery: register failed: %{public}@",
                       log: log, type: .error, e.localizedDescription)
            }
        }
        consecutiveXPCFailuresWhileEnabled = 0
        // After recovery, state is almost certainly `.requiresApproval`.
        // Rearm the approval-prompt one-shot so that if the user dismisses
        // the Login Items pane without approving, the existing approval
        // modal can still nudge them on a later refresh — without this, a
        // dismissed recovery leaves the app in silent-⚠︎ mode with no
        // further prompt until quit-and-relaunch.
        hasShownApprovalPromptThisLaunch = false
        openLoginItemsSettings()
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
        // Sample the state left by the *previous* refresh cycle before
        // firing a new one. This is the right moment to detect the
        // "SMAppService says enabled but XPC keeps failing" stale-
        // registration pattern from issue #8.
        checkHelperHealth()

        HelperClient.shared.fans { [weak self] fans in
            self?.latestFans = fans
            self?.rebuildMenu()
        }
        HelperClient.shared.temperatures { [weak self] temps in
            self?.latestTemps = temps
            self?.rebuildMenu()
        }
        refreshControllerOnly()
    }

    /// Narrow refresh for controller-only mutations (setpoint / sensor /
    /// preset / resume-on-launch). Avoids re-fetching fans + temps when
    /// only the controller state actually changed.
    private func refreshControllerOnly() {
        HelperClient.shared.getControlState { [weak self] state in
            self?.latestControlState = state
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

        menu.addItem(sectionHeader("Control"))
        appendControllerItems(to: menu)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(sectionHeader("Temperatures"))
        menu.addItem(displaySensorSubmenu())
        if latestTemps.isEmpty {
            menu.addItem(disabled("  No sensors found"))
        } else {
            let grouped = groupedTemps(latestTemps)
            let cpuFamily = grouped.filter { Self.cpuFamilyGroups.contains($0.0) }
            let others = grouped.filter { !Self.cpuFamilyGroups.contains($0.0) }
            if !cpuFamily.isEmpty {
                menu.addItem(cpuFamilyMenuItem(children: cpuFamily))
            }
            for (group, list) in others {
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
        // When SMAppService registration hasn't completed — either awaiting
        // user approval after install, or not yet registered — signal that
        // the app needs attention instead of showing a silent " --°". If the
        // user deliberately uninstalled, suppress: they don't want the nag.
        // Also gated on `launchApprovalCheckComplete` so we don't flicker
        // " ⚠︎" in the brief window between app launch and the deferred
        // approval-prompt evaluation.
        if runningFromAppBundle, !userDidUninstall, launchApprovalCheckComplete {
            let status = helperService().status
            if status == .requiresApproval
                || status == .notRegistered
                || status == .notFound {
                statusItem.button?.title = " ⚠︎"
                return
            }
        }
        guard let celsius = displayedCelsius(latestTemps) else {
            statusItem.button?.title = " --°"
            return
        }
        statusItem.button?.title = String(format: " %.0f°", celsius)
    }

    /// Resolves `displaySensor` against the latest readings. Returns nil
    /// when the chosen group has no readings — caller renders " --°".
    private func displayedCelsius(_ temps: [TemperatureDTO]) -> Double? {
        switch displaySensor {
        case .auto:
            return hottestCPU(temps)?.celsius
        case .selector(let sel):
            let group: SensorGroup
            switch sel {
            case .groupMax(let g), .groupAvg(let g): group = g
            }
            let pool = temps.filter { $0.group == group }
            guard !pool.isEmpty else { return nil }
            switch sel {
            case .groupMax: return pool.max { $0.celsius < $1.celsius }?.celsius
            case .groupAvg: return pool.map(\.celsius).reduce(0, +) / Double(pool.count)
            }
        }
    }

    private func hottestCPU(_ temps: [TemperatureDTO]) -> TemperatureDTO? {
        // Prefer a raw P-core reading — hottest Firestorm/Avalanche/etc.
        // sensor is the best headline number under CPU load.
        let pCores = temps.filter { $0.rawName.hasPrefix("pACC ") }
        if let hot = pCores.max(by: { $0.celsius < $1.celsius }) { return hot }
        // Fall back through any CPU-adjacent group before going to all temps.
        let cpuish = temps.filter { Self.cpuFamilyGroups.contains($0.group) }
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
        let summary: String
        if latestControlState?.enabled == true {
            if let output = latestControlState?.lastOutputPercent {
                summary = String(format: "All fans: %.0f RPM avg — controller %.0f%%", avgRPM, output)
            } else {
                summary = String(format: "All fans: %.0f RPM avg — controller", avgRPM)
            }
        } else if allAuto {
            summary = String(format: "All fans: %.0f RPM avg — auto", avgRPM)
        } else {
            summary = String(format: "All fans: %.0f RPM avg", avgRPM)
        }
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

    private func temperatureGroupItem(group: SensorGroup,
                                      readings: [TemperatureDTO],
                                      displayName: String? = nil) -> NSMenuItem {
        let name = displayName ?? group.rawValue
        let avg = readings.map { $0.celsius }.reduce(0, +) / Double(readings.count)
        let title = String(format: "%@ — %.1f°C avg (%d sensor%@)",
                           name, avg, readings.count,
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

    /// Rolls up the CPU-family subgroups (P-Cores / E-Cores / SoC / Other)
    /// under a single "CPU" parent with an aggregate average across all
    /// contained sensors. Each child remains its own submenu.
    private func cpuFamilyMenuItem(children: [(SensorGroup, [TemperatureDTO])]) -> NSMenuItem {
        let all = children.flatMap { $0.1 }
        let avg = all.map { $0.celsius }.reduce(0, +) / Double(all.count)
        let title = String(format: "CPU — %.1f°C avg (%d sensor%@)",
                           avg, all.count, all.count == 1 ? "" : "s")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        for (group, list) in children {
            let displayName: String? = (group == .cpu) ? "Other" : nil
            submenu.addItem(temperatureGroupItem(group: group,
                                                 readings: list,
                                                 displayName: displayName))
        }
        item.submenu = submenu
        return item
    }

    // MARK: - Controller menu items

    /// Preset setpoint choices for the "Target temperature" submenu.
    /// The low values (30, 40 °C) are sized for surface-temp targets
    /// (Ambient / Palm sensor); the higher values are sized for silicon
    /// (CPU / GPU). Mixing low preset + CPU sensor will pin fans to max,
    /// which is the user's call.
    private static let setpointPresets: [Double] = [30, 40, 65, 72, 75, 80, 85]

    /// Sensor-selector choices for the picker submenu. All `max` variants
    /// first, then all `avg` variants, split by a separator. Palm-rest /
    /// skin sensors (`Ts*` SMC keys) land in the `.ambient` group, so
    /// "Ambient" is the right pick if the user wants to cool based on
    /// surface temperature instead of silicon temperature.
    private static let sensorChoices: [(label: String, selector: SensorSelector)] = [
        ("P-Cores (max)",      .groupMax(.pcore)),
        ("E-Cores (max)",      .groupMax(.ecore)),
        ("SoC (max)",          .groupMax(.soc)),
        ("CPU fallback (max)", .groupMax(.cpu)),
        ("GPU (max)",          .groupMax(.gpu)),
        ("Memory (max)",       .groupMax(.memory)),
        ("Storage (max)",      .groupMax(.storage)),
        ("Battery (max)",      .groupMax(.battery)),
        ("Ambient / Palm (max)", .groupMax(.ambient)),
        ("P-Cores (avg)",      .groupAvg(.pcore)),
        ("E-Cores (avg)",      .groupAvg(.ecore)),
        ("SoC (avg)",          .groupAvg(.soc)),
        ("CPU fallback (avg)", .groupAvg(.cpu)),
        ("GPU (avg)",          .groupAvg(.gpu)),
        ("Memory (avg)",       .groupAvg(.memory)),
        ("Storage (avg)",      .groupAvg(.storage)),
        ("Battery (avg)",      .groupAvg(.battery)),
        ("Ambient / Palm (avg)", .groupAvg(.ambient))
    ]

    private func appendControllerItems(to menu: NSMenu) {
        guard let state = latestControlState else {
            menu.addItem(disabled("  Controller: connecting…"))
            return
        }

        // Status line — mode + live reading when enabled.
        let statusLine: String
        if state.enabled {
            if let reading = state.currentReadingCelsius,
               let error = state.currentErrorCelsius,
               let output = state.lastOutputPercent {
                statusLine = String(format: "  Active — %.1f°C / err %+.1f°C / out %.0f%%",
                                    reading, error, output)
            } else {
                statusLine = "  Active — waiting for first tick…"
            }
        } else if let reason = state.fallbackReason {
            statusLine = "  ⚠︎ Disabled — \(reason)"
        } else {
            statusLine = "  Disabled"
        }
        menu.addItem(disabled(statusLine))

        // Target temperature: always shown, even when disabled (so the user
        // can see / change the setpoint before flipping enable on).
        menu.addItem(disabled(String(format: "  Target: %.0f°C — Sensor: %@ — Preset: %@",
                                      state.setpointCelsius,
                                      shortLabel(for: state.sensor),
                                      state.preset.rawValue.capitalized)))

        // Enable / disable toggle.
        let toggle = NSMenuItem(
            title: state.enabled ? "Disable Controller" : "Enable Controller",
            action: #selector(toggleController(_:)),
            keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        // Target temperature submenu.
        menu.addItem(setpointSubmenu(state: state))
        // Sensor submenu.
        menu.addItem(sensorSubmenu(state: state))
        // Preset submenu.
        menu.addItem(presetSubmenu(state: state))

        // Resume-on-reboot checkbox.
        let resume = NSMenuItem(title: "Resume on Reboot",
                                action: #selector(toggleResumeOnLaunch(_:)),
                                keyEquivalent: "")
        resume.target = self
        resume.state = state.resumeOnLaunch ? .on : .off
        menu.addItem(resume)
    }

    private func shortLabel(for sensor: SensorSelector) -> String {
        switch sensor {
        case .groupMax(let g): return "\(g.rawValue) max"
        case .groupAvg(let g): return "\(g.rawValue) avg"
        }
    }

    private func setpointSubmenu(state: ControlStateDTO) -> NSMenuItem {
        let parent = NSMenuItem(title: "Target Temperature",
                                action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        for preset in Self.setpointPresets {
            let item = NSMenuItem(
                title: String(format: "%.0f°C", preset),
                action: #selector(applySetpoint(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: preset)
            item.state = (abs(state.setpointCelsius - preset) < 0.1) ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(NSMenuItem.separator())
        let custom = NSMenuItem(title: "Custom…",
                                action: #selector(promptCustomSetpoint(_:)),
                                keyEquivalent: "")
        custom.target = self
        submenu.addItem(custom)
        parent.submenu = submenu
        return parent
    }

    private func sensorSubmenu(state: ControlStateDTO) -> NSMenuItem {
        let parent = NSMenuItem(title: "Sensor", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        appendSensorChoiceRows(
            to: submenu,
            action: #selector(applySensor(_:)),
            isSelected: { $0 == state.sensor },
            makeBox: { SensorSelectorBox($0) }
        )
        parent.submenu = submenu
        return parent
    }

    /// Builds one checkmarked row per `sensorChoices` entry, inserting a
    /// single separator between the `max` and `avg` blocks. Shared by the
    /// controller's "Sensor" picker and the menu-bar display picker — they
    /// have identical layout but different action targets, selection state,
    /// and representedObject types.
    private func appendSensorChoiceRows(
        to submenu: NSMenu,
        action: Selector,
        isSelected: (SensorSelector) -> Bool,
        makeBox: (SensorSelector) -> NSObject
    ) {
        var lastWasMax: Bool?
        for choice in Self.sensorChoices {
            let isMax: Bool = {
                if case .groupMax = choice.selector { return true } else { return false }
            }()
            if let prev = lastWasMax, prev != isMax {
                submenu.addItem(NSMenuItem.separator())
            }
            lastWasMax = isMax
            let item = NSMenuItem(title: choice.label,
                                  action: action,
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = makeBox(choice.selector)
            item.state = isSelected(choice.selector) ? .on : .off
            submenu.addItem(item)
        }
    }

    private func presetSubmenu(state: ControlStateDTO) -> NSMenuItem {
        let parent = NSMenuItem(title: "Preset", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        for preset in ControlPreset.allCases {
            let item = NSMenuItem(title: preset.rawValue.capitalized,
                                  action: #selector(applyPreset(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue as NSString
            item.state = (preset == state.preset) ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: - Controller actions

    @objc private func toggleController(_ sender: NSMenuItem) {
        let newEnabled = !(latestControlState?.enabled ?? false)
        HelperClient.shared.setControlEnabled(newEnabled) { [weak self] err in
            if let err = err {
                self?.notifyWriteRejected(reason: err.localizedDescription)
            }
            self?.refresh()
        }
    }

    @objc private func toggleResumeOnLaunch(_ sender: NSMenuItem) {
        let newFlag = !(latestControlState?.resumeOnLaunch ?? false)
        HelperClient.shared.setControlResumeOnLaunch(newFlag) { [weak self] err in
            if let err = err {
                self?.notifyWriteRejected(reason: err.localizedDescription)
            }
            self?.refreshControllerOnly()
        }
    }

    @objc private func applySetpoint(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        HelperClient.shared.setControlSetpoint(n.doubleValue) { [weak self] err in
            if let err = err {
                self?.notifyWriteRejected(reason: err.localizedDescription)
            }
            self?.refreshControllerOnly()
        }
    }

    @objc private func promptCustomSetpoint(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Set target temperature"
        alert.informativeText = "Enter a value between 20 and 110 °C."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        if let current = latestControlState?.setpointCelsius {
            field.stringValue = String(format: "%.0f", current)
        } else {
            field.placeholderString = "75"
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        // Without this, the text field doesn't take first-responder on some
        // macOS versions and the user has to click before typing.
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let value = Double(field.stringValue), value >= 20, value <= 110 else {
            notifyWriteRejected(reason: "setpoint must be 20–110 °C")
            return
        }
        HelperClient.shared.setControlSetpoint(value) { [weak self] err in
            if let err = err {
                self?.notifyWriteRejected(reason: err.localizedDescription)
            }
            self?.refreshControllerOnly()
        }
    }

    @objc private func applySensor(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SensorSelectorBox else { return }
        HelperClient.shared.setControlSensor(box.selector) { [weak self] err in
            if let err = err {
                self?.notifyWriteRejected(reason: err.localizedDescription)
            }
            self?.refreshControllerOnly()
        }
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        // The UI builds these raw values from `ControlPreset.allCases` so a
        // decode failure here would mean the enum grew a case and the UI
        // wasn't updated — bail rather than silently sending a surprise
        // write with some default preset.
        guard let name = sender.representedObject as? String,
              let preset = ControlPreset(rawValue: name) else {
            return
        }
        HelperClient.shared.setControlPreset(preset) { [weak self] err in
            if let err = err {
                self?.notifyWriteRejected(reason: err.localizedDescription)
            }
            self?.refreshControllerOnly()
        }
    }

    // MARK: - Fan menu items

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
        // Controller ownership wins — when the PI loop is driving the fan,
        // the `mode == 1` + `targetRPM` pair the SMC reports reflects *its*
        // last write, not a direct user choice. Surfacing "67%" here would
        // misleadingly imply the user set 67%; show "controller 67%" so the
        // active owner is clear.
        if latestControlState?.enabled == true {
            if let output = latestControlState?.lastOutputPercent {
                return String(format: "controller %.0f%%", output)
            }
            return "controller"
        }
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

    // MARK: - Display sensor

    private func loadDisplaySensor() {
        guard let data = UserDefaults.standard.data(forKey: displaySensorKey) else {
            return
        }
        do {
            displaySensor = try JSONDecoder().decode(DisplaySensor.self, from: data)
        } catch {
            // Stale / corrupt blob — likely a downgrade from a future build
            // that added an enum case, or a hand-edit. Drop the bad value
            // so we don't re-fail every launch, and fall back to .auto.
            os_log("display sensor decode failed (%{public}@) — resetting to auto",
                   log: log, type: .info, error.localizedDescription)
            UserDefaults.standard.removeObject(forKey: displaySensorKey)
        }
    }

    private func saveDisplaySensor() {
        guard let data = try? JSONEncoder().encode(displaySensor) else { return }
        UserDefaults.standard.set(data, forKey: displaySensorKey)
    }

    /// Short label for the parent submenu row. When the user picked a
    /// specific group that currently has no readings, annotate so it's
    /// obvious why the menu bar shows "--°" instead of a number.
    private func displaySensorLabel(_ d: DisplaySensor, temps: [TemperatureDTO]) -> String {
        switch d {
        case .auto:
            return "Auto"
        case .selector(let s):
            let label = shortLabel(for: s)
            let group: SensorGroup
            switch s {
            case .groupMax(let g), .groupAvg(let g): group = g
            }
            let hasReadings = temps.contains { $0.group == group }
            return hasReadings ? label : "\(label) (no readings)"
        }
    }

    private func displaySensorSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(
            title: "Menu Bar Sensor: \(displaySensorLabel(displaySensor, temps: latestTemps))",
            action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self

        let auto = NSMenuItem(title: "Auto (hottest CPU)",
                              action: #selector(applyDisplaySensor(_:)),
                              keyEquivalent: "")
        auto.target = self
        auto.representedObject = DisplaySensorBox(.auto)
        auto.state = (displaySensor == .auto) ? .on : .off
        submenu.addItem(auto)
        submenu.addItem(NSMenuItem.separator())

        appendSensorChoiceRows(
            to: submenu,
            action: #selector(applyDisplaySensor(_:)),
            isSelected: { self.displaySensor == .selector($0) },
            makeBox: { DisplaySensorBox(.selector($0)) }
        )
        parent.submenu = submenu
        return parent
    }

    @objc private func applyDisplaySensor(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? DisplaySensorBox else { return }
        displaySensor = box.choice
        saveDisplaySensor()
        // Update the title synchronously — `rebuildMenu()` would early-return
        // here because the menu is still tracking when the action fires
        // (`menuDidClose` runs after). The next 2-second timer rebuild
        // refreshes the parent label and checkmark state in the dropdown.
        updateStatusTitle()
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
