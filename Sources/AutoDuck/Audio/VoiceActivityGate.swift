import Foundation

/// Turns noisy per-window evidence into a clean "someone is talking" boolean with onset
/// debouncing and a release hold. Main thread only.
final class VoiceActivityGate {
    /// Classifier confidence needed for a window to count as positive.
    var speechThreshold: Float = 0.55
    /// Post-AEC level (dBFS, 80th percentile over the window) needed for a window to count.
    var levelThresholdDB: Float = -46
    /// Also require speech > music for the window to count.
    var requireSpeechOverMusic = false
    /// Consecutive positive windows before opening (windows arrive ~5×/s).
    var onsetWindows = 2
    /// Seconds of no speech before closing.
    var holdSeconds: TimeInterval = 4

    private(set) var isOpen = false {
        didSet { if oldValue != isOpen { onChange?(isOpen) } }
    }
    var onChange: ((Bool) -> Void)?

    /// Last window verdict, for the UI.
    private(set) var lastWindowPositive = false

    private var consecutivePositives = 0
    private var releaseTimer: Timer?

    /// Classifier mode: one call per classifier window.
    func feed(speech: Float, music: Float, levelDB: Float) {
        let positive = speech >= speechThreshold
            && levelDB >= levelThresholdDB
            && (!requireSpeechOverMusic || speech > music)
        lastWindowPositive = positive
        if positive {
            consecutivePositives += 1
            cancelRelease()
            if consecutivePositives >= onsetWindows { isOpen = true }
        } else {
            consecutivePositives = 0
            scheduleReleaseIfNeeded()
        }
    }

    /// Apple-VAD mode: start/stop events from the voice-processing unit.
    func setVoiceActivity(_ talking: Bool) {
        lastWindowPositive = talking
        if talking {
            cancelRelease()
            isOpen = true
        } else {
            scheduleReleaseIfNeeded()
        }
    }

    func reset() {
        cancelRelease()
        consecutivePositives = 0
        lastWindowPositive = false
        isOpen = false
    }

    private func cancelRelease() {
        releaseTimer?.invalidate()
        releaseTimer = nil
    }

    private func scheduleReleaseIfNeeded() {
        guard isOpen, releaseTimer == nil else { return }
        let t = Timer(timeInterval: holdSeconds, repeats: false) { [weak self] _ in
            self?.releaseTimer = nil
            self?.isOpen = false
        }
        RunLoop.main.add(t, forMode: .common)
        releaseTimer = t
    }
}
