//
//  LaunchAtLogin.swift
//  Focusrite Volume Control
//
//  Manages Launch at Login functionality using SMAppService (macOS 13+)
//

import Foundation
import ServiceManagement
import Combine

class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    @Published var isEnabled: Bool {
        didSet {
            if isEnabled {
                enable()
            } else {
                disable()
            }
        }
    }

    private init() {
        // Read current state from system
        if #available(macOS 13.0, *) {
            isEnabled = SMAppService.mainApp.status == .enabled
        } else {
            isEnabled = false
        }
    }

    private func enable() {
        guard #available(macOS 13.0, *) else {
            DispatchQueue.main.async { self.isEnabled = false }
            return
        }
        do {
            try SMAppService.mainApp.register()
        } catch {
            print("Failed to enable launch at login: \(error)")
            // Revert the published value if registration failed
            DispatchQueue.main.async {
                self.isEnabled = false
            }
        }
    }

    private func disable() {
        guard #available(macOS 13.0, *) else { return }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            print("Failed to disable launch at login: \(error)")
            // Revert the published value if unregistration failed
            DispatchQueue.main.async {
                self.isEnabled = true
            }
        }
    }

}
