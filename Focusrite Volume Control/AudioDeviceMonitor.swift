//
//  AudioDeviceMonitor.swift
//  Focusrite Volume Control
//
//  Monitors the default audio output device using CoreAudio.
//  Detects whether a Focusrite Scarlett is the active output and
//  notifies observers when the device changes.
//

import Foundation
import CoreAudio
import Combine

class AudioDeviceMonitor: ObservableObject {

    @Published private(set) var isFocusriteDefaultOutput: Bool = false

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    /// Re-check the current default output device
    func refresh() {
        isFocusriteDefaultOutput = checkDefaultOutputDevice()
    }

    // MARK: - Device Detection

    private func checkDefaultOutputDevice() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        ) == noErr else {
            return false
        }

        let name = getStringProperty(deviceID, selector: kAudioObjectPropertyName) ?? "Unknown"
        let manufacturer = getStringProperty(deviceID, selector: kAudioObjectPropertyManufacturer) ?? ""

        let combined = "\(name) \(manufacturer)".lowercased()
        return combined.contains("focusrite") || combined.contains("scarlett")
    }

    private func getStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var rawValue: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &rawValue
        ) == noErr else {
            return nil
        }

        return rawValue?.takeRetainedValue() as String?
    }

    // MARK: - Change Monitoring

    private func startMonitoring() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
        listenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func stopMonitoring() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        listenerBlock = nil
    }
}
