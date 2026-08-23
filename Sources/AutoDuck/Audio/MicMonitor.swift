import AVFoundation
import SoundAnalysis
import CoreMedia
import Accelerate

enum MicError: LocalizedError {
    case noInputDevice
    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone available"
        }
    }
}

/// How we decide that a person (not the music) is talking.
enum DetectionMode: String, CaseIterable, Identifiable {
    /// Echo-cancelled mic → Apple's sound classifier ("speech" labels) AND a post-AEC level gate.
    case classifier
    /// Echo-cancelled mic, muted, using Apple's built-in "talking while muted" voice-activity detector.
    case appleVAD

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classifier: return "Classifier + level"
        case .appleVAD: return "Apple voice detector"
        }
    }
}

/// Captures the microphone through Apple's voice-processing I/O unit (acoustic echo cancellation
/// against what the Mac itself is playing + noise reduction). We never store audio; buffers are
/// analysed and dropped.
///
/// Findings that shaped this (see Probe.swift, macOS 26.4, MacBook Pro):
///  * Don't touch `mainMixerNode`/`outputNode` — connecting the mixer makes VPIO init fail (-10875).
///  * The VPIO input node advertises a bogus 9-channel format; tap it as mono at its sample rate.
///  * Echo from the Mac's own speakers is attenuated ~25 dB, but the residual still *sounds like
///    speech* to the classifier, so the classifier alone isn't enough — hence the level gate.
///  * Muting the VPIO input mutes it for every engine in the process, so the two modes can't run
///    side by side.
final class MicMonitor {
    struct Scores {
        let speech: Float       // max confidence over "talking" labels
        let music: Float        // max confidence over "music/singing/instrument" labels
        let topLabel: String
        let topConfidence: Float
        /// 80th-percentile RMS level (dBFS) of the echo-cancelled mic over the classifier window.
        let levelDB: Float
    }

    // All callbacks are delivered on the main thread.
    var onLevel: ((Float) -> Void)?                 // instantaneous mic level in dBFS (~12×/s)
    var onScores: ((Scores) -> Void)?               // classifier mode, ~5×/s
    var onVoiceActivity: ((Bool) -> Void)?          // appleVAD mode
    var onFailure: ((String) -> Void)?
    var onConfigurationChange: (() -> Void)?        // input device changed, engine needs restart

    private(set) var isRunning = false
    private(set) var mode: DetectionMode = .classifier
    private(set) var voiceProcessingActive = false
    private(set) var inputFormatDescription = ""

    private var engine: AVAudioEngine?
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: ClassificationObserver?
    private var configObserver: NSObjectProtocol?
    private let analysisQueue = DispatchQueue(label: "com.autoduck.analysis", qos: .userInitiated)

    // Recent per-buffer levels, for the per-window level statistic. Guarded by `levelLock`.
    private let levelLock = NSLock()
    private var recentLevels: [(t: TimeInterval, db: Float)] = []
    private var windowSeconds: Double = 0.75

    func start(mode: DetectionMode) throws {
        guard !isRunning else { return }
        self.mode = mode
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        // Echo cancellation is the whole trick: without it the mic would "hear" the singer in the song.
        do {
            try input.setVoiceProcessingEnabled(true)
            voiceProcessingActive = input.isVoiceProcessingEnabled
        } catch {
            voiceProcessingActive = false
            Log.audio.error("Voice processing unavailable, falling back to raw mic: \(error.localizedDescription, privacy: .public)")
        }
        if voiceProcessingActive {
            // macOS ducks *other apps'* audio whenever a voice-processing unit runs. Ask for the minimum —
            // lowering the music is our job, and we want to do it on our own terms.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            // AGC would pump quiet echo residue up to "speech" levels; we want honest levels.
            input.isVoiceProcessingAGCEnabled = false
        }

        let nodeFormat = input.outputFormat(forBus: 0)
        guard nodeFormat.sampleRate > 0, nodeFormat.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: nodeFormat.sampleRate, channels: 1) else {
            self.engine = nil
            throw MicError.noInputDevice
        }
        inputFormatDescription = "\(Int(format.sampleRate)) Hz mono (node \(nodeFormat.channelCount) ch), VPIO \(voiceProcessingActive ? "on" : "off"), mode \(mode.rawValue)"
        Log.audio.info("Mic input: \(self.inputFormatDescription, privacy: .public)")

        switch mode {
        case .classifier:
            try setupAnalyzer(format: format)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
                self?.handle(buffer: buffer, at: when)
            }
        case .appleVAD:
            guard voiceProcessingActive else {
                self.engine = nil
                throw NSError(domain: "AutoDuck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple voice detector needs voice processing, which is unavailable"])
            }
            let ok = input.setMutedSpeechActivityEventListener { [weak self] event in
                let talking = (event == .started)
                DispatchQueue.main.async { self?.onVoiceActivity?(talking) }
            }
            if !ok { Log.audio.error("setMutedSpeechActivityEventListener refused") }
            input.isVoiceProcessingInputMuted = true
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Log.audio.info("Audio engine configuration changed")
            self?.onConfigurationChange?()
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            if mode == .classifier { engine.inputNode.removeTap(onBus: 0) }
            if mode == .appleVAD, engine.inputNode.isVoiceProcessingEnabled {
                engine.inputNode.isVoiceProcessingInputMuted = false
            }
            engine.stop()
        }
        engine = nil
        analysisQueue.sync {
            analyzer?.removeAllRequests()
            analyzer = nil
        }
        observer = nil
        levelLock.lock(); recentLevels.removeAll(); levelLock.unlock()
        isRunning = false
    }

    // MARK: - Classification

    private func setupAnalyzer(format: AVAudioFormat) throws {
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = Self.pickWindowDuration(for: request, desiredSeconds: 0.75)
        request.overlapFactor = 0.75   // a fresh result roughly every windowDuration/4
        windowSeconds = request.windowDuration.seconds
        let observer = ClassificationObserver(
            knownLabels: request.knownClassifications,
            onScores: { [weak self] speech, music, top, topConfidence in
                guard let self else { return }
                let level = self.windowLevel()
                let scores = Scores(speech: speech, music: music, topLabel: top,
                                    topConfidence: topConfidence, levelDB: level)
                DispatchQueue.main.async { self.onScores?(scores) }
            },
            onError: { [weak self] message in
                DispatchQueue.main.async { self?.onFailure?(message) }
            })
        try analyzer.add(request, withObserver: observer)
        self.analyzer = analyzer
        self.observer = observer
        Log.audio.info("Classifier window \(request.windowDuration.seconds, format: .fixed(precision: 2)) s, overlap \(request.overlapFactor)")
    }

    private static func pickWindowDuration(for request: SNClassifySoundRequest, desiredSeconds: Double) -> CMTime {
        switch request.windowDurationConstraint {
        case .enumeratedDurations(let options):
            let best = options.min { abs($0.seconds - desiredSeconds) < abs($1.seconds - desiredSeconds) }
            return best ?? request.windowDuration
        case .durationRange(let range):
            let seconds = min(max(desiredSeconds, range.start.seconds), range.end.seconds)
            return CMTime(seconds: seconds, preferredTimescale: 48_000)
        @unknown default:
            return request.windowDuration
        }
    }

    private func handle(buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
            var rms: Float = 0
            vDSP_rmsqv(channels[0], 1, &rms, vDSP_Length(buffer.frameLength))
            let db = 20 * log10(max(rms, 1e-6))   // floor at -120 dBFS
            let now = Date().timeIntervalSinceReferenceDate
            levelLock.lock()
            recentLevels.append((now, db))
            if recentLevels.count > 200 { recentLevels.removeFirst(recentLevels.count - 200) }
            levelLock.unlock()
            DispatchQueue.main.async { [weak self] in self?.onLevel?(db) }
        }
        analysisQueue.async { [weak self] in
            self?.analyzer?.analyze(buffer, atAudioFramePosition: when.sampleTime)
        }
    }

    /// 80th percentile of the per-buffer levels over the last classifier window.
    private func windowLevel() -> Float {
        let cutoff = Date().timeIntervalSinceReferenceDate - windowSeconds
        levelLock.lock()
        let values = recentLevels.filter { $0.t >= cutoff }.map { $0.db }.sorted()
        levelLock.unlock()
        guard !values.isEmpty else { return -120 }
        return values[min(values.count - 1, Int(Double(values.count) * 0.8))]
    }
}

/// Maps the built-in classifier's ~300 labels onto two scores: "people talking" and "music".
final class ClassificationObserver: NSObject, SNResultsObserving {
    private let talkLabels: Set<String>
    private let musicLabels: Set<String>
    private let onScores: (_ speech: Float, _ music: Float, _ top: String, _ topConfidence: Float) -> Void
    private let onError: (String) -> Void

    private static let talkHints = [
        "speech", "conversation", "narration", "monologue", "shout", "yell", "whisper",
        "scream", "babbl", "laugh", "giggl", "chuckle", "snicker", "crying", "sobbing",
    ]
    private static let musicHints = [
        "music", "singing", "sing", "choir", "rapping", "humming", "yodel", "chant",
        "guitar", "piano", "drum", "violin", "orchestra", "synthesizer", "bass", "organ",
        "trumpet", "saxophone", "flute", "harmonica", "accordion", "banjo", "harp", "cello",
        "ukulele", "mandolin", "sitar", "keyboard", "percussion", "cymbal", "tambourine",
        "marimba", "xylophone", "steelpan", "harpsichord", "clarinet", "trombone", "tuba",
        "bagpipes", "didgeridoo", "theremin", "strings", "brass", "beatbox", "scratching",
        "turntable", "plucked", "bowed", "wind_instrument",
    ]

    init(knownLabels: [String],
         onScores: @escaping (_ speech: Float, _ music: Float, _ top: String, _ topConfidence: Float) -> Void,
         onError: @escaping (String) -> Void) {
        var talk = Set<String>()
        var music = Set<String>()
        for label in knownLabels {
            let lower = label.lowercased()
            if Self.talkHints.contains(where: { lower.contains($0) }) {
                talk.insert(label)
            } else if Self.musicHints.contains(where: { lower.contains($0) }) {
                music.insert(label)
            }
        }
        talkLabels = talk
        musicLabels = music
        self.onScores = onScores
        self.onError = onError
        super.init()
        Log.audio.info("Classifier: \(knownLabels.count) labels, \(talk.count) talk, \(music.count) music")
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        var speech: Float = 0
        var music: Float = 0
        for c in result.classifications {
            let confidence = Float(c.confidence)
            if talkLabels.contains(c.identifier) {
                speech = max(speech, confidence)
            } else if musicLabels.contains(c.identifier) {
                music = max(music, confidence)
            }
        }
        let top = result.classifications.first
        onScores(speech, music, top?.identifier ?? "", Float(top?.confidence ?? 0))
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        onError(error.localizedDescription)
    }

    func requestDidComplete(_ request: SNRequest) {}
}
