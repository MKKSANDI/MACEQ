import Atomics
import AudioToolbox
import CoreAudio
import Foundation

final class MicEQAudioEngine: @unchecked Sendable {
    typealias MeterCallback = @Sendable (_ inputLevelDB: Double, _ outputLevelDB: Double) -> Void

    private let sampleRate: Double = 48_000
    private let channels: UInt32 = 1
    private let monitorChannels: UInt32 = 2

    // Low-latency target: keep only a small backlog between unsynced device clocks.
    private let miceqRingCapacityFrames: Int = 8_192
    private let monitorRingCapacityFrames: Int = 4_096
    private let appAudioRingCapacityFrames: Int = 65_536
    private let miceqTargetLatencyFrames: Int = 64
    private let monitorTargetLatencyFrames: Int = 32
    private let appAudioTargetLatencyFrames: Int = 1_024
    private let trimHysteresisFrames: Int = 16
    private let appAudioTrimHysteresisFrames: Int = 512

    // Request small I/O buffers for this client to reduce monitoring delay.
    // Note: CoreAudio devices (especially Bluetooth) may ignore this request.
    private let requestedIOBufferFrames: UInt32 = 32

    // Restore any buffer-size tweaks when stopping.
    private var originalDeviceBufferFrames: [AudioDeviceID: UInt32] = [:]

    private var inputUnit: AudioUnit?
    private var miceqOutputUnit: AudioUnit?
    private var monitorOutputUnit: AudioUnit?

    private var miceqRing: SPSCFloatRingBuffer?
    private var monitorRing: SPSCFloatRingBuffer?
    private var appAudioRing: SPSCFloatRingBuffer?
    private var sharedEQ = EQSharedState(maxBands: 96)

    private var inputScratch: UnsafeMutablePointer<Float32>?
    private var monitorScratch: UnsafeMutablePointer<Float32>?
    private var appAudioScratch: UnsafeMutablePointer<Float32>?
    private var appAudioScratchCapacity = 0
    private var maxFramesPerSlice: UInt32 = 4096

    private let eqUpdateQueue = DispatchQueue(label: "com.macq.eq-update", qos: .userInitiated)
    private let eqUpdateQueued = ManagedAtomic<UInt8>(0)
    private let eqUpdateGeneration = ManagedAtomic<UInt64>(0)
    private let eqLatestLock = NSLock()
    private var eqLatestSettings: EQSettings = .default

    private var inputPeakMilliDB = ManagedAtomic<Int32>(-8000)
    private var outputPeakMilliDB = ManagedAtomic<Int32>(-8000)
    private var meterTimer: DispatchSourceTimer?
    private var meterCallback: MeterCallback?
    private let muteFlag = ManagedAtomic<UInt8>(0)
    private let appAudioVolumeMilli = ManagedAtomic<Int32>(750)
    private let appAudioPrimed = ManagedAtomic<UInt8>(0)

    func start(
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID,
        monitorOutputDeviceID: AudioDeviceID?,
        eqSettings: EQSettings,
        meters: @escaping MeterCallback
    ) throws {
        stop()

        meterCallback = meters
        muteFlag.store(0, ordering: .relaxed)
        sharedEQ.store(eqSettings, sampleRate: sampleRate)

        miceqRing = SPSCFloatRingBuffer(capacityFrames: miceqRingCapacityFrames)
        monitorRing = monitorOutputDeviceID == nil ? nil : SPSCFloatRingBuffer(capacityFrames: monitorRingCapacityFrames)
        appAudioRing = SPSCFloatRingBuffer(capacityFrames: appAudioRingCapacityFrames)

        // Try to reduce end-to-end latency by requesting small device buffer sizes.
        // This affects the selected devices globally while MACQ is running, so we restore on stop().
        originalDeviceBufferFrames.removeAll()
        tuneDeviceBufferFrames(deviceID: inputDeviceID, requested: requestedIOBufferFrames)
        tuneDeviceBufferFrames(deviceID: outputDeviceID, requested: requestedIOBufferFrames)
        if let monitorOutputDeviceID {
            tuneDeviceBufferFrames(deviceID: monitorOutputDeviceID, requested: requestedIOBufferFrames)
        }

        do {
            try setupInputUnit(deviceID: inputDeviceID)
            try setupOutputUnit(deviceID: outputDeviceID)
            if let monitorOutputDeviceID {
                try setupMonitorOutputUnit(deviceID: monitorOutputDeviceID)
            }

            try startUnits()
            startMeterTimer()
        } catch {
            stop() // cleanup + restore buffer sizes
            throw error
        }
    }

    func stop() {
        stopMeterTimer()
        meterCallback = nil

        if let au = monitorOutputUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        if let au = miceqOutputUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        if let au = inputUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }

        monitorOutputUnit = nil
        miceqOutputUnit = nil
        inputUnit = nil
        miceqRing = nil
        monitorRing = nil
        appAudioRing = nil

        if let p = inputScratch {
            p.deallocate()
            inputScratch = nil
        }
        if let p = monitorScratch {
            p.deallocate()
            monitorScratch = nil
        }
        if let p = appAudioScratch {
            p.deallocate()
            appAudioScratch = nil
        }
        appAudioScratchCapacity = 0
        appAudioPrimed.store(0, ordering: .relaxed)

        restoreDeviceBufferFrames()
    }

    func setMuted(_ muted: Bool) {
        muteFlag.store(muted ? 1 : 0, ordering: .relaxed)
    }

    func setApplicationAudioVolume(_ volume: Double) {
        let clamped = max(0.0, min(2.0, volume))
        appAudioVolumeMilli.store(Int32(clamped * 1000.0), ordering: .relaxed)
    }

    func writeApplicationAudio(_ samples: UnsafePointer<Float32>, frameCount: Int) {
        appAudioRing?.write(samples, count: frameCount)
    }

    func resetApplicationAudioBuffer() {
        appAudioRing?.reset()
        appAudioPrimed.store(0, ordering: .relaxed)
    }

    func updateEQSettings(_ settings: EQSettings) {
        // Coalesce rapid UI updates (slider drags) and keep coefficient math off the MainActor.
        eqLatestLock.lock()
        eqLatestSettings = settings
        eqLatestLock.unlock()

        _ = eqUpdateGeneration.wrappingIncrementThenLoad(ordering: .releasing)

        let queued = eqUpdateQueued.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing)
        guard queued.exchanged else { return }

        eqUpdateQueue.async { [weak self] in
            self?.drainEQUpdates()
        }
    }

    private func drainEQUpdates() {
        var lastApplied: UInt64 = 0

        while true {
            let gen = eqUpdateGeneration.load(ordering: .acquiring)
            if gen == lastApplied { break }
            lastApplied = gen

            eqLatestLock.lock()
            let snapshot = eqLatestSettings
            eqLatestLock.unlock()

            sharedEQ.store(snapshot, sampleRate: sampleRate)
        }

        eqUpdateQueued.store(0, ordering: .releasing)

        // Handle the race where a new generation arrives after we drop the queued flag.
        let genAfter = eqUpdateGeneration.load(ordering: .acquiring)
        if genAfter != lastApplied {
            let queued = eqUpdateQueued.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing)
            guard queued.exchanged else { return }
            eqUpdateQueue.async { [weak self] in
                self?.drainEQUpdates()
            }
        }
    }

    // MARK: - Latency tuning

    private func tuneDeviceBufferFrames(deviceID: AudioDeviceID, requested: UInt32) {
        guard deviceID != 0 else { return }

        if originalDeviceBufferFrames[deviceID] == nil, let current = getDeviceUInt32(deviceID: deviceID, selector: kAudioDevicePropertyBufferFrameSize) {
            originalDeviceBufferFrames[deviceID] = current
        }

        let range = getDeviceRange(deviceID: deviceID, selector: kAudioDevicePropertyBufferFrameSizeRange)
        guard let range else {
            _ = setDeviceUInt32(deviceID: deviceID, selector: kAudioDevicePropertyBufferFrameSize, value: requested)
            return
        }

        let minFrames = UInt32(max(1.0, ceil(range.mMinimum)))
        let maxFrames = UInt32(max(1.0, floor(range.mMaximum)))

        var candidate = max(minFrames, min(maxFrames, requested))
        while candidate <= maxFrames {
            if setDeviceUInt32(deviceID: deviceID, selector: kAudioDevicePropertyBufferFrameSize, value: candidate) == noErr {
                return
            }
            // Many devices accept power-of-two-like sizes; try larger values until we succeed.
            if candidate >= maxFrames { return }
            candidate = min(maxFrames, candidate &* 2)
        }
    }

    private func restoreDeviceBufferFrames() {
        guard originalDeviceBufferFrames.isEmpty == false else { return }
        let originals = originalDeviceBufferFrames
        originalDeviceBufferFrames.removeAll()
        for (deviceID, frames) in originals {
            _ = setDeviceUInt32(deviceID: deviceID, selector: kAudioDevicePropertyBufferFrameSize, value: frames)
        }
    }

    private func getDeviceUInt32(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func setDeviceUInt32(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, value: UInt32) -> OSStatus {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var v = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &v)
    }

    private func getDeviceRange(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> AudioValueRange? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioValueRange(mMinimum: 0, mMaximum: 0)
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    // MARK: - Setup

    private func setupInputUnit(deviceID: AudioDeviceID) throws {
        let au = try createHALOutputUnit()

        var enableInput: UInt32 = 1
        try check(AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout.size(ofValue: enableInput))
        ), "Enable input IO")

        var disableOutput: UInt32 = 0
        try check(AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout.size(ofValue: disableOutput))
        ), "Disable output IO")

        var dev = deviceID
        try check(AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout.size(ofValue: dev))
        ), "Set input device")

        var asbd = floatMonoASBD(sampleRate: sampleRate)
        try check(AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ), "Set input stream format")

        // Ensure we can handle large slices (e.g. device power saving or larger buffer sizes).
        var maxFrames = maxFramesPerSlice
        _ = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            UInt32(MemoryLayout.size(ofValue: maxFrames))
        )

        inputScratch = UnsafeMutablePointer<Float32>.allocate(capacity: Int(maxFramesPerSlice))
        inputScratch?.initialize(repeating: 0, count: Int(maxFramesPerSlice))

        var cb = AURenderCallbackStruct(
            inputProc: inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &cb,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ), "Set input callback")

        try check(AudioUnitInitialize(au), "Initialize input AUHAL")

        inputUnit = au
    }

    private func setupOutputUnit(deviceID: AudioDeviceID) throws {
        let au = try createHALOutputUnit()

        var enableOutput: UInt32 = 1
        _ = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &enableOutput,
            UInt32(MemoryLayout.size(ofValue: enableOutput))
        )

        var disableInput: UInt32 = 0
        _ = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &disableInput,
            UInt32(MemoryLayout.size(ofValue: disableInput))
        )

        var dev = deviceID
        try check(AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout.size(ofValue: dev))
        ), "Set output device")

        var asbd = floatMonoASBD(sampleRate: sampleRate)
        try check(AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ), "Set output stream format")

        var maxFrames = maxFramesPerSlice
        _ = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            UInt32(MemoryLayout.size(ofValue: maxFrames))
        )

        var cb = AURenderCallbackStruct(
            inputProc: outputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(
            au,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &cb,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ), "Set render callback")

        try check(AudioUnitInitialize(au), "Initialize output AUHAL")

        miceqOutputUnit = au
    }

    private func setupMonitorOutputUnit(deviceID: AudioDeviceID) throws {
        let au = try createHALOutputUnit()

        var enableOutput: UInt32 = 1
        _ = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &enableOutput,
            UInt32(MemoryLayout.size(ofValue: enableOutput))
        )

        var disableInput: UInt32 = 0
        _ = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &disableInput,
            UInt32(MemoryLayout.size(ofValue: disableInput))
        )

        var dev = deviceID
        try check(AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout.size(ofValue: dev))
        ), "Set monitor output device")

        var asbd = floatStereoASBD(sampleRate: sampleRate)
        try check(AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ), "Set monitor stream format")

        var maxFrames = maxFramesPerSlice
        _ = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            UInt32(MemoryLayout.size(ofValue: maxFrames))
        )

        monitorScratch = UnsafeMutablePointer<Float32>.allocate(capacity: Int(maxFramesPerSlice))
        monitorScratch?.initialize(repeating: 0, count: Int(maxFramesPerSlice))

        var cb = AURenderCallbackStruct(
            inputProc: monitorCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(
            au,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &cb,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ), "Set monitor render callback")

        try check(AudioUnitInitialize(au), "Initialize monitor AUHAL")

        monitorOutputUnit = au
    }

    private func startUnits() throws {
        guard let inAU = inputUnit, let outAU = miceqOutputUnit else { return }
        try check(AudioOutputUnitStart(inAU), "Start input AUHAL")
        try check(AudioOutputUnitStart(outAU), "Start output AUHAL")
        if let mon = monitorOutputUnit {
            try check(AudioOutputUnitStart(mon), "Start monitor AUHAL")
        }
    }

    private func createHALOutputUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AudioEngineError("Unable to find AUHAL component")
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "AudioComponentInstanceNew")
        guard let out = au else { throw AudioEngineError("Failed to create AUHAL instance") }
        return out
    }

    private func floatMonoASBD(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func floatStereoASBD(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4 * monitorChannels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * monitorChannels,
            mChannelsPerFrame: monitorChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    // MARK: - Callbacks

    private let inputCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
        let engine = Unmanaged<MicEQAudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
        return engine.handleInput(inTimeStamp: inTimeStamp, frames: inNumberFrames)
    }

    private let outputCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
        let engine = Unmanaged<MicEQAudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
        return engine.handleMicEQOutput(ioData: ioData, frames: inNumberFrames)
    }

    private let monitorCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
        let engine = Unmanaged<MicEQAudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
        return engine.handleMonitorOutput(ioData: ioData, frames: inNumberFrames)
    }

    private func handleInput(inTimeStamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let au = inputUnit, let miceqRing, let inputScratch else { return noErr }
        let n = Int(frames)
        if n == 0 { return noErr }

        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(n * MemoryLayout<Float32>.size), mData: inputScratch)
        )

        var flags: AudioUnitRenderActionFlags = []
        let status = AudioUnitRender(au, &flags, inTimeStamp, 1, frames, &abl)
        if status != noErr { return status }

        // DSP (in-place)
        let active = sharedEQ.load()
        sharedEQ.processor.apply(
            snapshot: active,
            samples: inputScratch,
            frameCount: n,
            inPeakMilliDB: inputPeakMilliDB,
            outPeakMilliDB: outputPeakMilliDB
        )

        mixApplicationAudio(into: inputScratch, frameCount: n)

        if muteFlag.load(ordering: .relaxed) != 0 {
            inputScratch.update(repeating: 0, count: n)
            inputPeakMilliDB.store(-8000, ordering: .relaxed)
            outputPeakMilliDB.store(-8000, ordering: .relaxed)
        } else {
            var finalPeak: Float = 0
            for i in 0..<n {
                finalPeak = max(finalPeak, abs(inputScratch[i]))
            }
            outputPeakMilliDB.store(toMilliDB(finalPeak), ordering: .relaxed)
        }

        miceqRing.write(inputScratch, count: n)
        monitorRing?.write(inputScratch, count: n)
        return noErr
    }

    private func toMilliDB(_ peak: Float) -> Int32 {
        guard peak > 0 else { return -8000 }
        let db = 20.0 * log10(Double(peak))
        let clamped = max(-80.0, min(0.0, db))
        return Int32(clamped * 100.0)
    }

    private func mixApplicationAudio(into samples: UnsafeMutablePointer<Float32>, frameCount: Int) {
        guard let appAudioRing else { return }

        ensureAppAudioScratchCapacity(frameCount)
        guard let appAudioScratch else { return }

        let available = appAudioRing.used()
        let desired = frameCount + appAudioTargetLatencyFrames
        if appAudioPrimed.load(ordering: .relaxed) == 0 {
            guard available >= desired else { return }
            appAudioPrimed.store(1, ordering: .relaxed)
        }

        if available > desired + appAudioTrimHysteresisFrames {
            appAudioRing.drop(available - desired)
        }

        let read = appAudioRing.read(appAudioScratch, count: frameCount)
        guard read > 0 else { return }
        if read < frameCount {
            appAudioPrimed.store(0, ordering: .relaxed)
        }

        let volume = Float32(appAudioVolumeMilli.load(ordering: .relaxed)) / 1000.0
        guard volume > 0 else { return }

        for i in 0..<read {
            let micSample = samples[i].isFinite ? samples[i] : 0
            let appSample = appAudioScratch[i].isFinite ? appAudioScratch[i] : 0
            let mixed = micSample + appSample * volume
            samples[i] = softLimit(mixed)
        }
    }

    private func ensureAppAudioScratchCapacity(_ frameCount: Int) {
        guard frameCount > appAudioScratchCapacity else { return }
        appAudioScratch?.deallocate()
        let capacity = max(Int(maxFramesPerSlice), 1 << Int(ceil(log2(Double(frameCount)))))
        appAudioScratch = UnsafeMutablePointer<Float32>.allocate(capacity: capacity)
        appAudioScratch?.initialize(repeating: 0, count: capacity)
        appAudioScratchCapacity = capacity
    }

    @inline(__always)
    private func softLimit(_ value: Float32) -> Float32 {
        let threshold: Float32 = 0.98
        let absolute = abs(value)
        guard absolute > threshold else { return value }

        let excess = absolute - threshold
        let shaped = threshold + (1 - threshold) * (excess / (excess + (1 - threshold)))
        return value < 0 ? -min(1, shaped) : min(1, shaped)
    }

    private func handleMicEQOutput(ioData: UnsafeMutablePointer<AudioBufferList>?, frames: UInt32) -> OSStatus {
        guard let miceqRing, let ioData else { return noErr }
        let n = Int(frames)
        if n == 0 { return noErr }

        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard let outBuf = buffers.first else { return noErr }
        guard let mData = outBuf.mData else { return noErr }

        let dst = mData.bindMemory(to: Float32.self, capacity: n)

        // Prevent latency from growing if input/output clocks drift.
        let available = miceqRing.used()
        let desired = n + miceqTargetLatencyFrames
        if available > desired + trimHysteresisFrames {
            miceqRing.drop(available - desired)
        }

        let read = miceqRing.read(dst, count: n)
        if read < n {
            dst.advanced(by: read).initialize(repeating: 0, count: n - read)
        }
        return noErr
    }

    private func handleMonitorOutput(ioData: UnsafeMutablePointer<AudioBufferList>?, frames: UInt32) -> OSStatus {
        guard let monitorRing, let monitorScratch, let ioData else { return noErr }
        let n = Int(frames)
        if n == 0 { return noErr }

        // Prevent monitoring latency from growing if device clocks drift.
        let available = monitorRing.used()
        let desired = n + monitorTargetLatencyFrames
        if available > desired + trimHysteresisFrames {
            monitorRing.drop(available - desired)
        }

        let got = monitorRing.read(monitorScratch, count: n)
        if got < n {
            monitorScratch.advanced(by: got).initialize(repeating: 0, count: n - got)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard let outBuf = buffers.first else { return noErr }
        guard let mData = outBuf.mData else { return noErr }

        let dst = mData.bindMemory(to: Float32.self, capacity: n * Int(monitorChannels))
        for i in 0..<n {
            let x = monitorScratch[i]
            dst[i * 2 + 0] = x
            dst[i * 2 + 1] = x
        }
        return noErr
    }

    // MARK: - Meters

    private func startMeterTimer() {
        stopMeterTimer()

        guard let cb = meterCallback else { return }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let inDB = Double(self.inputPeakMilliDB.load(ordering: .relaxed)) / 100.0
            let outDB = Double(self.outputPeakMilliDB.load(ordering: .relaxed)) / 100.0
            cb(inDB, outDB)
        }
        timer.resume()
        meterTimer = timer
    }

    private func stopMeterTimer() {
        meterTimer?.cancel()
        meterTimer = nil
    }

    // MARK: - Errors

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioEngineError("\(operation) failed (OSStatus \(status))") }
    }
}

// MARK: - Shared EQ State (double-buffered, lock-free-ish)

private struct NoiseGateParams {
    var isEnabled: Bool = false
    var openThreshold: Float = 0.01
    var closeThreshold: Float = 0.008
    var minGain: Float = 1.0
    var attackCoeff: Float = 0.0
    var releaseCoeff: Float = 0.0
    var holdFrames: Int32 = 0
}

private struct CompressorParams {
    var isEnabled: Bool = false
    var thresholdDB: Float = -18
    var ratio: Float = 3
    var kneeDB: Float = 0
    var attackCoeff: Float = 0.0
    var releaseCoeff: Float = 0.0
    var makeupGain: Float = 1.0
}

private struct DeEsserParams {
    var isEnabled: Bool = false
    var filter: BiquadCoefficients = .passthrough
    var thresholdDB: Float = -22
    var ratio: Float = 6
    var attackCoeff: Float = 0.0
    var releaseCoeff: Float = 0.0
    var maxReductionDB: Float = 8
}

private struct VoiceIsolationParams {
    var isEnabled: Bool = false
    var strength: Float = 0
    var noiseFloorDB: Float = -58
    var speechThresholdDB: Float = -42
    var reductionDB: Float = 18
    var attackCoeff: Float = 0
    var releaseCoeff: Float = 0
    var focusHighPass: BiquadCoefficients = .passthrough
    var focusLowPass: BiquadCoefficients = .passthrough
    var presence: BiquadCoefficients = .passthrough
}

private struct EQSnapshotView {
    let revision: UInt32
    let isBypassed: Bool
    let preamp: Float
    let outputGain: Float
    let enabled: UnsafePointer<UInt8>
    let coeffs: UnsafePointer<BiquadCoefficients>
    let bandCount: Int
    let noiseGate: NoiseGateParams
    let compressor: CompressorParams
    let deEsser: DeEsserParams
    let voiceIsolation: VoiceIsolationParams
}

private final class EQProcessor {
    private var filters: [BiquadFilter]
    private var lastRevision: UInt32 = 0
    private var gate = NoiseGateState()
    private var comp = CompressorState()
    private var deEsser = DeEsserState()
    private var isolation = VoiceIsolationState()

    init(maxBands: Int) {
        filters = Array(repeating: BiquadFilter(), count: maxBands)
    }

    @inline(__always)
    func apply(
        snapshot: EQSnapshotView,
        samples: UnsafeMutablePointer<Float32>,
        frameCount: Int,
        inPeakMilliDB: ManagedAtomic<Int32>,
        outPeakMilliDB: ManagedAtomic<Int32>
    ) {
        if snapshot.revision != lastRevision {
            for i in 0..<snapshot.bandCount {
                filters[i].c = snapshot.coeffs[i]
            }
            deEsser.filter.c = snapshot.deEsser.filter
            isolation.focusHighPass.c = snapshot.voiceIsolation.focusHighPass
            isolation.focusLowPass.c = snapshot.voiceIsolation.focusLowPass
            isolation.presence.c = snapshot.voiceIsolation.presence
            lastRevision = snapshot.revision
        }

        let pre = snapshot.preamp
        let out = snapshot.outputGain
        let bypass = snapshot.isBypassed

        var inPeak: Float = 0
        var outPeak: Float = 0

        for n in 0..<frameCount {
            var x = samples[n]
            inPeak = max(inPeak, abs(x))

            if !bypass {
                x *= pre

                if snapshot.voiceIsolation.isEnabled {
                    x = isolation.process(x, params: snapshot.voiceIsolation)
                }

                if snapshot.noiseGate.isEnabled {
                    x = gate.process(x, params: snapshot.noiseGate)
                }
                for i in 0..<snapshot.bandCount where snapshot.enabled[i] != 0 {
                    x = filters[i].process(x)
                }

                if snapshot.compressor.isEnabled {
                    x = comp.process(x, params: snapshot.compressor)
                }

                if snapshot.deEsser.isEnabled {
                    x = deEsser.process(x, params: snapshot.deEsser)
                }

                x *= out
                x = min(1.0, max(-1.0, x))
            }

            outPeak = max(outPeak, abs(x))
            samples[n] = x
        }

        inPeakMilliDB.store(toMilliDB(inPeak), ordering: .relaxed)
        outPeakMilliDB.store(toMilliDB(outPeak), ordering: .relaxed)
    }

    private func toMilliDB(_ peak: Float) -> Int32 {
        guard peak > 0 else { return -8000 }
        let db = 20.0 * log10(Double(peak))
        let clamped = max(-80.0, min(0.0, db))
        return Int32(clamped * 100.0)
    }

    private struct NoiseGateState {
        private var env: Float = 0
        private var gain: Float = 1
        private var isOpen: Bool = true
        private var hold: Int32 = 0

        @inline(__always)
        mutating func process(_ x: Float, params: NoiseGateParams) -> Float {
            let a = abs(x)

            // Simple envelope follower.
            if a > env {
                env = env * params.attackCoeff + a * (1 - params.attackCoeff)
            } else {
                env = env * params.releaseCoeff + a * (1 - params.releaseCoeff)
            }

            if isOpen {
                if env < params.closeThreshold {
                    if hold <= 0 {
                        hold = params.holdFrames
                    } else {
                        hold &-= 1
                        if hold <= 0 {
                            isOpen = false
                        }
                    }
                } else {
                    hold = 0
                }
            } else {
                if env >= params.openThreshold {
                    isOpen = true
                    hold = 0
                }
            }

            let target: Float = isOpen ? 1.0 : params.minGain
            if target > gain {
                gain = gain * params.attackCoeff + target * (1 - params.attackCoeff)
            } else {
                gain = gain * params.releaseCoeff + target * (1 - params.releaseCoeff)
            }

            return x * gain
        }
    }

    private struct CompressorState {
        private var gain: Float = 1
        private var target: Float = 1
        private var blockPeak: Float = 0
        private var countdown: Int = 48 // ~1kHz control rate @ 48k
        private let controlPeriod: Int = 48

        @inline(__always)
        mutating func process(_ x: Float, params: CompressorParams) -> Float {
            let a = abs(x)
            if a > blockPeak { blockPeak = a }

            countdown -= 1
            if countdown <= 0 {
                countdown = controlPeriod
                let level = max(1e-9 as Float, blockPeak)
                blockPeak = 0
                let levelDB = 20.0 * Float(log10(Double(level)))

                // Hard-knee compression with an optional soft-knee region.
                let desiredGainDB: Float
                if params.kneeDB > 0 {
                    let kneeHalf = params.kneeDB / 2
                    if levelDB <= params.thresholdDB - kneeHalf {
                        desiredGainDB = 0
                    } else if levelDB >= params.thresholdDB + kneeHalf {
                        let over = levelDB - params.thresholdDB
                        desiredGainDB = (params.thresholdDB + over / params.ratio) - levelDB
                    } else {
                        // Quadratic soft knee.
                        let xk = levelDB - (params.thresholdDB - kneeHalf)
                        let yk = (xk * xk) / (params.kneeDB)
                        let over = yk
                        desiredGainDB = (params.thresholdDB + over / params.ratio) - (params.thresholdDB - kneeHalf + xk)
                    }
                } else {
                    if levelDB <= params.thresholdDB {
                        desiredGainDB = 0
                    } else {
                        let over = levelDB - params.thresholdDB
                        desiredGainDB = (params.thresholdDB + over / params.ratio) - levelDB
                    }
                }

                let desired = Float(pow(10.0, Double(desiredGainDB) / 20.0))
                target = desired * params.makeupGain
            }

            if target < gain {
                gain = gain * params.attackCoeff + target * (1 - params.attackCoeff)
            } else {
                gain = gain * params.releaseCoeff + target * (1 - params.releaseCoeff)
            }

            return x * gain
        }
    }

    private struct DeEsserState {
        var filter = BiquadFilter()
        private var gain: Float = 1
        private var target: Float = 1
        private var blockPeak: Float = 0
        private var countdown: Int = 48 // ~1kHz control rate @ 48k
        private let controlPeriod: Int = 48

        @inline(__always)
        mutating func process(_ x: Float, params: DeEsserParams) -> Float {
            // Extract a rough “sibilance band” component.
            let band = filter.process(x)
            let a = abs(band)
            if a > blockPeak { blockPeak = a }

            countdown -= 1
            if countdown <= 0 {
                countdown = controlPeriod
                let level = max(1e-9 as Float, blockPeak)
                blockPeak = 0
                let envDB = 20.0 * Float(log10(Double(level)))

                let desiredReductionDB: Float
                if envDB <= params.thresholdDB {
                    desiredReductionDB = 0
                } else {
                    let over = envDB - params.thresholdDB
                    let gr = over - (over / params.ratio)
                    desiredReductionDB = min(params.maxReductionDB, max(0, gr))
                }

                let desiredGain = Float(pow(10.0, Double(-desiredReductionDB) / 20.0))
                target = desiredGain
            }

            if target < gain {
                gain = gain * params.attackCoeff + target * (1 - params.attackCoeff)
            } else {
                gain = gain * params.releaseCoeff + target * (1 - params.releaseCoeff)
            }

            // Split-band reduction: attenuate only the extracted band.
            return x + band * (gain - 1.0)
        }
    }

    private struct VoiceIsolationState {
        var focusHighPass = BiquadFilter()
        var focusLowPass = BiquadFilter()
        var presence = BiquadFilter()
        private var env: Float = 0
        private var gain: Float = 1

        @inline(__always)
        mutating func process(_ x: Float, params: VoiceIsolationParams) -> Float {
            let focused = focusLowPass.process(focusHighPass.process(x))
            let a = abs(focused)
            if a > env {
                env = env * params.attackCoeff + a * (1 - params.attackCoeff)
            } else {
                env = env * params.releaseCoeff + a * (1 - params.releaseCoeff)
            }

            let envDB = 20.0 * Float(log10(Double(max(1e-9 as Float, env))))
            let confidence = smoothstep(edge0: params.noiseFloorDB, edge1: params.speechThresholdDB, x: envDB)
            let reduction = params.reductionDB * params.strength * (1 - confidence)
            let targetGain = Float(pow(10.0, Double(-reduction) / 20.0))

            if targetGain > gain {
                gain = gain * params.attackCoeff + targetGain * (1 - params.attackCoeff)
            } else {
                gain = gain * params.releaseCoeff + targetGain * (1 - params.releaseCoeff)
            }

            let focusMix = min(0.42, params.strength * 0.42)
            let isolated = x * (1 - focusMix) + focused * focusMix
            return presence.process(isolated * gain)
        }

        @inline(__always)
        private func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
            let width = max(0.001, edge1 - edge0)
            let t = min(1, max(0, (x - edge0) / width))
            return t * t * (3 - 2 * t)
        }
    }
}

private final class EQSharedState {
    private let maxBands: Int
    private let activeIndex = ManagedAtomic<UInt32>(0)
    private var revisionCounter: UInt32 = 1
    private var lastStoredSettings: EQSettings?
    private var lastStoredSampleRate: Double = 0

    private var meta0 = Meta()
    private var meta1 = Meta()
    private let enabled0: UnsafeMutablePointer<UInt8>
    private let enabled1: UnsafeMutablePointer<UInt8>
    private let coeffs0: UnsafeMutablePointer<BiquadCoefficients>
    private let coeffs1: UnsafeMutablePointer<BiquadCoefficients>

    let processor: EQProcessor

    init(maxBands: Int = 16) {
        self.maxBands = maxBands
        self.processor = EQProcessor(maxBands: maxBands)

        enabled0 = UnsafeMutablePointer<UInt8>.allocate(capacity: maxBands)
        enabled1 = UnsafeMutablePointer<UInt8>.allocate(capacity: maxBands)
        coeffs0 = UnsafeMutablePointer<BiquadCoefficients>.allocate(capacity: maxBands)
        coeffs1 = UnsafeMutablePointer<BiquadCoefficients>.allocate(capacity: maxBands)

        enabled0.initialize(repeating: 0, count: maxBands)
        enabled1.initialize(repeating: 0, count: maxBands)
        coeffs0.initialize(repeating: .passthrough, count: maxBands)
        coeffs1.initialize(repeating: .passthrough, count: maxBands)
    }

    deinit {
        enabled0.deallocate()
        enabled1.deallocate()
        coeffs0.deallocate()
        coeffs1.deallocate()
    }

    func store(_ settings: EQSettings, sampleRate: Double) {
        let current = activeIndex.load(ordering: .relaxed)
        let next: UInt32 = current == 0 ? 1 : 0

        let preamp = Float(pow(10.0, settings.preampDB / 20.0))
        let outGain = Float(pow(10.0, settings.outputGainDB / 20.0))

        let enabled = (next == 0) ? enabled0 : enabled1
        let coeffs = (next == 0) ? coeffs0 : coeffs1

        // Start from the currently-active buffers to avoid redoing expensive coefficient math
        // for bands that didn't change (e.g. slider drags of a single band).
        let curEnabled = (current == 0) ? enabled0 : enabled1
        let curCoeffs = (current == 0) ? coeffs0 : coeffs1
        enabled.update(from: curEnabled, count: maxBands)
        coeffs.update(from: curCoeffs, count: maxBands)

        let prev = lastStoredSettings
        let needsFullRecalc = prev == nil || lastStoredSampleRate != sampleRate || (prev?.bands.count != settings.bands.count)

        for i in 0..<maxBands {
            if i < settings.bands.count {
                let band = settings.bands[i]
                let hadPrevBand = prev?.bands.indices.contains(i) == true
                let prevBand = hadPrevBand ? prev?.bands[i] : nil
                let shouldUpdateBand = needsFullRecalc || hadPrevBand == false || prevBand != band
                if shouldUpdateBand {
                    enabled[i] = band.isEnabled ? 1 : 0
                    coeffs[i] = BiquadDesign.coefficients(for: band, sampleRate: sampleRate)
                }
            } else {
                // Clear any previously-used slots when band count shrinks.
                enabled[i] = 0
                coeffs[i] = .passthrough
            }
        }

        var meta = (current == 0) ? meta0 : meta1
        meta.revision = revisionCounter
        revisionCounter &+= 1
        meta.isBypassed = settings.isBypassed
        meta.preamp = preamp
        meta.outputGain = outGain
        if needsFullRecalc || prev?.noiseGate != settings.noiseGate {
            meta.noiseGate = makeNoiseGateParams(settings.noiseGate, sampleRate: sampleRate)
        }
        if needsFullRecalc || prev?.compressor != settings.compressor {
            meta.compressor = makeCompressorParams(settings.compressor, sampleRate: sampleRate)
        }
        if needsFullRecalc || prev?.deEsser != settings.deEsser {
            meta.deEsser = makeDeEsserParams(settings.deEsser, sampleRate: sampleRate)
        }
        if needsFullRecalc || prev?.voiceIsolation != settings.voiceIsolation {
            meta.voiceIsolation = makeVoiceIsolationParams(settings.voiceIsolation, sampleRate: sampleRate)
        }
        if next == 0 { meta0 = meta } else { meta1 = meta }

        lastStoredSettings = settings
        lastStoredSampleRate = sampleRate

        activeIndex.store(next, ordering: .releasing)
    }

    func load() -> EQSnapshotView {
        let idx = activeIndex.load(ordering: .acquiring)
        if idx == 0 {
            return EQSnapshotView(
                revision: meta0.revision,
                isBypassed: meta0.isBypassed,
                preamp: meta0.preamp,
                outputGain: meta0.outputGain,
                enabled: UnsafePointer(enabled0),
                coeffs: UnsafePointer(coeffs0),
                bandCount: maxBands,
                noiseGate: meta0.noiseGate,
                compressor: meta0.compressor,
                deEsser: meta0.deEsser,
                voiceIsolation: meta0.voiceIsolation
            )
        } else {
            return EQSnapshotView(
                revision: meta1.revision,
                isBypassed: meta1.isBypassed,
                preamp: meta1.preamp,
                outputGain: meta1.outputGain,
                enabled: UnsafePointer(enabled1),
                coeffs: UnsafePointer(coeffs1),
                bandCount: maxBands,
                noiseGate: meta1.noiseGate,
                compressor: meta1.compressor,
                deEsser: meta1.deEsser,
                voiceIsolation: meta1.voiceIsolation
            )
        }
    }

    private func makeNoiseGateParams(_ s: EQSettings.NoiseGateSettings, sampleRate: Double) -> NoiseGateParams {
        guard s.isEnabled, s.rangeDB > 0 else { return NoiseGateParams() }

        let openThr = dbToLinear(s.thresholdDB)
        let closeThr = dbToLinear(s.thresholdDB - max(0, s.hysteresisDB))
        let minGain = dbToLinear(-max(0, s.rangeDB))

        return NoiseGateParams(
            isEnabled: true,
            openThreshold: openThr,
            closeThreshold: min(openThr, closeThr),
            minGain: min(1.0, max(0.0, minGain)),
            attackCoeff: timeCoeff(ms: s.attackMs, sampleRate: sampleRate),
            releaseCoeff: timeCoeff(ms: s.releaseMs, sampleRate: sampleRate),
            holdFrames: Int32(max(0, Int((s.holdMs / 1000.0) * sampleRate)))
        )
    }

    private func makeVoiceIsolationParams(_ s: EQSettings.VoiceIsolationSettings, sampleRate: Double) -> VoiceIsolationParams {
        guard s.isEnabled, s.strength > 0, s.reductionDB > 0 else { return VoiceIsolationParams() }

        let low = EQBand(
            isEnabled: true,
            type: .highPass,
            frequencyHz: s.focusLowHz,
            gainDB: 0,
            q: 0.707
        )
        let high = EQBand(
            isEnabled: true,
            type: .lowPass,
            frequencyHz: s.focusHighHz,
            gainDB: 0,
            q: 0.707
        )
        let presence = EQBand(
            isEnabled: true,
            type: .peaking,
            frequencyHz: 3_800,
            gainDB: s.presenceBoostDB * min(1.0, max(0.0, s.strength / 100.0)),
            q: 1.2
        )

        return VoiceIsolationParams(
            isEnabled: true,
            strength: Float(min(1.0, max(0.0, s.strength / 100.0))),
            noiseFloorDB: Float(s.noiseFloorDB),
            speechThresholdDB: Float(max(s.noiseFloorDB + 1, s.speechThresholdDB)),
            reductionDB: Float(max(0, min(80.0, s.reductionDB))),
            attackCoeff: timeCoeff(ms: s.attackMs, sampleRate: sampleRate),
            releaseCoeff: timeCoeff(ms: s.releaseMs, sampleRate: sampleRate),
            focusHighPass: BiquadDesign.coefficients(for: low, sampleRate: sampleRate),
            focusLowPass: BiquadDesign.coefficients(for: high, sampleRate: sampleRate),
            presence: BiquadDesign.coefficients(for: presence, sampleRate: sampleRate)
        )
    }

    private func makeCompressorParams(_ s: EQSettings.CompressorSettings, sampleRate: Double) -> CompressorParams {
        guard s.isEnabled, s.ratio > 1.0 else { return CompressorParams() }
        return CompressorParams(
            isEnabled: true,
            thresholdDB: Float(s.thresholdDB),
            ratio: Float(max(1.01, min(20.0, s.ratio))),
            kneeDB: Float(max(0, min(24.0, s.kneeDB))),
            attackCoeff: timeCoeff(ms: s.attackMs, sampleRate: sampleRate),
            releaseCoeff: timeCoeff(ms: s.releaseMs, sampleRate: sampleRate),
            makeupGain: dbToLinear(s.makeupGainDB)
        )
    }

    private func makeDeEsserParams(_ s: EQSettings.DeEsserSettings, sampleRate: Double) -> DeEsserParams {
        guard s.isEnabled, s.ratio > 1.0, s.maxReductionDB > 0 else { return DeEsserParams() }

        let band = EQBand(
            isEnabled: true,
            type: .bandPass,
            frequencyHz: s.frequencyHz,
            gainDB: 0,
            q: s.q
        )

        return DeEsserParams(
            isEnabled: true,
            filter: BiquadDesign.coefficients(for: band, sampleRate: sampleRate),
            thresholdDB: Float(s.thresholdDB),
            ratio: Float(max(1.01, min(20.0, s.ratio))),
            attackCoeff: timeCoeff(ms: s.attackMs, sampleRate: sampleRate),
            releaseCoeff: timeCoeff(ms: s.releaseMs, sampleRate: sampleRate),
            maxReductionDB: Float(max(0, min(24.0, s.maxReductionDB)))
        )
    }

    private func dbToLinear(_ db: Double) -> Float {
        Float(pow(10.0, db / 20.0))
    }

    private func timeCoeff(ms: Double, sampleRate: Double) -> Float {
        guard ms > 0 else { return 0 }
        let seconds = ms / 1000.0
        return Float(exp(-1.0 / (seconds * sampleRate)))
    }

    private struct Meta {
        var revision: UInt32 = 0
        var isBypassed: Bool = false
        var preamp: Float = 1.0
        var outputGain: Float = 1.0
        var noiseGate: NoiseGateParams = .init()
        var compressor: CompressorParams = .init()
        var deEsser: DeEsserParams = .init()
        var voiceIsolation: VoiceIsolationParams = .init()
    }
}

private struct AudioEngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
