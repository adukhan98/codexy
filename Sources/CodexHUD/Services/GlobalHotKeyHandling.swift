import Foundation

@MainActor
protocol GlobalHotKeyHandling: AnyObject {
    var shortcutDescription: String { get }
    func register(action: @escaping @MainActor () -> Void) throws
    func unregister()
}
enum GlobalHotKeyFailure: Error, Equatable, Sendable {
    case registrationFailed
    case shortcutUnavailable
}
