//
//  AppleScriptBackend.swift
//  Focusrite Volume Control
//
//  Controls Focusrite Control 2 via native Accessibility writes and AppleScript fallback.
//

import Foundation
import Combine
import os.log
import AppKit
import ApplicationServices

/// Focusrite Control 2 accessibility backend.
class AppleScriptBackend: VolumeBackend {

    // MARK: - Constants

    private let fc2Process = "Focusrite Control 2"
    private let logger = Logger(subsystem: "solutions.enum.FocusriteVolumeControl", category: "AppleScriptBackend")

    // MARK: - State

    private var _state = VolumeState()
    private let stateSubject = CurrentValueSubject<VolumeState, Never>(VolumeState())

    /// Track if FC2 is verified ready (reset on errors)
    private var isFC2Verified = false
    private var playbackWriteVersion = 0
    private let fastPlaybackWriter = AXPlaybackWriter()

    var statePublisher: AnyPublisher<VolumeState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    // MARK: - Connection

    func connect() async -> VolumeResult {
        // Ensure FC2 is running and Direct tab is active (retry for startup timing)
        var lastError: String = "Unknown error"
        for attempt in 1...3 {
            let result = await ensureDirectTab()
            if case .success = result {
                return await refresh()
            }
            if case .error(let msg) = result {
                lastError = msg
                logger.info("⏳ Connect attempt \(attempt) failed: \(msg, privacy: .public), retrying...")
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return .error(lastError)
    }

    func disconnect() {
        isFC2Verified = false
        fastPlaybackWriter.invalidate()
        _state.isConnected = false
        _state.statusMessage = "Disconnected"
        stateSubject.send(_state)
    }

    func refresh() async -> VolumeResult {
        do {
            let writeVersion = playbackWriteVersion
            try await ensureReady()
            let script = """
            tell application "System Events"
                tell process "\(fc2Process)"
                    set directGroup to group 5 of window "\(fc2Process)"
                    set playbackGroup to group "Playback 1 - 2" of directGroup
                    return (value of slider "Level" of playbackGroup as text) & "|" & (value of checkbox "Direct Monitor" of window "\(fc2Process)" as text)
                end tell
            end tell
            """
            let values = try await runOsascript(script).components(separatedBy: "|")
            guard values.count == 2,
                  let playbackVol = parseDbValue(values[0]) else {
                throw VolumeBackendError.appleScriptError("Unexpected Focusrite Control 2 values")
            }
            // A poll started before a key press must not replace the newer value.
            if writeVersion == playbackWriteVersion {
                _state.playbackVolume = playbackVol
                _state.directMonitorEnabled = values[1].lowercased() == "true" || values[1] == "1"
            }
            _state.isConnected = true
            _state.statusMessage = "Connected"
            stateSubject.send(_state)
            return .success
        } catch {
            isFC2Verified = false  // Reset on error to force re-check next time
            _state.isConnected = false
            _state.statusMessage = error.localizedDescription
            stateSubject.send(_state)
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Playback Volume

    func setPlaybackVolume(_ db: Double, ensureDirectMonitor: Bool) async -> VolumeResult {
        playbackWriteVersion += 1
        do {
            let actual = try await writePlaybackVolume(db, ensureDirectMonitor: ensureDirectMonitor)
            _state.playbackVolume = actual
            if ensureDirectMonitor { _state.directMonitorEnabled = true }
            stateSubject.send(_state)
            return .success
        } catch {
            isFC2Verified = false
            return .error(error.localizedDescription)
        }
    }

    /// Check Direct Monitor at write time, so changes made in FC2 cannot leave
    /// the keyboard writing a slider whose output is no longer audible.
    private func writePlaybackVolume(_ db: Double, ensureDirectMonitor: Bool) async throws -> Double {
        // AX writes in this process avoid launching osascript and routing every
        // key press through System Events. Keep the established script as a
        // fallback when FC2 changes its accessibility tree or is starting up.
        if AXIsProcessTrusted(), isFC2Verified {
            do {
                return try await fastPlaybackWriter.write(db, ensureDirectMonitor: ensureDirectMonitor)
            } catch {
                fastPlaybackWriter.invalidate()
                logger.debug("Native AX write unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }

        let script = """
        tell application "System Events"
            tell process "\(fc2Process)"
                set fcWindow to window "\(fc2Process)"
                if \(ensureDirectMonitor ? "true" : "false") then
                    set monitorControl to checkbox "Direct Monitor" of fcWindow
                    if (value of monitorControl as text) is not "true" and (value of monitorControl as text) is not "1" then click monitorControl
                end if
                set levelControl to slider "Level" of group "Playback 1 - 2" of group 5 of fcWindow
                set value of levelControl to "\(formatDbValue(db))"
                return value of levelControl
            end tell
        end tell
        """
        do {
            try await ensureReady()
            guard let value = parseDbValue(try await runOsascript(script)) else {
                throw VolumeBackendError.appleScriptError("Invalid playback volume response")
            }
            return value
        } catch {
            // FC2 may have changed tabs or relaunched since the last successful write.
            isFC2Verified = false
            try await ensureReady()
            guard let value = parseDbValue(try await runOsascript(script)) else {
                throw VolumeBackendError.appleScriptError("Invalid playback volume response")
            }
            return value
        }
    }

    // MARK: - Direct Monitor

    func setDirectMonitorEnabled(_ enabled: Bool) async -> VolumeResult {
        do {
            try await setDirectMonitor(enabled: enabled)
            _state.directMonitorEnabled = enabled
            stateSubject.send(_state)
            return .success
        } catch {
            isFC2Verified = false
            return .error(error.localizedDescription)
        }
    }

    // MARK: - AppleScript Commands via osascript

    /// Ensure FC2 is running and Direct tab is active
    private func ensureDirectTab() async -> VolumeResult {
        do {
            try await ensureFC2Ready()
            return .success
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Launch FC2 if not running, ensure Direct tab is active
    private func ensureFC2Ready() async throws {
        logger.info("🔧 ensureFC2Ready: checking if FC2 is running...")

        // Check if FC2 is running
        let checkScript = """
        tell application "System Events"
            return exists process "\(fc2Process)"
        end tell
        """
        let isRunning = try await runOsascript(checkScript) == "true"

        if !isRunning {
            logger.info("🚀 FC2 not running, launching it minimized...")
            // AppleScript `launch` can bring FC2 to the front; this cannot.
            guard await FC2Relauncher.launchMinimized() else { throw VolumeBackendError.fc2NotRunning }
            // Give it a moment more to fully initialize UI
            try await Task.sleep(for: .milliseconds(1000))
        } else {
            logger.info("✅ FC2 already running")
        }

        // Accessibility sees FC2's window only when it is minimized or on the
        // current desktop. Never activate FC2 to find it: that takes focus and
        // switches desktops whenever this runs (reconnects, wake, errors).
        let windowCountScript = """
        tell application "System Events"
            tell process "\(fc2Process)" to return count of windows
        end tell
        """
        if try await runOsascript(windowCountScript) == "0" {
            // A window on another desktop is still FC2's main window.
            // Minimizing it in place does not switch desktops and makes it
            // reachable from all of them.
            guard let pid = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.focusrite.control").first?.processIdentifier,
                  FC2Window.minimize(in: AXUIElementCreateApplication(pid)) else {
                throw VolumeBackendError.fc2WindowNotFound
            }
            logger.info("📥 Minimized FC2's window from another desktop")
            var reachable = false
            for _ in 1...10 {
                try await Task.sleep(for: .milliseconds(200))
                if try await runOsascript(windowCountScript) != "0" {
                    reachable = true
                    break
                }
            }
            if !reachable { throw VolumeBackendError.fc2WindowNotFound }
        }

        // Check if Direct tab is already active.
        let tabCheckScript = """
        tell application "System Events"
            tell process "\(fc2Process)"
                if (count of windows) = 0 then
                    return "no_window"
                end if
                try
                    get group "Playback 1 - 2" of group 5 of window "\(fc2Process)"
                    return "ready"
                on error
                    return "wrong_tab"
                end try
            end tell
        end tell
        """

        let tabStatus = try await runOsascript(tabCheckScript)

        if tabStatus == "ready" {
            logger.info("✅ FC2 already on Direct tab")
            return
        }

        // Direct tab not active — need to switch
        logger.info("🔀 Switching to Direct tab...")
        let switchScript = """
        tell application "System Events"
            tell process "\(fc2Process)"
                if (count of windows) > 0 then
                    click checkbox "Direct" of group "Navigation bar" of window "\(fc2Process)"
                end if
            end tell
        end tell
        """
        _ = try await runOsascript(switchScript)
        logger.info("✅ FC2 ready on Direct tab")
    }

    /// Ensure FC2 is ready before performing an action
    private func ensureReady() async throws {
        // Skip check if already verified (fast path for repeated actions)
        if isFC2Verified {
            return
        }

        logger.info("🔍 ensureReady: checking FC2 status...")

        // Quick check if process exists and Direct tab is active
        let checkScript = """
        tell application "System Events"
            if not (exists process "\(fc2Process)") then
                return "not_running"
            end if
            tell process "\(fc2Process)"
                if (count of windows) = 0 then
                    return "no_window"
                end if
                -- Check if Direct tab is active by checking if expected elements exist
                try
                    get group "Playback 1 - 2" of group 5 of window "\(fc2Process)"
                    return "ready"
                on error
                    return "wrong_tab"
                end try
            end tell
        end tell
        """

        let status = try await runOsascript(checkScript)
        logger.info("📊 FC2 status: \(status, privacy: .public)")

        if status == "ready" {
            isFC2Verified = true
            logger.info("✅ FC2 verified ready")
        } else {
            logger.info("⚠️ FC2 not ready (status: \(status, privacy: .public)), setting up...")
            // Need to set up FC2
            try await ensureFC2Ready()
            isFC2Verified = true
        }
    }

    /// Set Direct Monitor state
    private func setDirectMonitor(enabled: Bool) async throws {
        try await ensureReady()

        // FC2 returns true/false for checkbox values
        let targetValue = enabled ? "true" : "false"
        let script = """
        tell application "System Events"
            tell process "\(fc2Process)"
                set cb to checkbox "Direct Monitor" of window "\(fc2Process)"
                if (value of cb) is not \(targetValue) then
                    click cb
                end if
            end tell
        end tell
        """

        _ = try await runOsascript(script)
    }

    // MARK: - osascript Execution

    /// Run AppleScript via osascript subprocess (same as Node.js script)
    private func runOsascript(_ script: String) async throws -> String {
        // Extract first line for logging (avoid logging full scripts)
        let scriptPreview = script.components(separatedBy: .newlines).first ?? "script"

        return try await withCheckedThrowingContinuation { [logger] continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                    process.waitUntilExit()

                    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

                    if process.terminationStatus != 0 {
                        let rawError = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        logger.error("❌ osascript failed: \(rawError, privacy: .public) | script: \(scriptPreview, privacy: .public)")

                        // Parse osascript error: "138:237: execution error: System Events got an error: ... (-600)"
                        // Extract the meaningful part after "execution error: "
                        var cleanMessage = rawError.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let range = cleanMessage.range(of: "execution error: ") {
                            cleanMessage = String(cleanMessage[range.upperBound...])
                        }
                        // Strip trailing error codes like "(-600)" and period
                        cleanMessage = cleanMessage.replacingOccurrences(
                            of: #"\s*\(-?\d+\)\s*$"#, with: "", options: .regularExpression)

                        // Map known errors to specific types
                        let error: VolumeBackendError
                        if cleanMessage.contains("Can\u{2019}t get process") || cleanMessage.contains("(-600)") || rawError.contains("(-600)") {
                            error = .fc2NotRunning
                        } else if cleanMessage.contains("Can\u{2019}t get window") || cleanMessage.contains("count of windows") {
                            error = .fc2WindowNotFound
                        } else {
                            error = .appleScriptError(cleanMessage)
                        }
                        continuation.resume(throwing: error)
                    } else {
                        let output = String(data: outputData, encoding: .utf8) ?? ""
                        continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } catch {
                    logger.error("❌ osascript exception: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Utilities

    /// Parse dB string like "-6dB" or "0dB" to Double
    private func parseDbValue(_ str: String) -> Double? {
        let cleaned = str.trimmingCharacters(in: .whitespacesAndNewlines)
        let numStr = cleaned.replacingOccurrences(of: "dB", with: "")
                            .replacingOccurrences(of: " ", with: "")
        return Double(numStr)
    }

    /// Format Double to dB string like "-6dB"
    private func formatDbValue(_ db: Double) -> String {
        return "\(Int(round(db)))dB"
    }
}

/// Cached Accessibility elements for the hot playback-volume path. The first
/// lookup is more work; later writes touch only the monitor switch and slider.
private final class AXPlaybackWriter {
    private struct Controls {
        let pid: pid_t
        let slider: AXUIElement
        let directMonitor: AXUIElement
    }

    private let queue = DispatchQueue(label: "focusrite.playback.ax", qos: .userInitiated)
    private var controls: Controls?

    func invalidate() {
        queue.async { self.controls = nil }
    }

    func write(_ db: Double, ensureDirectMonitor: Bool) async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let controls = try self.resolveControls()
                    if ensureDirectMonitor {
                        let value = try self.attribute(kAXValueAttribute as CFString,
                                                       of: controls.directMonitor)
                        let enabled = (value as? NSNumber)?.boolValue == true ||
                            (value as? String)?.lowercased() == "true" ||
                            (value as? String) == "1"
                        if !enabled {
                            try self.check(AXUIElementPerformAction(
                                controls.directMonitor, kAXPressAction as CFString))
                        }
                    }
                    let target = "\(Int(round(db)))dB" as CFString
                    try self.check(AXUIElementSetAttributeValue(
                        controls.slider, kAXValueAttribute as CFString, target))
                    let reported = try self.attribute(kAXValueAttribute as CFString,
                                                      of: controls.slider) as? String
                    let numeric = reported?
                        .replacingOccurrences(of: "dB", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let numeric, let actual = Double(numeric),
                          abs(actual - db) < 0.5 else {
                        throw AXWriteError.unavailable
                    }
                    continuation.resume(returning: actual)
                } catch {
                    self.controls = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func resolveControls() throws -> Controls {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.focusrite.control").first else {
            throw AXWriteError.unavailable
        }
        if let controls, controls.pid == app.processIdentifier { return controls }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let window = FC2Window.element(in: root) else {
            throw AXWriteError.unavailable
        }
        let groups = try elements(kAXChildrenAttribute as CFString, of: window)
            .filter { role(of: $0) == (kAXGroupRole as String) }
        guard groups.count >= 5 else { throw AXWriteError.unavailable }
        let playbackGroups = try elements(kAXChildrenAttribute as CFString, of: groups[4])
        guard let playback = playbackGroups.first(where: { name(of: $0) == "Playback 1 - 2" }),
              let slider = try elements(kAXChildrenAttribute as CFString, of: playback)
                .first(where: { role(of: $0) == (kAXSliderRole as String) && name(of: $0) == "Level" }),
              let monitor = try elements(kAXChildrenAttribute as CFString, of: window)
                .first(where: { role(of: $0) == (kAXCheckBoxRole as String) && name(of: $0) == "Direct Monitor" })
        else { throw AXWriteError.unavailable }

        let found = Controls(pid: app.processIdentifier, slider: slider, directMonitor: monitor)
        controls = found
        return found
    }

    private func elements(_ key: CFString, of element: AXUIElement) throws -> [AXUIElement] {
        guard let result = try attribute(key, of: element) as? [AXUIElement] else {
            throw AXWriteError.unavailable
        }
        return result
    }

    private func attribute(_ key: CFString, of element: AXUIElement) throws -> CFTypeRef {
        var value: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(element, key, &value))
        guard let value else { throw AXWriteError.unavailable }
        return value
    }

    private func role(of element: AXUIElement) -> String? {
        try? attribute(kAXRoleAttribute as CFString, of: element) as? String
    }

    private func name(of element: AXUIElement) -> String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute] {
            if let value = try? attribute(key as CFString, of: element) as? String,
               !value.isEmpty { return value }
        }
        return nil
    }

    private func check(_ error: AXError) throws {
        guard error == .success else { throw AXWriteError.ax(error.rawValue) }
    }

    private enum AXWriteError: LocalizedError {
        case unavailable
        case ax(Int32)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Focusrite controls are not available in the AX tree"
            case .ax(let code): return "Accessibility error \(code)"
            }
        }
    }
}
