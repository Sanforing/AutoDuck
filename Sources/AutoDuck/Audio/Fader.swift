import Foundation

/// Smoothly interpolates a value over time on the main run loop (30 steps/s, ease-in-out).
final class Fader {
    private let from: Float
    private let to: Float
    private let duration: TimeInterval
    private let onStep: (Float) -> Void
    private let onDone: () -> Void
    private var timer: Timer?
    private var startedAt = Date()

    init(from: Float, to: Float, duration: TimeInterval,
         onStep: @escaping (Float) -> Void, onDone: @escaping () -> Void) {
        self.from = from
        self.to = to
        self.duration = duration
        self.onStep = onStep
        self.onDone = onDone
    }

    func start() {
        startedAt = Date()
        guard duration > 0.02, abs(to - from) > 0.0005 else {
            onStep(to)
            onDone()
            return
        }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keep fading while menus/popovers are open
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let progress = min(1, Date().timeIntervalSince(startedAt) / duration)
        let eased = Float(progress * progress * (3 - 2 * progress))   // smoothstep
        onStep(from + (to - from) * eased)
        if progress >= 1 {
            timer?.invalidate()
            timer = nil
            onDone()
        }
    }
}
