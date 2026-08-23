import Foundation

/// The volume state machine: idle -> duckingDown -> ducked -> restoring -> idle.
///
/// * `setSpeaking(true)` lowers the system volume to `baseline * duckFraction`.
/// * `setSpeaking(false)` brings it back to the baseline the user had before.
/// * If the user touches the volume while we're ducked, we get out of the way: the duck cycle is
///   abandoned and we won't re-duck until the current conversation is over.
///
/// Main thread only.
final class Ducker {
    enum State: Equatable { case idle, duckingDown, ducked, restoring }

    private(set) var state: State = .idle {
        didSet { if oldValue != state { onStateChange?(state) } }
    }
    /// The user's own volume, captured when a duck starts.
    private(set) var baseline: Float = 1
    /// True after the user adjusted the volume mid-duck; cleared when speech ends.
    private(set) var userOverride = false

    var onStateChange: ((State) -> Void)?

    private let volume: VolumeController
    private let settings: AppSettings
    private var fader: Fader?

    init(volume: VolumeController, settings: AppSettings) {
        self.volume = volume
        self.settings = settings
        volume.onExternalChange = { [weak self] v in self?.handleExternalChange(v) }
    }

    func setSpeaking(_ speaking: Bool) {
        if speaking { duck() } else { release() }
    }

    private var duckTarget: Float { max(0, baseline * Float(settings.duckFraction)) }

    /// Lower the volume. `force` ignores the user-override latch and the minimum-baseline rule
    /// (used by the "Test" button).
    @discardableResult
    func duck(force: Bool = false) -> Bool {
        if userOverride && !force { return false }
        switch state {
        case .duckingDown, .ducked:
            return true
        case .idle:
            guard let current = volume.getVolume() else { return false }
            guard force || current >= Float(settings.minimumBaseline) else {
                Log.duck.info("Volume \(current) already low; not ducking")
                return false
            }
            baseline = current
            Log.duck.info("Duck: \(current) -> \(self.duckTarget)")
            runFade(to: duckTarget, seconds: settings.fadeDownSeconds, during: .duckingDown, then: .ducked)
            return true
        case .restoring:
            // Speech resumed mid-restore: turn around, keep the original baseline.
            runFade(to: duckTarget, seconds: settings.fadeDownSeconds, during: .duckingDown, then: .ducked)
            return true
        }
    }

    /// Bring the volume back up (after the hold time has elapsed — the gate handles timing).
    func release() {
        userOverride = false
        switch state {
        case .idle, .restoring:
            return
        case .duckingDown, .ducked:
            Log.duck.info("Restore -> \(self.baseline)")
            runFade(to: baseline, seconds: settings.fadeUpSeconds, during: .restoring, then: .idle)
        }
    }

    /// Immediate restore, for quit/termination.
    func restoreNow() {
        fader?.cancel()
        fader = nil
        if state != .idle {
            volume.setVolume(baseline)
            state = .idle
        }
    }

    private func runFade(to target: Float, seconds: Double, during: State, then after: State) {
        fader?.cancel()
        let from = volume.getVolume() ?? baseline
        state = during
        let f = Fader(from: from, to: target, duration: seconds,
                      onStep: { [weak self] v in self?.volume.setVolume(v) },
                      onDone: { [weak self] in
                          self?.fader = nil
                          self?.state = after
                      })
        fader = f
        f.start()
    }

    private func handleExternalChange(_ newVolume: Float) {
        guard state != .idle else { return }
        Log.duck.info("User changed volume to \(newVolume) during \(String(describing: self.state)); handing control back")
        fader?.cancel()
        fader = nil
        state = .idle
        userOverride = true
    }
}
