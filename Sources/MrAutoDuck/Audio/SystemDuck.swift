import CoreAudio
import Darwin
import Foundation

/// The moment a voice-processing unit is created, macOS treats the process as "in a voice chat" and
/// ducks every other app's audio on the output device by ~15 dB — visible in CoreAudio's log as
/// `AudioDeviceDuck(<speakers>, 0.177828, …)` — and it stays ducked until the unit is destroyed.
/// The public ducking-configuration API only governs the *additional* static/dynamic ducking, not
/// this one, so music sounds "behind a door" the whole time we listen.
///
/// `AudioDeviceDuck` is the (long-stable, private) client call the system itself used, and duck state
/// is kept per HAL client: calling it again from this process with level 1.0 releases our duck and
/// nobody else's. If the symbol ever disappears from CoreAudio, we quietly do nothing and macOS's
/// ducking simply remains — worse sound, no crash.
enum SystemDuck {
    private typealias DuckFn = @convention(c) (
        AudioDeviceID, Float32, UnsafePointer<AudioTimeStamp>?, Float32
    ) -> OSStatus

    private static let duckFn: DuckFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, "AudioDeviceDuck") else {
            Log.audio.error("AudioDeviceDuck not found; cannot lift the system's voice-chat ducking")
            return nil
        }
        return unsafeBitCast(symbol, to: DuckFn.self)
    }()

    /// Restore other apps' audio on `device` to full level (0.35 s ramp). Safe to call repeatedly.
    static func release(on device: AudioDeviceID) {
        guard device != kAudioObjectUnknown, let duckFn else { return }
        let status = duckFn(device, 1.0, nil, 0.35)
        Log.audio.info("Lifted the system's voice-chat duck on device \(device): status \(status)")
    }
}
