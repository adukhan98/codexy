import AppKit
import QuartzCore

/// Pauses the compositor-only orb animations whenever their panel cannot be
/// seen. This prevents an infinite animation from consuming GPU time while
/// the user session is locked, the display sleeps, or the HUD is ordered out.
@MainActor
final class AnimatedOrbRootView: NSView {
    private var systemActivityObserver: UUID?
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    private var systemInteractionIsActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
        observeSystemActivity()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
        observeSystemActivity()
    }

    deinit {
        if let systemActivityObserver {
            Task { @MainActor in
                SystemSessionLifecycle.shared.removeActivityObserver(
                    systemActivityObserver
                )
            }
        }
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowLifecycle()
        DispatchQueue.main.async { [weak self] in
            self?.refreshAnimationState()
        }
    }

    private func observeSystemActivity() {
        systemActivityObserver = SystemSessionLifecycle.shared.observeActivity {
            [weak self] isActive in
            self?.systemInteractionIsActive = isActive
            self?.refreshAnimationState()
        }
    }

    private func observeWindowLifecycle() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        guard let window else {
            refreshAnimationState()
            return
        }

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification
        ]
        windowObservers = names.map { name in
            center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshAnimationState()
                }
            }
        }
    }

    private func refreshAnimationState() {
        let windowIsVisible = window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
        setAnimationsPaused(
            !systemInteractionIsActive || !windowIsVisible
        )
    }

    private func setAnimationsPaused(_ paused: Bool) {
        guard let layer else { return }
        if paused {
            guard layer.speed != 0 else { return }
            let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = pausedTime
        } else {
            guard layer.speed == 0 else { return }
            let pausedTime = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            let resumedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.beginTime = resumedTime - pausedTime
        }
    }
}
