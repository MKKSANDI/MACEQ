import Atomics
import AudioToolbox
import CoreAudio
import Foundation

/// Records a short mono mic sample from a specific CoreAudio input device.
/// Designed for small captures (a few seconds) for AI analysis / EQ suggestion.
final class MicSampleRecorder: @unchecked Sendable {
    private let sampleRate: Double = 48_000
    private let channels: UInt32 = 1

    private var inputUnit: AudioUnit?
    private var scratch: UnsafeMutablePointer<Float32>?
    private var maxFramesPerSlice: UInt32 = 4096

    private var captureBuffer: UnsafeMutablePointer<Float32>?
    private var captureCapacityFrames: Int = 0
    private let capturedFrames = ManagedAtomic<Int32>(0)

    private let inputCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
        let recorder = Unmanaged<MicSampleRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
        return recorder.handleInput(inTimeStamp: inTimeStamp, frames: inNumberFrames)
    }

    deinit {
        stopAndTearDown()
    }

    func recordWAV(deviceID: AudioDeviceID, seconds: Double) async throws -> Data {
        stopAndTearDown()

        let frames = max(1, Int(seconds * sampleRate))
        captureCapacityFrames = frames
        capturedFrames.store(0, ordering: .relaxed)

        let capPtr = UnsafeMutablePointer<Float32>.allocate(capacity: frames)
        capPtr.initialize(repeating: 0, count: frames)
        captureBuffer = capPtr

        try setupInputUnit(deviceID: deviceID)
        try start()

        // Poll until the capture is complete.
        while capturedFrames.load(ordering: .acquiring) < Int32(frames) {
            try await Task.sleep(for: .milliseconds(10))
        }

        stopAndTearDownAudioOnly()

        guard let buffer = captureBuffer else { throw RecorderError("Internal capture buffer missing") }
        let floats = UnsafeBufferPointer(start: buffer, count: frames)
        let wav = encodeWAV16Mono(samples: floats, sampleRate: Int(sampleRate))

        buffer.deallocate()
        captureBuffer = nil
        captureCapacityFrames = 0

        return wav
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

        var asbd = AudioStreamBasicDescription(
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
        try check(AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ), "Set input stream format")

        var maxFrames: UInt32 = maxFramesPerSlice
        _ = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            UInt32(MemoryLayout.size(ofValue: maxFrames))
        )
        maxFramesPerSlice = maxFrames

        scratch = UnsafeMutablePointer<Float32>.allocate(capacity: Int(maxFramesPerSlice))
        scratch?.initialize(repeating: 0, count: Int(maxFramesPerSlice))

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

    private func start() throws {
        guard let au = inputUnit else { return }
        try check(AudioOutputUnitStart(au), "Start input AUHAL")
    }

    private func stopAndTearDownAudioOnly() {
        if let au = inputUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        inputUnit = nil

        if let p = scratch {
            p.deallocate()
            scratch = nil
        }
    }

    private func stopAndTearDown() {
        stopAndTearDownAudioOnly()
        if let p = captureBuffer {
            p.deallocate()
            captureBuffer = nil
        }
        captureCapacityFrames = 0
        capturedFrames.store(0, ordering: .relaxed)
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
            throw RecorderError("Unable to find AUHAL component")
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "AudioComponentInstanceNew")
        guard let out = au else { throw RecorderError("Failed to create AUHAL instance") }
        return out
    }

    // MARK: - Callback

    private func handleInput(inTimeStamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let au = inputUnit, let scratch, let captureBuffer else { return noErr }
        let n = Int(frames)
        if n == 0 { return noErr }

        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(n * MemoryLayout<Float32>.size), mData: scratch)
        )

        var flags: AudioUnitRenderActionFlags = []
        let status = AudioUnitRender(au, &flags, inTimeStamp, 1, frames, &abl)
        if status != noErr { return status }

        let already = Int(capturedFrames.load(ordering: .relaxed))
        let remaining = captureCapacityFrames - already
        if remaining <= 0 { return noErr }

        let toCopy = min(n, remaining)
        captureBuffer.advanced(by: already).update(from: scratch, count: toCopy)
        capturedFrames.store(Int32(already + toCopy), ordering: .releasing)

        return noErr
    }

    // MARK: - WAV encoding

    private func encodeWAV16Mono(samples: UnsafeBufferPointer<Float32>, sampleRate: Int) -> Data {
        let frameCount = samples.count
        let bytesPerSample = 2
        let dataSize = frameCount * bytesPerSample
        let riffSize = 36 + dataSize

        var out = Data()
        out.reserveCapacity(44 + dataSize)

        func append(_ value: UInt32) { var v = value.littleEndian; out.append(Data(bytes: &v, count: 4)) }
        func append16(_ value: UInt16) { var v = value.littleEndian; out.append(Data(bytes: &v, count: 2)) }
        func appendStr(_ s: String) { out.append(s.data(using: .ascii)!) }

        appendStr("RIFF")
        append(UInt32(riffSize))
        appendStr("WAVE")

        appendStr("fmt ")
        append(UInt32(16)) // PCM fmt chunk size
        append16(UInt16(1)) // PCM
        append16(UInt16(1)) // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 1 * bytesPerSample)) // byte rate
        append16(UInt16(1 * bytesPerSample)) // block align
        append16(UInt16(16)) // bits per sample

        appendStr("data")
        append(UInt32(dataSize))

        for i in 0..<frameCount {
            let x = max(-1.0, min(1.0, Double(samples[i])))
            let s = Int16((x * 32767.0).rounded())
            var v = s.littleEndian
            out.append(Data(bytes: &v, count: 2))
        }

        return out
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw RecorderError("\(operation) failed (OSStatus \(status))") }
    }
}

private struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
