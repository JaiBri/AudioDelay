import Foundation
import Testing
@testable import AudioDelay

private func device(_ uid: String, _ name: String? = nil, bluetooth: Bool = false, id: UInt32 = 1) -> OutputDeviceInfo {
    OutputDeviceInfo(id: id, uid: uid, name: name ?? uid, isBluetooth: bluetooth)
}

@Suite
struct OutputSettingsTests {
    @Test
    func migrationKeepsLegacyDeviceEvenWhenDisconnected() {
        let settings = OutputSettings.migratedFromLegacy(
            delaySeconds: 1.5,
            outputDeviceUID: "old-uid",
            available: [device("other")],
            currentDefaultUID: "other",
            blackHoleUIDs: []
        )
        #expect(settings.outputs.count == 1)
        #expect(settings.outputs[0].uid == "old-uid")
        #expect(settings.outputs[0].enabled)
        #expect(settings.outputs[0].delaySeconds == 1.5)
        #expect(settings.outputs[0].volumePercent == 100)
        #expect(settings.processingSampleRate == 48_000)
    }

    @Test
    func migrationFallsBackToCurrentDefaultThenFirstAvailable() {
        let fromDefault = OutputSettings.migratedFromLegacy(
            delaySeconds: nil,
            outputDeviceUID: "",
            available: [device("a"), device("b")],
            currentDefaultUID: "b",
            blackHoleUIDs: []
        )
        #expect(fromDefault.outputs.map(\.uid) == ["b"])
        #expect(fromDefault.outputs[0].delaySeconds == 0)

        let defaultIsBlackHole = OutputSettings.migratedFromLegacy(
            delaySeconds: nil,
            outputDeviceUID: nil,
            available: [device("a"), device("b")],
            currentDefaultUID: "BlackHole2ch_UID",
            blackHoleUIDs: ["BlackHole2ch_UID"]
        )
        #expect(defaultIsBlackHole.outputs.map(\.uid) == ["a"])

        let nothing = OutputSettings.migratedFromLegacy(
            delaySeconds: nil, outputDeviceUID: nil, available: [], currentDefaultUID: nil, blackHoleUIDs: []
        )
        #expect(nothing.outputs.isEmpty)
    }

    @Test
    func decodingClampsAndToleratesMissingFields() throws {
        let json = """
        {"version": 2, "outputs": [{"uid": "x", "delaySeconds": 9, "volumePercent": -5}],
         "processingSampleRate": 12345}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: json)
        #expect(decoded.outputs[0].delaySeconds == 5)
        #expect(decoded.outputs[0].volumePercent == 0)
        #expect(decoded.outputs[0].enabled)
        #expect(decoded.outputs[0].name == "x")
        #expect(decoded.processingSampleRate == 48_000)
        #expect(!decoded.bitExactWired)
    }

    @Test
    func roundTripsThroughJSON() throws {
        var settings = OutputSettings(processingSampleRate: 96_000, bitExactWired: true)
        settings.outputs = [
            OutputConfig(uid: "a", name: "A", enabled: true, delaySeconds: 0.25, volumePercent: 40, isBluetooth: true),
            OutputConfig(uid: "b", name: "B", enabled: false)
        ]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test
    func storeMigratesOnceAndThenReadsSavedSettings() {
        let suite = "AudioDelayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2.0, forKey: OutputSettingsStore.legacyDelayKey)
        defaults.set("legacy", forKey: OutputSettingsStore.legacyOutputKey)

        let first = OutputSettingsStore.load(defaults: defaults, available: [], currentDefaultUID: nil, blackHoleUIDs: [])
        #expect(first.outputs.map(\.uid) == ["legacy"])
        #expect(first.outputs[0].delaySeconds == 2.0)

        var edited = first
        edited.outputs[0].delaySeconds = 0.5
        OutputSettingsStore.save(edited, defaults: defaults)
        let second = OutputSettingsStore.load(defaults: defaults, available: [], currentDefaultUID: nil, blackHoleUIDs: [])
        #expect(second == edited)
    }

    @Test
    func upsertCreatesDisabledEntryForUnknownDevice() {
        var settings = OutputSettings()
        settings.upsert(uid: "new", name: "New", isBluetooth: true) { $0.volumePercent = 30 }
        #expect(settings.outputs.count == 1)
        #expect(!settings.outputs[0].enabled)
        #expect(settings.outputs[0].volumePercent == 30)
        #expect(settings.outputs[0].isBluetooth)

        settings.upsert(uid: "new", name: "Renamed", isBluetooth: true) { $0.enabled = true }
        #expect(settings.outputs.count == 1)
        #expect(settings.outputs[0].name == "Renamed")
        #expect(settings.outputs[0].enabled)
        #expect(settings.enabledUIDs == ["new"])
    }
}

@Suite
struct PrimaryOutputSelectionTests {
    @Test
    func prefersEnabledWiredOverEnabledBluetooth() {
        let configs = [
            OutputConfig(uid: "bt", name: "BT", enabled: true, isBluetooth: true),
            OutputConfig(uid: "usb", name: "USB", enabled: true)
        ]
        let chosen = PrimaryOutputSelection.choose(
            configs: configs,
            available: [device("bt", bluetooth: true), device("usb")],
            legacyOutputUID: nil, currentDefaultUID: "bt", blackHoleUIDs: []
        )
        #expect(chosen?.uid == "usb")
    }

    @Test
    func skipsDisconnectedAndFallsBack() {
        let configs = [OutputConfig(uid: "gone", name: "Gone", enabled: true)]
        let legacy = PrimaryOutputSelection.choose(
            configs: configs, available: [device("a"), device("legacy")],
            legacyOutputUID: "legacy", currentDefaultUID: "a", blackHoleUIDs: []
        )
        #expect(legacy?.uid == "legacy")

        let current = PrimaryOutputSelection.choose(
            configs: configs, available: [device("a"), device("b")],
            legacyOutputUID: nil, currentDefaultUID: "b", blackHoleUIDs: []
        )
        #expect(current?.uid == "b")

        let blackHoleDefault = PrimaryOutputSelection.choose(
            configs: configs, available: [device("a"), device("b")],
            legacyOutputUID: nil, currentDefaultUID: "bh", blackHoleUIDs: ["bh"]
        )
        #expect(blackHoleDefault?.uid == "a")

        let none = PrimaryOutputSelection.choose(
            configs: configs, available: [], legacyOutputUID: nil, currentDefaultUID: nil, blackHoleUIDs: []
        )
        #expect(none == nil)
    }
}

@Suite
struct OutputReconcilerTests {
    private let configs = [
        OutputConfig(uid: "a", name: "A", enabled: true),
        OutputConfig(uid: "b", name: "B", enabled: true),
        OutputConfig(uid: "c", name: "C", enabled: false)
    ]

    @Test
    func startsEnabledPresentNotRunning() {
        let plan = OutputReconciler.plan(configs: configs, present: ["a", "b", "c"], running: [])
        #expect(plan == OutputReconciler.Plan(start: ["a", "b"], stop: []))
    }

    @Test
    func stopsDisappearedAndDisabled() {
        let plan = OutputReconciler.plan(configs: configs, present: ["a", "c"], running: ["a", "b", "c"])
        #expect(plan == OutputReconciler.Plan(start: [], stop: ["b", "c"]))
    }

    @Test
    func idempotentWhenSettled() {
        let plan = OutputReconciler.plan(configs: configs, present: ["a", "b"], running: ["a", "b"])
        #expect(plan == OutputReconciler.Plan(start: [], stop: []))
    }
}

@Suite
struct OutputTargetMathTests {
    @Test
    func subtractsChainLatencyAndFloorsAtRingMinimum() {
        #expect(OutputTargetMath.targetFrames(userSeconds: 1.0, sampleRate: 48_000,
                                              chainLatencyFrames: 4_800, minRingFrames: 3_840) == 43_200)
        #expect(OutputTargetMath.targetFrames(userSeconds: 0.0, sampleRate: 48_000,
                                              chainLatencyFrames: 4_800, minRingFrames: 3_840) == 3_840)
        #expect(OutputTargetMath.targetFrames(userSeconds: 99, sampleRate: 48_000,
                                              chainLatencyFrames: 0, minRingFrames: 0) == 240_000)
        #expect(OutputTargetMath.targetFrames(userSeconds: -1, sampleRate: 48_000,
                                              chainLatencyFrames: 0, minRingFrames: 100) == 100)
    }

    @Test
    func perceivedRoundTripsAtEveryRate() {
        for rate in OutputSettings.supportedSampleRates {
            let latency = Int(rate * 0.230)
            let target = OutputTargetMath.targetFrames(userSeconds: 0.75, sampleRate: rate,
                                                       chainLatencyFrames: latency, minRingFrames: 0)
            let perceived = OutputTargetMath.perceivedMs(targetFrames: target, chainLatencyFrames: latency, sampleRate: rate)
            #expect(abs(perceived - 750) <= 1)
        }
    }

    @Test
    func convertsDeviceLatencyToRingRate() {
        #expect(OutputTargetMath.framesAtRingRate(10_156, deviceRate: 44_100, ringRate: 48_000) == 11_055)
        #expect(OutputTargetMath.framesAtRingRate(10_156, deviceRate: 44_100, ringRate: 44_100) == 10_156)
    }
}

@Suite
struct GainTests {
    @Test
    func unityIsExactAndCurveIsSquared() {
        #expect(OutputGain.linearGain(percent: 100) == 1.0)
        #expect(OutputGain.linearGain(percent: 120) == 1.0)
        #expect(OutputGain.linearGain(percent: 0) == 0.0)
        #expect(abs(OutputGain.linearGain(percent: 50) - 0.25) < 0.000_001)
    }

    @Test
    func rampReachesTargetExactlyWithoutOvershoot() {
        var ramp = GainRamp(initial: 1.0, sampleRate: 48_000, rampSeconds: 0.020)
        var frames = 0
        var previous: Float = 1.0
        while ramp.current != 0.25 {
            let g = ramp.advance(toward: 0.25)
            #expect(g <= previous)
            #expect(g >= 0.25)
            previous = g
            frames += 1
            #expect(frames < 2_000)
        }
        #expect(frames <= 960)
        #expect(ramp.advance(toward: 0.25) == 0.25)

        var up = GainRamp(initial: 0.0, sampleRate: 48_000)
        for _ in 0..<2_000 { _ = up.advance(toward: 1.0) }
        #expect(up.current == 1.0)
    }
}

@Suite
struct RingSizingTests {
    @Test
    func capacityIsPowerOfTwoAndHoldsEightSeconds() {
        #expect(RingSizing.capacityFrames(sampleRate: 44_100) == 524_288)
        #expect(RingSizing.capacityFrames(sampleRate: 48_000) == 524_288)
        #expect(RingSizing.capacityFrames(sampleRate: 96_000) == 1_048_576)
        for rate in OutputSettings.supportedSampleRates {
            let capacity = RingSizing.capacityFrames(sampleRate: rate)
            #expect(capacity & (capacity - 1) == 0)
            #expect(Double(capacity) >= rate * 8)
        }
    }

    @Test
    func crossfadeIsThirtyMilliseconds() {
        #expect(RingSizing.crossfadeFrames(sampleRate: 44_100) == 1_323)
        #expect(RingSizing.crossfadeFrames(sampleRate: 48_000) == 1_440)
        #expect(RingSizing.crossfadeFrames(sampleRate: 96_000) == 2_880)
    }

    @Test
    func bluetoothOutputAt44kRaisesRingFloor() {
        let frames = AudioBufferSizing.minimumRingFrames(
            ringSampleRate: 48_000,
            captureBufferFrames: 1_024,
            captureSampleRate: 48_000,
            outputBufferFrames: 4_096,
            outputSampleRate: 44_100
        )
        #expect(frames == 4 * 4_459)
    }
}

@Suite
struct AudioRingTests {
    @Test
    func writesWrapAndReadBackExactly() {
        let ring = AudioRing(sampleRate: 48_000)
        let count = ring.capacity - 100
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for i in 0..<count {
            left[i] = Float(i)
            right[i] = -Float(i)
        }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                ring.write(left: l.baseAddress!, right: r.baseAddress!, frames: count)
            }
        }
        #expect(ring.loadWritePosition() == Int64(count))

        let tail: [Float] = [1_000, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000, 8_000]
        tail.withUnsafeBufferPointer { t in
            for _ in 0..<25 { ring.write(left: t.baseAddress!, right: t.baseAddress!, frames: 8) }
        }
        let w = Int(ring.loadWritePosition())
        #expect(w == count + 200)
        #expect(ring.sample(ring.left, index: w - 1) == 8_000)
        #expect(ring.sample(ring.right, index: w - 1) == 8_000)
        #expect(ring.sample(ring.left, index: w - 200 - 1) == Float(count - 1))
        #expect(ring.sample(ring.right, index: w - 200 - 1) == -Float(count - 1))

        // Interpolation holds the newest sample at the write limit.
        #expect(ring.sample(ring.left, pos: Double(w - 1) + 0.5, writeLimit: Double(w)) == 8_000)
        #expect(ring.sample(ring.left, pos: Double(w - 2) + 0.5, writeLimit: Double(w)) == 7_500)

        ring.resetWritePosition()
        #expect(ring.loadWritePosition() == 0)
    }
}

@Suite
struct SystemOutputChangeInterpretationTests {
    @Test
    func enabledSpeakerIsReasserted() {
        #expect(SystemOutputChangeInterpretation.classify(
            newDefaultUID: "bt", enabledConfiguredUIDs: ["bt", "usb"]
        ) == .reassertBlackHole)
    }

    @Test
    func otherDevicesAreBypass() {
        #expect(SystemOutputChangeInterpretation.classify(
            newDefaultUID: "hdmi", enabledConfiguredUIDs: ["bt", "usb"]
        ) == .userBypass)
        #expect(SystemOutputChangeInterpretation.classify(
            newDefaultUID: "bt", enabledConfiguredUIDs: []
        ) == .userBypass)
    }
}
