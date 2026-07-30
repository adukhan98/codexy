import AVFoundation
import ApplicationServices
import Foundation

@MainActor
final class PermissionService: PermissionChecking {
    private(set) var microphone: PermissionState = .unknown
    private(set) var accessibility: PermissionState = .unknown

    init() {
        refresh()
    }

    func refresh() {
        microphone = Self.microphoneState(
            from: AVCaptureDevice.authorizationStatus(for: .audio)
        )
        accessibility = AXIsProcessTrusted() ? .granted : .denied
    }

    func requestMicrophone() async -> PermissionState {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refresh()
        return microphone
    }

    @discardableResult
    func requestAccessibility(prompt: Bool = true) -> PermissionState {
        let options = [
            "AXTrustedCheckOptionPrompt": prompt
        ] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
            ? .granted
            : .denied
        return accessibility
    }

    private static func microphoneState(
        from status: AVAuthorizationStatus
    ) -> PermissionState {
        switch status {
        case .authorized:
            .granted
        case .notDetermined:
            .notDetermined
        case .denied, .restricted:
            .denied
        @unknown default:
            .unknown
        }
    }
}
