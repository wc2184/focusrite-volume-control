//
//  VolumeController.swift
//  Focusrite Volume Control
//
//  High-level volume control logic for Focusrite devices.
//  Uses Focusrite Control 2's accessibility UI.
//

import Foundation
import Combine
import AppKit  // For NSSound

/// The 16 visible HUD steps and the exact FC2 levels selected by volume keys.
/// Keeping this table shared prevents the key behavior and HUD from drifting.
enum VolumeTickScale {
    static let levels: [Double] = [
        -127, -25, -18, -12, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6
    ]

    static var maximumTick: Int { levels.count - 1 }

    static func tick(for volume: Double) -> Int {
        levels.indices.min { abs(levels[$0] - volume) < abs(levels[$1] - volume) } ?? 0
    }
}

/// Manages volume, mute, and direct monitor controls
/// This is the Controller in our MVC architecture
class VolumeController: ObservableObject {

    // MARK: - Published State (for UI binding)

    @Published var playbackVolume: Double = 0.0  // dB
    @Published var playbackMuted: Bool = false

    @Published var directMonitorEnabled: Bool = false

    @Published var isConnected: Bool = false
    @Published var statusMessage: String = "Initializing..."

    // MARK: - Configuration

    /// Reads macOS "Play feedback when volume is changed" from System Settings → Sound
    var playVolumeSound: Bool {
        UserDefaults.standard.bool(forKey: "com.apple.sound.beep.feedback")
    }
    @Published var ensureDirectMonitorOn: Bool = true  // Auto-enable Direct Monitor before volume changes
    @Published var allowGain: Bool = true  // The HUD's full scale is +6 dB.
    let minVolume: Double = -127.0  // FC2's actual minimum

    /// Maximum volume depends on allowGain setting
    var maxVolume: Double { allowGain ? 6.0 : 0.0 }

    // MARK: - Private Properties

    private let backend: VolumeBackend
    private var cancellables = Set<AnyCancellable>()

    // Pre-mute volume for restore
    private var preMuteVolume: Double = -20.0

    // Tracks the most recent pending volume to prevent stale backend responses
    // from overwriting optimistic updates during rapid key presses
    private var pendingVolume: Double?
    private var volumeWriteTask: Task<Void, Never>?
    private var isConnecting = false
    private var lastVolumeInteraction = Date.distantPast

    // MARK: - Initialization

    init(backend: VolumeBackend) {
        self.backend = backend
        setupBindings()
    }

    /// Convenience init with default AppleScript backend
    convenience init() {
        self.init(backend: AppleScriptBackend())
    }

    private func setupBindings() {
        // Observe backend state changes
        // Use RunLoop.main.next to ensure updates happen after current view cycle
        backend.statePublisher
            .debounce(for: .milliseconds(10), scheduler: RunLoop.main)
            .sink { [weak self] state in
                self?.updateFromBackendState(state)
            }
            .store(in: &cancellables)
    }

    private func updateFromBackendState(_ state: VolumeState) {
        // Don't overwrite optimistic volume while rapid changes are pending
        if pendingVolume == nil {
            if playbackVolume != state.playbackVolume { playbackVolume = state.playbackVolume }
            let isMuted = state.playbackVolume <= minVolume
            if playbackMuted != isMuted { playbackMuted = isMuted }
        }
        if directMonitorEnabled != state.directMonitorEnabled { directMonitorEnabled = state.directMonitorEnabled }
        if isConnected != state.isConnected { isConnected = state.isConnected }
        if statusMessage != state.statusMessage { statusMessage = state.statusMessage }
    }

    // MARK: - Connection

    func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        Task {
            let result = await backend.connect()
            self.isConnecting = false
            if case .error(let msg) = result {
                await MainActor.run {
                    self.statusMessage = msg
                    self.isConnected = false
                }
            }
        }
    }

    func disconnect() {
        volumeWriteTask?.cancel()
        volumeWriteTask = nil
        pendingVolume = nil
        backend.disconnect()
    }

    func refresh() {
        guard pendingVolume == nil else { return }
        Task {
            _ = await backend.refresh()
        }
    }

    func poll() {
        guard Date().timeIntervalSince(lastVolumeInteraction) > 2 else { return }
        refresh()
    }

    // MARK: - Playback Volume Control

    func setPlaybackVolume(_ newVolume: Double) {
        // FC2 only accepts integer dB values - round to nearest int
        let rounded = round(newVolume)
        let clamped = max(minVolume, min(maxVolume, rounded))

        // Optimistic update so rapid key presses accumulate correctly
        playbackVolume = clamped
        playbackMuted = clamped <= minVolume
        pendingVolume = clamped
        lastVolumeInteraction = Date()

        // A single writer preserves key-press order. If more presses arrive while
        // FC2 is busy, send only the newest accumulated value next.
        guard volumeWriteTask == nil else { return }
        volumeWriteTask = Task { [weak self] in
            guard let self else { return }
            while let target = self.pendingVolume {
                let result = await self.backend.setPlaybackVolume(
                    target, ensureDirectMonitor: self.ensureDirectMonitorOn)
                if case .error(let message) = result {
                    self.statusMessage = message
                    self.isConnected = false
                }
                if self.pendingVolume == target {
                    self.pendingVolume = nil
                    if case .error = result { self.refresh() }
                }
            }
            self.volumeWriteTask = nil
        }
    }

    /// Play system sound for volume feedback if enabled
    private func playVolumeFeedback() {
        guard playVolumeSound else { return }
        NSSound.beep()
    }

    func playbackVolumeUp() {
        if playbackMuted {
            setPlaybackVolume(VolumeTickScale.levels[1])
            return
        }
        let nextTick = min(VolumeTickScale.maximumTick,
                           VolumeTickScale.tick(for: playbackVolume) + 1)
        setPlaybackVolume(min(maxVolume, VolumeTickScale.levels[nextTick]))
    }

    func playbackVolumeDown() {
        if playbackMuted {
            return
        }
        let nextTick = max(0, VolumeTickScale.tick(for: playbackVolume) - 1)
        if nextTick == 0 {
            mute()
        } else {
            setPlaybackVolume(VolumeTickScale.levels[nextTick])
        }
    }

    // MARK: - Mute Control (volume-based: min volume = muted)

    func toggleMute() {
        if playbackMuted {
            unmute()
        } else {
            mute()
        }
    }

    func mute() {
        // Save current volume before muting (only if not already at min)
        if playbackVolume > minVolume {
            preMuteVolume = playbackVolume
        }

        // Set to minimum volume (acts as mute)
        // playbackMuted will be derived from volume in updateFromBackendState
        setPlaybackVolume(minVolume)
    }

    func unmute() {
        // Restore previous volume
        // playbackMuted will be derived from volume in updateFromBackendState
        setPlaybackVolume(preMuteVolume)
    }

    // MARK: - Direct Monitor Control

    func toggleDirectMonitor() {
        Task {
            _ = await backend.setDirectMonitorEnabled(!directMonitorEnabled)
        }
    }

    func volumeUp() {
        playVolumeFeedback()
        playbackVolumeUp()
    }
    func volumeDown() {
        playVolumeFeedback()
        playbackVolumeDown()
    }
}
