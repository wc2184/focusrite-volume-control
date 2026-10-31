//
//  FC2HealthMonitor.swift
//  Focusrite Volume Control
//
//  Detects when Focusrite Control 2 loses its USB control connection to the
//  interface, and relaunches FC2 minimized to recover it.
//

import AppKit
import ApplicationServices
import Combine
import os.log

/// FC2 keeps moving its slider while every USB write to the interface times
/// out, so its Accessibility tree cannot reveal the failure. FC2's own log can:
/// it records a failed meter read every ~9 seconds for as long as it lasts.
final class FC2HealthMonitor: ObservableObject {

    struct Policy {
        /// Real outages log an error every ~9 s; a lone error happens on unplug.
        var errorThreshold = 3
        var errorWindow: TimeInterval = 30
        /// Give a relaunched FC2 time to reach the device before judging it.
        var restartCooldown: TimeInterval = 120
        /// Stop restarting if relaunches are not fixing it.
        var maxRestarts = 3
        var restartBudgetWindow: TimeInterval = 3600
    }

    static let defaultLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Focusrite/Focusrite Control 2/fc2.log")

    @Published private(set) var isUnresponsive = false

    /// Checked before every restart (preference and Focusrite-output gating).
    var isRestartAllowed: () -> Bool = { true }
    var onRestartNeeded: (() -> Void)?

    private let logURL: URL
    private let policy: Policy
    private let now: () -> Date
    private let logger = Logger(subsystem: "solutions.enum.FocusriteVolumeControl", category: "FC2Health")

    private var timer: Timer?
    private var offset: UInt64?
    private var partialLine = ""
    private var recentErrors: [Date] = []
    private var restarts: [Date] = []

    init(logURL: URL = FC2HealthMonitor.defaultLogURL,
         policy: Policy = Policy(),
         now: @escaping () -> Date = Date.init) {
        self.logURL = logURL
        self.policy = policy
        self.now = now
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Tailing

    func start() {
        // Only react to new lines; the log keeps every past outage.
        offset = fileSize()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = 0.3
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        guard let size = fileSize() else { return }
        var start = offset ?? size
        if size < start {
            // FC2 replaced or truncated its log.
            start = 0
            partialLine = ""
        }
        guard size > start,
              let handle = try? FileHandle(forReadingFrom: logURL) else {
            offset = start
            return
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return }
        offset = start + UInt64(data.count)

        var lines = (partialLine + String(decoding: data, as: UTF8.self))
            .components(separatedBy: "\n")
        partialLine = lines.removeLast()
        for line in lines { ingest(line) }
    }

    private func fileSize() -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?
            .uint64Value
    }

    // MARK: - Detection

    func ingest(_ line: String) {
        if line.contains("Application initialised") {
            // A new FC2 process starts with no failed requests of its own.
            recentErrors.removeAll()
            return
        }
        if line.contains("Device mounted") {
            // FC2 has reopened the interface after a relaunch or replug.
            recentErrors.removeAll()
            if isUnresponsive {
                logger.info("✅ FC2 reconnected to the interface")
                isUnresponsive = false
            }
            return
        }

        // Code 1 is a timed-out USB request; code 11 only accompanies unplugging.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(": 1"),
              trimmed.contains("error fetching peaks") || trimmed.contains("error setting mixer coefficients")
        else { return }

        let time = now()
        recentErrors = recentErrors.filter { time.timeIntervalSince($0) < policy.errorWindow } + [time]
        guard recentErrors.count >= policy.errorThreshold else { return }

        if !isUnresponsive {
            logger.error("⚠️ FC2 cannot reach the interface; its slider no longer changes the volume")
            isUnresponsive = true
        }
        requestRestartIfAllowed(at: time)
    }

    private func requestRestartIfAllowed(at time: Date) {
        guard isRestartAllowed() else { return }
        if let last = restarts.last, time.timeIntervalSince(last) < policy.restartCooldown { return }
        restarts = restarts.filter { time.timeIntervalSince($0) < policy.restartBudgetWindow }
        guard restarts.count < policy.maxRestarts else {
            logger.error("🛑 FC2 restart limit reached; leaving it for manual recovery")
            return
        }
        restarts.append(time)
        logger.info("🔄 Restarting FC2 (\(self.restarts.count) of \(self.policy.maxRestarts) this hour)")
        onRestartNeeded?()
    }
}

// MARK: - Relaunch

enum FC2Relauncher {
    private static let bundleID = "com.focusrite.control"
    private static let logger = Logger(subsystem: "solutions.enum.FocusriteVolumeControl", category: "FC2Health")

    /// Quits FC2 (forcing it if its stuck USB thread blocks quitting), then
    /// relaunches it in the background and minimizes its window.
    @MainActor
    static func restartMinimized() async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let url = running.first?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            logger.error("❌ FC2 is not installed")
            return false
        }

        for app in running {
            app.terminate()
            if !(await waitUntilTerminated(app, seconds: 3)) {
                logger.info("⏳ FC2 did not quit; forcing it")
                app.forceTerminate()
                _ = await waitUntilTerminated(app, seconds: 2)
            }
        }
        return await launchMinimized(at: url)
    }

    /// Launches FC2 in the background and minimizes its window, which keeps it
    /// reachable through Accessibility from every desktop without taking focus.
    @MainActor
    static func launchMinimized() async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            logger.error("❌ FC2 is not installed")
            return false
        }
        return await launchMinimized(at: url)
    }

    @MainActor
    private static func launchMinimized(at url: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        guard let relaunched = try? await NSWorkspace.shared.openApplication(at: url,
                                                                            configuration: configuration) else {
            logger.error("❌ FC2 launch failed")
            return false
        }

        // Minimized windows stay in the AX tree; closed ones do not.
        for _ in 0..<40 {
            if FC2Window.minimize(in: AXUIElementCreateApplication(relaunched.processIdentifier)) {
                logger.info("✅ FC2 launched and minimized")
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        logger.error("⚠️ FC2 launched but its window could not be minimized")
        return true
    }

    @MainActor
    private static func waitUntilTerminated(_ app: NSRunningApplication, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !app.isTerminated && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return app.isTerminated
    }

}

// MARK: - Window lookup

/// Accessibility lists only windows that are minimized or on the current
/// desktop. FC2's main window remains available from any desktop.
enum FC2Window {
    static func element(in root: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(root, 0.5)
        let listed = (attribute(kAXWindowsAttribute, of: root) as? [AXUIElement]) ?? []
        let candidates = listed + [kAXMainWindowAttribute, kAXFocusedWindowAttribute].compactMap { key -> AXUIElement? in
            guard let value = attribute(key, of: root),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        return candidates.first { title(of: $0) == "Focusrite Control 2" }
    }

    /// Minimizing does not switch desktops, unlike activating FC2.
    static func minimize(in root: AXUIElement) -> Bool {
        guard let window = element(in: root) else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                            kCFBooleanTrue) == .success
    }

    private static func title(of element: AXUIElement) -> String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let value = attribute(key, of: element) as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func attribute(_ key: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}
