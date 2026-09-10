import AVFoundation
import CoreAudio
import Foundation

struct OutputDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBluetooth: Bool
}

// Thin, stateless wrappers over the Core Audio property API. Everything here is
// synchronous and safe to call from the main thread; nothing is called from a
// realtime callback.
enum CoreAudioDevices {

    // MARK: Enumeration

    static func allDeviceIDs() -> [AudioDeviceID] {
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
        return ids
    }

    static func enumerateOutputDevices() -> [OutputDeviceInfo] {
        var result: [OutputDeviceInfo] = []
        for id in allDeviceIDs() {
            guard hasOutputStreams(deviceID: id),
                  let uid = uidForDevice(id),
                  let name = nameForDevice(id) else { continue }
            result.append(OutputDeviceInfo(id: id, uid: uid, name: name, isBluetooth: isBluetooth(id)))
        }
        return result
    }

    static func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        hasStreams(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)
    }

    static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        hasStreams(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
    }

    static func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    static func channelCount(of deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
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

    static func uidForDevice(_ id: AudioDeviceID) -> String? {
        readCFString(deviceID: id, selector: kAudioDevicePropertyDeviceUID)
    }

    static func nameForDevice(_ id: AudioDeviceID) -> String? {
        readCFString(deviceID: id, selector: kAudioObjectPropertyName)
    }

    static func readCFString(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
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

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for id in allDeviceIDs() where uidForDevice(id) == uid { return id }
        return nil
    }

    static func transportType(of id: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return st == noErr ? value : nil
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        guard let transport = transportType(of: id) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    // Aggregate and Multi-Output devices list their members under this property;
    // the size query fails for ordinary devices.
    static func subDeviceUIDs(of id: AudioDeviceID) -> [String]? {
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
        guard st == noErr, let cfList = unmanaged?.takeRetainedValue() else { return nil }
        return cfList as NSArray as? [String]
    }

    // MARK: Default output

    static func defaultOutputDeviceID() -> AudioDeviceID? {
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

    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) throws {
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
                    userInfo: [NSLocalizedDescriptionKey: "Set default output failed (\(status))"]
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

    // MARK: Buffer size and sample rate

    static func bufferFrameSize(of deviceID: AudioDeviceID) -> UInt32? {
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

    static func bufferFrameSizeRange(of deviceID: AudioDeviceID) -> AudioValueRange? {
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

    static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double? {
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

    static func availableNominalSampleRateRanges(of deviceID: AudioDeviceID) -> [AudioValueRange] {
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

    static func supportsNominalSampleRate(_ rate: Double, on deviceID: AudioDeviceID) -> Bool {
        availableNominalSampleRateRanges(of: deviceID).contains {
            rate >= $0.mMinimum && rate <= $0.mMaximum
        }
    }

    @discardableResult
    static func setNominalSampleRateIfSupported(_ rate: Double, on deviceID: AudioDeviceID) -> Bool {
        guard rate.isFinite, rate > 0 else { return false }
        if let current = nominalSampleRate(of: deviceID), abs(current - rate) < 0.5 {
            return true
        }
        guard supportsNominalSampleRate(rate, on: deviceID) else { return false }

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
    static func ensureNominalSampleRate(_ rate: Double, on deviceID: AudioDeviceID) -> Bool {
        let attempts = 20
        for attempt in 0..<attempts {
            if setNominalSampleRateIfSupported(rate, on: deviceID) { return true }
            if attempt < attempts - 1 { usleep(50_000) }
        }
        return false
    }

    @discardableResult
    static func setBufferFrameSize(_ frames: UInt32, on deviceID: AudioDeviceID) -> Bool {
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

    // Never force every device to the same tiny frame count: frame duration, not
    // frame count, determines the deadline. This only raises dangerously short
    // buffers left by this app or another client; a larger user setting is kept.
    @discardableResult
    static func ensureStableBufferDuration(on deviceID: AudioDeviceID) -> UInt32 {
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
        guard current < preferred else { return current }

        _ = setBufferFrameSize(preferred, on: deviceID)
        return bufferFrameSize(of: deviceID) ?? current
    }

    // MARK: Latency

    struct OutputLatencyComponents {
        var device: UInt32 = 0
        var safety: UInt32 = 0
        var stream: UInt32 = 0
        var total: UInt32 { device + safety + stream }
    }

    static func outputLatencyComponents(of deviceID: AudioDeviceID) -> OutputLatencyComponents {
        func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope) -> UInt32 {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
            )
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : 0
        }

        var result = OutputLatencyComponents()
        result.device = readUInt32(deviceID, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
        result.safety = readUInt32(deviceID, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &streams) == noErr,
               let first = streams.first {
                result.stream = readUInt32(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
            }
        }
        return result
    }

    // MARK: AUHAL device binding

    static func boundDevice(of au: AudioUnit) -> AudioDeviceID? {
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

    static func boundDeviceName(of au: AudioUnit) -> String {
        guard let id = boundDevice(of: au) else { return "an unknown device" }
        return nameForDevice(id) ?? "an unknown device"
    }

    @discardableResult
    static func writeCurrentDevice(_ id: AudioDeviceID, on au: AudioUnit) -> OSStatus {
        var deviceID = id
        return AudioUnitSetProperty(au,
                                    kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global,
                                    0,
                                    &deviceID,
                                    UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    // Writing CurrentDevice is not enough on its own. Core Audio drops a write that
    // matches the unit's existing value, and AVAudioEngine then re-binds the unit to the
    // system default while starting — which is how switching the delay off and on again
    // left playback sitting on BlackHole, feeding captured audio straight back into the
    // capture device with nothing reaching the speakers. Route through the decoy device
    // first so the write that matters is a genuine transition, and read the value back
    // rather than trusting a noErr return. The decoy must not be a Bluetooth device:
    // binding even an idle unit to one can wake the link and stall for hundreds of ms.
    static func pinDevice(_ id: AudioDeviceID,
                          on au: AudioUnit,
                          role: String,
                          decoy: AudioDeviceID?,
                          attempts: Int) throws {
        if boundDevice(of: au) == id, let decoy, decoy != id {
            for _ in 0..<attempts {
                writeCurrentDevice(decoy, on: au)
                if boundDevice(of: au) != id { break }
                usleep(40_000)
            }
        }

        var lastStatus: OSStatus = noErr
        for attempt in 0..<attempts {
            lastStatus = writeCurrentDevice(id, on: au)
            if boundDevice(of: au) == id { return }
            if attempt < attempts - 1 { usleep(40_000) }
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
