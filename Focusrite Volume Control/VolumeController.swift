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

    private static let perceptualWithGain = perceptualLevels(maximum: 6)
    private static let perceptualWithoutGain = perceptualLevels(maximum: 0)

    static func levels(perceptual: Bool, allowGain: Bool) -> [Double] {
        guard perceptual else { return levels }
        return allowGain ? perceptualWithGain : perceptualWithoutGain
    }

    static func tick(for volume: Double, levels: [Double] = VolumeTickScale.levels) -> Int {
        levels.indices.min { abs(levels[$0] - volume) < abs(levels[$1] - volume) } ?? 0
    }

    private static func perceptualLevels(maximum: Double) -> [Double] {
        let minimum = levels[0]
        // Calibrate the power curve to -16 dB at tick 8 of 16, with either
        // 0 or +6 dB at the top. FC2 accepts integer dB values only.
        let exponent = log((-16 - minimum) / (maximum - minimum)) / log(0.5)
        var result = (0...maximumTick).map { tick in
            round(minimum + (maximum - minimum) * pow(Double(tick) / Double(maximumTick), exponent))
        }
        // Keep unity gain selectable when the curve also includes boost.
        if maximum > 0 {
            result[self.tick(for: 0, levels: result)] = 0
        }
        return result
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
    @Published var usePerceptualVolumeCurve: Bool {
        didSet { preferences?.set(usePerceptualVolumeCurve, forKey: "usePerceptualVolumeCurve") }
    }
    let minVolume: Double = -127.0  // FC2's actual minimum

    /// Maximum volume depends on allowGain setting
    var maxVolume: Double { allowGain ? 6.0 : 0.0 }

    var volumeLevels: [Double] {
        VolumeTickScale.levels(perceptual: usePerceptualVolumeCurve, allowGain: allowGain)
    }

    var maximumVolumeTick: Int {
        VolumeTickScale.tick(for: maxVolume, levels: volumeLevels)
    }

    func volumeTick(for volume: Double) -> Int {
        min(maximumVolumeTick, VolumeTickScale.tick(for: volume, levels: volumeLevels))
    }

    func volumeForTick(_ tick: Int) -> Double {
        volumeLevels[max(0, min(maximumVolumeTick, tick))]
    }

    // MARK: - Private Properties

    private let backend: VolumeBackend
    private let preferences: UserDefaults?
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

    init(backend: VolumeBackend, preferences: UserDefaults? = .standard) {
        self.backend = backend
        self.preferences = preferences
        self.usePerceptualVolumeCurve = preferences?.object(forKey: "usePerceptualVolumeCurve") as? Bool ?? true
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
            setPlaybackVolume(volumeForTick(1))
            return
        }
        let nextTick = min(maximumVolumeTick, volumeTick(for: playbackVolume) + 1)
        setPlaybackVolume(volumeForTick(nextTick))
    }

    func playbackVolumeDown() {
        if playbackMuted {
            return
        }
        let nextTick = max(0, volumeTick(for: playbackVolume) - 1)
        if nextTick == 0 {
            mute()
        } else {
            setPlaybackVolume(volumeForTick(nextTick))
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
