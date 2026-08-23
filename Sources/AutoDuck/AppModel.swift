import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import Foundation
import ServiceManagement

/// Wires the pieces together and exposes state to the UI. Main thread only.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum MicState: Equatable {
        case idle, requesting, denied, starting, running
        case failed(String)
    }

    let settings: AppSettings
    let volume = VolumeController()
    let mic = MicMonitor()
    let gate = VoiceActivityGate()
    let ducker: Ducker

    @Published private(set) var micState: MicState = .idle
    /// Instantaneous echo-cancelled mic level in dBFS.
    @Published private(set) var levelDB: Float = -120
    /// Level statistic of the last classifier window (dBFS), compared against the threshold.
    @Published private(set) var windowLevelDB: Float = -120
    @Published private(set) var lastWindowPositive = false
    @Published private(set) var vadTalking = false
    @Published private(set) var speechScore: Float = 0
    @Published private(set) var musicScore: Float = 0
    @Published private(set) var topLabel: String = ""
    @Published private(set) var gateOpen = false
    @Published private(set) var duckState: Ducker.State = .idle
    @Published private(set) var currentVolume: Float = 0
    @Published private(set) var outputDeviceName: String = ""
    @Published private(set) var volumeSupported = true
    @Published private(set) var voiceProcessingActive = false
    @Published private(set) var launchAtLogin = false

    private var hotkey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()
    private var wasEnabled: Bool
    private var wakeObserver: NSObjectProtocol?
    private var restartWorkItem: DispatchWorkItem?
    /// Ignore detections until the echo canceller has had a moment to converge after (re)start.
    private var micWarmupUntil = Date.distantPast

    /// Diagnostic / docs modes that must not start the microphone or touch the volume.
    static var isDeveloperMode: Bool {
        Probe.isActive || Probe.isActive2 || Probe.isActive3 || Probe.isActive4 || DocsRenderer.isActive
    }

    private init() {
        if Self.isDeveloperMode, let ephemeral = UserDefaults(suiteName: "com.autoduck.developer-mode") {
            // Diagnostics and docs rendering must never read or write the user's real preferences.
            ephemeral.removePersistentDomain(forName: "com.autoduck.developer-mode")
            settings = AppSettings(defaults: ephemeral)
        } else {
            settings = AppSettings()
        }
        ducker = Ducker(volume: volume, settings: settings)
        wasEnabled = settings.isEnabled
        wire()
        applySettings()
        refreshOutputInfo()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Log.app.info("AutoDuck starting (enabled: \(self.settings.isEnabled))")
        if settings.isEnabled && !Self.isDeveloperMode { startListening() }
    }

    // MARK: - Wiring

    private func wire() {
        volume.onVolumeChanged = { [weak self] v in self?.currentVolume = v }
        volume.onDeviceChanged = { [weak self] in
            guard let self else { return }
            self.refreshOutputInfo()
            // The echo canceller's reference is the default output; restart so it follows the new device.
            if self.settings.isEnabled { self.scheduleMicRestart() }
        }

        mic.onLevel = { [weak self] db in self?.levelDB = db }
        mic.onScores = { [weak self] s in
            guard let self else { return }
            self.speechScore = s.speech
            self.musicScore = s.music
            self.topLabel = s.topLabel
            self.windowLevelDB = s.levelDB
            if self.settings.isEnabled, Date() >= self.micWarmupUntil {
                self.gate.feed(speech: s.speech, music: s.music, levelDB: s.levelDB)
                self.lastWindowPositive = self.gate.lastWindowPositive
                if self.gate.lastWindowPositive || self.gate.isOpen {
                    Log.duck.info("window speech=\(s.speech, format: .fixed(precision: 2)) music=\(s.music, format: .fixed(precision: 2)) level=\(s.levelDB, format: .fixed(precision: 0)) dB top=\(s.topLabel, privacy: .public) positive=\(self.gate.lastWindowPositive)")
                }
            }
        }
        mic.onVoiceActivity = { [weak self] talking in
            guard let self else { return }
            self.vadTalking = talking
            if self.settings.isEnabled, Date() >= self.micWarmupUntil { self.gate.setVoiceActivity(talking) }
        }
        mic.onFailure = { [weak self] message in
            self?.micState = .failed(message)
            Log.audio.error("Classifier failed: \(message, privacy: .public)")
        }
        mic.onConfigurationChange = { [weak self] in self?.scheduleMicRestart() }

        gate.onChange = { [weak self] open in
            guard let self else { return }
            self.gateOpen = open
            Log.duck.info("Voice gate \(open ? "open" : "closed", privacy: .public)")
            self.ducker.setSpeaking(open)
        }
        ducker.onStateChange = { [weak self] s in self?.duckState = s }

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.settings.isEnabled else { return }
            Log.app.info("Woke from sleep; restarting mic")
            self.scheduleMicRestart()
        }
    }

    /// Called after any settings change (objectWillChange fires *before* the change, hence the
    /// receive(on: main) hop so we read the new values).
    private func applySettings() {
        gate.speechThreshold = settings.speechThreshold
        gate.levelThresholdDB = settings.levelThresholdDB
        gate.requireSpeechOverMusic = settings.requireSpeechOverMusic
        gate.holdSeconds = settings.holdSeconds

        if settings.detectionMode != mic.mode, mic.isRunning {
            Log.app.info("Detection mode -> \(self.settings.detectionMode.rawValue, privacy: .public); restarting mic")
            scheduleMicRestart()
        }

        if settings.hotkeyEnabled, hotkey == nil {
            hotkey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
                guard let self else { return }
                self.settings.isEnabled.toggle()
            }
        } else if !settings.hotkeyEnabled {
            hotkey = nil
        }

        if settings.isEnabled != wasEnabled {
            wasEnabled = settings.isEnabled
            if settings.isEnabled { startListening() } else { stopListening() }
        }
    }

    // MARK: - Mic lifecycle

    func startListening() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startMic()
        case .notDetermined:
            micState = .requesting
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { self.startMic() } else { self.micState = .denied }
                }
            }
        default:
            micState = .denied
        }
    }

    private func startMic() {
        guard settings.isEnabled else { return }
        micState = .starting
        do {
            try mic.start(mode: settings.detectionMode)
            voiceProcessingActive = mic.voiceProcessingActive
            micWarmupUntil = Date().addingTimeInterval(2.0)
            micState = .running
        } catch {
            micState = .failed(error.localizedDescription)
            let ns = error as NSError
            Log.audio.error("Mic start failed: \(error.localizedDescription, privacy: .public) [\(ns.domain, privacy: .public) \(ns.code)]")
        }
    }

    private func stopListening() {
        mic.stop()
        gate.reset()
        ducker.release()
        micState = .idle
        levelDB = -120
        windowLevelDB = -120
        speechScore = 0
        musicScore = 0
        topLabel = ""
        lastWindowPositive = false
        vadTalking = false
    }

    private func scheduleMicRestart() {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.settings.isEnabled else { return }
            self.mic.stop()
            self.gate.reset()
            self.vadTalking = false
            self.startListening()
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    // MARK: - Actions

    func testDuck() {
        ducker.duck(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.gate.isOpen else { return }
            self.ducker.release()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func shutdown() {
        mic.stop()
        ducker.restoreNow()
    }

    private func refreshOutputInfo() {
        outputDeviceName = volume.deviceName
        volumeSupported = volume.supportsVolume
        currentVolume = volume.getVolume() ?? 0
    }

    // MARK: - Docs rendering

    /// Paints the popover with representative values for `--render-docs`. Never called in normal use.
    func applyDemoState(listening: Bool) {
        micState = .running
        voiceProcessingActive = true
        outputDeviceName = "MacBook Pro Speakers"
        volumeSupported = true
        if listening {
            currentVolume = 0.75
            speechScore = 0.12; musicScore = 0.61; windowLevelDB = -58; levelDB = -57
            topLabel = "music"; gateOpen = false; lastWindowPositive = false; duckState = .idle
        } else {
            currentVolume = 0.19
            speechScore = 0.91; musicScore = 0.22; windowLevelDB = -31; levelDB = -33
            topLabel = "speech"; gateOpen = true; lastWindowPositive = true; duckState = .ducked
        }
    }

    // MARK: - Presentation

    enum MenuBarIcon: Equatable {
        case duck(DuckIcon.Style)
        case symbol(String)
    }

    /// The mascot in the menu bar: awake while listening, asleep while the music rests, faded when off.
    var menuBarIcon: MenuBarIcon {
        if micState == .denied { return .symbol("mic.slash.fill") }
        if case .failed = micState { return .symbol("exclamationmark.triangle.fill") }
        if !settings.isEnabled { return .duck(.paused) }
        switch duckState {
        case .duckingDown, .ducked: return .duck(.sleeping)
        case .restoring, .idle: return .duck(.resting)
        }
    }

    /// SF Symbol for the popover header.
    var statusSymbol: String {
        if micState == .denied { return "mic.slash.fill" }
        if case .failed = micState { return "exclamationmark.triangle.fill" }
        if !settings.isEnabled { return "speaker.slash.fill" }
        switch duckState {
        case .duckingDown, .ducked: return "speaker.wave.1.fill"
        case .restoring: return "speaker.wave.2.fill"
        case .idle: return "speaker.wave.3.fill"
        }
    }

    var statusText: String {
        switch micState {
        case .denied: return "Microphone access needed"
        case .failed(let message): return "Problem: \(message)"
        case .requesting: return "Waiting for microphone permission…"
        case .starting: return "Starting…"
        case .idle where !settings.isEnabled: return "Paused — music is left alone"
        case .idle: return "Idle"
        case .running: break
        }
        switch duckState {
        case .duckingDown: return "Someone's talking — lowering music"
        case .ducked: return "Ducked to \(Int((currentVolume * 100).rounded()))% — waiting for quiet"
        case .restoring: return "Quiet again — bringing music back"
        case .idle: return gateOpen ? "Voice detected" : "Listening for conversation"
        }
    }
}
