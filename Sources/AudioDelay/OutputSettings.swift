import Foundation

// MARK: - Persistent model

struct OutputConfig: Codable, Equatable, Identifiable {
    var uid: String
    var id: String { uid }
    var name: String
    var enabled: Bool
    var delaySeconds: Double
    var volumePercent: Double
    var isBluetooth: Bool

    static let maximumDelaySeconds = RingSizing.maximumDelaySeconds

    init(uid: String, name: String, enabled: Bool = true,
         delaySeconds: Double = 0, volumePercent: Double = 100, isBluetooth: Bool = false) {
        self.uid = uid
        self.name = name
        self.enabled = enabled
        self.delaySeconds = OutputConfig.clampDelay(delaySeconds)
        self.volumePercent = OutputConfig.clampVolume(volumePercent)
        self.isBluetooth = isBluetooth
    }

    private enum CodingKeys: String, CodingKey {
        case uid, name, enabled, delaySeconds, volumePercent, isBluetooth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(String.self, forKey: .uid)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? uid
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        delaySeconds = OutputConfig.clampDelay(try c.decodeIfPresent(Double.self, forKey: .delaySeconds) ?? 0)
        volumePercent = OutputConfig.clampVolume(try c.decodeIfPresent(Double.self, forKey: .volumePercent) ?? 100)
        isBluetooth = try c.decodeIfPresent(Bool.self, forKey: .isBluetooth) ?? false
    }

    static func clampDelay(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return max(0, min(maximumDelaySeconds, seconds))
    }

    static func clampVolume(_ percent: Double) -> Double {
        guard percent.isFinite else { return 100 }
        return max(0, min(100, percent))
    }
}

struct OutputSettings: Codable, Equatable {
    static let currentVersion = 2
    static let supportedSampleRates: [Double] = [44_100, 48_000, 96_000]
    static let defaultSampleRate: Double = 48_000

    var version: Int
    var outputs: [OutputConfig]
    var processingSampleRate: Double
    var bitExactWired: Bool

    init(outputs: [OutputConfig] = [],
         processingSampleRate: Double = OutputSettings.defaultSampleRate,
         bitExactWired: Bool = false) {
        self.version = OutputSettings.currentVersion
        self.outputs = outputs
        self.processingSampleRate = OutputSettings.validSampleRate(processingSampleRate)
        self.bitExactWired = bitExactWired
    }

    private enum CodingKeys: String, CodingKey {
        case version, outputs, processingSampleRate, bitExactWired
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? OutputSettings.currentVersion
        outputs = try c.decodeIfPresent([OutputConfig].self, forKey: .outputs) ?? []
        processingSampleRate = OutputSettings.validSampleRate(
            try c.decodeIfPresent(Double.self, forKey: .processingSampleRate) ?? OutputSettings.defaultSampleRate
        )
        bitExactWired = try c.decodeIfPresent(Bool.self, forKey: .bitExactWired) ?? false
    }

    static func validSampleRate(_ rate: Double) -> Double {
        supportedSampleRates.first { abs($0 - rate) < 0.5 } ?? defaultSampleRate
    }

    func config(for uid: String) -> OutputConfig? {
        outputs.first { $0.uid == uid }
    }

    var enabledUIDs: Set<String> {
        Set(outputs.filter(\.enabled).map(\.uid))
    }

    // Returns the config, creating a disabled default entry for an unknown device.
    mutating func upsert(uid: String, name: String, isBluetooth: Bool,
                         _ mutate: (inout OutputConfig) -> Void) {
        if let index = outputs.firstIndex(where: { $0.uid == uid }) {
            outputs[index].name = name
            outputs[index].isBluetooth = isBluetooth
            mutate(&outputs[index])
        } else {
            var config = OutputConfig(uid: uid, name: name, enabled: false, isBluetooth: isBluetooth)
            mutate(&config)
            outputs.append(config)
        }
    }

    // Legacy 1.0 installs stored one device and one delay. Keep that device even if it
    // is not connected right now; otherwise fall back to what the Mac is playing on.
    static func migratedFromLegacy(delaySeconds: Double?,
                                   outputDeviceUID: String?,
                                   available: [OutputDeviceInfo],
                                   currentDefaultUID: String?,
                                   blackHoleUIDs: Set<String>) -> OutputSettings {
        let delay = delaySeconds ?? 0
        if let uid = outputDeviceUID, !uid.isEmpty {
            let device = available.first { $0.uid == uid }
            return OutputSettings(outputs: [
                OutputConfig(uid: uid,
                             name: device?.name ?? "Previous output",
                             enabled: true,
                             delaySeconds: delay,
                             volumePercent: 100,
                             isBluetooth: device?.isBluetooth ?? false)
            ])
        }
        if let currentDefaultUID, !blackHoleUIDs.contains(currentDefaultUID),
           let device = available.first(where: { $0.uid == currentDefaultUID }) {
            return OutputSettings(outputs: [
                OutputConfig(uid: device.uid, name: device.name, enabled: true,
                             delaySeconds: delay, isBluetooth: device.isBluetooth)
            ])
        }
        if let device = available.first {
            return OutputSettings(outputs: [
                OutputConfig(uid: device.uid, name: device.name, enabled: true,
                             delaySeconds: delay, isBluetooth: device.isBluetooth)
            ])
        }
        return OutputSettings()
    }
}

enum OutputSettingsStore {
    static let key = "outputSettings"
    static let legacyDelayKey = "delaySeconds"
    static let legacyOutputKey = "outputDeviceUID"

    static func load(defaults: UserDefaults,
                     available: [OutputDeviceInfo],
                     currentDefaultUID: String?,
                     blackHoleUIDs: Set<String>) -> OutputSettings {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(OutputSettings.self, from: data) {
            return decoded
        }
        let legacyDelay = defaults.object(forKey: legacyDelayKey) as? Double
        let legacyUID = defaults.string(forKey: legacyOutputKey)
        let migrated = OutputSettings.migratedFromLegacy(
            delaySeconds: legacyDelay,
            outputDeviceUID: legacyUID,
            available: available,
            currentDefaultUID: currentDefaultUID,
            blackHoleUIDs: blackHoleUIDs
        )
        save(migrated, defaults: defaults)
        return migrated
    }

    static func save(_ settings: OutputSettings, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Primary device (where the Mac plays when the delay is off)

enum PrimaryOutputSelection {
    // Wired before Bluetooth: the direct route should land on a device that is always
    // attached and has no A2DP latency, and a Bluetooth default invites macOS's own
    // auto-switching on every reconnect.
    static func choose(configs: [OutputConfig],
                       available: [OutputDeviceInfo],
                       legacyOutputUID: String?,
                       currentDefaultUID: String?,
                       blackHoleUIDs: Set<String>) -> OutputDeviceInfo? {
        let byUID = Dictionary(available.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let enabledPresent = configs.filter(\.enabled).compactMap { byUID[$0.uid] }

        if let wired = enabledPresent.first(where: { !$0.isBluetooth }) { return wired }
        if let any = enabledPresent.first { return any }
        if let legacyOutputUID, let legacy = byUID[legacyOutputUID] { return legacy }
        if let currentDefaultUID, !blackHoleUIDs.contains(currentDefaultUID),
           let current = byUID[currentDefaultUID] { return current }
        return available.first
    }
}

// MARK: - Reconciliation of configured vs. connected vs. running

enum OutputReconciler {
    struct Plan: Equatable {
        var start: [String]
        var stop: [String]
    }

    static func plan(configs: [OutputConfig], present: Set<String>, running: Set<String>) -> Plan {
        let enabled = configs.filter(\.enabled).map(\.uid)
        let start = enabled.filter { present.contains($0) && !running.contains($0) }
        let enabledSet = Set(enabled)
        let stop = running.filter { !present.contains($0) || !enabledSet.contains($0) }.sorted()
        return Plan(start: start, stop: stop)
    }
}

// MARK: - Per-output delay target

enum OutputTargetMath {
    // Ring target = max(floor, userIntent − chainLatency). Subtracting the chain means
    // the slider value approximates the *perceived* delay on that speaker, so equal
    // values on two speakers with different latencies come out in sync.
    static func targetFrames(userSeconds: Double,
                             sampleRate: Double,
                             chainLatencyFrames: Int,
                             minRingFrames: Int) -> Int {
        let clamped = OutputConfig.clampDelay(userSeconds)
        let userFrames = Int(clamped * sampleRate)
        return max(minRingFrames, userFrames - chainLatencyFrames)
    }

    static func perceivedMs(targetFrames: Int, chainLatencyFrames: Int, sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return 0 }
        return Int((Double(targetFrames + chainLatencyFrames) / sampleRate) * 1000.0)
    }

    static func framesAtRingRate(_ frames: Int, deviceRate: Double, ringRate: Double) -> Int {
        guard deviceRate.isFinite, deviceRate > 0, ringRate.isFinite, ringRate > 0 else { return frames }
        return Int(ceil(Double(frames) * ringRate / deviceRate))
    }
}

// MARK: - Gain

enum OutputGain {
    // Squared law: 50 % ≈ −12 dB, which feels linear to the ear. 100 % is exactly 1.0
    // so the multiply is an identity and unity playback stays bit-transparent.
    static func linearGain(percent: Double) -> Float {
        let p = OutputConfig.clampVolume(percent) / 100.0
        if p >= 1.0 { return 1.0 }
        if p <= 0.0 { return 0.0 }
        return Float(p * p)
    }
}

// Linear ramp on the render thread so volume changes never click. Clamps exactly onto
// the target, so once a ramp finishes the gain is the exact published value.
struct GainRamp {
    private(set) var current: Float
    let stepPerFrame: Float

    init(initial: Float, sampleRate: Double, rampSeconds: Double = 0.020) {
        current = initial
        let frames = max(1.0, sampleRate * rampSeconds)
        stepPerFrame = Float(1.0 / frames)
    }

    @inline(__always)
    mutating func advance(toward target: Float) -> Float {
        if current == target { return current }
        if current < target {
            current = min(target, current + stepPerFrame)
        } else {
            current = max(target, current - stepPerFrame)
        }
        return current
    }

    mutating func jump(to value: Float) {
        current = value
    }
}

// MARK: - System default output changes while the delay is on

// macOS makes a freshly connected Bluetooth speaker the default output on its own.
// With the delay on that used to look exactly like the user picking a device in
// Sound Settings, and the delay switched itself off every time the speaker came back.
// Any speaker that is enabled in the app is therefore treated as ours: the route is
// restored. Picking a device that is not enabled in the app is still a bypass.
enum SystemOutputChangeInterpretation {
    enum Verdict: Equatable {
        case userBypass
        case reassertBlackHole
    }

    static func classify(newDefaultUID: String, enabledConfiguredUIDs: Set<String>) -> Verdict {
        enabledConfiguredUIDs.contains(newDefaultUID) ? .reassertBlackHole : .userBypass
    }
}
