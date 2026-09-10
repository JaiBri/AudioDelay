import AVFoundation
import Darwin

enum RingSizing {
    static let maximumDelaySeconds = 5.0
    // Enough for the maximum delay, the 0.25 s hard-resync threshold, a slow output
    // callback, and generous slack against the writer overtaking a reader.
    static let minimumCapacitySeconds = 8.0
    static let crossfadeSeconds = 0.030

    // Power of two so the reader can mask instead of divide.
    static func capacityFrames(sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 524_288 }
        let needed = Int(ceil(sampleRate * minimumCapacitySeconds))
        var capacity = 1
        while capacity < needed { capacity <<= 1 }
        return capacity
    }

    static func crossfadeFrames(sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 1_440 }
        return max(1, Int(sampleRate * crossfadeSeconds))
    }
}

// Single-writer, multi-reader float ring. The capture callback is the only writer and
// publishes `writePos` with a full barrier only after both channels are completely
// written. Readers own their cursors and never modify the ring, so any number of
// output engines can read concurrently without a lock. Resetting the write position
// is the one shared mutation and is only legal while no reader is running.
final class AudioRing {
    let sampleRate: Double
    let capacity: Int
    let mask: Int
    let crossfadeFrames: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    private let writePos: UnsafeMutablePointer<Int64>

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.capacity = RingSizing.capacityFrames(sampleRate: sampleRate)
        self.mask = capacity - 1
        self.crossfadeFrames = RingSizing.crossfadeFrames(sampleRate: sampleRate)
        self.left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        self.right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        self.writePos = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        writePos.initialize(to: 0)
    }

    deinit {
        left.deallocate()
        right.deallocate()
        writePos.deinitialize(count: 1)
        writePos.deallocate()
    }

    @inline(__always)
    func loadWritePosition() -> Int64 {
        OSAtomicAdd64Barrier(0, writePos)
    }

    // Only safe with every reader stopped: readers derive their cursors from this.
    func resetWritePosition() {
        let old = loadWritePosition()
        _ = OSAtomicAdd64Barrier(-old, writePos)
    }

    // MARK: Writer (capture thread)

    func write(frames: Int, bufList: UnsafeMutableAudioBufferListPointer) {
        guard frames > 0, frames <= capacity, bufList.count >= 1 else { return }
        let first = bufList[0]
        let nChan = Int(first.mNumberChannels)
        let w = Int(loadWritePosition())

        if bufList.count == 1 {
            // Interleaved (or mono).
            guard nChan > 0,
                  let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<frames {
                let l = data[i * nChan]
                let r = nChan >= 2 ? data[i * nChan + 1] : l
                left[(w + i) & mask] = l
                right[(w + i) & mask] = r
            }
        } else {
            // Non-interleaved, ≥2 buffers.
            guard let l = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            let rPtr = bufList[1].mData?.assumingMemoryBound(to: Float.self) ?? l
            copy(l, destination: left, writePosition: w, frameCount: frames)
            copy(rPtr, destination: right, writePosition: w, frameCount: frames)
        }

        // Publish only after both channels are completely written.
        _ = OSAtomicAdd64Barrier(Int64(frames), writePos)
    }

    // Convenience for tests and non-Core-Audio callers.
    func write(left source: UnsafePointer<Float>, right rightSource: UnsafePointer<Float>, frames: Int) {
        guard frames > 0, frames <= capacity else { return }
        let w = Int(loadWritePosition())
        copy(source, destination: left, writePosition: w, frameCount: frames)
        copy(rightSource, destination: right, writePosition: w, frameCount: frames)
        _ = OSAtomicAdd64Barrier(Int64(frames), writePos)
    }

    @inline(__always)
    private func copy(_ source: UnsafePointer<Float>,
                      destination: UnsafeMutablePointer<Float>,
                      writePosition: Int,
                      frameCount: Int) {
        let index = writePosition & mask
        let firstCount = min(frameCount, capacity - index)
        destination.advanced(by: index).update(from: source, count: firstCount)

        let remaining = frameCount - firstCount
        if remaining > 0 {
            destination.update(from: source.advanced(by: firstCount), count: remaining)
        }
    }

    // MARK: Readers (render threads)

    // Linear interpolation for the fractional-cursor reader.
    @inline(__always)
    func sample(_ ring: UnsafeMutablePointer<Float>, pos: Double, writeLimit: Double) -> Float {
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

    // Exact copy for the integer-cursor (bit-exact) reader.
    @inline(__always)
    func sample(_ ring: UnsafeMutablePointer<Float>, index: Int) -> Float {
        ring[index & mask]
    }
}
