import AVFoundation
import CoreAudio
import AppKit
import Darwin

enum EngineState: Equatable {
    case idle
    case blackHoleMissing
    case running(delayMs: Int)
    case error(String)
}

struct OutputDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
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

// BlackHole and the physical output device are driven by different hardware clocks.
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

final class AudioDelayEngine: ObservableObject {
    static let shared = AudioDelayEngine()

    @Published private(set) var state: EngineState = .idle
    @Published private(set) var availableOutputs: [OutputDeviceInfo] = []
    @Published private(set) var isSystemOutputBlackHole: Bool = false
    @Published private(set) var systemOutputName: String = "unknown"
    @Published private(set) var inputDiagnostic: String = ""
    @Published private(set) var outputDiagnostic: String = ""
    @Published private(set) var baselineMs: Int = 0
    @Published private(set) var isDelayEnabled: Bool = false

    // Two AVAudioEngine instances — Apple-supported pattern (one device per engine).
    // captureEngine.inputNode is pinned to BlackHole; playbackEngine.outputNode to the
    // user's chosen real output. The ring buffer bridges them. The instances are reused
    // for the app's lifetime: see buildAndStartEngines for why releasing them crashes.
    private var captureEngine = AVAudioEngine()
    private var playbackEngine = AVAudioEngine()
    private var sinkNode: AVAudioSinkNode?
    private var sourceNode: AVAudioSourceNode?
    private var blackHoleUID: String = ""
    private var blackHoleUIDs: Set<String> = []
    private(set) var blackHoleName: String = ""

    // Pinning can transiently fail while the previous run releases a device, and a
    // started engine can still end up on the wrong device, so both steps are retried.
    private let pinAttempts = 4
    private let engineStartAttempts = 3
    private var configurationObservers: [NSObjectProtocol] = []
    private var isRestarting = false
    private var recoveryWork: DispatchWorkItem?

    private let sampleRate: Double = 48_000
    private let ringCapacity = 262_144
    private let mask: Int
    private let crossfadeFrames: Int = 1_440  // 30 ms @ 48 kHz
    private var minRingFrames: Int = 3_840    // Updated from actual device buffers at start.
    private var chainLatencyFrames: Int = 0
    private var userTargetSeconds: Double = 0.0
    private var configuredOutputDeviceID: AudioDeviceID?
    private var originalOutputSampleRate: Double?
    private var originalOutputBufferFrames: UInt32?
    private var configuredOutputBufferFrames: UInt32?

    // The capture and playback callbacks run concurrently. All cross-thread scalar
    // state is published with full memory barriers; the sample arrays themselves are
    // protected by the single-writer/single-reader cursor ordering.
    private let ringL: UnsafeMutablePointer<Float>
    private let ringR: UnsafeMutablePointer<Float>
    private let writePos: UnsafeMutablePointer<Int64>
    private var readPos: Double = 0
    private var crossfadeFromReadPos: Double = 0
    private var crossfadeRemaining: Int = 0
    private var lastSeenTargetRevision: UInt32 = .max
    private var driftCompensator = RingDriftCompensator(sampleRate: 48_000)

    // High 32 bits: revision; low 32 bits: non-negative target frame count. Packing
    // both values makes each render callback see a coherent snapshot without a lock.
    private let targetStateBits: UnsafeMutablePointer<Int64>

    private var debounceWork: DispatchWorkItem?

    init() {
        self.mask = ringCapacity - 1
        self.ringL = UnsafeMutablePointer<Float>.allocate(capacity: ringCapacity)
        self.ringR = UnsafeMutablePointer<Float>.allocate(capacity: ringCapacity)
        self.writePos = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        self.targetStateBits = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        self.ringL.initialize(repeating: 0, count: ringCapacity)
        self.ringR.initialize(repeating: 0, count: ringCapacity)
        self.writePos.initialize(to: 0)
        self.targetStateBits.initialize(to: 0)
        refreshOutputs()
    }

    deinit {
        teardown()
        ringL.deallocate()
        ringR.deallocate()
        writePos.deinitialize(count: 1)
        writePos.deallocate()
        targetStateBits.deinitialize(count: 1)
        targetStateBits.deallocate()
    }

    // MARK: - Public API

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    // BlackHole ships as 2ch, 16ch and 64ch, and more than one can be installed at
    // once. Match the family rather than a single product name so the app works on
    // whichever variant a user already has, and prefer the narrowest one: every extra
    // channel is captured and discarded, since the delay path itself is stereo.
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

    func refreshOutputs() {
        let all = enumerateOutputDevices()
        // Exclude every BlackHole variant, not just the one being captured from, and
        // any aggregate (e.g. a Multi-Output Device from an OBS-style setup) that has
        // one as a member. Selecting either as the "real" output would route the delay
        // straight back into the capture device — audible as complete silence.
        availableOutputs = all.filter { !blackHoleUIDs.contains($0.uid) && !wrapsBlackHole($0.id) }
    }

    // Aggregate and Multi-Output devices list their members under this property;
    // the size query fails for ordinary devices.
    private func wrapsBlackHole(_ id: AudioDeviceID) -> Bool {
        guard !blackHoleUIDs.isEmpty else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let st = withUnsafeMutablePointer(to: &unmanaged) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { raw in
                AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw)
            }
        }
        guard st == noErr, let cfList = unmanaged?.takeRetainedValue(),
              let subDeviceUIDs = cfList as NSArray as? [String] else { return false }
        return subDeviceUIDs.contains { blackHoleUIDs.contains($0) }
    }

    private func enumerateLoopbackCandidates() -> [(uid: String, name: String, channels: Int)] {
        enumerateOutputDevices().compactMap { device in
            guard device.name.hasPrefix("BlackHole") else { return nil }
            // A capture source has to expose input streams too; an output-only device
            // with a similar name cannot loop system audio back to us.
            guard hasInputStreams(deviceID: device.id) else { return nil }
            return (device.uid, device.name, channelCount(of: device.id, scope: kAudioObjectPropertyScopeInput))
        }
    }

    func setDelayEnabled(_ enabled: Bool, outputUID: String?) {
        if enabled {
            enableDelay(outputUID: outputUID)
        } else {
            disableDelay(outputUID: outputUID)
        }
    }

    func applyOutputSelection(outputUID: String?) {
        if isDelayEnabled {
            enableDelay(outputUID: outputUID)
        } else {
            disableDelay(outputUID: outputUID)
        }
    }

    func handleSystemOutputChange(outputUID: String?) {
        refreshOutputs()
        refreshSystemOutput()

        if isSystemOutputBlackHole {
            // Preserve compatibility with changing the route in System Settings: choosing
            // BlackHole manually means "On" and starts the saved processing path.
            if !isDelayEnabled || !isRunning {
                enableDelay(outputUID: outputUID)
            }
        } else if isDelayEnabled {
            // A manual switch to a physical output is an intentional direct bypass.
            isDelayEnabled = false
            persistDelayEnabled(false)
            teardown()
            refreshSystemOutput()

            if let id = defaultOutputDeviceID(), let uid = uidForDevice(id),
               availableOutputs.contains(where: { $0.id == id }) {
                UserDefaults.standard.set(uid, forKey: "outputDeviceUID")
            }
        }
    }

    func prepareForTermination(outputUID: String?) {
        refreshOutputs()
        refreshSystemOutput()
        // Only reroute when quitting would otherwise leave the system playing into
        // BlackHole. With the delay off the current route is already the user's
        // choice, and overriding it with a saved device would hijack whatever they
        // switched to since.
        let mustRestore = isDelayEnabled || isSystemOutputBlackHole
        let output = chosenOutput(outputUID: outputUID)
        teardown()

        if mustRestore, let output {
            try? setDefaultOutputDevice(output.id)
        }
        refreshSystemOutput()
    }

    private func enableDelay(outputUID: String?) {
        refreshOutputs()
        guard !blackHoleUID.isEmpty,
              let blackHoleID = deviceID(forUID: blackHoleUID) else {
            isDelayEnabled = false
            persistDelayEnabled(false)
            state = .blackHoleMissing
            return
        }
        guard let output = chosenOutput(outputUID: outputUID) else {
            isDelayEnabled = false
            persistDelayEnabled(false)
            state = .error("No real output devices available")
            return
        }

        // Reading from BlackHole is microphone input as far as TCC is concerned. Resolve
        // permission before touching the route: switching first would silence the user's
        // audio while the consent prompt is on screen, and a denied permission would
        // otherwise run the whole chain and deliver silence under a green status light.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.enableDelay(outputUID: outputUID)
                    } else {
                        self.handleMicrophoneDenied(outputUID: outputUID)
                    }
                }
            }
            return
        default:
            handleMicrophoneDenied(outputUID: outputUID)
            return
        }

        isDelayEnabled = true
        persistDelayEnabled(true)

        do {
            try setDefaultOutputDevice(blackHoleID)
            refreshSystemOutput()
            guard isSystemOutputBlackHole else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(kAudioHardwareUnspecifiedError),
                    userInfo: [NSLocalizedDescriptionKey: "macOS did not switch to BlackHole"]
                )
            }
        } catch {
            fallBackToDirectOutput(output, failure: "Enable delay: \(error.localizedDescription)")
            return
        }

        guard start(outputUID: output.uid) else {
            let failure: String
            if case .error(let message) = state {
                failure = message
            } else {
                failure = "Could not start audio processing"
            }
            fallBackToDirectOutput(output, failure: failure)
            return
        }
    }

    private func disableDelay(outputUID: String?) {
        refreshOutputs()
        let output = chosenOutput(outputUID: outputUID)
        isDelayEnabled = false
        persistDelayEnabled(false)
        teardown()

        guard let output else {
            state = .error("No real output devices available")
            refreshSystemOutput()
            return
        }

        do {
            try setDefaultOutputDevice(output.id)
            refreshSystemOutput()
        } catch {
            state = .error("Disable delay: \(error.localizedDescription)")
            refreshSystemOutput()
        }
    }

    private func fallBackToDirectOutput(_ output: OutputDeviceInfo, failure: String) {
        isDelayEnabled = false
        persistDelayEnabled(false)
        teardown()
        try? setDefaultOutputDevice(output.id)
        refreshSystemOutput()
        state = .error(failure)
    }

    static let microphoneDeniedMessage =
        "Microphone access is off. Enable AudioDelay under System Settings → Privacy & Security → Microphone, then turn the delay on again."

    private func handleMicrophoneDenied(outputUID: String?) {
        isDelayEnabled = false
        persistDelayEnabled(false)
        state = .error(Self.microphoneDeniedMessage)
        refreshSystemOutput()
        // If the route already points at BlackHole — a previous session's state
        // restored at launch — leaving it there means silence. Return to a real
        // output so denying the prompt never mutes the Mac.
        if isSystemOutputBlackHole, let output = chosenOutput(outputUID: outputUID) {
            try? setDefaultOutputDevice(output.id)
            refreshSystemOutput()
        }
    }

    private func persistDelayEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "delayEnabled")
    }

    private func chosenOutput(outputUID: String?) -> OutputDeviceInfo? {
        if let outputUID, !outputUID.isEmpty,
           let chosen = availableOutputs.first(where: { $0.uid == outputUID }) {
            return chosen
        }
        if let configuredOutputDeviceID,
           let configured = availableOutputs.first(where: { $0.id == configuredOutputDeviceID }) {
            return configured
        }
        if let defaultID = defaultOutputDeviceID(),
           let current = availableOutputs.first(where: { $0.id == defaultID }) {
            return current
        }
        return availableOutputs.first
    }

    @discardableResult
    func start(outputUID: String?) -> Bool {
        teardown()

        guard !blackHoleUID.isEmpty else {
            state = .blackHoleMissing
            return false
        }
        guard let blackHoleID = deviceID(forUID: blackHoleUID) else {
            state = .error("BlackHole device disappeared")
            return false
        }

        let chosen = chosenOutput(outputUID: outputUID)
        guard let output = chosen else {
            state = .error("No real output devices available")
            return false
        }

        // System audio arrives from BlackHole at the ring's 48 kHz rate. Running a
        // physical output at 192 kHz only quarters its callback deadline and adds an
        // unnecessary realtime converter, so normalize it while this engine owns it.
        configuredOutputDeviceID = output.id
        originalOutputSampleRate = nominalSampleRate(of: output.id)
        originalOutputBufferFrames = bufferFrameSize(of: output.id)
        _ = setNominalSampleRateIfSupported(sampleRate, on: output.id)

        // The capture connection cannot resample: AVAudioSinkNode consumes the hardware
        // format as-is, and AVAudioEngine raises an uncatchable NSException when the
        // connection format disagrees with the device. Every BlackHole variant supports
        // 48 kHz, so run it there — and fail cleanly rather than crash if that write
        // ever stops taking.
        guard ensureNominalSampleRate(sampleRate, on: blackHoleID) else {
            let actual = Int(nominalSampleRate(of: blackHoleID) ?? 0)
            state = .error("\(blackHoleName) is at \(actual) Hz and could not be set to 48000 Hz")
            return false
        }

        // Never force every device to the same tiny frame count: frame duration, not
        // frame count, determines the deadline. The old 256-frame setting gave the
        // 192 kHz Scarlett only 1.33 ms and Core Audio regularly skipped its cycles.
        let captureIOFrames = ensureStableBufferDuration(on: blackHoleID)
        let outputIOFrames = ensureStableBufferDuration(on: output.id)
        configuredOutputBufferFrames = outputIOFrames
        let captureRate = nominalSampleRate(of: blackHoleID) ?? sampleRate
        let outputRate = nominalSampleRate(of: output.id) ?? sampleRate
        minRingFrames = min(
            ringCapacity / 4,
            AudioBufferSizing.minimumRingFrames(
                ringSampleRate: sampleRate,
                captureBufferFrames: captureIOFrames,
                captureSampleRate: captureRate,
                outputBufferFrames: outputIOFrames,
                outputSampleRate: outputRate
            )
        )

        // Establish a safe target before either realtime callback can run. It is
        // recomputed after start once presentation latency becomes available.
        recomputeTargetFrames()

        // A rebuild triggered from inside this method must not be mistaken for macOS
        // reconfiguring the devices underneath us.
        isRestarting = true
        defer { isRestarting = false }

        var lastFailure = "Could not start audio processing"
        var started = false
        for attempt in 1...engineStartAttempts {
            switch buildAndStartEngines(blackHoleID: blackHoleID, outputID: output.id) {
            case .success(let inputFormat, let outputFormat):
                outputDiagnostic = "Output: \(Int(outputFormat.sampleRate)) Hz, \(outputFormat.channelCount) ch"
                inputDiagnostic = "Input: \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch"
                outputDiagnostic += " · I/O: \(captureIOFrames)/\(outputIOFrames)f"
                started = true
            case .failure(let message):
                lastFailure = message
                // Only the engines are torn down between attempts; a full teardown would
                // undo the sample rate and buffer sizing established above. The ring is
                // cleared so nothing captured during a misrouted attempt — e.g. from the
                // default microphone — can be played out once a later attempt succeeds.
                stopEngines()
                resetRingState()
                if attempt < engineStartAttempts { usleep(60_000) }
            }
            if started { break }
        }

        guard started else {
            teardown()
            state = .error(lastFailure)
            return false
        }

        // presentationLatency is only valid once the engine is running. Sum input + output
        // sides — that's the chain latency we can observe (excludes BlackHole's internal
        // buffer and the DAC, but those are unmeasurable from this layer).
        let inLat = captureEngine.inputNode.presentationLatency
        let outLat = playbackEngine.outputNode.presentationLatency
        chainLatencyFrames = max(0, Int((inLat + outLat) * sampleRate))
        baselineMs = Int((Double(chainLatencyFrames) / sampleRate) * 1000.0)
        outputDiagnostic += " · Baseline: \(baselineMs) ms"

        // Re-derive ring target now that we know chain latency.
        recomputeTargetFrames()

        state = .running(delayMs: currentPerceivedMs())
        refreshSystemOutput()
        return true
    }

    private enum EngineStartOutcome {
        case success(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat)
        case failure(String)
    }

    private func buildAndStartEngines(blackHoleID: AudioDeviceID,
                                      outputID: AudioDeviceID) -> EngineStartOutcome {
        // The engines are deliberately reused rather than rebuilt per attempt. Releasing
        // an AVAudioEngine whose I/O unit still has Core Audio property listeners
        // registered crashes inside AVAudioIOUnit::IOUnitPropertyListener, and device
        // changes are exactly when those listeners fire.

        // Constructing an AUHAL can itself time out when an active device has an
        // impossibly short deadline, so the devices are stabilized before this runs.
        guard let inputAU = captureEngine.inputNode.audioUnit,
              let outputAU = playbackEngine.outputNode.audioUnit else {
            return .failure("Engine has no input/output unit")
        }
        do {
            try pinDevice(blackHoleID, on: inputAU, role: "capture", blackHoleID: blackHoleID)
            try pinDevice(outputID, on: outputAU, role: "output", blackHoleID: blackHoleID)
        } catch {
            return .failure("Pin device: \(error.localizedDescription)")
        }

        // Read back what the AUHAL actually negotiated after pinning. Some machines run
        // BlackHole at a different rate until the write above settles, and the 16/64ch
        // variants expose more than two channels; connecting with anything other than
        // this exact format is an uncatchable NSException, not an error return.
        let captureFormat = captureEngine.inputNode.inputFormat(forBus: 0)
        guard abs(captureFormat.sampleRate - sampleRate) < 0.5 else {
            return .failure("\(blackHoleName) is at \(Int(captureFormat.sampleRate)) Hz, expected 48000 Hz")
        }
        guard captureFormat.channelCount >= 1 else {
            return .failure("\(blackHoleName) reports no input channels")
        }

        let sink = AVAudioSinkNode { [unowned self] _, frames, abl in
            let listPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            self.writeFromInput(frames: Int(frames), bufList: listPtr)
            return noErr
        }

        // AVAudioSourceNode converts sample rate but not channel count (its header:
        // "only Linear PCM conversions are supported (sample rate, bit depth,
        // interleaving)"), so the render block must speak the device's channel count.
        // A mono speakerphone or a multichannel HDMI receiver would otherwise raise
        // the same uncatchable format exception as the capture side.
        let outputFormat = playbackEngine.outputNode.inputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount >= 1,
              let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                               channels: outputFormat.channelCount) else {
            return .failure("\(nameForDevice(outputID) ?? "Output device") reports no usable format")
        }
        let source = AVAudioSourceNode(format: sourceFormat) { [unowned self] silence, _, frames, abl in
            let listPtr = UnsafeMutableAudioBufferListPointer(abl)
            self.readToOutput(silence: silence, frames: Int(frames), bufList: listPtr)
            return noErr
        }

        captureEngine.attach(sink)
        // Hardware format, verified at 48 kHz above. writeFromInput takes the first two
        // channels, so the wider BlackHole variants work without a converter.
        captureEngine.connect(captureEngine.inputNode, to: sink, format: captureFormat)

        playbackEngine.attach(source)
        // Connect source directly to outputNode (skip mainMixerNode). mainMixer's
        // auto-connect to outputNode is negotiated against outputNode's format AT THE
        // MOMENT mainMixer is first referenced — which may have been BEFORE we pinned
        // outputNode to the user's chosen device. Direct node-to-node connect resolves
        // format at connection time using the destination's CURRENT inputFormat.
        playbackEngine.connect(source, to: playbackEngine.outputNode, format: outputFormat)

        sinkNode = sink
        sourceNode = source

        do {
            captureEngine.prepare()
            try captureEngine.start()
        } catch {
            return .failure("Capture start: \(error.localizedDescription)")
        }
        do {
            playbackEngine.prepare()
            try playbackEngine.start()
        } catch {
            return .failure("Playback start: \(error.localizedDescription)")
        }

        // Starting an engine is the moment a unit can be pulled back to the system
        // default, and that failure is inaudible from inside the app: both engines run
        // and the ring buffer fills normally while nothing reaches the speakers. Confirm
        // the routing actually held instead of trusting the earlier writes.
        guard boundDevice(of: outputAU) == outputID else {
            return .failure("Playback moved to \(boundDeviceName(of: outputAU))")
        }
        guard boundDevice(of: inputAU) == blackHoleID else {
            return .failure("Capture moved to \(boundDeviceName(of: inputAU))")
        }

        observeConfigurationChanges()
        return .success(inputFormat: captureEngine.inputNode.outputFormat(forBus: 0),
                        outputFormat: outputFormat)
    }

    // AVAudioEngine posts this when Core Audio reconfigures underneath it — a device
    // unplugged, another app changing a sample rate, or the I/O unit being re-bound. The
    // engine is already stopped by then, so rebuild rather than stay silently connected
    // to nothing.
    private func observeConfigurationChanges() {
        removeConfigurationObservers()
        for engine in [captureEngine, playbackEngine] {
            let token = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleRecovery()
            }
            configurationObservers.append(token)
        }
    }

    private func removeConfigurationObservers() {
        for token in configurationObservers {
            NotificationCenter.default.removeObserver(token)
        }
        configurationObservers.removeAll()
    }

    private func scheduleRecovery() {
        guard isDelayEnabled, !isRestarting else { return }
        recoveryWork?.cancel()
        // Device changes arrive in bursts; one rebuild after they settle is enough.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isDelayEnabled, !self.isRestarting else { return }
            let uid = UserDefaults.standard.string(forKey: "outputDeviceUID") ?? ""
            self.enableDelay(outputUID: uid.isEmpty ? nil : uid)
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func stopEngines() {
        removeConfigurationObservers()
        if captureEngine.isRunning { captureEngine.stop() }
        if playbackEngine.isRunning { playbackEngine.stop() }
        if let s = sinkNode { captureEngine.detach(s); sinkNode = nil }
        if let s = sourceNode { playbackEngine.detach(s); sourceNode = nil }
    }

    // Only safe with both engines stopped: the render callbacks read this state.
    private func resetRingState() {
        let oldWritePos = atomicLoad(writePos)
        _ = OSAtomicAdd64Barrier(-oldWritePos, writePos)
        readPos = 0
        crossfadeRemaining = 0
        lastSeenTargetRevision = .max
        driftCompensator.reset()
    }

    func teardown() {
        recoveryWork?.cancel()
        stopEngines()
        resetRingState()
        chainLatencyFrames = 0
        baselineMs = 0
        restoreOutputConfiguration()
        inputDiagnostic = ""
        outputDiagnostic = ""
        state = .idle
    }

    func refreshSystemOutput() {
        guard let id = defaultOutputDeviceID() else {
            isSystemOutputBlackHole = false
            systemOutputName = "unknown"
            return
        }
        let uid = uidForDevice(id) ?? ""
        // Any installed variant counts: a user who picked "BlackHole 16ch" in Sound
        // Settings is routed into a loopback, not into a physical output.
        isSystemOutputBlackHole = !uid.isEmpty
            && (uid == blackHoleUID || blackHoleUIDs.contains(uid))
        systemOutputName = nameForDevice(id) ?? "unknown"
    }

    func setDelaySeconds(_ seconds: Double) {
        let clamped = max(0.0, min(5.0, seconds))
        debounceWork?.cancel()
        // The debounce only exists to keep slider drags from repositioning the live
        // reader on every pixel. With no engine running, apply immediately so the
        // restored value is in place before a subsequent start() computes its target.
        guard isRunning else {
            userTargetSeconds = clamped
            recomputeTargetFrames()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.userTargetSeconds = clamped
            self.recomputeTargetFrames()
            if case .running = self.state {
                self.state = .running(delayMs: self.currentPerceivedMs())
            }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    // Recompute ring target = max(floor, userIntent − chainLatency). Subtracting the
    // chain means the user's slider value approximates the *perceived* total delay.
    private func recomputeTargetFrames() {
        let userFrames = Int(userTargetSeconds * sampleRate)
        let effective = max(minRingFrames, userFrames - chainLatencyFrames)
        publishTargetFrames(effective)
    }

    private func currentPerceivedMs() -> Int {
        let frames = loadTargetState().targetFrames
        return Int((Double(frames + chainLatencyFrames) / sampleRate) * 1000.0)
    }

    @inline(__always)
    private func atomicLoad(_ value: UnsafeMutablePointer<Int64>) -> Int64 {
        OSAtomicAdd64Barrier(0, value)
    }

    private func loadTargetState() -> (targetFrames: Int, targetRevision: UInt32) {
        let raw = UInt64(bitPattern: atomicLoad(targetStateBits))
        return (
            targetFrames: Int(UInt32(truncatingIfNeeded: raw)),
            targetRevision: UInt32(truncatingIfNeeded: raw >> 32)
        )
    }

    private func publishTargetFrames(_ frames: Int) {
        let target = UInt64(UInt32(clamping: frames))

        while true {
            let oldBits = atomicLoad(targetStateBits)
            let oldRaw = UInt64(bitPattern: oldBits)
            let revision = UInt32(truncatingIfNeeded: oldRaw >> 32) &+ 1
            let newRaw = (UInt64(revision) << 32) | target
            let newBits = Int64(bitPattern: newRaw)

            if OSAtomicCompareAndSwap64Barrier(oldBits, newBits, targetStateBits) {
                return
            }
        }
    }

    // MARK: - Audio thread: sink (ring writer)

    private func writeFromInput(frames: Int, bufList: UnsafeMutableAudioBufferListPointer) {
        guard frames > 0, frames <= ringCapacity, bufList.count >= 1 else { return }
        let first = bufList[0]
        let nChan = Int(first.mNumberChannels)
        let w = Int(atomicLoad(writePos))

        if bufList.count == 1 {
            // Interleaved (or mono).
            guard nChan > 0,
                  let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<frames {
                let l = data[i * nChan]
                let r = nChan >= 2 ? data[i * nChan + 1] : l
                ringL[(w + i) & mask] = l
                ringR[(w + i) & mask] = r
            }
        } else {
            // Non-interleaved, ≥2 buffers.
            guard let l = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            let rPtr = bufList[1].mData?.assumingMemoryBound(to: Float.self) ?? l
            copyToRing(l, destination: ringL, writePosition: w, frameCount: frames)
            copyToRing(rPtr, destination: ringR, writePosition: w, frameCount: frames)
        }

        // Publish only after both channels are completely written.
        _ = OSAtomicAdd64Barrier(Int64(frames), writePos)
    }

    @inline(__always)
    private func copyToRing(_ source: UnsafePointer<Float>,
                            destination: UnsafeMutablePointer<Float>,
                            writePosition: Int,
                            frameCount: Int) {
        let index = writePosition & mask
        let firstCount = min(frameCount, ringCapacity - index)
        destination.advanced(by: index).update(from: source, count: firstCount)

        let remaining = frameCount - firstCount
        if remaining > 0 {
            destination.update(from: source.advanced(by: firstCount), count: remaining)
        }
    }

    // MARK: - Audio thread: source (ring reader with crossfade-on-change)

    private func readToOutput(silence: UnsafeMutablePointer<ObjCBool>,
                              frames: Int,
                              bufList: UnsafeMutableAudioBufferListPointer) {
        guard frames > 0, bufList.count >= 1,
              let leftData = bufList[0].mData else {
            silence.pointee = true
            return
        }
        let outL = leftData.assumingMemoryBound(to: Float.self)
        // Mono hardware gets an L+R mixdown; anything wider than stereo gets the
        // stereo pair in its first two channels and silence in the rest.
        let outR = bufList.count >= 2 ? bufList[1].mData?.assumingMemoryBound(to: Float.self) : nil
        if bufList.count > 2 {
            for extra in 2..<bufList.count {
                if let data = bufList[extra].mData {
                    memset(data, 0, frames * MemoryLayout<Float>.size)
                }
            }
        }

        let targetState = loadTargetState()
        let target = targetState.targetFrames
        let w = Double(atomicLoad(writePos))
        let buffered = w - readPos
        let targetChanged = targetState.targetRevision != lastSeenTargetRevision
        let driftedTooFar = !targetChanged && driftCompensator.requiresResynchronization(
            bufferedFrames: buffered,
            targetFrames: Double(target),
            capacityFrames: Double(ringCapacity - 1)
        )

        if targetChanged || driftedTooFar {
            let oldReadPos = readPos
            readPos = w - Double(target)
            if RingReadSafety.hasCompleteBlock(
                readPosition: oldReadPos,
                writePosition: w,
                readStep: driftCompensator.readStep,
                frameCount: frames,
                capacityFrames: Double(ringCapacity - 1)
            ), RingReadSafety.hasCompleteBlock(
                readPosition: readPos,
                writePosition: w,
                readStep: 1.0,
                frameCount: frames,
                capacityFrames: Double(ringCapacity - 1)
            ) {
                crossfadeFromReadPos = oldReadPos
                crossfadeRemaining = crossfadeFrames
            } else {
                crossfadeRemaining = 0
            }
            lastSeenTargetRevision = targetState.targetRevision
            driftCompensator.reset()
        }

        // While priming, follow the advancing write cursor. Once this candidate is
        // non-negative the same callback can begin rendering immediately.
        if readPos < 0 {
            readPos = w - Double(target)
        }

        // Startup and a late capture callback must never produce a partial audio block.
        // Partial blocks made the old reader alternate audio and zeroes indefinitely,
        // which is the characteristic "robotic" failure. Vend one complete silent block
        // and hold the read cursor so capture can catch up without losing audio.
        let cap = Double(ringCapacity - 1)
        guard RingReadSafety.hasCompleteBlock(
            readPosition: readPos,
            writePosition: w,
            readStep: driftCompensator.readStep,
            frameCount: frames,
            capacityFrames: cap
        ) else {
            zeroOutput(outL, outR, frameCount: frames)
            silence.pointee = true
            crossfadeRemaining = 0
            return
        }

        let readStep = driftCompensator.update(
            bufferedFrames: w - readPos,
            targetFrames: Double(target),
            renderedFrames: frames
        )

        guard RingReadSafety.hasCompleteBlock(
            readPosition: readPos,
            writePosition: w,
            readStep: readStep,
            frameCount: frames,
            capacityFrames: cap
        ) else {
            zeroOutput(outL, outR, frameCount: frames)
            silence.pointee = true
            crossfadeRemaining = 0
            return
        }

        for i in 0..<frames {
            let oldUnderrun = crossfadeFromReadPos < 0 || crossfadeFromReadPos >= w || (w - crossfadeFromReadPos) > cap

            let l: Float
            let r: Float
            if crossfadeRemaining > 0 && !oldUnderrun {
                let t = Float(crossfadeRemaining) / Float(crossfadeFrames)
                let oldL = sampleAt(ringL, pos: crossfadeFromReadPos, writeLimit: w)
                let oldR = sampleAt(ringR, pos: crossfadeFromReadPos, writeLimit: w)
                let newL = sampleAt(ringL, pos: readPos, writeLimit: w)
                let newR = sampleAt(ringR, pos: readPos, writeLimit: w)
                l = oldL * t + newL * (1 - t)
                r = oldR * t + newR * (1 - t)
                crossfadeFromReadPos += readStep
                crossfadeRemaining -= 1
            } else {
                l = sampleAt(ringL, pos: readPos, writeLimit: w)
                r = sampleAt(ringR, pos: readPos, writeLimit: w)
                if crossfadeRemaining > 0 { crossfadeRemaining -= 1 }
            }
            if let outR {
                outL[i] = l
                outR[i] = r
            } else {
                outL[i] = (l + r) * 0.5
            }
            readPos += readStep
        }
        silence.pointee = false
    }

    @inline(__always)
    private func zeroOutput(_ left: UnsafeMutablePointer<Float>,
                            _ right: UnsafeMutablePointer<Float>?,
                            frameCount: Int) {
        let byteCount = frameCount * MemoryLayout<Float>.size
        memset(left, 0, byteCount)
        if let right {
            memset(right, 0, byteCount)
        }
    }

    @inline(__always)
    private func sampleAt(_ ring: UnsafeMutablePointer<Float>,
                          pos: Double,
                          writeLimit: Double) -> Float {
        let floorPos = Int(pos.rounded(.down))
        let frac = Float(pos - Double(floorPos))
        let s0 = ring[floorPos & mask]
        // Fractional drift correction can put the reader between the newest sample
        // and the not-yet-written next sample. Hold the newest valid value there.
        let s1 = Double(floorPos + 1) < writeLimit
            ? ring[(floorPos + 1) & mask]
            : s0
        return s0 * (1 - frac) + s1 * frac
    }

    // MARK: - Core Audio device helpers

    private func enumerateOutputDevices() -> [OutputDeviceInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        var result: [OutputDeviceInfo] = []
        for id in ids {
            guard hasOutputStreams(deviceID: id),
                  let uid = uidForDevice(id),
                  let name = nameForDevice(id) else { continue }
            result.append(OutputDeviceInfo(id: id, uid: uid, name: name))
        }
        return result
    }

    private func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        hasStreams(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)
    }

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        hasStreams(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
    }

    private func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private func channelCount(of deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func uidForDevice(_ id: AudioDeviceID) -> String? {
        readCFString(deviceID: id, selector: kAudioDevicePropertyDeviceUID)
    }

    private func nameForDevice(_ id: AudioDeviceID) -> String? {
        readCFString(deviceID: id, selector: kAudioObjectPropertyName)
    }

    private func readCFString(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &unmanaged) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { rawPtr in
                AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, rawPtr)
            }
        }
        guard st == noErr, let cfStr = unmanaged?.takeRetainedValue() else { return nil }
        return cfStr as String
    }

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids where uidForDevice(id) == uid { return id }
        return nil
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    private func setDefaultOutputDevice(_ deviceID: AudioDeviceID) throws {
        for selector in [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice
        ] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var requested = deviceID
            let status = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &requested
            )
            if status != noErr {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(status),
                    userInfo: [
                        NSLocalizedDescriptionKey: "Set default output failed (\(status))"
                    ]
                )
            }
        }

        guard defaultOutputDeviceID() == deviceID else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(kAudioHardwareUnspecifiedError),
                userInfo: [NSLocalizedDescriptionKey: "Default output did not change"]
            )
        }
    }

    private func bufferFrameSize(of deviceID: AudioDeviceID) -> UInt32? {
        var frames: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &frames)
        return status == noErr ? frames : nil
    }

    private func bufferFrameSizeRange(of deviceID: AudioDeviceID) -> AudioValueRange? {
        var range = AudioValueRange()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &range)
        return status == noErr ? range : nil
    }

    private func nominalSampleRate(of deviceID: AudioDeviceID) -> Double? {
        var rate: Float64 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate)
        return status == noErr && rate.isFinite && rate > 0 ? rate : nil
    }

    private func availableNominalSampleRateRanges(of deviceID: AudioDeviceID) -> [AudioValueRange] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioValueRange>.size else { return [] }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &ranges) == noErr else {
            return []
        }
        return ranges
    }

    @discardableResult
    private func setNominalSampleRateIfSupported(_ rate: Double,
                                                  on deviceID: AudioDeviceID) -> Bool {
        guard rate.isFinite, rate > 0 else { return false }
        if let current = nominalSampleRate(of: deviceID), abs(current - rate) < 0.5 {
            return true
        }

        let supported = availableNominalSampleRateRanges(of: deviceID).contains {
            rate >= $0.mMinimum && rate <= $0.mMaximum
        }
        guard supported else { return false }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var requested = Float64(rate)
        let status = AudioObjectSetPropertyData(
            deviceID,
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &requested
        )
        guard status == noErr else { return false }
        return nominalSampleRate(of: deviceID).map { abs($0 - rate) < 0.5 } ?? false
    }

    // Nominal-rate writes are applied asynchronously by some drivers: the setter can
    // return noErr while a readback still reports the old rate for a moment.
    private func ensureNominalSampleRate(_ rate: Double, on deviceID: AudioDeviceID) -> Bool {
        let attempts = 20
        for attempt in 0..<attempts {
            if setNominalSampleRateIfSupported(rate, on: deviceID) { return true }
            if attempt < attempts - 1 { usleep(50_000) }
        }
        return false
    }

    private func restoreOutputConfiguration() {
        defer {
            configuredOutputDeviceID = nil
            originalOutputSampleRate = nil
            originalOutputBufferFrames = nil
            configuredOutputBufferFrames = nil
        }

        guard let deviceID = configuredOutputDeviceID else { return }

        // Restore only if the rate still equals the value this app selected; an
        // external change made while running belongs to the user or another app.
        if let originalRate = originalOutputSampleRate,
           abs(originalRate - sampleRate) >= 0.5,
           let currentRate = nominalSampleRate(of: deviceID),
           abs(currentRate - sampleRate) < 0.5 {
            _ = setNominalSampleRateIfSupported(originalRate, on: deviceID)
        }

        // Direct mode should also get the hardware buffer size it had before delay
        // processing. Do not overwrite a value another app changed while we were on.
        if let originalFrames = originalOutputBufferFrames,
           let configuredFrames = configuredOutputBufferFrames,
           let currentFrames = bufferFrameSize(of: deviceID),
           currentFrames == configuredFrames,
           currentFrames != originalFrames {
            _ = setBufferFrameSize(originalFrames, on: deviceID)
        }
    }

    @discardableResult
    private func setBufferFrameSize(_ frames: UInt32, on deviceID: AudioDeviceID) -> Bool {
        var requested = frames
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            deviceID,
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &requested
        )
        return status == noErr && bufferFrameSize(of: deviceID) == frames
    }

    @discardableResult
    private func ensureStableBufferDuration(on deviceID: AudioDeviceID) -> UInt32 {
        let current = bufferFrameSize(of: deviceID) ?? 1_024
        guard let rate = nominalSampleRate(of: deviceID),
              let range = bufferFrameSizeRange(of: deviceID) else { return current }

        let minimum = UInt32(clamping: Int(ceil(range.mMinimum)))
        let maximum = UInt32(clamping: Int(floor(range.mMaximum)))
        let preferred = AudioBufferSizing.preferredDeviceFrames(
            sampleRate: rate,
            minimum: minimum,
            maximum: maximum
        )

        // Preserve an already safer/larger user setting. This only raises dangerously
        // short buffers left by this app or another client.
        guard current < preferred else { return current }

        _ = setBufferFrameSize(preferred, on: deviceID)
        return bufferFrameSize(of: deviceID) ?? current
    }

    private func boundDevice(of au: AudioUnit) -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioUnitGetProperty(au,
                                      kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global,
                                      0,
                                      &deviceID,
                                      &size)
        return st == noErr ? deviceID : nil
    }

    private func boundDeviceName(of au: AudioUnit) -> String {
        guard let id = boundDevice(of: au) else { return "an unknown device" }
        return nameForDevice(id) ?? "an unknown device"
    }

    @discardableResult
    private func writeCurrentDevice(_ id: AudioDeviceID, on au: AudioUnit) -> OSStatus {
        var deviceID = id
        return AudioUnitSetProperty(au,
                                    kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global,
                                    0,
                                    &deviceID,
                                    UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    // Any device other than the one being pinned, used to force a real property change.
    private func decoyDevice(excluding target: AudioDeviceID,
                             blackHoleID: AudioDeviceID) -> AudioDeviceID? {
        if let other = availableOutputs.first(where: { $0.id != target })?.id { return other }
        return target == blackHoleID ? nil : blackHoleID
    }

    // Writing CurrentDevice is not enough on its own. Core Audio drops a write that
    // matches the unit's existing value, and AVAudioEngine then re-binds the unit to the
    // system default while starting — which is how switching the delay off and on again
    // left playback sitting on BlackHole, feeding captured audio straight back into the
    // capture device with nothing reaching the speakers. Route through another device
    // first so the write that matters is a genuine transition, and read the value back
    // rather than trusting a noErr return.
    private func pinDevice(_ id: AudioDeviceID,
                           on au: AudioUnit,
                           role: String,
                           blackHoleID: AudioDeviceID) throws {
        if boundDevice(of: au) == id,
           let decoy = decoyDevice(excluding: id, blackHoleID: blackHoleID) {
            for _ in 0..<pinAttempts {
                writeCurrentDevice(decoy, on: au)
                if boundDevice(of: au) != id { break }
                usleep(40_000)
            }
        }

        var lastStatus: OSStatus = noErr
        for attempt in 0..<pinAttempts {
            lastStatus = writeCurrentDevice(id, on: au)
            if boundDevice(of: au) == id { return }
            if attempt < pinAttempts - 1 { usleep(40_000) }
        }

        throw NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(lastStatus),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "could not bind \(role) to \(nameForDevice(id) ?? "device \(id)") (\(lastStatus))"
            ]
        )
    }
}
