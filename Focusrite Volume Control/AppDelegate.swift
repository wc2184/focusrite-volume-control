//
//  AppDelegate.swift
//  Focusrite Volume Control
//
//  Menu bar app delegate - intercepts system volume keys for Focusrite control
//
import Cocoa
import SwiftUI
import Combine
import ApplicationServices

// Media key codes (from IOKit/hidsystem/ev_keymap.h)
private let NX_KEYTYPE_SOUND_UP: Int = 0
private let NX_KEYTYPE_SOUND_DOWN: Int = 1
private let NX_KEYTYPE_MUTE: Int = 7

// System-defined event type (NX_SYSDEFINED = 14)
private let kCGEventTypeSystemDefined: CGEventType = CGEventType(rawValue: 14)!

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var statusMenu: NSMenu!
    private var preferencesWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    // Volume controller with AppleScript backend
    var volumeController: VolumeController!

    private var cancellables = Set<AnyCancellable>()

    // CGEventTap for intercepting media keys
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Monitors whether a Focusrite Scarlett is the default audio output
    private var audioDeviceMonitor: AudioDeviceMonitor!
    // Fast-access flag for the CGEventTap callback (updated via Combine subscription)
    private var isFocusriteActive = false

    // Custom hotkey manager for non-media-key shortcuts
    private var hotkeyManager: HotkeyManager!
    private var syncTimer: Timer?
    private let confirmedDockVolume = ConfirmedDockVolume()
    private let fc2Health = FC2HealthMonitor()
    private var isRestartingFC2 = false
    private var volumeToReapply: Double?
    private var dockClickTimer: Timer?
    private var wasLeftMousePressed = false
    private var pendingDockClose: Bool?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        confirmedDockVolume.start()

        // Initialize volume controller with AppleScript backend
        volumeController = VolumeController()

        // Monitor default audio output device for Focusrite detection
        audioDeviceMonitor = AudioDeviceMonitor()

        // Set up menu bar (always visible, even before permissions)
        setupMenuBar()
        setupStatusMenu()
        setupDockClickTimer()

        // Observe connection state to update icon
        volumeController.$isConnected
            .combineLatest(volumeController.$playbackMuted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected, isMuted in
                self?.updateStatusIcon(connected: isConnected, muted: isMuted)
            }
            .store(in: &cancellables)

        // Keep HUD values in sync with backend (updates content but doesn't show the HUD)
        volumeController.$playbackVolume
            .combineLatest(volumeController.$playbackMuted,
                           volumeController.$usePerceptualVolumeCurve,
                           volumeController.$allowGain)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { volume, isMuted, perceptual, allowGain in
                VolumeHUDPanel.shared.update(volume: volume, isMuted: isMuted,
                                            levels: VolumeTickScale.levels(perceptual: perceptual, allowGain: allowGain))
            }
            .store(in: &cancellables)

        // Auto-connect/disconnect when the default output device changes
        audioDeviceMonitor.$isFocusriteDefaultOutput
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                guard let self else { return }
                self.isFocusriteActive = isActive
                if isActive {
                    print("🎧 Focusrite is default output — intercepting media keys")
                    self.volumeController.connect()
                } else {
                    print("🔇 Focusrite is not default output — passing media keys through to system")
                    self.volumeController.disconnect()
                }
            }
            .store(in: &cancellables)

        setupFC2HealthMonitor()

        // Keep the displayed value aligned with edits in FC2 and recover after
        // FC2 restarts or its window changes.
        syncTimer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            // A relaunch in progress must not be raced by a second launch.
            guard let self, self.isFocusriteActive, !self.isRestartingFC2 else { return }
            if self.volumeController.isConnected {
                self.volumeController.poll()
            } else {
                self.volumeController.connect()
            }
        }
        RunLoop.main.add(syncTimer!, forMode: .common)

        // Gate media key tap + connection on permissions
        showOnboardingIfNeeded()
    }

    // MARK: - Onboarding

    // MARK: - FC2 Recovery

    private func setupFC2HealthMonitor() {
        fc2Health.isRestartAllowed = { [weak self] in
            guard let self else { return false }
            return self.volumeController.autoRestartFC2 && self.isFocusriteActive && !self.isRestartingFC2
        }
        fc2Health.onRestartNeeded = { [weak self] in
            self?.restartFC2()
        }
        // Presses during a relaunch are newer than the level saved before it.
        volumeController.onUserVolumeSet = { [weak self] level in
            guard let self, self.volumeToReapply != nil else { return }
            self.volumeToReapply = level
        }
        fc2Health.$isUnresponsive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] unresponsive in
                guard let self else { return }
                self.confirmedDockVolume.isFC2Unresponsive = unresponsive
                guard !unresponsive, self.volumeToReapply != nil else { return }
                // The mount is logged before FC2 is ready to accept writes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.reapplySavedVolume()
                }
            }
            .store(in: &cancellables)
        fc2Health.start()
    }

    private func restartFC2() {
        isRestartingFC2 = true
        volumeToReapply = volumeController.playbackVolume
        volumeController.holdsWrites = true
        Task { @MainActor [weak self] in
            let relaunched = await FC2Relauncher.restartMinimized()
            guard let self else { return }
            self.isRestartingFC2 = false
            guard relaunched else {
                self.reapplySavedVolume()
                return
            }
            // Never leave keys unwritten if FC2 does not log a remount.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.volumeController.holdsWrites else { return }
                self.reapplySavedVolume()
            }
        }
    }

    /// Resume writes with the newest level chosen while FC2 was relaunching.
    private func reapplySavedVolume() {
        volumeController.holdsWrites = false
        guard let volume = volumeToReapply else { return }
        volumeToReapply = nil
        volumeController.reapplyAfterFC2Restart(volume)
    }

    private func showOnboardingIfNeeded() {
        guard !areAllPermissionsGranted() else {
            proceedAfterOnboarding()
            return
        }

        let onboardingView = OnboardingView { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.proceedAfterOnboarding()
        }

        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Setup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func proceedAfterOnboarding() {
        setupMediaKeyTap()
        setupHotkeyManager()
        // Connection is handled by the audioDeviceMonitor subscription —
        // it auto-connects when a Focusrite device becomes the default output.
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockClickTimer?.invalidate()
        confirmedDockVolume.stop()
        fc2Health.stop()
        syncTimer?.invalidate()
        volumeController.disconnect()
        removeMediaKeyTap()
        hotkeyManager?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The Dock mouse handler owns both opening and closing. Reopening
        // here races with closing and undoes the second click.
        return false
    }

    private func setupDockClickTimer() {
        dockClickTimer = Timer(timeInterval: 0.015, repeats: true) { [weak self] _ in
            guard let self else { return }
            let pressed = NSEvent.pressedMouseButtons & 1 != 0
            defer { self.wasLeftMousePressed = pressed }
            if !pressed, self.wasLeftMousePressed, let shouldClose = self.pendingDockClose {
                self.pendingDockClose = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self else { return }
                    if shouldClose {
                        self.preferencesWindow?.close()
                        self.preferencesWindow = nil
                    }
                    else { self.showPreferences() }
                }
                return
            }
            guard pressed, !self.wasLeftMousePressed else { return }
            let location = NSEvent.mouseLocation
            let topLeft = CGPoint(x: location.x, y: NSScreen.screens.first.map { $0.frame.maxY - location.y } ?? location.y)
            guard self.isFocusriteDockItem(at: topLeft) else { return }
            self.pendingDockClose = self.preferencesWindow?.isVisible == true
        }
        RunLoop.main.add(dockClickTimer!, forMode: .common)
    }

    private func isFocusriteDockItem(at point: CGPoint) -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return false
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 0.1)
        var clickedElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dockElement, Float(point.x), Float(point.y), &clickedElement) == .success,
              let clickedElement else { return false }
        var title: CFTypeRef?
        return AXUIElementCopyAttributeValue(clickedElement, kAXTitleAttribute as CFString, &title) == .success
            && title as? String == "Focusrite Volume Control"
    }

    /// Show the floating HUD with current volume state
    private func showHUD() {
        let vc = volumeController!
        VolumeHUDPanel.shared.show(volume: vc.playbackVolume, isMuted: vc.playbackMuted,
                                  levels: vc.volumeLevels)
    }

    private func setupHotkeyManager() {
        hotkeyManager = HotkeyManager()
        hotkeyManager.onVolumeUp = { [weak self] in
            guard self?.isFocusriteActive == true else { return }
            self?.volumeController.volumeUp()
            self?.showHUD()
        }
        hotkeyManager.onVolumeDown = { [weak self] in
            guard self?.isFocusriteActive == true else { return }
            self?.volumeController.volumeDown()
            self?.showHUD()
        }
        hotkeyManager.onMute = { [weak self] in
            guard self?.isFocusriteActive == true else { return }
            self?.volumeController.toggleMute()
            self?.showHUD()
        }
        hotkeyManager.onDirectMonitor = { [weak self] in
            guard self?.isFocusriteActive == true else { return }
            self?.volumeController.toggleDirectMonitor()
        }
        hotkeyManager.start()
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Volume")
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
            // Enable right-click
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 180)
        popover.behavior = .transient
        popover.animates = true

        // Set content view with preferences callback
        let contentView = PopoverView(volumeController: volumeController) { [weak self] in
            self?.showPreferences()
        }
        popover.contentViewController = NSHostingController(rootView: contentView)
    }

    private func setupStatusMenu() {
        statusMenu = NSMenu()

        // About
        let aboutItem = NSMenuItem(title: "About Focusrite Volume Control", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        statusMenu.addItem(aboutItem)

        // Preferences
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferencesMenuItem), keyEquivalent: ",")
        prefsItem.target = self
        statusMenu.addItem(prefsItem)

        // Report Issue
        let issueItem = NSMenuItem(title: "Report Issue / Request Feature...", action: #selector(openIssues), keyEquivalent: "")
        issueItem.target = self
        statusMenu.addItem(issueItem)

        statusMenu.addItem(NSMenuItem.separator())

        // Reconnect
        let reconnectItem = NSMenuItem(title: "Reconnect to Focusrite Control 2", action: #selector(reconnect), keyEquivalent: "r")
        reconnectItem.target = self
        statusMenu.addItem(reconnectItem)

        statusMenu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click: show menu
            popover.performClose(nil)
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil  // Clear so left-click works next time
        } else {
            // Left-click: toggle popover
            togglePopover()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Make window key but clear focus so no button has focus ring
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
                window.makeFirstResponder(nil)
            }
        }
    }

    // MARK: - Menu Actions

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Focusrite Volume Control"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        alert.informativeText = "Control your Focusrite Scarlett Solo volume with system media keys.\n\nVersion \(version) (\(build))\n\n\u{00A9} 2026"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        let coffeeButton = NSButton(frame: .zero)
        coffeeButton.title = "If this app saved you time, buy me a coffee"
        coffeeButton.bezelStyle = .inline
        coffeeButton.isBordered = false
        coffeeButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        coffeeButton.contentTintColor = .linkColor
        coffeeButton.target = self
        coffeeButton.action = #selector(openCoffeeLink)
        coffeeButton.sizeToFit()
        alert.accessoryView = coffeeButton

        alert.runModal()
    }

    @objc private func openCoffeeLink() {
        if let url = URL(string: "https://buymeacoffee.com/enum") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showPreferencesMenuItem() {
        showPreferences()
    }

    func showPreferences() {
        // Close popover if open
        popover.performClose(nil)

        // If window already exists, just bring it to front
        if let window = preferencesWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create preferences window
        let prefsView = PreferencesView(volumeController: volumeController)
        let hostingController = NSHostingController(rootView: prefsView)

        // Let the window size itself to fit the SwiftUI content
        let fittingSize = hostingController.sizeThatFits(in: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(fittingSize)

        // Position window under the menu bar icon
        if let button = statusItem.button {
            let buttonRect = button.window?.convertToScreen(button.frame) ?? .zero
            let windowWidth = fittingSize.width
            let windowHeight = fittingSize.height

            // Center horizontally under the icon, position below menu bar
            let x = buttonRect.midX - windowWidth / 2
            let y = buttonRect.minY - windowHeight - 15  // 15pt gap below menu bar

            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }

        window.isReleasedWhenClosed = false

        preferencesWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openIssues() {
        if let url = URL(string: "https://github.com/wc2184/focusrite-volume-control/issues") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func reconnect() {
        audioDeviceMonitor.refresh()
        volumeController.disconnect()
        if isFocusriteActive {
            volumeController.connect()
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func updateStatusIcon(connected: Bool, muted: Bool) {
        guard let button = statusItem.button else { return }

        let iconName: String
        if !connected {
            iconName = "speaker.slash"
        } else if muted {
            iconName = "speaker.slash.fill"
        } else {
            iconName = "speaker.wave.2.fill"
        }

        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Volume")
    }

    // MARK: - Media Key Tap (intercepts and blocks system volume)

    private func setupMediaKeyTap() {
        // Event mask for system-defined events (media keys)
        let eventMask: CGEventMask = 1 << kCGEventTypeSystemDefined.rawValue

        // Create event tap - requires Accessibility permissions
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,  // Can modify/block events
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passRetained(event)
                }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return appDelegate.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            print("⚠️ Failed to create event tap - grant Accessibility permissions in System Settings")
            return
        }

        // Add to run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        print("✅ Media key tap installed - system volume keys now control Focusrite only")
    }

    private func removeMediaKeyTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        // Only handle system-defined events
        guard type == kCGEventTypeSystemDefined else {
            return Unmanaged.passRetained(event)
        }

        // Convert to NSEvent to parse media key data
        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passRetained(event)
        }

        // Check for media key subtype (8 = NX_SUBTYPE_AUX_CONTROL_BUTTONS)
        guard nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passRetained(event)
        }

        // Parse key data from data1
        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let keyDown = keyState == 0x0A

        // Only handle key down
        guard keyDown else {
            // If Focusrite is active, suppress key-up too; otherwise pass through
            return isFocusriteActive ? nil : Unmanaged.passRetained(event)
        }

        // If Focusrite is not the default output, pass media keys through to the system
        guard isFocusriteActive else {
            return Unmanaged.passRetained(event)
        }

        // Handle volume keys - block system HUD, show custom Focusrite HUD instead
        switch keyCode {
        case NX_KEYTYPE_SOUND_UP:
            DispatchQueue.main.async {
                self.volumeController.volumeUp()
                self.showHUD()
            }
            return nil  // Block system volume change and HUD

        case NX_KEYTYPE_SOUND_DOWN:
            DispatchQueue.main.async {
                self.volumeController.volumeDown()
                self.showHUD()
            }
            return nil  // Block system volume change and HUD

        case NX_KEYTYPE_MUTE:
            DispatchQueue.main.async {
                self.volumeController.toggleMute()
                self.showHUD()
            }
            return nil  // Block system volume change and HUD

        default:
            return Unmanaged.passRetained(event)
        }
    }
}
