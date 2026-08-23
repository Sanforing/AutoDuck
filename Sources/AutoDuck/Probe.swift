import AVFoundation
import CoreAudio
import Foundation

/// Diagnostic mode: `open build/AutoDuck.app --args --probe`
/// Tries several AVAudioEngine configurations and writes what happens to
/// ~/Library/Logs/AutoDuck/probe.log. Used during development only.
enum Probe {
    static var isActive: Bool { CommandLine.arguments.contains("--probe") }

    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AutoDuck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("probe.log")
    }()

    private static func write(_ line: String) {
        let text = "\(Date()): \(line)\n"
        Log.audio.info("probe: \(line, privacy: .public)")
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(text.data(using: .utf8)!)
            try? h.close()
        } else {
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    static func run(completion: @escaping () -> Void) {
        try? FileManager.default.removeItem(at: logURL)
        write("=== probe start ===")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                write("mic permission granted: \(granted)")
                guard granted else { completion(); return }
                runConfigs()
                completion()
            }
        }
    }

    private static func describe(_ f: AVAudioFormat) -> String {
        "\(Int(f.sampleRate)) Hz \(f.channelCount) ch \(f.commonFormat.rawValue) interleaved=\(f.isInterleaved)"
    }

    private static func defaultInputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func runConfigs() {
        // A: raw mic, no VPIO
        attempt("A raw mic, tap with node format") { engine in
            let input = engine.inputNode
            let f = input.outputFormat(forBus: 0)
            write("  A input inFmt=\(describe(input.inputFormat(forBus: 0))) outFmt=\(describe(f))")
            input.installTap(onBus: 0, bufferSize: 4096, format: f) { _, _ in }
        }
        // B: VPIO, tap with node output format, no mixer touch
        attempt("B VPIO, tap node format, no mixer") { engine in
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            let f = input.outputFormat(forBus: 0)
            write("  B input inFmt=\(describe(input.inputFormat(forBus: 0))) outFmt=\(describe(f)) outputNode inFmt=\(describe(engine.outputNode.inputFormat(forBus: 0))) outputNode outFmt=\(describe(engine.outputNode.outputFormat(forBus: 0)))")
            input.installTap(onBus: 0, bufferSize: 4096, format: f) { _, _ in }
        }
        // C: VPIO, tap with nil format
        attempt("C VPIO, tap nil format, no mixer") { engine in
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { _, _ in }
        }
        // D: VPIO, mono tap format at node sample rate
        attempt("D VPIO, mono tap format") { engine in
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            let f = input.outputFormat(forBus: 0)
            let mono = AVAudioFormat(standardFormatWithSampleRate: f.sampleRate, channels: 1)!
            input.installTap(onBus: 0, bufferSize: 4096, format: mono) { _, _ in }
        }
        // E: VPIO, connect mixer -> output (our original setup)
        attempt("E VPIO, mixer connected, tap node format") { engine in
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            engine.mainMixerNode.outputVolume = 0
            let f = input.outputFormat(forBus: 0)
            write("  E after mixer: input outFmt=\(describe(f)) outputNode inFmt=\(describe(engine.outputNode.inputFormat(forBus: 0)))")
            input.installTap(onBus: 0, bufferSize: 4096, format: f) { _, _ in }
        }
        // F: VPIO, prepare first, then read format and tap
        attempt("F VPIO, prepare before reading format") { engine in
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            engine.prepare()
            let f = input.outputFormat(forBus: 0)
            write("  F after prepare: input outFmt=\(describe(f))")
            input.installTap(onBus: 0, bufferSize: 4096, format: f) { _, _ in }
        }
        // G: VPIO with explicit input device = default input device
        attempt("G VPIO, explicit current device") { engine in
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            if let au = input.audioUnit {
                var dev = defaultInputDevice()
                let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
                write("  G set device \(dev): status \(st)")
            } else {
                write("  G no audioUnit")
            }
            let f = input.outputFormat(forBus: 0)
            write("  G input outFmt=\(describe(f))")
            input.installTap(onBus: 0, bufferSize: 4096, format: f) { _, _ in }
        }
        // H: VPIO, tap format = inputFormat(forBus:0) of the input node
        attempt("H VPIO, tap with inputFormat") { engine in
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            let f = input.inputFormat(forBus: 0)
            write("  H inFmt=\(describe(f))")
            input.installTap(onBus: 0, bufferSize: 4096, format: f) { _, _ in }
        }
        write("=== probe end ===")
    }

    private static func attempt(_ name: String, _ configure: (AVAudioEngine) throws -> Void) {
        write("--- \(name)")
        let engine = AVAudioEngine()
        do {
            try configure(engine)
            engine.prepare()
            try engine.start()
            write("  \(name): STARTED  (input outFmt now \(describe(engine.inputNode.outputFormat(forBus: 0))))")
            // let it run a moment
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        } catch {
            let ns = error as NSError
            write("  \(name): FAILED \(ns.domain) \(ns.code) \(error.localizedDescription)")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}

// MARK: - Probe 2: which channel carries the echo-cancelled voice, and how much does AEC remove?

import Accelerate

extension Probe {
    static var isActive2: Bool { CommandLine.arguments.contains("--probe2") }

    static func run2(completion: @escaping () -> Void) {
        try? FileManager.default.removeItem(at: logURL)
        write("=== probe2 start === system volume: \(VolumeController().getVolume().map { String($0) } ?? "?")")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else { write("no mic permission"); completion(); return }
                measure("RAW mic (no VPIO)", vpio: false, mono: false)
                measure("VPIO, 9ch node format", vpio: true, mono: false)
                measure("VPIO, mono tap", vpio: true, mono: true)
                write("=== probe2 end ===")
                completion()
            }
        }
    }

    /// Plays a phrase through the speakers starting at t=1s; logs per-channel RMS (dBFS) for
    /// the quiet part (0.2–0.9 s) and the playback part (1.5–4.5 s).
    private static func measure(_ name: String, vpio: Bool, mono: Bool) {
        write("--- \(name)")
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if vpio {
            do { try input.setVoiceProcessingEnabled(true) } catch { write("  VPIO enable failed: \(error)"); return }
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let nodeFormat = input.outputFormat(forBus: 0)
        let tapFormat = mono ? AVAudioFormat(standardFormatWithSampleRate: nodeFormat.sampleRate, channels: 1)! : nodeFormat
        let channels = Int(tapFormat.channelCount)
        let lock = NSLock()
        var samples: [(t: Double, rms: [Float])] = []
        let start = Date()
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            var rms = [Float](repeating: 0, count: channels)
            for c in 0..<channels {
                var v: Float = 0
                vDSP_rmsqv(data[c], 1, &v, vDSP_Length(buffer.frameLength))
                rms[c] = v
            }
            lock.lock(); samples.append((Date().timeIntervalSince(start), rms)); lock.unlock()
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            write("  start failed: \(error)")
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-r", "180", "Testing, one two three. This is AutoDuck checking echo cancellation."]
        try? say.run()
        RunLoop.current.run(until: Date().addingTimeInterval(4.5))
        input.removeTap(onBus: 0)
        engine.stop()
        say.waitUntilExit()

        lock.lock(); let all = samples; lock.unlock()
        func meanDB(_ range: ClosedRange<Double>, _ c: Int) -> String {
            let vals = all.filter { range.contains($0.t) }.map { $0.rms[c] }
            guard !vals.isEmpty else { return "  n/a" }
            let mean = vals.reduce(0, +) / Float(vals.count)
            return String(format: "%6.1f", 20 * log10(max(mean, 1e-7)))
        }
        write("  tap format \(describe(tapFormat)), \(all.count) buffers")
        for c in 0..<channels {
            write("  ch\(c): quiet \(meanDB(0.2...0.9, c)) dB | speaking \(meanDB(1.5...4.5, c)) dB")
        }
    }
}

// MARK: - Probe 3: does the classifier still hear "speech" in what the Mac itself plays?

import SoundAnalysis

extension Probe {
    static var isActive3: Bool { CommandLine.arguments.contains("--probe3") }

    static func run3(completion: @escaping () -> Void) {
        try? FileManager.default.removeItem(at: logURL)
        write("=== probe3 start === system volume: \(VolumeController().getVolume().map { String($0) } ?? "?")")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else { write("no mic permission"); completion(); return }
                let musicPath = CommandLine.arguments.first { $0.hasSuffix(".mp3") || $0.hasSuffix(".m4a") || $0.hasSuffix(".wav") }
                let sources: [(String, () -> Process)] = [
                    ("TTS speech via speakers", {
                        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                        p.arguments = ["-r", "170", "Hello there. Could you turn the music down a little? We are trying to talk to you. Dinner is ready in five minutes."]
                        return p
                    }),
                ] + (musicPath.map { path in [("Music file via speakers", {
                        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                        p.arguments = ["-t", "8", path]
                        return p
                    })] } ?? [])
                for (sourceName, makeProcess) in sources {
                    classify("RAW | \(sourceName)", vpio: false, makeProcess)
                    classify("VPIO mono | \(sourceName)", vpio: true, makeProcess)
                }
                write("=== probe3 end ===")
                completion()
            }
        }
    }

    private final class Collector: NSObject, SNResultsObserving {
        var rows: [(t: Double, speech: Float, music: Float, top: String)] = []
        let talk: Set<String>, music: Set<String>
        let start = Date()
        let lock = NSLock()
        init(labels: [String]) {
            // replicate the label mapping used by the app
            var t = Set<String>(), m = Set<String>()
            let talkHints = ["speech", "conversation", "narration", "monologue", "shout", "yell", "whisper", "scream", "babbl", "laugh", "giggl", "chuckle", "snicker", "crying", "sobbing"]
            let musicHints = ["music", "singing", "sing", "choir", "rapping", "humming", "yodel", "chant", "guitar", "piano", "drum", "violin", "orchestra", "synthesizer", "bass", "organ", "trumpet", "saxophone", "flute", "harmonica", "accordion", "banjo", "harp", "cello", "ukulele", "mandolin", "sitar", "keyboard", "percussion", "cymbal", "tambourine", "marimba", "xylophone", "steelpan", "harpsichord", "clarinet", "trombone", "tuba", "bagpipes", "didgeridoo", "theremin", "strings", "brass", "beatbox", "scratching", "turntable", "plucked", "bowed", "wind_instrument"]
            for l in labels {
                let lower = l.lowercased()
                if talkHints.contains(where: { lower.contains($0) }) { t.insert(l) }
                else if musicHints.contains(where: { lower.contains($0) }) { m.insert(l) }
            }
            talk = t; music = m
        }
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            var s: Float = 0, m: Float = 0
            for c in r.classifications {
                if talk.contains(c.identifier) { s = max(s, Float(c.confidence)) }
                else if music.contains(c.identifier) { m = max(m, Float(c.confidence)) }
            }
            lock.lock(); rows.append((Date().timeIntervalSince(start), s, m, r.classifications.first?.identifier ?? "")); lock.unlock()
        }
        func request(_ request: SNRequest, didFailWithError error: Error) { Probe.write("  classifier error \(error)") }
        func requestDidComplete(_ request: SNRequest) {}
    }

    private static func classify(_ name: String, vpio: Bool, _ makeProcess: () -> Process) {
        write("--- \(name)")
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if vpio {
            do { try input.setVoiceProcessingEnabled(true) } catch { write("  VPIO enable failed: \(error)"); return }
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let nodeFormat = input.outputFormat(forBus: 0)
        let tapFormat = AVAudioFormat(standardFormatWithSampleRate: nodeFormat.sampleRate, channels: 1)!
        let analyzer = SNAudioStreamAnalyzer(format: tapFormat)
        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { write("  no classifier"); return }
        request.windowDuration = CMTime(seconds: 0.75, preferredTimescale: 48_000)
        request.overlapFactor = 0.75
        let collector = Collector(labels: request.knownClassifications)
        try? analyzer.add(request, withObserver: collector)
        let q = DispatchQueue(label: "probe.analysis")
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, when in
            q.async { analyzer.analyze(buffer, atAudioFramePosition: when.sampleTime) }
        }
        do { engine.prepare(); try engine.start() } catch { write("  start failed: \(error)"); return }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let p = makeProcess()
        try? p.run()
        RunLoop.current.run(until: Date().addingTimeInterval(8.5))
        input.removeTap(onBus: 0)
        engine.stop()
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        q.sync { analyzer.removeAllRequests() }

        collector.lock.lock(); let rows = collector.rows; collector.lock.unlock()
        let during = rows.filter { $0.t > 2.5 && $0.t < 9.5 }
        func stats(_ xs: [Float]) -> String {
            guard !xs.isEmpty else { return "n/a" }
            return String(format: "max %.2f mean %.2f", xs.max()!, xs.reduce(0, +) / Float(xs.count))
        }
        var hist: [String: Int] = [:]
        during.forEach { hist[$0.top, default: 0] += 1 }
        let topLabels = hist.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        write("  windows during playback: \(during.count)")
        write("  speech: \(stats(during.map { $0.speech }))   music: \(stats(during.map { $0.music }))")
        write("  top labels: \(topLabels)")
        write("  windows over 0.55 speech: \(during.filter { $0.speech >= 0.55 }.count)  | speech>music: \(during.filter { $0.speech > $0.music }.count)")
    }
}

// MARK: - Probe 4: level-aware detection — echo return loss (raw vs AEC) + Apple's muted-speech VAD

extension Probe {
    static var isActive4: Bool { CommandLine.arguments.contains("--probe4") }

    private final class LevelTrack {
        let lock = NSLock()
        var rows: [(t: Double, db: Float)] = []
        let start: Date
        init(start: Date) { self.start = start }
        func add(_ buffer: AVAudioPCMBuffer) {
            guard let d = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            var rms: Float = 0
            vDSP_rmsqv(d[0], 1, &rms, vDSP_Length(buffer.frameLength))
            let db = 20 * log10(max(rms, 1e-7))
            lock.lock(); rows.append((Date().timeIntervalSince(start), db)); lock.unlock()
        }
        func summary(_ range: ClosedRange<Double>) -> String {
            lock.lock(); let xs = rows.filter { range.contains($0.t) }.map { $0.db }.sorted(); lock.unlock()
            guard !xs.isEmpty else { return "n/a" }
            let p50 = xs[xs.count / 2], p90 = xs[min(xs.count - 1, Int(Double(xs.count) * 0.9))]
            return String(format: "p50 %6.1f  p90 %6.1f  max %6.1f dB (n=%d)", p50, p90, xs.last!, xs.count)
        }
    }

    static func run4(completion: @escaping () -> Void) {
        try? FileManager.default.removeItem(at: logURL)
        write("=== probe4 start === system volume: \(VolumeController().getVolume().map { String($0) } ?? "?")")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else { write("no mic permission"); completion(); return }
                run4Body()
                write("=== probe4 end ===")
                completion()
            }
        }
    }

    private static func run4Body() {
        let musicPath = CommandLine.arguments.first { $0.hasSuffix(".mp3") || $0.hasSuffix(".m4a") || $0.hasSuffix(".wav") }

        /// Plays TTS at t=3..~11 s and music at t=13.5..21.5 s, calls `report` for each phase.
        func schedule(report: (String, ClosedRange<Double>) -> Void, start: Date) {
            func wait(until t: Double) { RunLoop.current.run(until: start.addingTimeInterval(t)) }
            wait(until: 3.0)
            let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-r", "170", "Hello there. Could you turn the music down a little? We are trying to talk to you. Dinner is ready in five minutes."]
            try? say.run()
            wait(until: 11.5)
            say.waitUntilExit()
            wait(until: 13.5)
            var music: Process?
            if let musicPath {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                p.arguments = ["-t", "8", musicPath]
                try? p.run(); music = p
            }
            wait(until: 22.5)
            music?.terminate()
            wait(until: 25.0)
            report("quiet", 1.0...2.8)
            report("TTS via speakers", 3.5...11.0)
            report("gap", 11.8...13.3)
            report("music via speakers", 14.0...22.0)
            report("quiet after", 23.0...24.8)
        }

        // ---- Run 1: RAW mic levels (must run before any VPIO engine exists in this process)
        do {
            write("--- run 1: RAW mic")
            let start = Date()
            let engine = AVAudioEngine()
            let track = LevelTrack(start: start)
            let input = engine.inputNode
            let f = AVAudioFormat(standardFormatWithSampleRate: input.outputFormat(forBus: 0).sampleRate, channels: 1)!
            input.installTap(onBus: 0, bufferSize: 4096, format: f) { buffer, _ in track.add(buffer) }
            engine.prepare(); try engine.start()
            schedule(report: { name, range in write("  [\(name)] raw: \(track.summary(range))") }, start: start)
            input.removeTap(onBus: 0); engine.stop()
        } catch { write("  run 1 failed: \(error)") }

        // ---- Run 2: VPIO unmuted, AGC off: levels + classifier
        do {
            write("--- run 2: VPIO (AGC off) levels + classifier")
            let start = Date()
            let engine = AVAudioEngine()
            let track = LevelTrack(start: start)
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            input.isVoiceProcessingAGCEnabled = false
            let f = AVAudioFormat(standardFormatWithSampleRate: input.outputFormat(forBus: 0).sampleRate, channels: 1)!
            let analyzer = SNAudioStreamAnalyzer(format: f)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 0.75, preferredTimescale: 48_000)
            request.overlapFactor = 0.75
            let collector = Collector(labels: request.knownClassifications)
            try analyzer.add(request, withObserver: collector)
            let q = DispatchQueue(label: "probe4.analysis")
            input.installTap(onBus: 0, bufferSize: 4096, format: f) { buffer, when in
                track.add(buffer)
                q.async { analyzer.analyze(buffer, atAudioFramePosition: when.sampleTime) }
            }
            engine.prepare(); try engine.start()
            write("  started, AGC \(input.isVoiceProcessingAGCEnabled ? "on" : "off")")
            schedule(report: { name, range in
                collector.lock.lock(); let rows = collector.rows.filter { range.contains($0.t) }; collector.lock.unlock()
                let hi = rows.filter { $0.speech >= 0.55 }.count
                var hist: [String: Int] = [:]; rows.forEach { hist[$0.top, default: 0] += 1 }
                let top = hist.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                let meanS = rows.isEmpty ? 0 : rows.map { $0.speech }.reduce(0, +) / Float(rows.count)
                write("  [\(name)] aec: \(track.summary(range))")
                write(String(format: "  [%@] classifier: %d windows, %d speech>=0.55, mean speech %.2f | %@", name, rows.count, hi, meanS, top))
            }, start: start)
            input.removeTap(onBus: 0); engine.stop()
            q.sync { analyzer.removeAllRequests() }
        } catch { write("  run 2 failed: \(error)") }

        // ---- Run 3: VPIO muted + speech activity listener
        do {
            write("--- run 3: VPIO muted + Apple speech-activity VAD")
            let start = Date()
            let engine = AVAudioEngine()
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            let lock = NSLock()
            var events: [(t: Double, started: Bool)] = []
            let ok = input.setMutedSpeechActivityEventListener { event in
                let started = (event == .started)
                let t = Date().timeIntervalSince(start)
                lock.lock(); events.append((t, started)); lock.unlock()
                write(String(format: "  VAD event at %.1fs: %@", t, started ? "STARTED" : "ended"))
            }
            input.isVoiceProcessingInputMuted = true
            let f = AVAudioFormat(standardFormatWithSampleRate: input.outputFormat(forBus: 0).sampleRate, channels: 1)!
            let track = LevelTrack(start: start)
            input.installTap(onBus: 0, bufferSize: 4096, format: f) { buffer, _ in track.add(buffer) }
            engine.prepare(); try engine.start()
            write("  started, listener set: \(ok), muted: \(input.isVoiceProcessingInputMuted)")
            schedule(report: { name, range in
                lock.lock(); let ev = events.filter { range.contains($0.t) }; lock.unlock()
                write("  [\(name)] VAD events: \(ev.count) (\(ev.filter { $0.started }.count) started) | tap level \(track.summary(range))")
            }, start: start)
            input.removeTap(onBus: 0); engine.stop()
        } catch { write("  run 3 failed: \(error)") }
    }
}
