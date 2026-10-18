import XCTest
import Combine
import AppKit
import Carbon.HIToolbox
import class SwiftUI.NSHostingView
@testable import Focusrite_Volume_Control

final class Focusrite_Volume_ControlTests: XCTestCase {
    @MainActor
    func testHUDIsVisibleWithoutActivatingItsApplication() throws {
        let app = NSApplication.shared
        app.deactivate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        VolumeHUDPanel.shared.show(volume: -16, isMuted: false)
        defer { VolumeHUDPanel.shared.dismiss() }
        let panel = try XCTUnwrap(visibleHUD())
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(app.isActive, "Showing the HUD must not activate its app")
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.isOnActiveSpace)
        XCTAssertTrue(panel.occlusionState.contains(.visible), "An ordered HUD must actually be onscreen")
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.canHide)
    }

    @MainActor
    func testHUDDismissalRetiresNativeWindowAndNextActionCreatesVisibleReplacement() throws {
        let hud = VolumeHUDPanel.shared
        hud.show(volume: -16, isMuted: false)
        let original = try XCTUnwrap(visibleHUD())
        hud.dismiss()
        XCTAssertFalse(original.isVisible)
        XCTAssertNil(visibleHUD())

        hud.show(volume: -20, isMuted: false)
        defer { hud.dismiss() }
        let replacement = try XCTUnwrap(visibleHUD())
        XCTAssertFalse(original === replacement)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(replacement.occlusionState.contains(.visible))
        XCTAssertTrue(replacement.isOnActiveSpace)

        // Rapid keys reuse the visible panel instead of flickering/rebuilding.
        hud.show(volume: -16, isMuted: false)
        XCTAssertTrue(visibleHUD() === replacement)
    }

    @MainActor
    func testHUDEnvironmentChangesRetireWindowWithoutReopeningIt() throws {
        let hud = VolumeHUDPanel.shared
        defer { hud.dismiss() }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        var events = [NSWorkspace.activeSpaceDidChangeNotification,
                      NSWorkspace.willSleepNotification,
                      NSWorkspace.didWakeNotification,
                      NSWorkspace.screensDidSleepNotification,
                      NSWorkspace.screensDidWakeNotification,
                      NSWorkspace.sessionDidResignActiveNotification,
                      NSWorkspace.sessionDidBecomeActiveNotification]
            .map { (workspaceCenter, $0) }
        events.append((.default, NSApplication.didChangeScreenParametersNotification))
        for (center, name) in events {
            hud.show(volume: -16, isMuted: false)
            let original = try XCTUnwrap(visibleHUD())
            center.post(name: name, object: nil)
            XCTAssertFalse(original.isVisible, "\(name) must retire stale Space membership")
            XCTAssertNil(visibleHUD(), "An environment change must not open a HUD")

            hud.show(volume: -20, isMuted: false)
            let replacement = try XCTUnwrap(visibleHUD())
            XCTAssertFalse(original === replacement)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertTrue(replacement.occlusionState.contains(.visible), "\(name)")
        }
    }

    @MainActor
    func testHUDRetiredTimerCannotHideReplacementAndLatestPressExtendsLifetime() throws {
        let hud = VolumeHUDPanel.shared
        defer { hud.dismiss() }
        hud.show(volume: -16, isMuted: false)
        let original = try XCTUnwrap(visibleHUD())
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification,
                                                   object: nil)
        hud.show(volume: -20, isMuted: false)
        let replacement = try XCTUnwrap(visibleHUD())
        XCTAssertFalse(original === replacement)
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertTrue(replacement.isVisible, "The retired panel's timer must not dismiss a new HUD")
        hud.show(volume: -16, isMuted: false)
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertTrue(replacement.isVisible, "The latest key press must reset dismissal")
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertFalse(replacement.isVisible)
        XCTAssertNil(visibleHUD())
    }

    @MainActor
    private func visibleHUD() -> VolumeHUDWindow? {
        NSApplication.shared.windows.compactMap { $0 as? VolumeHUDWindow }.first { $0.isVisible }
    }

    func testNativeF12AndLeftArrowAreDistinctAndOnlyF12IsAllowedBare() {
        let left = KeyboardShortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: [])
        let f12 = KeyboardShortcut(keyCode: UInt16(kVK_F12), modifiers: [])
        XCTAssertEqual(left.keyCode, 123)
        XCTAssertEqual(f12.keyCode, 111)
        XCTAssertEqual(left.displayString, "←")
        XCTAssertEqual(f12.displayString, "F12")
        XCTAssertFalse(left.isAllowedGlobalShortcut)
        XCTAssertTrue(f12.isAllowedGlobalShortcut)
    }

    func testNavigationNeedsAnExplicitShortcutModifier() {
        for code in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                     kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
                     kVK_Tab, kVK_Return, kVK_Delete, kVK_ForwardDelete, kVK_Escape] {
            XCTAssertFalse(KeyboardShortcut(keyCode: UInt16(code), modifiers: []).isAllowedGlobalShortcut)
            XCTAssertFalse(KeyboardShortcut(keyCode: UInt16(code), modifiers: [.shift]).isAllowedGlobalShortcut)
            for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
                XCTAssertTrue(KeyboardShortcut(keyCode: UInt16(code), modifiers: modifier).isAllowedGlobalShortcut)
            }
        }
    }

    func testLoadingRepairsUnsafeSavedNavigationAndPreservesValidShortcuts() throws {
        let domain = "FocusriteShortcutTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let saved: [String: KeyboardShortcut] = [
            "volumeUp": KeyboardShortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: []),
            "volumeDown": KeyboardShortcut(keyCode: UInt16(kVK_F12), modifiers: []),
            "mute": KeyboardShortcut(keyCode: UInt16(kVK_RightArrow), modifiers: [.option]),
            "directMonitor": KeyboardShortcut(keyCode: UInt16(kVK_UpArrow), modifiers: [.shift])
        ]
        preferences.set(try JSONEncoder().encode(saved), forKey: "keyboardShortcuts")
        for manager in [ShortcutManager(preferences: preferences), ShortcutManager(preferences: preferences)] {
            XCTAssertEqual(manager.shortcut(for: .volumeUp), ShortcutAction.volumeUp.defaultShortcut)
            XCTAssertEqual(manager.shortcut(for: .volumeDown), saved["volumeDown"])
            XCTAssertEqual(manager.shortcut(for: .mute), saved["mute"])
            XCTAssertNil(manager.shortcut(for: .directMonitor))
        }
    }

    func testSettingRejectsBareNavigationWithoutReplacingExistingShortcut() {
        let manager = ShortcutManager(preferences: nil)
        manager.setShortcut(KeyboardShortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: []), for: .volumeUp)
        XCTAssertEqual(manager.shortcut(for: .volumeUp), ShortcutAction.volumeUp.defaultShortcut)
    }

    @MainActor
    func testRecorderCancellationReleasesFocusAndCannotCaptureAnotherKey() {
        let recorder = ShortcutRecorderNSView()
        var captures: [KeyboardShortcut] = []
        var cancellations = 0
        recorder.onShortcutRecorded = { captures.append($0) }
        recorder.onCancel = { cancellations += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = recorder
        recorder.isRecording = true
        XCTAssertTrue(window.makeFirstResponder(recorder))
        recorder.keyDown(with: keyEvent(UInt16(kVK_Escape), window: window))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(window.firstResponder === recorder)
        recorder.keyDown(with: keyEvent(UInt16(kVK_F12), window: window))
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(captures.isEmpty)
    }

    @MainActor
    func testRecorderCompletesExactlyOnceAndIgnoresInactiveAndRepeatedKeys() {
        let recorder = ShortcutRecorderNSView()
        var captures: [KeyboardShortcut] = []
        recorder.onShortcutRecorded = { captures.append($0) }
        recorder.keyDown(with: keyEvent(UInt16(kVK_F12)))
        XCTAssertTrue(captures.isEmpty)
        recorder.isRecording = true
        recorder.keyDown(with: keyEvent(UInt16(kVK_F12), repeated: true))
        XCTAssertTrue(captures.isEmpty)
        recorder.keyDown(with: keyEvent(UInt16(kVK_F12)))
        XCTAssertFalse(recorder.isRecording)
        recorder.keyDown(with: keyEvent(UInt16(kVK_F11)))
        XCTAssertEqual(captures.map(\.keyCode), [UInt16(kVK_F12)])
    }

    @MainActor
    func testRecorderLosingFocusCancelsRecording() {
        let recorder = ShortcutRecorderNSView()
        var cancellations = 0
        recorder.onCancel = { cancellations += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = recorder
        recorder.isRecording = true
        XCTAssertTrue(window.makeFirstResponder(recorder))
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(cancellations, 1)
    }

    @MainActor
    func testSwiftUIRecorderBindingCancelsAndCompletesWithoutLaterAssignments() throws {
        let shortcuts = ShortcutManager(preferences: nil)
        let host = NSHostingView(rootView: ShortcutRecorderView(action: .volumeUp, shortcutManager: shortcuts))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 50),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func recorder(in view: NSView) -> ShortcutRecorderNSView? {
            if let found = view as? ShortcutRecorderNSView { return found }
            return view.subviews.lazy.compactMap { recorder(in: $0) }.first
        }
        shortcuts.recordingAction = .volumeUp
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let native = try XCTUnwrap(recorder(in: host))
        XCTAssertTrue(native.isRecording)
        XCTAssertTrue(window.firstResponder === native)
        native.keyDown(with: keyEvent(UInt16(kVK_Escape), window: window))
        XCTAssertNil(shortcuts.recordingAction)
        XCTAssertFalse(window.firstResponder === native)
        native.keyDown(with: keyEvent(UInt16(kVK_LeftArrow), window: window))
        XCTAssertEqual(shortcuts.shortcut(for: .volumeUp), ShortcutAction.volumeUp.defaultShortcut)

        shortcuts.recordingAction = .volumeUp
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(native.isRecording)
        native.keyDown(with: keyEvent(UInt16(kVK_F12), window: window))
        XCTAssertNil(shortcuts.recordingAction)
        native.keyDown(with: keyEvent(UInt16(kVK_F11), window: window))
        XCTAssertEqual(shortcuts.shortcut(for: .volumeUp)?.keyCode, UInt16(kVK_F12))
    }

    @MainActor
    func testHotkeysUpdateImmediatelyPauseForRecordingAndPassOrdinaryArrows() {
        let shortcuts = ShortcutManager(preferences: nil)
        let hotkeys = HotkeyManager(shortcutManager: shortcuts)
        var increases = 0
        hotkeys.onVolumeUp = { increases += 1 }
        hotkeys.start()
        defer { hotkeys.stop() }
        let sink = KeyEventSinkView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = sink
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.makeFirstResponder(sink)
        func press(_ code: Int) {
            let app = NSApplication.shared
            app.postEvent(keyEvent(UInt16(code), window: window), atStart: true)
            if let event = app.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(0.03),
                                         inMode: .default, dequeue: true) { app.sendEvent(event) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        shortcuts.setShortcut(KeyboardShortcut(keyCode: UInt16(kVK_F12), modifiers: []), for: .volumeUp)
        press(kVK_F12)
        XCTAssertEqual(increases, 1)
        shortcuts.recordingAction = .volumeDown
        press(kVK_F12)
        XCTAssertEqual(increases, 1)
        shortcuts.recordingAction = nil
        press(kVK_F12)
        XCTAssertEqual(increases, 2)
        for code in [kVK_LeftArrow, kVK_RightArrow] { press(code) }
        XCTAssertEqual(increases, 2)
        XCTAssertTrue(sink.receivedKeys.contains(UInt16(kVK_LeftArrow)))
        XCTAssertTrue(sink.receivedKeys.contains(UInt16(kVK_RightArrow)))
        shortcuts.resetToDefault(for: .volumeUp)
        press(kVK_F12)
        XCTAssertEqual(increases, 2)
    }

    private func keyEvent(_ code: UInt16, window: NSWindow? = nil, repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window?.windowNumber ?? 0, context: nil,
                        characters: "", charactersIgnoringModifiers: "", isARepeat: repeated, keyCode: code)!
    }

    func testEachVolumeKeyMovesExactlyOneTickAndRetraces() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.usePerceptualVolumeCurve = false
        for tick in 0..<VolumeTickScale.maximumTick {
            controller.setPlaybackVolume(VolumeTickScale.levels[tick])
            controller.playbackVolumeUp()
            XCTAssertEqual(VolumeTickScale.tick(for: controller.playbackVolume), tick + 1)
            XCTAssertEqual(controller.playbackVolume, VolumeTickScale.levels[tick + 1])
            controller.playbackVolumeDown()
            XCTAssertEqual(VolumeTickScale.tick(for: controller.playbackVolume), tick)
            XCTAssertEqual(controller.playbackVolume, VolumeTickScale.levels[tick])
        }
    }

    func testHigherTicksUseOneDbSteps() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.usePerceptualVolumeCurve = false
        for volume in -6...5 {
            controller.setPlaybackVolume(Double(volume))
            controller.playbackVolumeUp()
            XCTAssertEqual(controller.playbackVolume, Double(volume + 1))
        }
    }

    func testPlusSixIsFullScale() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.usePerceptualVolumeCurve = false
        controller.setPlaybackVolume(5)
        controller.playbackVolumeUp()
        XCTAssertEqual(controller.playbackVolume, 6)
        controller.playbackVolumeUp()
        XCTAssertEqual(controller.playbackVolume, 6)
    }

    func testOptimisticValueAccumulatesWhileBackendIsBusy() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.usePerceptualVolumeCurve = false
        controller.setPlaybackVolume(-6)
        controller.playbackVolumeUp()
        controller.playbackVolumeUp()
        controller.playbackVolumeDown()
        XCTAssertEqual(controller.playbackVolume, -5)
    }

    func testPerceptualMidpointAndEndpointsWithAndWithoutGain() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.usePerceptualVolumeCurve = true
        for allowGain in [false, true] {
            controller.allowGain = allowGain
            XCTAssertEqual(controller.maximumVolumeTick, 16)
            XCTAssertEqual(controller.volumeForTick(0), -127)
            XCTAssertEqual(controller.volumeForTick(8), -16)
            XCTAssertEqual(controller.volumeForTick(16), allowGain ? 6 : 0)
            XCTAssertTrue(controller.volumeLevels.contains(0))
            XCTAssertEqual(Set(controller.volumeLevels).count, 17)
            XCTAssertEqual(controller.volumeLevels, controller.volumeLevels.sorted())
        }
    }

    func testPerceptualKeysSliderAndHUDStayOnTheSameTick() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        let hud = VolumeHUDViewModel()
        controller.usePerceptualVolumeCurve = true
        for allowGain in [false, true] {
            controller.allowGain = allowGain
            hud.levels = controller.volumeLevels
            for tick in 0..<16 {
                controller.setPlaybackVolume(controller.volumeForTick(tick))
                controller.playbackVolumeUp()
                hud.volumeDb = controller.playbackVolume
                hud.isMuted = controller.playbackMuted
                XCTAssertEqual(controller.volumeTick(for: controller.playbackVolume), tick + 1)
                XCTAssertEqual(hud.filledTickCount, tick + 1)
                XCTAssertEqual(controller.playbackVolume, controller.volumeForTick(tick + 1))

                controller.playbackVolumeDown()
                hud.volumeDb = controller.playbackVolume
                hud.isMuted = controller.playbackMuted
                XCTAssertEqual(hud.filledTickCount, tick)
                XCTAssertEqual(controller.playbackVolume, controller.volumeForTick(tick))
            }
        }
    }

    func testPerceptualRapidPressesAccumulateAndStopAtEndpoints() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.usePerceptualVolumeCurve = true
        controller.setPlaybackVolume(-16)
        controller.playbackVolumeUp()
        controller.playbackVolumeUp()
        controller.playbackVolumeDown()
        XCTAssertEqual(controller.volumeTick(for: controller.playbackVolume), 9)
        XCTAssertEqual(controller.playbackVolume, -13)

        for _ in 0..<30 { controller.playbackVolumeUp() }
        XCTAssertEqual(controller.playbackVolume, 6)
        for _ in 0..<30 { controller.playbackVolumeDown() }
        XCTAssertEqual(controller.playbackVolume, -127)
        XCTAssertTrue(controller.playbackMuted)
        controller.playbackVolumeUp()
        XCTAssertEqual(controller.volumeTick(for: controller.playbackVolume), 1)
        XCTAssertFalse(controller.playbackMuted)
    }

    func testChangingCurvePreservesCurrentVolumeAndMuteRestore() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.usePerceptualVolumeCurve = false
        controller.setPlaybackVolume(-12)
        controller.usePerceptualVolumeCurve = true
        XCTAssertEqual(controller.playbackVolume, -12)
        controller.mute()
        controller.usePerceptualVolumeCurve = false
        XCTAssertTrue(controller.playbackMuted)
        controller.unmute()
        XCTAssertEqual(controller.playbackVolume, -12)
        XCTAssertFalse(controller.playbackMuted)
    }

    func testPerceptualKeyMovesOneTickFromAnExternalOffGridValue() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.usePerceptualVolumeCurve = true
        controller.setPlaybackVolume(-14)
        let initialTick = controller.volumeTick(for: controller.playbackVolume)
        controller.playbackVolumeUp()
        XCTAssertEqual(controller.volumeTick(for: controller.playbackVolume), initialTick + 1)
        controller.playbackVolumeDown()
        XCTAssertEqual(controller.volumeTick(for: controller.playbackVolume), initialTick)
    }

    func testPerceptualCurvePreferenceSurvivesControllerReload() {
        let domain = "FocusriteVolumeControlTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let original = VolumeController(backend: StubBackend(), preferences: preferences)
        XCTAssertTrue(original.usePerceptualVolumeCurve)
        original.usePerceptualVolumeCurve = false
        let reloaded = VolumeController(backend: StubBackend(), preferences: preferences)
        XCTAssertFalse(reloaded.usePerceptualVolumeCurve)
        reloaded.usePerceptualVolumeCurve = true
        XCTAssertTrue(VolumeController(backend: StubBackend(), preferences: preferences).usePerceptualVolumeCurve)
    }

    func testPerceptualCurveIsTheDefaultWithoutASavedPreference() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        XCTAssertTrue(controller.usePerceptualVolumeCurve)
        XCTAssertEqual(controller.maximumVolumeTick, 16)
        XCTAssertEqual(controller.volumeForTick(8), -16)
    }
}

private final class KeyEventSinkView: NSView {
    var receivedKeys: [UInt16] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { receivedKeys.append(event.keyCode) }
}

private final class StubBackend: VolumeBackend {
    private let subject = CurrentValueSubject<VolumeState, Never>(VolumeState())
    var statePublisher: AnyPublisher<VolumeState, Never> { subject.eraseToAnyPublisher() }
    func connect() async -> VolumeResult { .success }
    func disconnect() {}
    func refresh() async -> VolumeResult { .success }
    func setPlaybackVolume(_ db: Double, ensureDirectMonitor: Bool) async -> VolumeResult { .success }
    func setDirectMonitorEnabled(_ enabled: Bool) async -> VolumeResult { .success }
}
