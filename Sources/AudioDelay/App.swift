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
    // Drawn as a template image so macOS tints it for the current menu bar. The previous
    // icon was hard-coded white, which made it invisible on a light menu bar.
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
    private let monitor = SystemOutputMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched straight from the mounted disk image (or Gatekeeper-translocated):
        // microphone permission, the login item, and the driver install would all bind
        // to a throwaway path. Ask for a real install instead of misbehaving later.
        // The read-only check keeps legitimate installs on external drives working.
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

        let storedDelay = UserDefaults.standard.object(forKey: "delaySeconds") as? Double ?? 0.0
        engine.setDelaySeconds(storedDelay)

        let storedUID = UserDefaults.standard.string(forKey: "outputDeviceUID") ?? ""
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
        engine.setDelayEnabled(storedEnabled, outputUID: storedUID.isEmpty ? nil : storedUID)

        monitor.onChange = { [weak engine] in
            guard let engine else { return }
            let uid = UserDefaults.standard.string(forKey: "outputDeviceUID") ?? ""
            engine.handleSystemOutputChange(outputUID: uid.isEmpty ? nil : uid)
        }
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let uid = UserDefaults.standard.string(forKey: "outputDeviceUID") ?? ""
        AudioDelayEngine.shared.prepareForTermination(outputUID: uid.isEmpty ? nil : uid)
    }
}

final class SystemOutputMonitor {
    var onChange: (() -> Void)?
    private var listenerInstalled = false
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var block: AudioObjectPropertyListenerBlock?

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
    @AppStorage("delaySeconds") var delaySeconds: Double = 0.0
    @AppStorage("outputDeviceUID") var outputDeviceUID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggleRow
            Divider()
            statusRow
            Divider()
            delayRow
            Divider()
            outputRow
            Divider()
            footerRow
        }
        .padding(14)
        .frame(width: 300)
        // Devices plugged in while the popover was closed should appear on open.
        .onAppear {
            engine.refreshOutputs()
            engine.refreshSystemOutput()
        }
    }

    private var toggleRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(
                get: { engine.isDelayEnabled },
                set: { enabled in
                    engine.setDelayEnabled(
                        enabled,
                        outputUID: outputDeviceUID.isEmpty ? nil : outputDeviceUID
                    )
                }
            )) {
                Text("Audio delay")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)

            Text(engine.isDelayEnabled
                 ? "On · routed through \(engine.blackHoleName.isEmpty ? "BlackHole" : engine.blackHoleName) at 48 kHz"
                 : "Off · direct output for lossless playback")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            if !engine.inputDiagnostic.isEmpty {
                Text("\(engine.inputDiagnostic)  ·  \(engine.outputDiagnostic)")
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
        case .running(let ms):
            if engine.isSystemOutputBlackHole {
                return "Active · \(ms) ms"
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
        case .running: return engine.isSystemOutputBlackHole ? .green : .orange
        case .blackHoleMissing, .error: return .red
        case .idle: return engine.isSystemOutputBlackHole ? .gray : .orange
        }
    }

    private var delayRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Delay").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(String(format: "%.2f s", delaySeconds))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $delaySeconds, in: 0...5, step: 0.01)
                .onChange(of: delaySeconds) { newValue in
                    engine.setDelaySeconds(newValue)
                }
            HStack(spacing: 8) {
                Button { adjust(-0.01) } label: { Image(systemName: "minus") }
                    .buttonStyle(.bordered)
                Button { adjust(+0.01) } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Min") { delaySeconds = 0; engine.setDelaySeconds(0) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var outputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output").font(.system(size: 12, weight: .medium))
            Picker("", selection: $outputDeviceUID) {
                Text("(auto)").tag("")
                ForEach(engine.availableOutputs) { dev in
                    Text(dev.name).tag(dev.uid)
                }
            }
            .labelsHidden()
            .onChange(of: outputDeviceUID) { newValue in
                engine.applyOutputSelection(outputUID: newValue.isEmpty ? nil : newValue)
            }
            if engine.availableOutputs.isEmpty {
                Text("No real output devices found")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

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
            Button("Restart") {
                engine.refreshOutputs()
                engine.refreshSystemOutput()
                engine.setDelayEnabled(
                    engine.isDelayEnabled,
                    outputUID: outputDeviceUID.isEmpty ? nil : outputDeviceUID
                )
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .keyboardShortcut("q")
        }
    }

    private func adjust(_ delta: Double) {
        let raw = (delaySeconds + delta) * 100
        let v = max(0.0, min(5.0, raw.rounded() / 100))
        delaySeconds = v
        engine.setDelaySeconds(v)
    }
}
