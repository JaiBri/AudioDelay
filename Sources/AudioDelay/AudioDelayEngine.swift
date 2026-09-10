import AVFoundation
import CoreAudio
import AppKit
import Darwin

enum EngineState: Equatable {
    case idle
    case blackHoleMissing
    case waitingForOutputs
    case running(active: Int, configured: Int)
    case error(String)
}

struct CaptureFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct DelayModePreference {
    static func initialEnabled(storedValue: Bool?, systemOutputIsBlackHole: Bool) -> Bool {
        storedValue ?? systemOutputIsBlackHole
    }
}

struct AudioBufferSizing {
    // Short hardware buffers save a few milliseconds, but they leave virtually no
    // scheduling margin. In particular, 256 frames at 192 kHz is only 1.33 ms.
    static let minimumIODuration: Double = 0.020
    static let minimumRingHeadroom: Double = 0.080
    static let callbackHeadroomMultiplier = 4

    static func preferredDeviceFrames(sampleRate: Double,
                                      minimum: UInt32,
                                      maximum: UInt32) -> UInt32 {
        guard sampleRate.isFinite, sampleRate > 0, minimum <= maximum else {
            return minimum
        }

        let durationFrames = UInt64(ceil(sampleRate * minimumIODuration))
        var powerOfTwo: UInt64 = 1
        while powerOfTwo < durationFrames, powerOfTwo < UInt64(UInt32.max) / 2 {
            powerOfTwo <<= 1
        }

        return UInt32(min(UInt64(maximum), max(UInt64(minimum), powerOfTwo)))
    }

    static func minimumRingFrames(ringSampleRate: Double,
                                  captureBufferFrames: UInt32,
                                  captureSampleRate: Double,
                                  outputBufferFrames: UInt32,
                                  outputSampleRate: Double) -> Int {
        func framesAtRingRate(_ frames: UInt32, _ deviceRate: Double) -> Int {
            guard deviceRate.isFinite, deviceRate > 0 else { return Int(frames) }
            return Int(ceil(Double(frames) * ringSampleRate / deviceRate))
        }

        let durationFloor = Int(ceil(ringSampleRate * minimumRingHeadroom))
        let largestCallback = max(
            framesAtRingRate(captureBufferFrames, captureSampleRate),
            framesAtRingRate(outputBufferFrames, outputSampleRate)
        )
        return max(durationFloor, largestCallback * callbackHeadroomMultiplier)
    }
}

struct RingReadSafety {
    static func hasCompleteBlock(readPosition: Double,
                                 writePosition: Double,
                                 readStep: Double,
                                 frameCount: Int,
                                 capacityFrames: Double) -> Bool {
        guard readPosition.isFinite, writePosition.isFinite, readStep.isFinite,
              readStep > 0, frameCount > 0 else { return false }

        let lastReadPosition = readPosition + Double(frameCount - 1) * readStep
        return readPosition >= 0
            && lastReadPosition < writePosition
            && writePosition - readPosition < capacityFrames
    }
}

// BlackHole and each physical output are driven by different hardware clocks.
// Even when both advertise the same nominal sample rate, a tiny clock difference will
// make the ring buffer grow or shrink over time. This controller makes an inaudibly
// small adjustment to the fractional read rate to keep the buffered audio on target.
struct RingDriftCompensator {
    private let smoothingFrames: Double
    private let proportionalGain: Double
    private let maxCorrection: Double
    private let hardResyncErrorFrames: Double

    private(set) var readStep: Double = 1.0
    private(set) var filteredErrorFrames: Double = 0.0

    init(sampleRate: Double) {
        // Average over two seconds so normal input/output callback phasing is not
        // mistaken for clock drift. A ten-second proportional time constant tracks
        // hardware drift without audible pitch modulation.
        smoothingFrames = sampleRate * 2.0
        proportionalGain = 1.0 / (sampleRate * 10.0)
        maxCorrection = 0.002 // ±2,000 ppm; normal correction is only a few ppm.
        hardResyncErrorFrames = sampleRate * 0.25
    }

    mutating func reset() {
        readStep = 1.0
        filteredErrorFrames = 0.0
    }

    mutating func update(bufferedFrames: Double,
                         targetFrames: Double,
                         renderedFrames: Int) -> Double {
        guard bufferedFrames.isFinite, targetFrames.isFinite, renderedFrames > 0 else {
            reset()
            return readStep
        }

        let error = bufferedFrames - targetFrames
        let alpha = min(1.0, Double(renderedFrames) / smoothingFrames)
        filteredErrorFrames += (error - filteredErrorFrames) * alpha

        let unclamped = filteredErrorFrames * proportionalGain
        let correction = max(-maxCorrection, min(maxCorrection, unclamped))
        readStep = 1.0 + correction
        return readStep
    }

    func requiresResynchronization(bufferedFrames: Double,
                                   targetFrames: Double,
                                   capacityFrames: Double) -> Bool {
        guard bufferedFrames.isFinite else { return true }
        guard bufferedFrames < capacityFrames else { return true }

        // A low buffer means capture was late. Jumping the reader backwards there
        // repeats old audio and can trap playback in a robotic loop. The render side
        // instead pauses for a complete block and lets capture catch up naturally.
        return bufferedFrames - targetFrames > hardResyncErrorFrames
    }
}

// Orchestration: one capture engine on BlackHole feeding a shared ring, and one
// PlaybackOutput per enabled, connected output device. Everything in here runs on
// the main thread; only the ring writer and each output's render callback are
// realtime.
final class AudioDelayEngine: ObservableObject {
    static let shared = AudioDelayEngine()

    @Published private(set) var state: EngineState = .idle
    @Published private(set) var availableOutputs: [OutputDeviceInfo] = []
    @Published private(set) var outputStatuses: [OutputStatus] = []
    @Published private(set) var settings = OutputSettings()
    @Published private(set) var isSystemOutputBlackHole: Bool = false
    @Published private(set) var systemOutputName: String = "unknown"
    @Published private(set) var inputDiagnostic: String = ""
    @Published private(set) var isDelayEnabled: Bool = false

    private let defaults = UserDefaults.standard
    private var settingsLoaded = false

    // The capture engine is reused for the app's lifetime, like every PlaybackOutput:
    // see PlaybackOutput for why releasing an engine is unsafe.
    private var captureEngine = AVAudioEngine()
    private var sinkNode: AVAudioSinkNode?
    private var captureObserver: NSObjectProtocol?
    private(set) var captureRunning = false
    private var captureIOFrames: UInt32 = 1_024
    private var captureSampleRate: Double = 48_000
    private var captureLatencyFrames: Int = 0

    private var blackHoleUID: String = ""
    private var blackHoleUIDs: Set<String> = []
    private(set) var blackHoleName: String = ""

    private var ring = AudioRing(sampleRate: OutputSettings.defaultSampleRate)
    private var outputs: [String: PlaybackOutput] = [:]

    private let pinAttempts = 4
    private let engineStartAttempts = 3
    private var isRestarting = false
    private var recoveryWork: DispatchWorkItem?
    private var deviceListWork: DispatchWorkItem?
    private var outputRebuildWork: [String: DispatchWorkItem] = [:]
    private var outputRetryWork: [String: DispatchWorkItem] = [:]
    private var delayWork: [String: DispatchWorkItem] = [:]
    private var settingsSaveWork: DispatchWorkItem?
    private var recentlyAppeared: [String: Date] = [:]
    private var knownOutputUIDs: Set<String> = []

    init() {
        refreshOutputs()
        if ProcessInfo.processInfo.environment["AUDIODELAY_DEBUG"] != nil {
            startDebugLogging()
        }
    }

    // AUDIODELAY_DEBUG=1 prints engine and per-speaker state every few seconds.
    private var debugTimer: Timer?
    private func startDebugLogging() {
        debugTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            var lines = ["[AudioDelay] state=\(self.state) enabled=\(self.isDelayEnabled) capture=\(self.captureRunning) sysOut=\(self.systemOutputName) bh=\(self.isSystemOutputBlackHole) ring=\(Int(self.ring.sampleRate)) w=\(self.ring.loadWritePosition())"]
            for status in self.outputStatuses {
                var line = "  - \(status.name): \(status.phase) min=\(status.minimumPerceivedMs)ms \(status.diagnostic)"
                if let output = self.outputs[status.uid], output.isRunning {
                    let snap = output.debugSnapshot()
                    line += " | blocks=\(snap.renderedBlocks) silent=\(snap.silentBlocks) buffered=\(snap.bufferedFrames) target=\(snap.targetFrames) chain=\(snap.chainLatencyFrames) floor=\(snap.minRingFrames)"
                }
                lines.append(line)
            }
            print(lines.joined(separator: "\n"))
            fflush(stdout)
        }
    }

    deinit {
        stopAllOutputs()
        stopCapture()
    }

    // MARK: - Public API

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var processingSampleRate: Double { ring.sampleRate }

    // BlackHole ships as 2ch, 16ch and 64ch, and more than one can be installed at
    // once. Match the family rather than a single product name, and prefer the
    // narrowest one: every extra channel is captured and discarded.
    @discardableResult
    func detectBlackHole() -> Bool {
        let candidates = enumerateLoopbackCandidates()
        blackHoleUIDs = Set(candidates.map(\.uid))

        guard let chosen = candidates.min(by: { $0.channels < $1.channels }) else {
            blackHoleUID = ""
            blackHoleName = ""
            return false
        }
        blackHoleUID = chosen.uid
        blackHoleName = chosen.name
        return true
    }

    // Must run after detectBlackHole so migration never picks a loopback device.
    func loadSettings() {
        guard !settingsLoaded else { return }
        refreshOutputs()
        let currentDefaultUID = CoreAudioDevices.defaultOutputDeviceID().flatMap { CoreAudioDevices.uidForDevice($0) }
        settings = OutputSettingsStore.load(
            defaults: defaults,
            available: availableOutputs,
            currentDefaultUID: currentDefaultUID,
            blackHoleUIDs: blackHoleUIDs
        )
        ring = AudioRing(sampleRate: settings.processingSampleRate)
        settingsLoaded = true
        publishStatuses()
    }

    func refreshOutputs() {
        let all = CoreAudioDevices.enumerateOutputDevices()
        // Exclude every BlackHole variant and any aggregate that has one as a member:
        // selecting either as a "real" output would route the delay straight back into
        // the capture device — audible as complete silence.
        let filtered = all.filter { !blackHoleUIDs.contains($0.uid) && !wrapsBlackHole($0.id) }
        let uids = Set(filtered.map(\.uid))
        let now = Date()
        for uid in uids.subtracting(knownOutputUIDs) {
            recentlyAppeared[uid] = now
        }
        recentlyAppeared = recentlyAppeared.filter { now.timeIntervalSince($0.value) < 60 }
        knownOutputUIDs = uids
        if filtered != availableOutputs {
            availableOutputs = filtered
        }
    }

    private func wrapsBlackHole(_ id: AudioDeviceID) -> Bool {
        guard !blackHoleUIDs.isEmpty,
              let subDeviceUIDs = CoreAudioDevices.subDeviceUIDs(of: id) else { return false }
        return subDeviceUIDs.contains { blackHoleUIDs.contains($0) }
    }

    private func enumerateLoopbackCandidates() -> [(uid: String, name: String, channels: Int)] {
        CoreAudioDevices.enumerateOutputDevices().compactMap { device in
            guard device.name.hasPrefix("BlackHole") else { return nil }
            guard CoreAudioDevices.hasInputStreams(deviceID: device.id) else { return nil }
            return (device.uid, device.name,
                    CoreAudioDevices.channelCount(of: device.id, scope: kAudioObjectPropertyScopeInput))
        }
    }

    func setDelayEnabled(_ enabled: Bool) {
        if enabled {
            enableDelay()
        } else {
            disableDelay()
        }
    }

    func restart() {
        refreshOutputs()
        refreshSystemOutput()
        setDelayEnabled(isDelayEnabled)
    }

    func setOutputEnabled(uid: String, _ enabled: Bool) {
        guard let device = availableOutputs.first(where: { $0.uid == uid }) else { return }
        settings.upsert(uid: uid, name: device.name, isBluetooth: device.isBluetooth) { $0.enabled = enabled }
        saveSettings()

        if isDelayEnabled {
            if captureRunning {
                reconcileOutputs()
            } else if enabled {
                enableDelay()
            }
        }
        publishStatuses()
    }

    func setOutputDelay(uid: String, seconds: Double) {
        guard let device = availableOutputs.first(where: { $0.uid == uid }) else { return }
        let clamped = OutputConfig.clampDelay(seconds)
        settings.upsert(uid: uid, name: device.name, isBluetooth: device.isBluetooth) { $0.delaySeconds = clamped }
        saveSettings(debounced: true)

        // The debounce keeps slider drags from repositioning the live reader on every
        // pixel. With no engine running, apply immediately.
        delayWork[uid]?.cancel()
        guard let output = outputs[uid], output.isRunning else {
            outputs[uid]?.setDelaySeconds(clamped)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            output.setDelaySeconds(clamped)
            self.publishStatuses()
        }
        delayWork[uid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    func setOutputVolume(uid: String, percent: Double) {
        guard let device = availableOutputs.first(where: { $0.uid == uid }) else { return }
        let clamped = OutputConfig.clampVolume(percent)
        settings.upsert(uid: uid, name: device.name, isBluetooth: device.isBluetooth) { $0.volumePercent = clamped }
        saveSettings(debounced: true)
        outputs[uid]?.setVolumePercent(clamped)
    }

    func setProcessingSampleRate(_ rate: Double) {
        let valid = OutputSettings.validSampleRate(rate)
        guard abs(valid - settings.processingSampleRate) >= 0.5 else { return }
        settings.processingSampleRate = valid
        saveSettings()
        restartProcessingPath()
    }

    func setBitExactWired(_ enabled: Bool) {
        guard enabled != settings.bitExactWired else { return }
        settings.bitExactWired = enabled
        saveSettings()
        restartProcessingPath()
    }

    private func restartProcessingPath() {
        if captureRunning {
            stopAllOutputs()
            stopCapture()
            ring = AudioRing(sampleRate: settings.processingSampleRate)
            enableDelay()
        } else {
            ring = AudioRing(sampleRate: settings.processingSampleRate)
            publishStatuses()
        }
    }

    // Selecting BlackHole in Sound Settings means "on". Any other device while we are
    // actively delaying is either macOS auto-switching to a speaker that just
    // connected (re-assert our route) or the user asking for a direct bypass.
    func handleSystemOutputChange() {
        refreshOutputs()
        refreshSystemOutput()

        if isSystemOutputBlackHole {
            if !isDelayEnabled || !captureRunning {
                enableDelay()
            }
            return
        }

        guard isDelayEnabled, captureRunning else { return }

        let newDefaultUID = CoreAudioDevices.defaultOutputDeviceID().flatMap { CoreAudioDevices.uidForDevice($0) } ?? ""
        let verdict = SystemOutputChangeInterpretation.classify(
            newDefaultUID: newDefaultUID,
            enabledConfiguredUIDs: settings.enabledUIDs
        )
        debugLog("system output -> \(systemOutputName) (\(newDefaultUID)) verdict=\(verdict)")
        switch verdict {
        case .reassertBlackHole:
            if let blackHoleID = CoreAudioDevices.deviceID(forUID: blackHoleUID),
               (try? CoreAudioDevices.setDefaultOutputDevice(blackHoleID)) != nil {
                refreshSystemOutput()
                reconcileOutputs()
                return
            }
            fallthrough
        case .userBypass:
            isDelayEnabled = false
            persistDelayEnabled(false)
            stopAllOutputs()
            stopCapture()
            state = .idle
            refreshSystemOutput()
            publishStatuses()
        }
    }

    // Device add/remove. The listener fires several times while a Bluetooth speaker
    // negotiates, so the reconcile is debounced; the appearance timestamps used by
    // handleSystemOutputChange are recorded immediately in refreshOutputs.
    func handleDeviceListChange() {
        refreshOutputs()
        debugLog("device list changed: \(availableOutputs.map(\.name))")
        deviceListWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.detectBlackHole()
            self.refreshOutputs()
            self.refreshSystemOutput()
            if self.isDelayEnabled {
                if self.captureRunning {
                    self.reconcileOutputs()
                } else if !self.isRestarting {
                    self.enableDelay()
                }
            }
            self.publishStatuses()
        }
        deviceListWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1000), execute: work)
    }

    func prepareForTermination() {
        refreshOutputs()
        refreshSystemOutput()
        // Only reroute when quitting would otherwise leave the system playing into
        // BlackHole. With the delay off the current route is already the user's choice.
        let mustRestore = captureRunning || isSystemOutputBlackHole
        let primary = primaryOutput()
        stopAllOutputs()
        stopCapture()

        if mustRestore, let primary {
            try? CoreAudioDevices.setDefaultOutputDevice(primary.id)
        }
        refreshSystemOutput()
    }

    func refreshSystemOutput() {
        guard let id = CoreAudioDevices.defaultOutputDeviceID() else {
            isSystemOutputBlackHole = false
            systemOutputName = "unknown"
            return
        }
        let uid = CoreAudioDevices.uidForDevice(id) ?? ""
        isSystemOutputBlackHole = !uid.isEmpty
            && (uid == blackHoleUID || blackHoleUIDs.contains(uid))
        systemOutputName = CoreAudioDevices.nameForDevice(id) ?? "unknown"
    }

    static let microphoneDeniedMessage =
        "Microphone access is off. Enable AudioDelay under System Settings → Privacy & Security → Microphone, then turn the delay on again."

    // MARK: - Enable / disable

    private func enableDelay() {
        loadSettings()
        refreshOutputs()
        guard !blackHoleUID.isEmpty,
              let blackHoleID = CoreAudioDevices.deviceID(forUID: blackHoleUID) else {
            isDelayEnabled = false
            persistDelayEnabled(false)
            stopAllOutputs()
            stopCapture()
            state = .blackHoleMissing
            publishStatuses()
            return
        }

        // Nothing to play on: keep the wish to delay, but never route the Mac into
        // BlackHole with no consumer — that would simply mute it.
        let present = Set(availableOutputs.map(\.uid))
        let plan = OutputReconciler.plan(configs: settings.outputs, present: present, running: [])
        if plan.start.isEmpty {
            isDelayEnabled = true
            persistDelayEnabled(true)
            stopAllOutputs()
            stopCapture()
            refreshSystemOutput()
            if isSystemOutputBlackHole, let primary = primaryOutput() {
                try? CoreAudioDevices.setDefaultOutputDevice(primary.id)
                refreshSystemOutput()
            }
            state = .waitingForOutputs
            publishStatuses()
            return
        }

        // Reading from BlackHole is microphone input as far as TCC is concerned. Resolve
        // permission before touching the route.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.enableDelay()
                    } else {
                        self.handleMicrophoneDenied()
                    }
                }
            }
            return
        default:
            handleMicrophoneDenied()
            return
        }

        isDelayEnabled = true
        persistDelayEnabled(true)

        do {
            try CoreAudioDevices.setDefaultOutputDevice(blackHoleID)
            refreshSystemOutput()
            guard isSystemOutputBlackHole else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(kAudioHardwareUnspecifiedError),
                    userInfo: [NSLocalizedDescriptionKey: "macOS did not switch to BlackHole"]
                )
            }
        } catch {
            fallBackToDirectOutput(failure: "Enable delay: \(error.localizedDescription)")
            return
        }

        if case .failure(let failure) = startCapture(blackHoleID: blackHoleID) {
            fallBackToDirectOutput(failure: failure.message)
            return
        }

        for uid in plan.start {
            startOutput(uid: uid)
        }

        if runningOutputUIDs.isEmpty {
            let firstError = plan.start.compactMap { outputs[$0]?.lastError }.first
            fallBackToDirectOutput(failure: firstError ?? "No speaker could be started")
            return
        }

        updateState()
        refreshSystemOutput()
        publishStatuses()
    }

    private func disableDelay() {
        refreshOutputs()
        isDelayEnabled = false
        persistDelayEnabled(false)
        stopAllOutputs()
        stopCapture()

        guard let primary = primaryOutput() else {
            state = .error("No real output devices available")
            refreshSystemOutput()
            publishStatuses()
            return
        }

        do {
            try CoreAudioDevices.setDefaultOutputDevice(primary.id)
            state = .idle
        } catch {
            state = .error("Disable delay: \(error.localizedDescription)")
        }
        refreshSystemOutput()
        publishStatuses()
    }

    private func fallBackToDirectOutput(failure: String) {
        isDelayEnabled = false
        persistDelayEnabled(false)
        stopAllOutputs()
        stopCapture()
        if let primary = primaryOutput() {
            try? CoreAudioDevices.setDefaultOutputDevice(primary.id)
        }
        refreshSystemOutput()
        state = .error(failure)
        publishStatuses()
    }

    private func handleMicrophoneDenied() {
        isDelayEnabled = false
        persistDelayEnabled(false)
        state = .error(Self.microphoneDeniedMessage)
        refreshSystemOutput()
        // If the route already points at BlackHole — a previous session's state
        // restored at launch — leaving it there means silence.
        if isSystemOutputBlackHole, let primary = primaryOutput() {
            try? CoreAudioDevices.setDefaultOutputDevice(primary.id)
            refreshSystemOutput()
        }
        publishStatuses()
    }

    private func persistDelayEnabled(_ enabled: Bool, reason: String = #function) {
        debugLog("delayEnabled=\(enabled) via \(reason)")
        defaults.set(enabled, forKey: "delayEnabled")
    }

    private var debugEnabled: Bool { ProcessInfo.processInfo.environment["AUDIODELAY_DEBUG"] != nil }

    private func debugLog(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        print("[AudioDelay] \(message())")
        fflush(stdout)
    }

    private func saveSettings(debounced: Bool = false) {
        settingsSaveWork?.cancel()
        guard debounced else {
            OutputSettingsStore.save(settings, defaults: defaults)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            OutputSettingsStore.save(self.settings, defaults: self.defaults)
        }
        settingsSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
    }

    private func primaryOutput() -> OutputDeviceInfo? {
        let currentDefaultUID = CoreAudioDevices.defaultOutputDeviceID().flatMap { CoreAudioDevices.uidForDevice($0) }
        return PrimaryOutputSelection.choose(
            configs: settings.outputs,
            available: availableOutputs,
            legacyOutputUID: defaults.string(forKey: OutputSettingsStore.legacyOutputKey),
            currentDefaultUID: currentDefaultUID,
            blackHoleUIDs: blackHoleUIDs
        )
    }

    // MARK: - Capture side

    private func startCapture(blackHoleID: AudioDeviceID) -> Result<Void, CaptureFailure> {
        stopAllOutputs()
        stopCapture()

        // The capture connection cannot resample: AVAudioSinkNode consumes the hardware
        // format as-is, and AVAudioEngine raises an uncatchable NSException when the
        // connection format disagrees with the device. Fail cleanly instead.
        guard CoreAudioDevices.ensureNominalSampleRate(ring.sampleRate, on: blackHoleID) else {
            let actual = Int(CoreAudioDevices.nominalSampleRate(of: blackHoleID) ?? 0)
            return .failure(CaptureFailure("\(blackHoleName) is at \(actual) Hz and could not be set to \(Int(ring.sampleRate)) Hz"))
        }

        captureIOFrames = CoreAudioDevices.ensureStableBufferDuration(on: blackHoleID)
        captureSampleRate = CoreAudioDevices.nominalSampleRate(of: blackHoleID) ?? ring.sampleRate

        // A rebuild triggered from inside this method must not be mistaken for macOS
        // reconfiguring the devices underneath us.
        isRestarting = true
        defer { isRestarting = false }

        var lastFailure = "Could not start audio capture"
        for attempt in 1...engineStartAttempts {
            switch buildAndStartCapture(blackHoleID: blackHoleID) {
            case .success(let format):
                inputDiagnostic = "Input: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch · I/O \(captureIOFrames)f"
                captureLatencyFrames = max(0, Int(captureEngine.inputNode.presentationLatency * ring.sampleRate))
                observeCaptureConfigurationChanges()
                captureRunning = true
                return .success(())
            case .failure(let failure):
                lastFailure = failure.message
                // The ring is cleared so nothing captured during a misrouted attempt —
                // e.g. from the default microphone — can be played out later.
                stopCaptureEngine()
                ring.resetWritePosition()
                if attempt < engineStartAttempts { usleep(60_000) }
            }
        }
        return .failure(CaptureFailure(lastFailure))
    }

    private func buildAndStartCapture(blackHoleID: AudioDeviceID) -> Result<AVAudioFormat, CaptureFailure> {
        guard let inputAU = captureEngine.inputNode.audioUnit else {
            return .failure(CaptureFailure("Engine has no input unit"))
        }
        // Bounce through a wired output rather than a Bluetooth one; see pinDevice.
        let decoy = availableOutputs.first(where: { !$0.isBluetooth })?.id ?? availableOutputs.first?.id
        do {
            try CoreAudioDevices.pinDevice(blackHoleID, on: inputAU, role: "capture",
                                           decoy: decoy, attempts: pinAttempts)
        } catch {
            return .failure(CaptureFailure("Pin device: \(error.localizedDescription)"))
        }

        let captureFormat = captureEngine.inputNode.inputFormat(forBus: 0)
        guard abs(captureFormat.sampleRate - ring.sampleRate) < 0.5 else {
            return .failure(CaptureFailure("\(blackHoleName) is at \(Int(captureFormat.sampleRate)) Hz, expected \(Int(ring.sampleRate)) Hz"))
        }
        guard captureFormat.channelCount >= 1 else {
            return .failure(CaptureFailure("\(blackHoleName) reports no input channels"))
        }

        let ring = self.ring
        let sink = AVAudioSinkNode { _, frames, abl in
            let listPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            ring.write(frames: Int(frames), bufList: listPtr)
            return noErr
        }
        captureEngine.attach(sink)
        // Hardware format, verified above. The ring takes the first two channels, so
        // the wider BlackHole variants work without a converter.
        captureEngine.connect(captureEngine.inputNode, to: sink, format: captureFormat)
        sinkNode = sink

        do {
            captureEngine.prepare()
            try captureEngine.start()
        } catch {
            return .failure(CaptureFailure("Capture start: \(error.localizedDescription)"))
        }

        guard CoreAudioDevices.boundDevice(of: inputAU) == blackHoleID else {
            return .failure(CaptureFailure("Capture moved to \(CoreAudioDevices.boundDeviceName(of: inputAU))"))
        }
        return .success(captureEngine.inputNode.outputFormat(forBus: 0))
    }

    private func observeCaptureConfigurationChanges() {
        removeCaptureObserver()
        captureObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: captureEngine,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleFullRecovery()
        }
    }

    private func removeCaptureObserver() {
        if let token = captureObserver {
            NotificationCenter.default.removeObserver(token)
            captureObserver = nil
        }
    }

    private func stopCaptureEngine() {
        if captureEngine.isRunning { captureEngine.stop() }
        if let s = sinkNode {
            captureEngine.detach(s)
            sinkNode = nil
        }
    }

    // Requires every output to be stopped: readers derive their cursors from the
    // write position that is reset here.
    private func stopCapture() {
        precondition(runningOutputUIDs.isEmpty, "stopCapture with live readers")
        recoveryWork?.cancel()
        removeCaptureObserver()
        stopCaptureEngine()
        ring.resetWritePosition()
        captureRunning = false
        captureLatencyFrames = 0
        inputDiagnostic = ""
    }

    private func scheduleFullRecovery() {
        debugLog("configuration change on capture engine")
        guard isDelayEnabled, !isRestarting else { return }
        recoveryWork?.cancel()
        for work in outputRebuildWork.values { work.cancel() }
        outputRebuildWork.removeAll()
        // Device changes arrive in bursts; one rebuild after they settle is enough.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isDelayEnabled, !self.isRestarting else { return }
            self.enableDelay()
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    // MARK: - Output side

    private var runningOutputUIDs: Set<String> {
        Set(outputs.values.filter(\.isRunning).map(\.uid))
    }

    private func output(for device: OutputDeviceInfo, config: OutputConfig) -> PlaybackOutput {
        if let existing = outputs[device.uid] {
            existing.update(name: device.name, isBluetooth: device.isBluetooth)
            return existing
        }
        let created = PlaybackOutput(uid: device.uid, name: device.name, isBluetooth: device.isBluetooth,
                                     delaySeconds: config.delaySeconds, volumePercent: config.volumePercent)
        outputs[device.uid] = created
        return created
    }

    @discardableResult
    private func startOutput(uid: String) -> Bool {
        guard captureRunning,
              let device = availableOutputs.first(where: { $0.uid == uid }),
              let config = settings.config(for: uid), config.enabled,
              let blackHoleID = CoreAudioDevices.deviceID(forUID: blackHoleUID) else { return false }

        let output = self.output(for: device, config: config)
        output.setDelaySeconds(config.delaySeconds)
        output.setVolumePercent(config.volumePercent)
        output.onConfigurationChange = { [weak self] in
            self?.scheduleOutputRebuild(uid: uid)
        }
        outputRetryWork[uid]?.cancel()

        let context = PlaybackStartContext(
            ring: ring,
            decoyDeviceID: blackHoleID,
            captureIOFrames: captureIOFrames,
            captureSampleRate: captureSampleRate,
            captureLatencyFrames: captureLatencyFrames,
            pinAttempts: pinAttempts,
            startAttempts: engineStartAttempts,
            bitExactWired: settings.bitExactWired
        )

        let outcome = output.start(device: device, context: context)
        debugLog("start \(device.name): \(outcome)")
        switch outcome {
        case .success:
            output.startRetries = 0
            updateState()
            publishStatuses()
            return true
        case .failure:
            // A speaker that just connected may not be ready for its first start.
            if let appeared = recentlyAppeared[uid], Date().timeIntervalSince(appeared) < 15,
               output.startRetries < 2 {
                output.startRetries += 1
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isDelayEnabled, self.captureRunning else { return }
                    self.refreshOutputs()
                    self.startOutput(uid: uid)
                }
                outputRetryWork[uid] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2), execute: work)
            }
            updateState()
            publishStatuses()
            return false
        }
    }

    private func stopOutput(uid: String) {
        if outputs[uid]?.isRunning == true { debugLog("stop \(outputs[uid]?.name ?? uid)") }
        outputRebuildWork[uid]?.cancel()
        outputRebuildWork[uid] = nil
        outputRetryWork[uid]?.cancel()
        outputRetryWork[uid] = nil
        delayWork[uid]?.cancel()
        outputs[uid]?.stop()
    }

    private func stopAllOutputs() {
        for uid in outputs.keys { stopOutput(uid: uid) }
    }

    // AVAudioEngine posts a configuration change when Core Audio reconfigures the
    // device underneath one output. Rebuild only that output; the capture side and
    // every other speaker keep running.
    private func scheduleOutputRebuild(uid: String) {
        debugLog("configuration change on \(outputs[uid]?.name ?? uid)")
        guard isDelayEnabled, captureRunning, !isRestarting,
              let output = outputs[uid], !output.isStarting else { return }
        outputRebuildWork[uid]?.cancel()

        let now = Date()
        output.rebuildTimestamps = output.rebuildTimestamps.filter { now.timeIntervalSince($0) < 10 } + [now]
        // A rate-restore ping-pong with another app would otherwise rebuild forever.
        let backoff: DispatchTimeInterval = output.rebuildTimestamps.count > 3
            ? .seconds(10) : .milliseconds(250)

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isDelayEnabled, self.captureRunning else { return }
            self.restartOutput(uid: uid)
        }
        outputRebuildWork[uid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: work)
    }

    private func restartOutput(uid: String) {
        stopOutput(uid: uid)
        refreshOutputs()
        if availableOutputs.contains(where: { $0.uid == uid }),
           settings.config(for: uid)?.enabled == true {
            startOutput(uid: uid)
        } else {
            updateState()
            publishStatuses()
        }
        settleIfNoOutputs()
    }

    private func reconcileOutputs() {
        guard captureRunning else { return }
        let plan = OutputReconciler.plan(
            configs: settings.outputs,
            present: Set(availableOutputs.map(\.uid)),
            running: runningOutputUIDs
        )
        for uid in plan.stop { stopOutput(uid: uid) }
        for uid in plan.start { startOutput(uid: uid) }
        settleIfNoOutputs()
        updateState()
        publishStatuses()
    }

    // The last speaker went away while the delay is on: give the Mac its direct
    // route back instead of leaving it muted in BlackHole, and wait for a speaker.
    private func settleIfNoOutputs() {
        guard captureRunning, runningOutputUIDs.isEmpty, outputRetryWork.isEmpty else { return }
        stopAllOutputs()
        stopCapture()
        if let primary = primaryOutput() {
            try? CoreAudioDevices.setDefaultOutputDevice(primary.id)
        }
        refreshSystemOutput()
        state = .waitingForOutputs
        publishStatuses()
    }

    // MARK: - Status

    private func updateState() {
        if case .error = state, !isDelayEnabled { return }
        guard isDelayEnabled else {
            state = .idle
            return
        }
        guard captureRunning else {
            state = .waitingForOutputs
            return
        }
        let present = Set(availableOutputs.map(\.uid))
        let configured = settings.outputs.filter { $0.enabled && present.contains($0.uid) }.count
        state = .running(active: runningOutputUIDs.count, configured: configured)
    }

    private func publishStatuses() {
        let statuses = availableOutputs
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { device -> OutputStatus in
                let config = settings.config(for: device.uid)
                let output = outputs[device.uid]
                let phase: OutputPhase
                if let config, config.enabled {
                    if let output, output.isRunning {
                        phase = .running(perceivedMs: output.perceivedDelayMs())
                    } else if let error = output?.lastError, isDelayEnabled, captureRunning {
                        phase = .error(error)
                    } else if isDelayEnabled, captureRunning {
                        phase = .starting
                    } else {
                        phase = .idle
                    }
                } else {
                    phase = .off
                }
                return OutputStatus(
                    uid: device.uid,
                    name: device.name,
                    isBluetooth: device.isBluetooth,
                    phase: phase,
                    minimumPerceivedMs: output?.minimumPerceivedDelayMs() ?? 0,
                    diagnostic: output?.isRunning == true ? output?.diagnostic ?? "" : ""
                )
            }
        if statuses != outputStatuses {
            outputStatuses = statuses
        }
    }
}

