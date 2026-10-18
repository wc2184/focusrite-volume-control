//
//  VolumeHUDWindow.swift
//  Focusrite Volume Control
//
//  NSPanel-based floating HUD window that shows Focusrite volume changes.
//  Non-activating, click-through, floats above all windows including fullscreen.
//

import Cocoa
import SwiftUI

// MARK: - HUD Window (NSPanel subclass)

class VolumeHUDWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Use the system HUD material with a mask that clips the backdrop itself.
    func setHUDContent<V: View>(_ rootView: V, size: NSSize) {
        let surface = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        surface.material = .hudWindow
        surface.blendingMode = .behindWindow
        surface.state = .active
        let mask = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 20, yRadius: 20).fill()
            return true
        }
        surface.maskImage = mask

        let hostingView = TransparentHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: surface.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])

        self.contentView = surface
    }
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

// MARK: - HUD Panel Manager (singleton)

class VolumeHUDPanel {
    static let shared = VolumeHUDPanel()

    private var panel: VolumeHUDWindow?
    private let viewModel = VolumeHUDViewModel()
    private var dismissTimer: Timer?
    private let dismissDelay: TimeInterval = 2.0
    private var environmentObservers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {
        // WindowServer can leave a long-lived all-Spaces panel attached to an
        // earlier desktop after locking, waking, or reconfiguring displays.
        // Retire it on transitions; only a new volume action may show a HUD.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.willSleepNotification,
                     NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observeEnvironmentChange(name, center: workspaceCenter)
        }
        observeEnvironmentChange(NSApplication.didChangeScreenParametersNotification,
                                 center: .default)
    }

    deinit {
        dismissTimer?.invalidate()
        for (center, observer) in environmentObservers {
            center.removeObserver(observer)
        }
    }

    /// Update the HUD values without showing it (for Combine-driven updates while already visible)
    func update(volume: Double, isMuted: Bool, levels: [Double] = VolumeTickScale.levels) {
        viewModel.levels = levels
        viewModel.volumeDb = volume
        viewModel.isMuted = isMuted
    }

    /// Show the HUD with current volume state (call from key/hotkey handlers)
    func show(volume: Double, isMuted: Bool, levels: [Double] = VolumeTickScale.levels) {
        // Update view model
        update(volume: volume, isMuted: isMuted, levels: levels)

        // Create panel lazily
        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        // Match the native HUD position on the pointer's display.
        positionPanel(panel)

        // Show immediately. An in-flight fade could otherwise hide a new HUD.
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // Reset dismiss timer
        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: dismissDelay, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        dismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Hide the HUD after the most recent key press.
    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        // A hidden panel must not survive a lock/unlock cycle. A fresh native
        // window gets fresh Space membership on the next volume action, even
        // when locking did not produce a sleep or session notification.
        panel.close()
    }

    // MARK: - Private

    private func observeEnvironmentChange(_ name: Notification.Name,
                                          center: NotificationCenter) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.dismiss()
        }
        environmentObservers.append((center, observer))
    }

    private func createPanel() {
        let hudView = VolumeHUDView(viewModel: viewModel)
        let panelSize = NSSize(width: VolumeHUDView.panelSize, height: VolumeHUDView.panelSize)

        let panel = VolumeHUDWindow(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = false
        // A global HUD must remain eligible while another app/Space is active.
        // NSPanel otherwise defaults to hiding when its application deactivates.
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.level = NSWindow.Level.screenSaver  // Above everything including fullscreen
        panel.collectionBehavior = NSWindow.CollectionBehavior([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.setHUDContent(hudView, size: panelSize)

        self.panel = panel
    }

    private func positionPanel(_ panel: VolumeHUDWindow) {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
                ?? NSScreen.main else { return }
        let screenFrame = screen.frame
        let panelSize = panel.frame.size

        // The supplied native capture places the HUD 140 points above the bottom.
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.minY + 140
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
