import AVFoundation

enum MicrophonePermission: String, Equatable {
    case notDetermined
    case denied
    case authorized

    static func current() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }
}

@MainActor
struct MicrophonePermissionService {
    func status() -> MicrophonePermission { .current() }

    func requestAccess() async -> MicrophonePermission {
        let granted = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                cont.resume(returning: ok)
            }
        }
        return granted ? .authorized : .denied
    }
}

