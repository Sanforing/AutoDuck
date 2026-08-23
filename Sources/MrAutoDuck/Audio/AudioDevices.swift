import CoreAudio
import Foundation

/// Read-only Core Audio helpers for choosing which microphone to listen with.
///
/// Why this exists: if the system's default input is a Bluetooth headset (AirPods, …), opening its
/// microphone drops the headset into the hands-free profile — everything it plays turns muffled and
/// mono, like it's behind a door — and the profile flip-flopping makes playback stutter. The room mic
/// we actually want is the Mac's own. So: use the default input, unless it's Bluetooth; then prefer
/// the built-in mic, then any other wired input; only use the Bluetooth mic when nothing else exists.
enum AudioDevices {
    struct Device: Equatable {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32

        var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
        var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
        /// Things we never pick on the user's behalf: virtual/aggregate devices, AirPlay, and the
        /// iPhone Continuity mic (selecting it would wake up the phone).
        var isPickable: Bool {
            switch transport {
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                 kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeAVB,
                 kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless,
                 kAudioDeviceTransportTypeUnknown:
                return false
            default:
                return !isBluetooth
            }
        }
    }

    struct Choice {
        let device: Device
        /// The system default input, when we decided not to use it.
        let skippedDefault: Device?
    }

    /// The microphone to listen with, per the rules above. `nil` when the system default can't be
    /// identified (the caller then leaves the I/O unit on whatever the system gives it).
    static func preferredInput() -> Choice? {
        let inputs = inputDevices()
        let defaultID = defaultInputDeviceID()
        guard let defaultDevice = inputs.first(where: { $0.id == defaultID }) else { return nil }
        guard defaultDevice.isBluetooth else { return Choice(device: defaultDevice, skippedDefault: nil) }
        let candidates = inputs.filter { $0.isPickable }
        if let builtIn = candidates.first(where: { $0.isBuiltIn }) {
            return Choice(device: builtIn, skippedDefault: defaultDevice)
        }
        if let other = candidates.first {
            return Choice(device: other, skippedDefault: defaultDevice)
        }
        return Choice(device: defaultDevice, skippedDefault: nil)
    }

    // MARK: - Queries

    static func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : AudioDeviceID(kAudioObjectUnknown)
    }

    static func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : AudioDeviceID(kAudioObjectUnknown)
    }

    /// Every device with at least one input channel, in the system's order.
    static func inputDevices() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(of: id) > 0 else { return nil }
            return Device(id: id, name: name(of: id), transport: transportType(of: id))
        }
    }

    static func name(of id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameRef: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &nameRef)
        if status == noErr, let name = nameRef?.takeRetainedValue() { return name as String }
        return "Audio device \(id)"
    }

    static func transportType(of id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = kAudioDeviceTransportTypeUnknown
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : kAudioDeviceTransportTypeUnknown
    }

    /// Whether some process currently has the device running (e.g. a Bluetooth mic that is open).
    static func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    /// Human-readable transport, for logs.
    static func transportName(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "continuity-wired"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity-wireless"
        case kAudioDeviceTransportTypeUnknown: return "unknown"
        default:
            let c = transport.bigEndian
            let bytes = withUnsafeBytes(of: c) { Array($0) }
            return String(bytes: bytes, encoding: .macOSRoman) ?? "\(transport)"
        }
    }

    // MARK: - Private

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
