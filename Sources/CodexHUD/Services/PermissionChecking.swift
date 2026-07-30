import Foundation

enum PermissionState: String, Equatable, Sendable {
    case unknown
    case notDetermined
    case denied
    case granted
}
@MainActor
protocol PermissionChecking: AnyObject {
    var microphone: PermissionState { get }
    var accessibility: PermissionState { get }
    func refresh()
}
