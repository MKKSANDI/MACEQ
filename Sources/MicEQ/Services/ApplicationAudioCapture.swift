import AudioToolbox
import CoreAudio
import Foundation

final class ApplicationAudioCapture: @unchecked Sendable {
    typealias AudioCallback = @Sendable (_ samples: UnsafePointer<Float32>, _ frameCount: Int) -> Void

    private let targetSampleRate: Double = 48_000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var callback: AudioCallback?

    private var mixScratch: UnsafeMutablePointer<Float32>?
    private var mixScratchCapacity = 0
    private var resampleScratch: UnsafeMutablePointer<Float32>?
    private var resampleScratchCapacity = 0
    private var sourceSampleRate: Double = 48_000
    private var sourceIsFloat32 = true
    private var resamplePosition: Double = 0
    private var resamplePreviousSample: Float32 = 0
    private var hasResamplePreviousSample = false

    var isRunning: Bool {
        aggregateDeviceID != kAudioObjectUnknown && ioProcID != nil
    }

    func start(processID pid: pid_t, callback: @escaping AudioCallback) throws {
        guard #available(macOS 14.2, *) else {
            throw AppAudioCaptureError.unsupportedOS
        }

        stop()

        self.callback = callback

        do {
            let processObjectID = try translatePIDToProcessObject(pid)
            let tapDescription = CATapDescription(monoMixdownOfProcesses: [processObjectID])
            tapDescription.name = "MACQ App Audio"
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .unmuted

            var createdTap = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateProcessTap(tapDescription, &createdTap), "Create application audio tap")
            tapID = createdTap

            let tapUID = try getTapUID(tapID)
            let aggregateUID = "com.macq.app-audio.\(UUID().uuidString)"

            let tapEntry: [String: Any] = [
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality,
            ]

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceNameKey: "MACQ App Audio",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [tapEntry],
                kAudioAggregateDeviceTapAutoStartKey: true,
            ]

            var createdAggregate = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregate), "Create application audio aggregate")
            aggregateDeviceID = createdAggregate

            setNominalSampleRate(aggregateDeviceID, sampleRate: targetSampleRate)
            updateSourceFormat()
            resetResampler()

            var procID: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcID(aggregateDeviceID, appAudioIOProc, Unmanaged.passUnretained(self).toOpaque(), &procID), "Create application audio IOProc")
            ioProcID = procID

            try check(AudioDeviceStart(aggregateDeviceID, ioProcID), "Start application audio capture")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
        }
        tapID = AudioObjectID(kAudioObjectUnknown)

        callback = nil
        sourceSampleRate = targetSampleRate
        sourceIsFloat32 = true
        resetResampler()
    }

    deinit {
        stop()
        mixScratch?.deallocate()
        resampleScratch?.deallocate()
    }

    fileprivate func handleInput(_ inputData: UnsafePointer<AudioBufferList>?) -> OSStatus {
        guard let inputData, let callback else { return noErr }
        guard sourceIsFloat32 else { return noErr }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let frames = frameCount(in: buffers)
        guard frames > 0 else { return noErr }

        guard let monoSamples = monoSamples(from: buffers, frameCount: frames) else { return noErr }

        if abs(sourceSampleRate - targetSampleRate) < 1 {
            callback(monoSamples, frames)
        } else {
            let outFrames = resampleToTargetRate(monoSamples, frameCount: frames)
            if outFrames > 0, let resampleScratch {
                callback(UnsafePointer(resampleScratch), outFrames)
            }
        }

        return noErr
    }

    private func frameCount(in buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        var result = Int.max
        var foundData = false

        for buffer in buffers {
            guard buffer.mData != nil else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
            guard frames > 0 else { continue }
            result = min(result, frames)
            foundData = true
        }

        return foundData ? result : 0
    }

    private func monoSamples(
        from buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) -> UnsafePointer<Float32>? {
        if buffers.count == 1,
           let first = buffers.first,
           first.mNumberChannels == 1,
           let data = first.mData {
            return UnsafePointer(data.bindMemory(to: Float32.self, capacity: frameCount))
        }

        ensureMixScratchCapacity(frameCount)
        guard let mixScratch else { return nil }

        for frame in 0..<frameCount {
            var sum: Float32 = 0
            var channelCount: Float32 = 0

            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let floatData = data.bindMemory(to: Float32.self, capacity: frameCount * channels)

                if buffers.count == 1 || channels > 1 {
                    let base = frame * channels
                    for channel in 0..<channels {
                        sum += sanitizeSample(floatData[base + channel])
                        channelCount += 1
                    }
                } else {
                    sum += sanitizeSample(floatData[frame])
                    channelCount += 1
                }
            }

            mixScratch[frame] = channelCount > 0 ? sum / channelCount : 0
        }

        return UnsafePointer(mixScratch)
    }

    private func resampleToTargetRate(_ source: UnsafePointer<Float32>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        if frameCount == 1 {
            ensureResampleScratchCapacity(1)
            resampleScratch?[0] = sanitizeSample(source[0])
            return 1
        }

        let sourceFramesPerOutputFrame = sourceSampleRate / targetSampleRate
        guard sourceFramesPerOutputFrame > 0, sourceFramesPerOutputFrame.isFinite else { return 0 }

        let expectedFrames = max(1, Int(ceil(Double(frameCount) / sourceFramesPerOutputFrame)) + 8)
        ensureResampleScratchCapacity(expectedFrames)
        guard let resampleScratch else { return 0 }

        if hasResamplePreviousSample == false {
            resamplePreviousSample = sanitizeSample(source[0])
            hasResamplePreviousSample = true
            resamplePosition = 0
        }

        var outputFrames = 0
        var position = resamplePosition
        let lastInterpolableFrame = Double(frameCount - 1)

        while position < lastInterpolableFrame && outputFrames < resampleScratchCapacity {
            let index = Int(floor(position))
            let fraction = Float32(position - Double(index))

            let a: Float32
            let b: Float32
            if index < 0 {
                a = resamplePreviousSample
                b = sanitizeSample(source[0])
            } else {
                a = sanitizeSample(source[index])
                b = sanitizeSample(source[min(index + 1, frameCount - 1)])
            }

            resampleScratch[outputFrames] = a + (b - a) * fraction
            outputFrames += 1
            position += sourceFramesPerOutputFrame
        }

        resamplePosition = position - Double(frameCount)
        if resamplePosition < -1.0 || resamplePosition > 1.0 {
            resamplePosition = 0
        }
        resamplePreviousSample = sanitizeSample(source[frameCount - 1])
        return outputFrames
    }

    private func resetResampler() {
        resamplePosition = 0
        resamplePreviousSample = 0
        hasResamplePreviousSample = false
    }

    private func ensureMixScratchCapacity(_ frameCount: Int) {
        guard frameCount > mixScratchCapacity else { return }
        mixScratch?.deallocate()
        let nextCapacity = max(1024, 1 << Int(ceil(log2(Double(frameCount)))))
        mixScratch = UnsafeMutablePointer<Float32>.allocate(capacity: nextCapacity)
        mixScratch?.initialize(repeating: 0, count: nextCapacity)
        mixScratchCapacity = nextCapacity
    }

    private func ensureResampleScratchCapacity(_ frameCount: Int) {
        guard frameCount > resampleScratchCapacity else { return }
        resampleScratch?.deallocate()
        let nextCapacity = max(1024, 1 << Int(ceil(log2(Double(frameCount)))))
        resampleScratch = UnsafeMutablePointer<Float32>.allocate(capacity: nextCapacity)
        resampleScratch?.initialize(repeating: 0, count: nextCapacity)
        resampleScratchCapacity = nextCapacity
    }

    private func sanitizeSample(_ sample: Float32) -> Float32 {
        guard sample.isFinite else { return 0 }
        return min(2, max(-2, sample))
    }

    private func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var processID = AudioObjectID(kAudioObjectUnknown)
        var mutablePID = pid
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        let status = withUnsafePointer(to: &mutablePID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                qualifier,
                &size,
                &processID
            )
        }

        guard status == noErr, processID != kAudioObjectUnknown else {
            throw AppAudioCaptureError.processNotAvailable
        }
        return processID
    }

    private func getTapUID(_ tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &cfUID)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get application audio tap UID") }

        return (cfUID?.takeRetainedValue() ?? "" as CFString) as String
    }

    private func setNominalSampleRate(_ deviceID: AudioObjectID, sampleRate: Double) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var rate = Float64(sampleRate)
        _ = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &rate
        )
    }

    private func updateSourceFormat() {
        if let format = firstStreamFormat(deviceID: aggregateDeviceID) {
            if format.mSampleRate > 0 {
                sourceSampleRate = format.mSampleRate
            }
            sourceIsFloat32 = format.mFormatID == kAudioFormatLinearPCM &&
                (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
                format.mBitsPerChannel == 32
        } else if let rate = nominalSampleRate(deviceID: aggregateDeviceID), rate > 0 {
            sourceSampleRate = rate
            sourceIsFloat32 = true
        } else {
            sourceSampleRate = targetSampleRate
            sourceIsFloat32 = true
        }
    }

    private func firstStreamFormat(deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeGlobal] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )

            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
                continue
            }

            let count = Int(size) / MemoryLayout<AudioObjectID>.size
            var streams = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
            let status = streams.withUnsafeMutableBufferPointer { pointer in
                AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer.baseAddress!)
            }
            guard status == noErr else { continue }

            for stream in streams where stream != kAudioObjectUnknown {
                var formatAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioStreamPropertyVirtualFormat,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var format = AudioStreamBasicDescription()
                var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                if AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, &format) == noErr {
                    return format
                }
            }
        }

        return nil
    }

    private func nominalSampleRate(deviceID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr ? Double(rate) : nil
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
    }
}

private let appAudioIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    let capture = Unmanaged<ApplicationAudioCapture>.fromOpaque(clientData).takeUnretainedValue()
    return capture.handleInput(inputData)
}

enum AppAudioCaptureError: LocalizedError {
    case unsupportedOS
    case processNotAvailable

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Application audio capture requires macOS 14.2 or newer."
        case .processNotAvailable:
            return "That app is not exposing audio to CoreAudio yet. Start playback in the app, then select it again."
        }
    }
}
