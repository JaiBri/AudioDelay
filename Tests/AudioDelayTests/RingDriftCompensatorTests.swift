import Testing
@testable import AudioDelay

@Suite
struct RingDriftCompensatorTests {
    private let sampleRate = 48_000.0
    private let targetFrames = 512.0

    @Test
    func testDelayModePreferencePersistsAndMigratesWithoutChangingTheRoute() {
        #expect(DelayModePreference.initialEnabled(
            storedValue: true,
            systemOutputIsBlackHole: false
        ))
        #expect(!DelayModePreference.initialEnabled(
            storedValue: false,
            systemOutputIsBlackHole: true
        ))
        #expect(DelayModePreference.initialEnabled(
            storedValue: nil,
            systemOutputIsBlackHole: true
        ))
        #expect(!DelayModePreference.initialEnabled(
            storedValue: nil,
            systemOutputIsBlackHole: false
        ))
    }

    @Test
    func testKeepsDelayBoundedWhenInputClockRunsFast() {
        let result = simulate(days: 4, clockDifferencePPM: 20)

        #expect(abs(result.bufferedFrames - targetFrames) < 20)
        #expect(abs(result.readStep - 1.000_020) < 0.000_002)
    }

    @Test
    func testKeepsDelayBoundedWhenInputClockRunsSlow() {
        let result = simulate(days: 4, clockDifferencePPM: -20)

        #expect(abs(result.bufferedFrames - targetFrames) < 20)
        #expect(abs(result.readStep - 0.999_980) < 0.000_002)
    }

    @Test
    func testRequestsResynchronizationBeforeRingWraps() {
        let compensator = RingDriftCompensator(sampleRate: sampleRate)

        #expect(!compensator.requiresResynchronization(
            bufferedFrames: targetFrames + sampleRate * 0.1,
            targetFrames: targetFrames,
            capacityFrames: 262_143
        ))
        #expect(compensator.requiresResynchronization(
            bufferedFrames: targetFrames + sampleRate * 0.3,
            targetFrames: targetFrames,
            capacityFrames: 262_143
        ))
        #expect(!compensator.requiresResynchronization(
            bufferedFrames: 0,
            targetFrames: targetFrames,
            capacityFrames: 262_143
        ))
    }

    @Test
    func testLateCaptureWaitsInsteadOfRewinding() {
        let compensator = RingDriftCompensator(sampleRate: sampleRate)

        // Even a large negative error must not jump backwards into already-played
        // audio. The render side will hold its cursor until a whole block is ready.
        #expect(!compensator.requiresResynchronization(
            bufferedFrames: 128,
            targetFrames: sampleRate,
            capacityFrames: 262_143
        ))
        #expect(!RingReadSafety.hasCompleteBlock(
            readPosition: 10_000,
            writePosition: 10_128,
            readStep: 1,
            frameCount: 256,
            capacityFrames: 262_143
        ))
    }

    @Test
    func testReaderOnlyVendsCompleteBlocks() {
        #expect(RingReadSafety.hasCompleteBlock(
            readPosition: 1_000,
            writePosition: 1_256,
            readStep: 1,
            frameCount: 256,
            capacityFrames: 262_143
        ))
        #expect(!RingReadSafety.hasCompleteBlock(
            readPosition: 1_001,
            writePosition: 1_256,
            readStep: 1,
            frameCount: 256,
            capacityFrames: 262_143
        ))
        #expect(!RingReadSafety.hasCompleteBlock(
            readPosition: -1,
            writePosition: 4_096,
            readStep: 1,
            frameCount: 256,
            capacityFrames: 262_143
        ))
    }

    @Test
    func testDeviceBufferSizingUsesDurationAtHighSampleRates() {
        #expect(AudioBufferSizing.preferredDeviceFrames(
            sampleRate: 48_000,
            minimum: 32,
            maximum: 4_096
        ) == 1_024)
        #expect(AudioBufferSizing.preferredDeviceFrames(
            sampleRate: 192_000,
            minimum: 32,
            maximum: 4_096
        ) == 4_096)
        #expect(AudioBufferSizing.preferredDeviceFrames(
            sampleRate: 192_000,
            minimum: 32,
            maximum: 2_048
        ) == 2_048)
    }

    @Test
    func testRingHeadroomNormalizesDeviceSampleRates() {
        let frames = AudioBufferSizing.minimumRingFrames(
            ringSampleRate: sampleRate,
            captureBufferFrames: 1_024,
            captureSampleRate: 48_000,
            outputBufferFrames: 4_096,
            outputSampleRate: 192_000
        )

        #expect(frames == 4_096)
    }

    @Test
    func testNormalCallbackPhasingDoesNotCauseRateHunting() {
        var compensator = RingDriftCompensator(sampleRate: sampleRate)
        var bufferedFrames = targetFrames
        var steadyStateBufferSum = 0.0
        let outputBlockFrames = 128
        let callbackCount = 200_000
        let averagingCallbacks = 4_000

        for callback in 0..<callbackCount {
            // A 512-frame BlackHole input block arrives once per four 128-frame
            // source callbacks. The controller should average this normal sawtooth.
            if callback > 0, callback.isMultiple(of: 4) {
                bufferedFrames += 512
            }

            let readStep = compensator.update(
                bufferedFrames: bufferedFrames,
                targetFrames: targetFrames,
                renderedFrames: outputBlockFrames
            )
            if callback >= callbackCount - averagingCallbacks {
                steadyStateBufferSum += bufferedFrames
            }
            bufferedFrames -= Double(outputBlockFrames) * readStep
        }

        let steadyStateAverage = steadyStateBufferSum / Double(averagingCallbacks)
        #expect(abs(steadyStateAverage - targetFrames) < 1)
        #expect(abs(compensator.readStep - 1.0) < 0.000_001)
    }

    private func simulate(days: Int,
                          clockDifferencePPM: Double) -> (bufferedFrames: Double, readStep: Double) {
        var compensator = RingDriftCompensator(sampleRate: sampleRate)
        var bufferedFrames = targetFrames
        let framesPerUpdate = Int(sampleRate) // One simulated second per iteration.
        let inputFramesPerOutputFrame = 1.0 + clockDifferencePPM / 1_000_000.0

        for _ in 0..<(days * 24 * 60 * 60) {
            let readStep = compensator.update(
                bufferedFrames: bufferedFrames,
                targetFrames: targetFrames,
                renderedFrames: framesPerUpdate
            )
            bufferedFrames += Double(framesPerUpdate) * (inputFramesPerOutputFrame - readStep)
        }

        return (bufferedFrames, compensator.readStep)
    }
}
