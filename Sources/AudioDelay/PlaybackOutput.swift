import AVFoundation
import CoreAudio
import Darwin
import Foundation

enum OutputPhase: Equatable {
    case off                        // toggle off in the app
    case idle                       // enabled, but the delay itself is off or waiting
    case starting
    case running(perceivedMs: Int)
    case error(String)
}

struct OutputStatus: Identifiable, Equatable {
    let uid: String
    var id: String { uid }
    var name: String
    var isBluetooth: Bool
    var phase: OutputPhase
    var minimumPerceivedMs: Int
    var diagnostic: String
}

struct PlaybackStartContext {
    let ring: AudioRing
    let decoyDeviceID: AudioDeviceID?
    let captureIOFrames: UInt32
    let captureSampleRate: Double
    let captureLatencyFrames: Int
    let pinAttempts: Int
    let startAttempts: Int
    let bitExactWired: Bool
}

enum PlaybackOutputError: LocalizedError {
    case noUnit
    case pin(String)
    case noUsableFormat(String)
    case start(String)
    case movedTo(String)

    var errorDescription: String? {
        switch self {
        case .noUnit: return "Engine has no output unit"
        case .pin(let s): return "Pin device: \(s)"
        case .noUsableFormat(let name): return "\(name) reports no usable format"
        case .start(let s): return "Playback start: \(s)"
        case .movedTo(let name): return "Playback moved to \(name)"
        }
    }
}

// One playback engine per output device. Instances are cached by device UID for the
// app's lifetime and never deallocated: releasing an AVAudioEngine whose I/O unit
// still has Core Audio property listeners registered crashes inside
// AVAudioIOUnit::IOUnitPropertyListener, and device removal is exactly when those
// listeners fire. A stopped instance costs one idle, uninitialized AUHAL.
final class PlaybackOutput {
    let uid: String
    private(set) var name: String
    private(set) var isBluetooth: Bool
    let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var configurationObserver: NSObjectProtocol?
    var onConfigurationChange: (() -> Void)?

    // Reader state: render thread only while running, main thread only while stopped.
    private var readPos: Double = 0
    private var crossfadeFromReadPos: Double = 0
    private var crossfadeRemaining: Int = 0
    private var lastSeenTargetRevision: UInt32 = .max
    private var driftCompensator = RingDriftCompensator(sampleRate: 48_000)
    private var gainRamp = GainRamp(initial: 1, sampleRate: 48_000)
    private var currentReadStep: Double = 1.0
    private var bitExact = false
    private var bitExactResyncFrames: Double = 0

    // Main → render, lock-free. targetStateBits packs revision (high 32) and frame
    // count (low 32) so a callback sees a coherent snapshot; gainBits holds a Float
    // bit pattern. Gain is deliberately not folded into the target word: bumping the
    // revision would re-target and crossfade on every volume tick.
    private let targetStateBits: UnsafeMutablePointer<Int64>
    private let gainBits: UnsafeMutablePointer<Int32>
    // Debug counters: [0] rendered blocks, [1] silent blocks, [2] buffered frames.
    private let stats: UnsafeMutablePointer<Int64>

    // Main-thread configuration.
    private(set) var userDelaySeconds: Double
    private(set) var volumePercent: Double
    private(set) var minRingFrames: Int = 0
    private(set) var chainLatencyFrames: Int = 0
    private(set) var sampleRate: Double = 48_000
    private var activeRing: AudioRing?

    private var configuredDeviceID: AudioDeviceID?
    private var originalSampleRate: Double?
    private var originalBufferFrames: UInt32?
    private var configuredBufferFrames: UInt32?

    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var diagnostic = ""
    private(set) var lastError: String?
    var rebuildTimestamps: [Date] = []
    var startRetries = 0

    init(uid: String, name: String, isBluetooth: Bool, delaySeconds: Double, volumePercent: Double) {
        self.uid = uid
        self.name = name
        self.isBluetooth = isBluetooth
        self.userDelaySeconds = OutputConfig.clampDelay(delaySeconds)
        self.volumePercent = OutputConfig.clampVolume(volumePercent)
        targetStateBits = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        targetStateBits.initialize(to: 0)
        gainBits = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        gainBits.initialize(to: Int32(bitPattern: Float(1.0).bitPattern))
        stats = UnsafeMutablePointer<Int64>.allocate(capacity: 3)
        stats.initialize(repeating: 0, count: 3)
    }

    struct DebugSnapshot {
        var renderedBlocks: Int64
        var silentBlocks: Int64
        var bufferedFrames: Int64
        var targetFrames: Int
        var chainLatencyFrames: Int
        var minRingFrames: Int
    }

    func debugSnapshot() -> DebugSnapshot {
        DebugSnapshot(
            renderedBlocks: OSAtomicAdd64Barrier(0, stats),
            silentBlocks: OSAtomicAdd64Barrier(0, stats + 1),
            bufferedFrames: OSAtomicAdd64Barrier(0, stats + 2),
            targetFrames: loadTargetState().targetFrames,
            chainLatencyFrames: chainLatencyFrames,
            minRingFrames: minRingFrames
        )
    }

    deinit {
        stop()
        targetStateBits.deinitialize(count: 1)
        targetStateBits.deallocate()
        gainBits.deinitialize(count: 1)
        gainBits.deallocate()
        stats.deinitialize(count: 3)
        stats.deallocate()
    }

    // MARK: - Control (main thread)

    func update(name: String, isBluetooth: Bool) {
        self.name = name
        self.isBluetooth = isBluetooth
    }

    func setDelaySeconds(_ seconds: Double) {
        userDelaySeconds = OutputConfig.clampDelay(seconds)
        recomputeTarget()
    }

    func setVolumePercent(_ percent: Double) {
        volumePercent = OutputConfig.clampVolume(percent)
        publishGain(OutputGain.linearGain(percent: volumePercent))
    }

    func perceivedDelayMs() -> Int {
        OutputTargetMath.perceivedMs(
            targetFrames: loadTargetState().targetFrames,
            chainLatencyFrames: chainLatencyFrames,
            sampleRate: sampleRate
        )
    }

    func minimumPerceivedDelayMs() -> Int {
        guard isRunning else { return 0 }
        return OutputTargetMath.perceivedMs(
            targetFrames: minRingFrames,
            chainLatencyFrames: chainLatencyFrames,
            sampleRate: sampleRate
        )
    }

    func start(device: OutputDeviceInfo, context: PlaybackStartContext) -> Result<Void, PlaybackOutputError> {
        stop()
        isStarting = true
        defer { isStarting = false }
        name = device.name
        isBluetooth = device.isBluetooth
        lastError = nil

        let ring = context.ring
        sampleRate = ring.sampleRate

        // System audio arrives from BlackHole at the ring rate. Running a physical
        // output at another rate only adds a realtime converter, so normalize it while
        // this engine owns it. Devices that cannot (Bluetooth is 44.1 kHz only) keep
        // their rate and AVAudioSourceNode converts.
        configuredDeviceID = device.id
        originalSampleRate = CoreAudioDevices.nominalSampleRate(of: device.id)
        originalBufferFrames = CoreAudioDevices.bufferFrameSize(of: device.id)
        _ = CoreAudioDevices.setNominalSampleRateIfSupported(ring.sampleRate, on: device.id)
        let outputIOFrames = CoreAudioDevices.ensureStableBufferDuration(on: device.id)
        configuredBufferFrames = outputIOFrames
        let outputRate = CoreAudioDevices.nominalSampleRate(of: device.id) ?? ring.sampleRate

        minRingFrames = min(
            ring.capacity / 4,
            AudioBufferSizing.minimumRingFrames(
                ringSampleRate: ring.sampleRate,
                captureBufferFrames: context.captureIOFrames,
                captureSampleRate: context.captureSampleRate,
                outputBufferFrames: outputIOFrames,
                outputSampleRate: outputRate
            )
        )

        bitExact = context.bitExactWired && !device.isBluetooth && abs(outputRate - ring.sampleRate) < 0.5
        bitExactResyncFrames = ring.sampleRate * 0.005
        driftCompensator = RingDriftCompensator(sampleRate: ring.sampleRate)
        let gain = OutputGain.linearGain(percent: volumePercent)
        gainRamp = GainRamp(initial: gain, sampleRate: ring.sampleRate)
        publishGain(gain)
        chainLatencyFrames = context.captureLatencyFrames
        resetReaderState()
        recomputeTarget()
        activeRing = ring

        var lastFailure: PlaybackOutputError = .start("Could not start playback")
        for attempt in 1...max(1, context.startAttempts) {
            switch buildAndStart(device: device, ring: ring, context: context) {
            case .success(let format):
                // presentationLatency is only valid once the engine runs. Some Bluetooth
                // stacks under-report it, so never go below what the device itself
                // advertises through its latency properties.
                let reported = engine.outputNode.presentationLatency
                let reportedFrames = max(0, Int(reported * ring.sampleRate))
                let components = CoreAudioDevices.outputLatencyComponents(of: device.id)
                let componentFrames = OutputTargetMath.framesAtRingRate(
                    Int(components.total), deviceRate: outputRate, ringRate: ring.sampleRate
                )
                let outputLatencyFrames = max(reportedFrames, componentFrames)
                chainLatencyFrames = context.captureLatencyFrames + outputLatencyFrames

                var text = "\(Int(outputRate)) Hz · \(format.channelCount) ch · I/O \(outputIOFrames)f"
                text += " · latency \(Int(Double(outputLatencyFrames) / ring.sampleRate * 1000)) ms"
                if bitExact { text += " · bit-exact" }
                diagnostic = text

                recomputeTarget()
                observeConfigurationChanges()
                isRunning = true
                return .success(())
            case .failure(let error):
                lastFailure = error
                stopEngine()
                resetReaderState()
                if attempt < context.startAttempts { usleep(60_000) }
            }
        }

        lastError = lastFailure.localizedDescription
        activeRing = nil
        restoreDeviceConfiguration()
        return .failure(lastFailure)
    }

    func stop() {
        removeConfigurationObserver()
        stopEngine()
        resetReaderState()
        restoreDeviceConfiguration()
        activeRing = nil
        isRunning = false
        diagnostic = ""
        chainLatencyFrames = 0
    }

    // MARK: - Engine plumbing

    private func buildAndStart(device: OutputDeviceInfo,
                               ring: AudioRing,
                               context: PlaybackStartContext) -> Result<AVAudioFormat, PlaybackOutputError> {
        guard let outputAU = engine.outputNode.audioUnit else { return .failure(.noUnit) }
        do {
            try CoreAudioDevices.pinDevice(device.id, on: outputAU, role: "output",
                                           decoy: context.decoyDeviceID, attempts: context.pinAttempts)
        } catch {
            return .failure(.pin(error.localizedDescription))
        }

        // AVAudioSourceNode converts sample rate but not channel count, so the render
        // block must speak the device's channel count. Connecting with anything other
        // than the device's exact format is an uncatchable NSException, not an error.
        // After pinning, the unit's client side keeps the rate it was created with (the
        // system default's, i.e. BlackHole's) while its device side follows the new
        // device. Feeding a 44.1 kHz Bluetooth speaker at a 48 kHz client rate produced
        // silence, so the connection format takes the device's rate from the node's
        // output side and the channel count from its input side.
        let nodeInput = engine.outputNode.inputFormat(forBus: 0)
        let deviceRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let connectRate = deviceRate > 0 ? deviceRate : nodeInput.sampleRate
        guard connectRate > 0, nodeInput.channelCount >= 1,
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: connectRate,
                                               channels: nodeInput.channelCount),
              let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: ring.sampleRate,
                                               channels: nodeInput.channelCount) else {
            return .failure(.noUsableFormat(device.name))
        }

        let source = AVAudioSourceNode(format: sourceFormat) { [unowned self] silence, _, frames, abl in
            self.render(ring: ring, silence: silence, frames: Int(frames),
                        bufList: UnsafeMutableAudioBufferListPointer(abl))
            return noErr
        }
        engine.attach(source)
        // Connect straight to outputNode (skip mainMixerNode): the mixer's auto-connect
        // is negotiated against outputNode's format when the mixer is first referenced,
        // which may predate the pin above.
        engine.connect(source, to: engine.outputNode, format: outputFormat)
        sourceNode = source

        do {
            engine.prepare()
            try engine.start()
        } catch {
            return .failure(.start(error.localizedDescription))
        }

        // Starting is the moment a unit can be pulled back to the system default, which
        // is BlackHole while the delay is on. Confirm the routing actually held.
        guard CoreAudioDevices.boundDevice(of: outputAU) == device.id else {
            return .failure(.movedTo(CoreAudioDevices.boundDeviceName(of: outputAU)))
        }
        return .success(outputFormat)
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        if let s = sourceNode {
            engine.detach(s)
            sourceNode = nil
        }
    }

    private func observeConfigurationChanges() {
        removeConfigurationObserver()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    private func removeConfigurationObserver() {
        if let token = configurationObserver {
            NotificationCenter.default.removeObserver(token)
            configurationObserver = nil
        }
    }

    // Only safe with the engine stopped: the render callback owns this state.
    private func resetReaderState() {
        readPos = 0
        crossfadeFromReadPos = 0
        crossfadeRemaining = 0
        lastSeenTargetRevision = .max
        currentReadStep = 1.0
        driftCompensator.reset()
    }

    private func restoreDeviceConfiguration() {
        defer {
            configuredDeviceID = nil
            originalSampleRate = nil
            originalBufferFrames = nil
            configuredBufferFrames = nil
        }
        guard let deviceID = configuredDeviceID else { return }

        // Restore only if the value still equals what this app selected; an external
        // change made while running belongs to the user or another app.
        if let originalRate = originalSampleRate,
           abs(originalRate - sampleRate) >= 0.5,
           let currentRate = CoreAudioDevices.nominalSampleRate(of: deviceID),
           abs(currentRate - sampleRate) < 0.5 {
            _ = CoreAudioDevices.setNominalSampleRateIfSupported(originalRate, on: deviceID)
        }
        if let originalFrames = originalBufferFrames,
           let configuredFrames = configuredBufferFrames,
           let currentFrames = CoreAudioDevices.bufferFrameSize(of: deviceID),
           currentFrames == configuredFrames,
           currentFrames != originalFrames {
            _ = CoreAudioDevices.setBufferFrameSize(originalFrames, on: deviceID)
        }
    }

    // MARK: - Lock-free publication

    private func recomputeTarget() {
        let frames = OutputTargetMath.targetFrames(
            userSeconds: userDelaySeconds,
            sampleRate: sampleRate,
            chainLatencyFrames: chainLatencyFrames,
            minRingFrames: minRingFrames
        )
        publishTargetFrames(frames)
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

    private func publishGain(_ gain: Float) {
        let new = Int32(bitPattern: gain.bitPattern)
        while true {
            let old = OSAtomicAdd32Barrier(0, gainBits)
            if OSAtomicCompareAndSwap32Barrier(old, new, gainBits) { return }
        }
    }

    @inline(__always)
    private func loadGain() -> Float {
        Float(bitPattern: UInt32(bitPattern: OSAtomicAdd32Barrier(0, gainBits)))
    }

    // MARK: - Audio thread: ring reader with crossfade-on-change and gain

    private func render(ring: AudioRing,
                        silence: UnsafeMutablePointer<ObjCBool>,
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

        _ = OSAtomicIncrement64Barrier(stats)
        let targetState = loadTargetState()
        let target = targetState.targetFrames
        let w = Double(ring.loadWritePosition())
        let cap = Double(ring.capacity - 1)
        let buffered = w - readPos
        stats[2] = Int64(buffered.isFinite ? buffered : 0)
        let targetChanged = targetState.targetRevision != lastSeenTargetRevision
        var driftedTooFar = !targetChanged && driftCompensator.requiresResynchronization(
            bufferedFrames: buffered,
            targetFrames: Double(target),
            capacityFrames: cap
        )
        // Bit-exact mode never bends the read rate. Instead the cursor is moved back
        // onto target with a crossfade once the smoothed drift exceeds a few ms.
        if bitExact, !targetChanged, abs(driftCompensator.filteredErrorFrames) > bitExactResyncFrames {
            driftedTooFar = true
        }

        if targetChanged || driftedTooFar {
            let oldReadPos = readPos
            readPos = w - Double(target)
            if RingReadSafety.hasCompleteBlock(
                readPosition: oldReadPos,
                writePosition: w,
                readStep: currentReadStep,
                frameCount: frames,
                capacityFrames: cap
            ), RingReadSafety.hasCompleteBlock(
                readPosition: readPos,
                writePosition: w,
                readStep: 1.0,
                frameCount: frames,
                capacityFrames: cap
            ) {
                crossfadeFromReadPos = oldReadPos
                crossfadeRemaining = ring.crossfadeFrames
            } else {
                crossfadeRemaining = 0
            }
            lastSeenTargetRevision = targetState.targetRevision
            driftCompensator.reset()
            currentReadStep = 1.0
        }

        // While priming, follow the advancing write cursor.
        if readPos < 0 {
            readPos = w - Double(target)
        }

        // Never vend a partial block: hold the cursor and let capture catch up.
        guard RingReadSafety.hasCompleteBlock(
            readPosition: readPos,
            writePosition: w,
            readStep: currentReadStep,
            frameCount: frames,
            capacityFrames: cap
        ) else {
            zeroOutput(outL, outR, frameCount: frames)
            silence.pointee = true
            crossfadeRemaining = 0
            _ = OSAtomicIncrement64Barrier(stats + 1)
            return
        }

        let compensated = driftCompensator.update(
            bufferedFrames: w - readPos,
            targetFrames: Double(target),
            renderedFrames: frames
        )
        let readStep = bitExact ? 1.0 : compensated
        currentReadStep = readStep

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
            _ = OSAtomicIncrement64Barrier(stats + 1)
            return
        }

        let targetGain = loadGain()
        let crossfadeFrames = Float(ring.crossfadeFrames)
        let ringL = ring.left
        let ringR = ring.right

        for i in 0..<frames {
            let oldUnderrun = crossfadeFromReadPos < 0 || crossfadeFromReadPos >= w || (w - crossfadeFromReadPos) > cap

            var l: Float
            var r: Float
            if crossfadeRemaining > 0 && !oldUnderrun {
                let t = Float(crossfadeRemaining) / crossfadeFrames
                let oldL: Float, oldR: Float, newL: Float, newR: Float
                if bitExact {
                    oldL = ring.sample(ringL, index: Int(crossfadeFromReadPos))
                    oldR = ring.sample(ringR, index: Int(crossfadeFromReadPos))
                    newL = ring.sample(ringL, index: Int(readPos))
                    newR = ring.sample(ringR, index: Int(readPos))
                } else {
                    oldL = ring.sample(ringL, pos: crossfadeFromReadPos, writeLimit: w)
                    oldR = ring.sample(ringR, pos: crossfadeFromReadPos, writeLimit: w)
                    newL = ring.sample(ringL, pos: readPos, writeLimit: w)
                    newR = ring.sample(ringR, pos: readPos, writeLimit: w)
                }
                l = oldL * t + newL * (1 - t)
                r = oldR * t + newR * (1 - t)
                crossfadeFromReadPos += readStep
                crossfadeRemaining -= 1
            } else {
                if bitExact {
                    l = ring.sample(ringL, index: Int(readPos))
                    r = ring.sample(ringR, index: Int(readPos))
                } else {
                    l = ring.sample(ringL, pos: readPos, writeLimit: w)
                    r = ring.sample(ringR, pos: readPos, writeLimit: w)
                }
                if crossfadeRemaining > 0 { crossfadeRemaining -= 1 }
            }

            let g = gainRamp.advance(toward: targetGain)
            if g != 1.0 {
                l *= g
                r *= g
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
}
