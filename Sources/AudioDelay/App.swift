import SwiftUI
import AppKit
import ServiceManagement
import CoreAudio

@main
struct AudioDelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var engine = AudioDelayEngine.shared
    private let menuBarIcon = AudioDelayMenuBarIcon.make()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(engine)
        } label: {
            Image(nsImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

enum AudioDelayMenuBarIcon {
    // Drawn as a template image so macOS tints it for the current menu bar.
    static func make() -> NSImage {
        if let symbol = NSImage(systemSymbolName: "waveform.badge.plus",
                                accessibilityDescription: "AudioDelay") {
            let configured = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            ) ?? symbol
            configured.isTemplate = true
            return configured
        }
        return fallbackIcon()
    }

    // Drawn by hand in case the symbol is ever unavailable: a wave and its echo.
    private static func fallbackIcon() -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setStroke()

        for (offset, width) in [(CGFloat(0), CGFloat(1.6)), (CGFloat(5), CGFloat(1.0))] {
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            for step in 0...20 {
                let t = CGFloat(step) / 20
                let x = offset + t * 11
                let y = size.height / 2 + sin(t * .pi * 2) * 4
                if step == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
            }
            path.stroke()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaultOutputMonitor = AudioObjectPropertyMonitor(selector: kAudioHardwarePropertyDefaultOutputDevice)
    private let deviceListMonitor = AudioObjectPropertyMonitor(selector: kAudioHardwarePropertyDevices)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched straight from the mounted disk image (or Gatekeeper-translocated):
        // microphone permission, the login item, and the driver install would all bind
        // to a throwaway path. Ask for a real install instead of misbehaving later.
        let bundlePath = Bundle.main.bundlePath
        let onReadOnlyVolume = (try? URL(fileURLWithPath: bundlePath)
            .resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        if bundlePath.contains("/AppTranslocation/")
            || (bundlePath.hasPrefix("/Volumes/") && onReadOnlyVolume) {
            let alert = NSAlert()
            alert.messageText = "Move AudioDelay to Applications first"
            alert.informativeText = """
                AudioDelay is running from the disk image. Drag it into the Applications \
                folder, eject the disk image, and open it from Applications.
                """
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let engine = AudioDelayEngine.shared

        if !engine.detectBlackHole() {
            guard BlackHoleInstaller.runFirstLaunchFlow(detect: { engine.detectBlackHole() }) else {
                NSApp.terminate(nil)
                return
            }
        }

        try? SMAppService.mainApp.register()

        engine.loadSettings()
        engine.refreshOutputs()
        engine.refreshSystemOutput()

        // Existing installs did not have an enabled preference. Derive the first value
        // from the current route so an upgrade never unexpectedly changes the user's audio.
        let savedEnabled = UserDefaults.standard.object(forKey: "delayEnabled") as? Bool
        let storedEnabled = DelayModePreference.initialEnabled(
            storedValue: savedEnabled,
            systemOutputIsBlackHole: engine.isSystemOutputBlackHole
        )
        if savedEnabled == nil {
            UserDefaults.standard.set(storedEnabled, forKey: "delayEnabled")
        }
        engine.setDelayEnabled(storedEnabled)

        defaultOutputMonitor.onChange = { [weak engine] in engine?.handleSystemOutputChange() }
        defaultOutputMonitor.start()
        deviceListMonitor.onChange = { [weak engine] in engine?.handleDeviceListChange() }
        deviceListMonitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioDelayEngine.shared.prepareForTermination()
    }
}

final class AudioObjectPropertyMonitor {
    var onChange: (() -> Void)?
    private var listenerInstalled = false
    private var address: AudioObjectPropertyAddress
    private var block: AudioObjectPropertyListenerBlock?

    init(selector: AudioObjectPropertySelector) {
        address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func start() {
        guard !listenerInstalled else { return }
        let cb: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.onChange?() }
        }
        block = cb
        let st = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            cb
        )
        if st == noErr { listenerInstalled = true }
    }
}

struct ContentView: View {
    @EnvironmentObject var engine: AudioDelayEngine
    @State private var advancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggleRow
            Divider()
            statusRow
            Divider()
            speakersSection
            Divider()
            advancedSection
            Divider()
            footerRow
        }
        .padding(14)
        .frame(width: 340)
        // Devices plugged in while the popover was closed should appear on open.
        .onAppear {
            engine.refreshOutputs()
            engine.refreshSystemOutput()
        }
    }

    // MARK: Master toggle

    private var toggleRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(
                get: { engine.isDelayEnabled },
                set: { engine.setDelayEnabled($0) }
            )) {
                Text("Audio delay")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)

            Text(engine.isDelayEnabled
                 ? "On · via \(engine.blackHoleName.isEmpty ? "BlackHole" : engine.blackHoleName) at \(rateLabel(engine.settings.processingSampleRate))"
                 : "Off · direct output")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Status

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                Spacer()
            }
            if !engine.inputDiagnostic.isEmpty {
                Text(engine.inputDiagnostic)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        if !engine.isDelayEnabled {
            if case .error(let message) = engine.state { return "Error: \(message)" }
            return "Direct · \(engine.systemOutputName)"
        }

        switch engine.state {
        case .idle: return "Starting delay…"
        case .blackHoleMissing: return "BlackHole not installed"
        case .waitingForOutputs: return "Waiting for a speaker · turn one on below"
        case .running(let active, let configured):
            if engine.isSystemOutputBlackHole {
                return active == configured
                    ? "Active · \(active) speaker\(active == 1 ? "" : "s")"
                    : "Active · \(active) of \(configured) speakers"
            } else {
                return "No audio — set system output to BlackHole (now: \(engine.systemOutputName))"
            }
        case .error(let s): return "Error: \(s)"
        }
    }

    private var statusColor: Color {
        if !engine.isDelayEnabled {
            if case .error = engine.state { return .red }
            return .gray
        }

        switch engine.state {
        case .running(let active, let configured):
            guard engine.isSystemOutputBlackHole else { return .orange }
            return active == configured ? .green : .orange
        case .blackHoleMissing, .error: return .red
        case .waitingForOutputs: return .orange
        case .idle: return engine.isSystemOutputBlackHole ? .gray : .orange
        }
    }

    // MARK: Speakers

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers").font(.system(size: 12, weight: .medium))
            if engine.outputStatuses.isEmpty {
                Text("No real output devices found")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(engine.outputStatuses) { status in
                SpeakerRow(status: status, config: engine.settings.config(for: status.uid))
                    .environmentObject(engine)
            }
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Processing rate").font(.system(size: 11))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { engine.settings.processingSampleRate },
                        set: { engine.setProcessingSampleRate($0) }
                    )) {
                        ForEach(OutputSettings.supportedSampleRates, id: \.self) { rate in
                            Text(rateLabel(rate)).tag(rate)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                Text("Match your source for wired playback without resampling. Bluetooth is always AAC/SBC at 44.1 kHz.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Toggle(isOn: Binding(
                    get: { engine.settings.bitExactWired },
                    set: { engine.setBitExactWired($0) }
                )) {
                    Text("Bit-exact wired output").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                Text("No interpolation on wired speakers running at the processing rate, at 100 % volume. Clock drift is corrected by a 30 ms crossfade every few minutes.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } label: {
            Text("Advanced").font(.system(size: 12, weight: .medium))
        }
    }

    // MARK: Footer

    private var footerRow: some View {
        HStack(spacing: 12) {
            if case .running = engine.state, !engine.isSystemOutputBlackHole {
                Button("Open Sound Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound?Output") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            if case .error(let message) = engine.state,
               message == AudioDelayEngine.microphoneDeniedMessage {
                Button("Open Microphone Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            Spacer()
            Button("Restart") { engine.restart() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .keyboardShortcut("q")
        }
    }
}

private func rateLabel(_ rate: Double) -> String {
    let khz = rate / 1000
    return khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
}

struct SpeakerRow: View {
    @EnvironmentObject var engine: AudioDelayEngine
    let status: OutputStatus
    let config: OutputConfig?

    private var enabled: Bool { config?.enabled ?? false }
    private var delay: Double { config?.delaySeconds ?? 0 }
    private var volume: Double { config?.volumePercent ?? 100 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { engine.setOutputEnabled(uid: status.uid, $0) }
                )) {
                    HStack(spacing: 4) {
                        Text(status.name)
                            .font(.system(size: 12, weight: enabled ? .medium : .regular))
                            .lineLimit(1)
                        if status.isBluetooth {
                            Image(systemName: "wave.3.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .help("Bluetooth · AAC/SBC, 44.1 kHz")
                        }
                    }
                }
                .toggleStyle(.checkbox)
                Spacer()
                Circle()
                    .fill(phaseColor)
                    .frame(width: 7, height: 7)
                Text(phaseText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if enabled {
                volumeRow
                delayRow
                if !status.diagnostic.isEmpty {
                    Text(status.diagnostic)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if case .error(let message) = status.phase {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Slider(value: Binding(
                get: { volume },
                set: { engine.setOutputVolume(uid: status.uid, percent: $0) }
            ), in: 0...100, step: 1)
            Text("\(Int(volume)) %")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var delayRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Slider(value: Binding(
                get: { delay },
                set: { engine.setOutputDelay(uid: status.uid, seconds: $0) }
            ), in: 0...OutputConfig.maximumDelaySeconds, step: 0.01)
            Button { adjust(-0.01) } label: { Image(systemName: "minus") }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            Button { adjust(+0.01) } label: { Image(systemName: "plus") }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            Text(String(format: "%.2f s", delay))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func adjust(_ delta: Double) {
        let raw = (delay + delta) * 100
        engine.setOutputDelay(uid: status.uid, seconds: raw.rounded() / 100)
    }

    private var phaseText: String {
        switch status.phase {
        case .off: return "off"
        case .idle: return "ready"
        case .starting: return "starting…"
        case .running(let ms):
            var text = "\(ms) ms"
            if status.minimumPerceivedMs > 0 { text += " · min \(status.minimumPerceivedMs)" }
            return text
        case .error: return "error"
        }
    }

    private var phaseColor: Color {
        switch status.phase {
        case .off: return .gray.opacity(0.4)
        case .idle: return .gray
        case .starting: return .orange
        case .running: return .green
        case .error: return .red
        }
    }
}
