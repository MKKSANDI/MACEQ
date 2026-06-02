import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let transportType: UInt32

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var isInput: Bool { inputChannels > 0 }
    var isOutput: Bool { outputChannels > 0 }

    var isBluetoothTransport: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var isAggregateTransport: Bool {
        transportType == kAudioDeviceTransportTypeAggregate || transportType == kAudioDeviceTransportTypeAutoAggregate
    }

    var isAirPlayTransport: Bool {
        transportType == kAudioDeviceTransportTypeAirPlay
    }

    var isVirtualTransport: Bool {
        transportType == kAudioDeviceTransportTypeVirtual
    }

    var isBuiltInTransport: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }

    var isHighLatencyTransport: Bool {
        isBluetoothTransport || isAirPlayTransport || isAggregateTransport
    }
}
