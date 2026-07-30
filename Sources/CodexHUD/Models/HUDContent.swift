import Foundation

struct HUDContent: Equatable, Sendable {
    var eyebrow: String?
    var title: String
    var detail: String?
    var primaryActionTitle: String?
    var secondaryActionTitle: String?

    static let dormant = HUDContent(
        eyebrow: nil,
        title: "Codex ready",
        detail: nil,
        primaryActionTitle: nil,
        secondaryActionTitle: nil
    )
}
