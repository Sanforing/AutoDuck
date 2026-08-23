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
///  * Never listen through a Bluetooth headset's mic: opening it drops the headset into the
///    hands-free profile (everything it plays turns muffled and mono) and the profile switching makes
///    playback stutter. The VPIO unit keeps its input device on element 1 and its output/echo-reference
///    device on element 0; plain AUHAL keeps one device on element 0. After re-pointing the unit, the
///    node's *input* format refreshes on `prepare()` while its cached output (client) format doesn't.
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
    /// The microphone we're listening with.
    private(set) var inputDeviceName = ""
    /// The system default input we deliberately left alone (a Bluetooth headset mic), if any.
    private(set) var skippedInputDeviceName: String?

    private var engine: AVAudioEngine?
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: ClassificationObserver?
    private var configObserver: NSObjectProtocol?
    private let analysisQueue = DispatchQueue(label: "com.mrautoduck.analysis", qos: .userInitiated)

    // Recent per-buffer levels, for the per-window level statistic. Guarded by `levelLock`.
    private let levelLock = NSLock()
    private var recentLevels: [(t: TimeInterval, db: Float)] = []
    private var windowSeconds: Double = 0.75

    func start(mode: DetectionMode) throws {
        guard !isRunning else { return }
        self.mode = mode
        let choice = AudioDevices.preferredInput()
        guard let choice, choice.skippedDefault != nil else {
            try startEngine(mode: mode, choice: nil, allowVoiceProcessing: true)
            return
        }
        // The default input is a Bluetooth headset mic. In order of preference:
        //  1. the room mic through the voice-processing unit (echo cancellation kept),
        //  2. the room mic raw — no echo cancellation, which is fine while the music plays in headphones,
        //  3. the Bluetooth mic itself, as a last resort (the user gets the muffling, but detection works).
        do {
            try startEngine(mode: mode, choice: choice, allowVoiceProcessing: true)
        } catch {
            Log.audio.error("Mic failed with \(choice.device.name, privacy: .public) + voice processing: \(error.localizedDescription, privacy: .public); trying without")
            teardownEngine()
            do {
                try startEngine(mode: mode, choice: choice, allowVoiceProcessing: false)
            } catch {
                Log.audio.error("Mic failed with \(choice.device.name, privacy: .public) raw: \(error.localizedDescription, privacy: .public); falling back to the default input")
                teardownEngine()
                try startEngine(mode: mode, choice: nil, allowVoiceProcessing: true)
            }
        }
    }

    /// Builds and starts a fresh engine. `choice == nil` means "use whatever the system default is".
    private func startEngine(mode: DetectionMode, choice: AudioDevices.Choice?, allowVoiceProcessing: Bool) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        // Echo cancellation is the whole trick: without it the mic would "hear" the singer in the song.
        voiceProcessingActive = false
        if allowVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessingActive = input.isVoiceProcessingEnabled
            } catch {
                Log.audio.error("Voice processing unavailable, falling back to raw mic: \(error.localizedDescription, privacy: .public)")
            }
        }
        if voiceProcessingActive {
            // macOS ducks *other apps'* audio whenever a voice-processing unit runs: with "advanced" off it
            // is a static cut for as long as we run (even `.min` is -4 dB — audibly "a bit lower" the
            // moment the duck is switched on; seen as `AudioDeviceDuck(dev, 0.63)` in CoreAudio's log).
            // "Advanced" ducking only cuts while the unit hears voice — which is when we're ducking hard
            // anyway — and leaves the music alone the rest of the time. Lowering the music is our job.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
            // AGC would pump quiet echo residue up to "speech" levels; we want honest levels.
            input.isVoiceProcessingAGCEnabled = false
        }

        // Which microphone. The default, unless that's a Bluetooth headset (see the class comment).
        skippedInputDeviceName = nil
        if let choice, let skipped = choice.skippedDefault {
            if select(choice.device, on: input) {
                skippedInputDeviceName = skipped.name
                inputDeviceName = choice.device.name
                Log.audio.notice("Listening with \(choice.device.name, privacy: .public) instead of the Bluetooth mic \(skipped.name, privacy: .public)")
            } else {
                Log.audio.error("Could not switch the mic to \(choice.device.name, privacy: .public); staying on \(skipped.name, privacy: .public)")
                inputDeviceName = skipped.name
            }
        } else {
            inputDeviceName = choice?.device.name ?? AudioDevices.name(of: AudioDevices.defaultInputDeviceID())
        }

        // The tap must run at the I/O unit's *device-side* sample rate — installTap throws an
        // Objective-C exception (uncatchable, fatal) otherwise. After a device switch the node's cached
        // formats still show the old device, so ask the unit itself. And never prepare() before the tap
        // is installed: an initialised unit refuses format changes, which is the same fatal exception.
        let hardwareFormat = input.inputFormat(forBus: 0)
        let nodeFormat = input.outputFormat(forBus: 0)
        let unitRate = deviceSideSampleRate(of: input)
        let tapRate = unitRate > 0 ? unitRate : (hardwareFormat.sampleRate > 0 ? hardwareFormat.sampleRate : nodeFormat.sampleRate)
        guard tapRate > 0, nodeFormat.channelCount > 0 || hardwareFormat.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: tapRate, channels: 1) else {
            self.engine = nil
            throw MicError.noInputDevice
        }
        inputFormatDescription = "\(inputDeviceName): unit \(Int(unitRate)) Hz, hw \(Int(hardwareFormat.sampleRate)) Hz \(hardwareFormat.channelCount) ch, node \(Int(nodeFormat.sampleRate)) Hz \(nodeFormat.channelCount) ch, tap \(Int(format.sampleRate)) Hz mono, VPIO \(voiceProcessingActive ? "on" : "off"), mode \(mode.rawValue)"
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
                throw NSError(domain: "MrAutoDuck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple voice detector needs voice processing, which is unavailable"])
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
        ) { [weak self, weak engine] _ in
            guard let self, let engine, engine === self.engine else { return }
            if engine.isRunning {
                // macOS 26 posts this when the voice-processing unit rebuilds its aggregate device right
                // after start — without stopping the engine. Restarting on it was a self-inflicted loop
                // that made other apps' playback stutter (a Bluetooth device in the mix makes it certain).
                Log.audio.info("Audio engine configuration changed; still running, carrying on")
                if self.voiceProcessingActive { SystemDuck.release(on: AudioDevices.defaultOutputDeviceID()) }
            } else {
                Log.audio.info("Audio engine configuration changed; engine stopped, restarting")
                self.onConfigurationChange?()
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true

        if voiceProcessingActive {
            // Lift the ~15 dB "voice chat" duck macOS put on the output device at unit creation
            // (see SystemDuck) — once now, and again after the unit's setup has settled.
            SystemDuck.release(on: AudioDevices.defaultOutputDeviceID())
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak engine] in
                guard let self, let engine, self.engine === engine, engine.isRunning else { return }
                SystemDuck.release(on: AudioDevices.defaultOutputDeviceID())
            }
        }

        if let skipped = choice?.skippedDefault, skippedInputDeviceName != nil {
            // Two seconds in: did the unit keep our mic, and did the Bluetooth mic stay closed?
            let element: AudioUnitElement = voiceProcessingActive ? 1 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak engine] in
                guard let self, let engine, self.engine === engine, engine.isRunning else { return }
                var device = AudioDeviceID(kAudioObjectUnknown)
                var size = UInt32(MemoryLayout<AudioDeviceID>.size)
                if let unit = engine.inputNode.audioUnit {
                    AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element, &device, &size)
                }
                let hw = engine.inputNode.inputFormat(forBus: 0)
                let btState = AudioDevices.isRunningSomewhere(skipped.id) ? "in use" : "idle"
                Log.audio.info("Mic check: unit on \(AudioDevices.name(of: device), privacy: .public) (\(device)), hw \(Int(hw.sampleRate)) Hz; \(skipped.name, privacy: .public) mic is \(btState, privacy: .public)")
            }
        }
    }

    func stop() {
        teardownEngine()
        isRunning = false
    }

    private func teardownEngine() {
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
    }

    /// Sample rate of the device the I/O unit is actually capturing from (its input-scope format on
    /// element 1). 0 if unknown.
    private func deviceSideSampleRate(of input: AVAudioInputNode) -> Double {
        guard let unit = input.audioUnit else { return 0 }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &asbd, &size)
        return status == noErr ? asbd.mSampleRate : 0
    }

    /// Points the engine's I/O unit at `device`. Returns false if the unit didn't take it.
    private func select(_ device: AudioDevices.Device, on input: AVAudioInputNode) -> Bool {
        guard let unit = input.audioUnit else {
            Log.audio.error("Input node has no audio unit; cannot choose a mic")
            return false
        }
        // VPIO: element 1 = input device, element 0 = output device (the echo reference). AUHAL: element 0.
        let element: AudioUnitElement = voiceProcessingActive ? 1 : 0
        var id = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element, &id, size)
        var readBack = AudioDeviceID(kAudioObjectUnknown)
        var readSize = size
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element, &readBack, &readSize)
        if status != noErr || readBack != device.id {
            Log.audio.error("Setting input device \(device.id) on element \(element) failed: status \(status), unit reports \(readBack)")
            return false
        }
        return true
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
