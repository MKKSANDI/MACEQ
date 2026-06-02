import Atomics
import Foundation

/// A mostly lock-free ring buffer suitable for passing mono Float32 audio between two realtime threads.
/// - Producer: writes samples
/// - Consumer: reads samples
final class SPSCFloatRingBuffer {
    private let capacity: Int
    private let mask: UInt64

    private let writePos = ManagedAtomic<UInt64>(0)
    private let readPos = ManagedAtomic<UInt64>(0)

    private let storage: UnsafeMutableBufferPointer<Float32>

    init(capacityFrames: Int) {
        precondition(capacityFrames > 0)

        // Round capacity up to a power of two to make wrap cheap.
        let cap = 1 << Int(ceil(log2(Double(capacityFrames))))
        self.capacity = cap
        self.mask = UInt64(cap - 1)

        let ptr = UnsafeMutablePointer<Float32>.allocate(capacity: cap)
        ptr.initialize(repeating: 0, count: cap)
        self.storage = UnsafeMutableBufferPointer(start: ptr, count: cap)
    }

    deinit {
        storage.baseAddress?.deallocate()
    }

    @inline(__always)
    func reset() {
        writePos.store(0, ordering: .relaxed)
        readPos.store(0, ordering: .relaxed)
        storage.initialize(repeating: 0)
    }

    /// Write `count` samples. If the buffer would overflow, this drops the oldest samples.
    @inline(__always)
    func write(_ src: UnsafePointer<Float32>, count: Int) {
        guard count > 0 else { return }

        // Ensure we have room by advancing readPos (dropping oldest) when necessary.
        while true {
            let r = readPos.load(ordering: .acquiring)
            let w = writePos.load(ordering: .relaxed)
            let used = w &- r
            let needed = UInt64(count)

            if used &+ needed <= UInt64(capacity) {
                break
            }

            let drop = (used &+ needed) &- UInt64(capacity)
            let desired = r &+ drop
            let result = readPos.compareExchange(expected: r, desired: desired, ordering: .acquiringAndReleasing)
            if result.exchanged { break }
        }

        let w = writePos.load(ordering: .relaxed)
        for i in 0..<count {
            storage[Int((w &+ UInt64(i)) & mask)] = src[i]
        }
        writePos.store(w &+ UInt64(count), ordering: .releasing)
    }

    /// Read up to `count` samples. Returns number of samples read.
    @inline(__always)
    func read(_ dst: UnsafeMutablePointer<Float32>, count: Int) -> Int {
        guard count > 0 else { return 0 }

        let r = readPos.load(ordering: .relaxed)
        let w = writePos.load(ordering: .acquiring)
        let available = Int(min(UInt64(count), w &- r))

        if available == 0 { return 0 }

        for i in 0..<available {
            dst[i] = storage[Int((r &+ UInt64(i)) & mask)]
        }
        readPos.store(r &+ UInt64(available), ordering: .releasing)
        return available
    }

    /// Number of samples currently buffered (writePos - readPos).
    @inline(__always)
    func used() -> Int {
        let r = readPos.load(ordering: .acquiring)
        let w = writePos.load(ordering: .acquiring)
        return Int(w &- r)
    }

    /// Drop (discard) up to `count` oldest samples.
    @inline(__always)
    func drop(_ count: Int) {
        guard count > 0 else { return }

        while true {
            let r = readPos.load(ordering: .relaxed)
            let w = writePos.load(ordering: .acquiring)
            let available = w &- r
            if available == 0 { return }

            let toDrop = min(UInt64(count), available)
            let desired = r &+ toDrop
            let result = readPos.compareExchange(expected: r, desired: desired, ordering: .acquiringAndReleasing)
            if result.exchanged { return }
        }
    }
}
