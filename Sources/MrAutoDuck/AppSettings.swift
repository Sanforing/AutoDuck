import Foundation
import Combine

/// User-tunable behaviour, persisted in UserDefaults. Read/written on the main thread.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    /// Master switch. When off, the mic is released and the volume is left alone.
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.isEnabled) } }

    /// 0 = needs very confident speech, 1 = triggers on faint/short speech.
    @Published var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: Key.sensitivity) } }

    /// Ducked volume as a fraction of the volume the user had set (0.25 = a quarter of the slider).
    @Published var duckFraction: Double { didSet { defaults.set(duckFraction, forKey: Key.duckFraction) } }

    @Published var fadeDownSeconds: Double { didSet { defaults.set(fadeDownSeconds, forKey: Key.fadeDownSeconds) } }

    /// How long to stay low after the last detected speech.
    @Published var holdSeconds: Double { didSet { defaults.set(holdSeconds, forKey: Key.holdSeconds) } }

    @Published var fadeUpSeconds: Double { didSet { defaults.set(fadeUpSeconds, forKey: Key.fadeUpSeconds) } }

    /// Stricter mode: only duck when the speech score beats the music score (fewer false triggers
    /// from vocals that leak past echo cancellation, but may miss quiet talk over loud music).
    @Published var requireSpeechOverMusic: Bool { didSet { defaults.set(requireSpeechOverMusic, forKey: Key.requireSpeechOverMusic) } }

    /// Don't bother ducking if the music is already at or below this level (0...1).
    @Published var minimumBaseline: Double { didSet { defaults.set(minimumBaseline, forKey: Key.minimumBaseline) } }

    /// ⌥⌘L toggles Mr. AutoDuck on/off from anywhere.
    @Published var hotkeyEnabled: Bool { didSet { defaults.set(hotkeyEnabled, forKey: Key.hotkeyEnabled) } }

    /// Which detector decides "a person is talking". See `DetectionMode`.
    @Published var detectionMode: DetectionMode { didSet { defaults.set(detectionMode.rawValue, forKey: Key.detectionMode) } }

    private enum Key {
        static let isEnabled = "isEnabled"
        static let sensitivity = "sensitivity"
        static let duckFraction = "duckFraction"
        static let fadeDownSeconds = "fadeDownSeconds"
        static let holdSeconds = "holdSeconds"
        static let fadeUpSeconds = "fadeUpSeconds"
        static let requireSpeechOverMusic = "requireSpeechOverMusic"
        static let minimumBaseline = "minimumBaseline"
        static let hotkeyEnabled = "hotkeyEnabled"
        static let detectionMode = "detectionMode"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.isEnabled: true,
            Key.sensitivity: 0.45,
            Key.duckFraction: 0.25,
            Key.fadeDownSeconds: 0.7,
            Key.holdSeconds: 4.0,
            Key.fadeUpSeconds: 3.0,
            Key.requireSpeechOverMusic: false,
            Key.minimumBaseline: 0.15,
            Key.hotkeyEnabled: true,
            Key.detectionMode: DetectionMode.classifier.rawValue,
        ])
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        sensitivity = defaults.double(forKey: Key.sensitivity)
        duckFraction = defaults.double(forKey: Key.duckFraction)
        fadeDownSeconds = defaults.double(forKey: Key.fadeDownSeconds)
        holdSeconds = defaults.double(forKey: Key.holdSeconds)
        fadeUpSeconds = defaults.double(forKey: Key.fadeUpSeconds)
        requireSpeechOverMusic = defaults.bool(forKey: Key.requireSpeechOverMusic)
        minimumBaseline = defaults.double(forKey: Key.minimumBaseline)
        hotkeyEnabled = defaults.bool(forKey: Key.hotkeyEnabled)
        detectionMode = DetectionMode(rawValue: defaults.string(forKey: Key.detectionMode) ?? "") ?? .classifier
    }

    /// Classifier confidence (0...1) that counts as "someone is talking".
    /// sensitivity 0 -> 0.85, 0.5 -> 0.55, 1 -> 0.25
    var speechThreshold: Float { Float(0.85 - 0.6 * sensitivity) }

    /// Post-echo-cancellation mic level (dBFS) a window must reach to count as talking.
    /// Measured on a MacBook Pro: echo residue of the Mac's own playback sits around -55…-45 dBFS,
    /// a person talking in the room around -45…-30 dBFS.
    /// sensitivity 0 -> -38 dB, 0.5 -> -47 dB, 1 -> -56 dB
    var levelThresholdDB: Float { Float(-38 - 18 * sensitivity) }
}
