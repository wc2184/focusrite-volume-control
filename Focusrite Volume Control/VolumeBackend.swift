//
//  VolumeBackend.swift
//  Focusrite Volume Control
//
//  Interface for the Focusrite Control 2 accessibility backend.
//

import Foundation
import Combine

/// Result of a volume operation
enum VolumeResult {
    case success
    case error(String)
}

/// Current state of the volume backend
struct VolumeState {
    var playbackVolume: Double = 0.0      // dB
    var directMonitorEnabled: Bool = false
    var isConnected: Bool = false
    var statusMessage: String = "Not connected"
}

/// Protocol for volume control backends
protocol VolumeBackend: AnyObject {
    /// Publisher for state changes
    var statePublisher: AnyPublisher<VolumeState, Never> { get }

    /// Initialize and connect to FC2
    func connect() async -> VolumeResult

    /// Disconnect from FC2
    func disconnect()

    /// Refresh state from FC2
    func refresh() async -> VolumeResult

    func setPlaybackVolume(_ db: Double, ensureDirectMonitor: Bool) async -> VolumeResult
    func setDirectMonitorEnabled(_ enabled: Bool) async -> VolumeResult

}

/// Errors that can occur during volume operations
enum VolumeBackendError: Error, LocalizedError {
    case fc2NotRunning
    case fc2WindowNotFound
    case appleScriptError(String)

    var errorDescription: String? {
        switch self {
        case .fc2NotRunning:
            return "Focusrite Control 2 is not running"
        case .fc2WindowNotFound:
            return "Minimize Focusrite Control 2 so volume keys can reach it from any desktop"
        case .appleScriptError(let msg):
            return "AppleScript error: \(msg)"
        }
    }
}
