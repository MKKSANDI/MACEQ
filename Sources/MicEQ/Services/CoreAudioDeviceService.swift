import CoreAudio
import Foundation

struct CoreAudioDeviceService {
    static let micEQDeviceName = "MicEQ"

    func listInputDevices() throws -> [AudioDevice] {
        let devices = try listAllDevices()
        return devices
            .filter { $0.inputChannels > 0 }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func listOutputDevices() throws -> [AudioDevice] {
        let devices = try listAllDevices()
        return devices
            .filter { $0.outputChannels > 0 }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func defaultInputDeviceID() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get default input device") }
        return deviceID
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get default output device") }
        return deviceID
    }

    func findDevice(named name: String) throws -> AudioDevice {
        let devices = try listAllDevices()
        if let exact = devices.first(where: { $0.name == name }) { return exact }
        if let ci = devices.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return ci }
        throw CoreAudioError(status: -1, operation: "Device not found: \(name)")
    }

    // MARK: - Private

    private func listAllDevices() throws -> [AudioDevice] {
        let ids = try allDeviceIDs()
        return try ids.map { id in
            let name = try deviceName(id: id)
            let uid = try deviceUID(id: id)
            let transportType = (try? deviceTransportType(id: id)) ?? 0
            let inputChannels = try channelCount(id: id, scope: kAudioObjectPropertyScopeInput)
            let outputChannels = try channelCount(id: id, scope: kAudioObjectPropertyScopeOutput)
            return AudioDevice(
                id: id,
                uid: uid,
                name: name,
                inputChannels: inputChannels,
                outputChannels: outputChannels,
                transportType: transportType
            )
        }
    }

    private func allDeviceIDs() throws -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get devices size") }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get devices") }

        return ids
    }

    private func deviceName(id: AudioDeviceID) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfName)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get device name") }

        return (cfName?.takeRetainedValue() ?? "" as CFString) as String
    }

    private func deviceUID(id: AudioDeviceID) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfUID)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get device UID") }

        return (cfUID?.takeRetainedValue() ?? "" as CFString) as String
    }

    private func channelCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get stream config size") }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }

        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, abl)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get stream config") }

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func deviceTransportType(id: AudioDeviceID) throws -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "Get transport type") }
        return transport
    }
}

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "\(operation) failed (OSStatus \(status))."
    }
}
