import Foundation
import CoreAudio

struct Microphone: Identifiable, Equatable {
    let id: String
    let deviceID: AudioDeviceID
    let name: String
}

final class MicrophoneManager: ObservableObject {
    @Published private(set) var devices: [Microphone] = []
    @Published private(set) var defaultDeviceName: String = "Unavailable"
    @Published var selectedUID: String {
        didSet { defaults.set(selectedUID, forKey: "MicrophoneDeviceUID") }
    }

    var selectedDeviceUnavailable: Bool {
        !selectedUID.isEmpty && !devices.contains { $0.id == selectedUID }
    }

    private let defaults: UserDefaults
    private let deviceQueue = DispatchQueue(label: "com.jiamengzhao.freetalking.devices")
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedUID = defaults.string(forKey: "MicrophoneDeviceUID") ?? ""
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = Self.address(selector)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.refresh()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
            )
            if status == noErr {
                listeners.append((address, listener))
            } else {
                logError("MicrophoneManager: Device listener failed with \(status)")
            }
        }
    }

    func refresh() {
        deviceQueue.async { [weak self] in
            let snapshot = Self.readDevices()
            DispatchQueue.main.async {
                self?.devices = snapshot.devices
                self?.defaultDeviceName = snapshot.devices.first { $0.deviceID == snapshot.defaultID }?.name ?? "Unavailable"
            }
        }
    }

    private static func readDevices() -> (devices: [Microphone], defaultID: AudioDeviceID) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        var available: [Microphone] = []
        if AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 {
            var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            let status = ids.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
            }
            if status == noErr {
                available = ids.compactMap { id in
                    guard Self.canBeDefaultInput(id), !Self.isPrivateAggregate(id), Self.hasInputChannels(id),
                          let uid = Self.stringProperty(id, kAudioDevicePropertyDeviceUID),
                          let name = Self.stringProperty(id, kAudioObjectPropertyName) else { return nil }
                    return Microphone(id: uid, deviceID: id, name: name)
                }
            }
        }
        let devices = available.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        if AudioObjectGetPropertyData(system, &address, 0, nil, &size, &deviceID) != noErr {
            deviceID = AudioDeviceID(kAudioObjectUnknown)
        }
        return (devices, deviceID)
    }

    static func recordingDevice(selectedUID: String) throws -> Microphone {
        let snapshot = readDevices()
        let devices = snapshot.devices
        let defaultDeviceID = snapshot.defaultID
        let device = selectedUID.isEmpty
            ? devices.first { $0.deviceID == defaultDeviceID }
            : devices.first { $0.id == selectedUID }
        guard let device else {
            throw NSError(domain: "FreeTalking.Audio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: selectedUID.isEmpty
                    ? "No microphone is available. Connect a microphone and try again."
                    : "The selected microphone is unavailable. Connect a microphone or choose another input device in FreeTalking Settings."
            ])
        }
        return device
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func canBeDefaultInput(_ id: AudioDeviceID) -> Bool {
        // Conferencing drivers can expose input channels for internal routing
        // while declaring that the device is not a selectable system input.
        var address = address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioDevicePropertyScopeInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value == 1
    }

    private static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioAggregateDevicePropertyComposition)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let composition = value?.takeRetainedValue() as? [String: Any] else { return false }
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }

    deinit {
        for (var address, listener) in listeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }
}
