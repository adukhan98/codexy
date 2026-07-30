import Foundation

@MainActor
protocol HUDPresenting: AnyObject {
    func show()
    func hide()
    func reposition()
    func updateLayout(for phase: HUDPhase, animated: Bool)
    func focusControls()
    func releaseKeyboardFocus()
}
