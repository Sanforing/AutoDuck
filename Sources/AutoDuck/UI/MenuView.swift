import SwiftUI

/// The popover shown from the menu bar icon.
struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showSettings = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            status
            meters
            Divider()
            DisclosureGroup("Settings", isExpanded: $showSettings) {
                settingsBody.padding(.top, 6)
            }
            .font(.subheadline.weight(.medium))
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.statusSymbol)
                .font(.title3)
                .foregroundStyle(model.settings.isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            Text("AutoDuck").font(.headline)
            Spacer()
            Toggle("", isOn: $settings.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.micState == .denied {
                Button("Allow microphone access…") { model.openMicrophoneSettings() }
                    .controlSize(.small)
            }
            HStack(spacing: 4) {
                Image(systemName: "hifispeaker").font(.caption)
                Text(model.outputDeviceName).lineLimit(1)
                Text("·")
                Text("\(Int((model.currentVolume * 100).rounded()))%").monospacedDigit()
                if !model.volumeSupported {
                    Text("· no software volume").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            if model.micState == .running && !model.voiceProcessingActive {
                Label("Echo cancellation unavailable — vocals in songs may trigger ducking",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Map dBFS to a 0…1 bar: -80 dB → 0, 0 dB → 1.
    private func bar(_ db: Float) -> Float { max(0, min(1, (db + 80) / 80)) }

    @ViewBuilder
    private var meters: some View {
        switch settings.detectionMode {
        case .classifier:
            VStack(spacing: 6) {
                MeterRow(label: "Speech", value: model.speechScore, tint: .green,
                         marker: settings.speechThreshold, active: model.gateOpen,
                         text: "\(Int((model.speechScore * 100).rounded()))%")
                MeterRow(label: "Music", value: model.musicScore, tint: .orange, marker: nil, active: false,
                         text: "\(Int((model.musicScore * 100).rounded()))%")
                MeterRow(label: "Level", value: bar(model.windowLevelDB), tint: .blue,
                         marker: bar(settings.levelThresholdDB), active: model.lastWindowPositive,
                         text: model.windowLevelDB <= -100 ? "—" : "\(Int(model.windowLevelDB.rounded())) dB")
                HStack {
                    Text("Both bars must pass their marker to count as talking.")
                    Spacer()
                    if !model.topLabel.isEmpty {
                        Text("hears: \(model.topLabel.replacingOccurrences(of: "_", with: " "))").lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        case .appleVAD:
            HStack(spacing: 8) {
                Circle()
                    .fill(model.vadTalking ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 10, height: 10)
                Text(model.vadTalking ? "Apple voice detector: someone is talking" : "Apple voice detector: quiet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Detector", selection: $settings.detectionMode) {
                ForEach(DetectionMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(settings.detectionMode == .classifier
                 ? "Sound classifier on the echo-cancelled mic, plus a level gate. Tune with the meters above."
                 : "Apple's built-in talker detector (the one behind \"you're muted\" hints). Fewer false alarms from music; may need you to speak up.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.detectionMode == .classifier {
                LabeledSlider(label: "Sensitivity", value: $settings.sensitivity, range: 0...1, step: 0.05,
                              text: String(format: "%d%%  (≥ %d dB, speech ≥ %.0f%%)",
                                           Int((settings.sensitivity * 100).rounded()),
                                           Int(settings.levelThresholdDB.rounded()),
                                           settings.speechThreshold * 100))
            }
            LabeledSlider(label: "Lower music to", value: $settings.duckFraction, range: 0.05...0.8, step: 0.05,
                          text: "\(Int((settings.duckFraction * 100).rounded()))% of current")
            LabeledSlider(label: "Keep low for", value: $settings.holdSeconds, range: 1...15, step: 0.5,
                          text: String(format: "%.1f s after talking", settings.holdSeconds))
            HStack(spacing: 12) {
                LabeledSlider(label: "Fade down", value: $settings.fadeDownSeconds, range: 0.1...3, step: 0.1,
                              text: String(format: "%.1f s", settings.fadeDownSeconds))
                LabeledSlider(label: "Fade up", value: $settings.fadeUpSeconds, range: 0.5...8, step: 0.5,
                              text: String(format: "%.1f s", settings.fadeUpSeconds))
            }
            if settings.detectionMode == .classifier {
                Toggle("Only duck when speech outscores music", isOn: $settings.requireSpeechOverMusic)
            }
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
            Toggle("⌥⌘L toggles AutoDuck", isOn: $settings.hotkeyEnabled)
        }
        .font(.caption)
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    private var footer: some View {
        HStack {
            Button("Test duck") { model.testDuck() }
                .controlSize(.small)
                .disabled(!model.volumeSupported)
            Spacer()
            Text("v0.1").font(.caption2).foregroundStyle(.tertiary)
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
                .keyboardShortcut("q")
        }
    }
}

private struct MeterRow: View {
    let label: String
    let value: Float
    let tint: Color
    let marker: Float?
    let active: Bool
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(active ? tint : tint.opacity(0.7))
                        .frame(width: max(0, geo.size.width * CGFloat(min(max(value, 0), 1))))
                        .animation(.linear(duration: 0.12), value: value)
                    if let marker {
                        Rectangle()
                            .fill(.primary.opacity(0.55))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * CGFloat(marker))
                    }
                }
            }
            .frame(height: 8)
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
