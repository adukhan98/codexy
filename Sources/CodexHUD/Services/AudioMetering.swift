import Foundation

@MainActor
protocol AudioMetering: AnyObject {
    var level: Double { get }
    func start() async throws
    func stop()
}
