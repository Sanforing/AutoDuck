import Foundation
import CoreAudio
import AudioToolbox

/// Reads and writes the system output volume of the *current default output device* through
/// Core Audio, and reports when somebody else (volume keys, Control Center, another app) changes it.
///
/// Everything here runs on the main thread: the property listeners are registered on the main queue.
final class VolumeController {
    private(set) var deviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    /// Any volume change on the device (including our own writes).
    var onVolumeChanged: ((Float) -> Void)?
    /// A volume change that did not come from one of our recent writes, i.e. the user took over.
    var onExternalChange: ((Float) -> Void)?
    /// The default output device changed (headphones plugged in, AirPlay, ...).
    var onDeviceChanged: (() -> Void)?

    private let queue = DispatchQueue.main
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var volumeListenerAddress: AudioObjectPropertyAddress?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    /// Values we wrote recently, used to tell our own writes apart from the user's.
    private var recentWrites: [(value: Float, at: TimeInterval)] = []

    /// Volume keys move the slider in 1/16 steps (0.0625); anything closer than this to one of our
    /// recent writes is treated as the device echoing our own write back (possibly quantised).
    private let ownWriteTolerance: Float = 0.04

    init() {
        deviceID = Self.defaultOutputDevice()
        installDeviceListener()
        installVolumeListener()
    }

    deinit {
        removeVolumeListener()
        if let deviceListener {
            var address = Self.defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, deviceListener)
        }
    }

    // MARK: - Device

    private static var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() -> AudioObjectID {
        var address = defaultDeviceAddress
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : AudioObjectID(kAudioObjectUnknown)
    }

    var deviceName: String {
        guard deviceID != kAudioObjectUnknown else { return "No output device" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameRef: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nameRef)
        if status == noErr, let name = nameRef?.takeRetainedValue() { return name as String }
        return "Output device"
    }

    // MARK: - Volume

    private var mainVolumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func channelVolumeAddress(_ channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel)
    }

    private func has(_ address: AudioObjectPropertyAddress) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var a = address
        return AudioObjectHasProperty(deviceID, &a)
    }

    var hasMainVolume: Bool { has(mainVolumeAddress) }
    var hasChannelVolume: Bool { has(channelVolumeAddress(1)) }
    /// Some devices (HDMI, some USB DACs) expose no software volume at all.
    var supportsVolume: Bool { hasMainVolume || hasChannelVolume }

    /// Current output volume, 0...1 (the position of the system volume slider), or nil if unknown.
    func getVolume() -> Float? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        var address = mainVolumeAddress
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
            return value
        }
        // Fallback for devices without a virtual main volume: average the first two channels.
        var sum: Float = 0
        var count: Float = 0
        for channel: UInt32 in [1, 2] {
            var ca = channelVolumeAddress(channel)
            var v: Float32 = 0
            var s = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(deviceID, &ca),
               AudioObjectGetPropertyData(deviceID, &ca, 0, nil, &s, &v) == noErr {
                sum += v
                count += 1
            }
        }
        return count > 0 ? sum / count : nil
    }

    func setVolume(_ volume: Float) {
        guard deviceID != kAudioObjectUnknown else { return }
        var value = Float32(min(max(volume, 0), 1))
        rememberWrite(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = mainVolumeAddress
        if AudioObjectHasProperty(deviceID, &address) {
            let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
            if status != noErr { Log.volume.error("Setting main volume failed: \(status)") }
            return
        }
        for channel: UInt32 in [1, 2] {
            var ca = channelVolumeAddress(channel)
            if AudioObjectHasProperty(deviceID, &ca) {
                let status = AudioObjectSetPropertyData(deviceID, &ca, 0, nil, size, &value)
                if status != noErr { Log.volume.error("Setting channel \(channel) volume failed: \(status)") }
            }
        }
    }

    private func rememberWrite(_ value: Float) {
        recentWrites.append((value, Date().timeIntervalSinceReferenceDate))
        if recentWrites.count > 64 { recentWrites.removeFirst(recentWrites.count - 64) }
    }

    // MARK: - Listeners

    private func installVolumeListener() {
        guard deviceID != kAudioObjectUnknown else { return }
        var address = hasMainVolume ? mainVolumeAddress : channelVolumeAddress(1)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.volumeDidChange() }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block)
        if status == noErr {
            volumeListener = block
            volumeListenerAddress = address
        } else {
            Log.volume.error("Could not listen for volume changes: \(status)")
        }
    }

    private func removeVolumeListener() {
        guard let block = volumeListener, var address = volumeListenerAddress else { return }
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
        volumeListener = nil
        volumeListenerAddress = nil
    }

    private func installDeviceListener() {
        var address = Self.defaultDeviceAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.defaultDeviceDidChange() }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        if status == noErr { deviceListener = block } else {
            Log.volume.error("Could not listen for default device changes: \(status)")
        }
    }

    private func defaultDeviceDidChange() {
        let newID = Self.defaultOutputDevice()
        guard newID != deviceID else { return }
        Log.volume.info("Default output device changed: \(self.deviceID) -> \(newID)")
        removeVolumeListener()
        deviceID = newID
        recentWrites.removeAll()
        installVolumeListener()
        onDeviceChanged?()
        if let v = getVolume() { onVolumeChanged?(v) }
    }

    private func volumeDidChange() {
        guard let v = getVolume() else { return }
        let now = Date().timeIntervalSinceReferenceDate
        recentWrites.removeAll { now - $0.at > 1.5 }
        let ours = recentWrites.contains { abs($0.value - v) < ownWriteTolerance }
        onVolumeChanged?(v)
        if !ours { onExternalChange?(v) }
    }
}
