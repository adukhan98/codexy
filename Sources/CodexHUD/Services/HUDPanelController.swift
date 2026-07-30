import AppKit
import SwiftUI

@MainActor
final class HUDPanelController: HUDPresenting {
    private let panel: HUDPanel
    private var currentPhase: HUDPhase = .dormant
    private var previousFrontmostApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var isKeyboardFocusMode = false
    private var isRequestedVisible = false
    private var systemInteractionIsActive = false
    private var systemActivityObserver: UUID?
    nonisolated(unsafe) private var screenObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var pointerMonitors: [Any] = []

    init() {
        let lifecycle = SystemSessionLifecycle.shared
        panel = HUDPanel(
            contentRect: NSRect(
                origin: .zero,
                size: HUDPhase.dormant.hudWindowSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        configurePanel()
        rememberExternalApplication(
            NSWorkspace.shared.frontmostApplication
        )
        observeScreenChanges()
        observeApplicationActivation()
        observeSystemActivity(lifecycle)
        observePointerLocation()
    }

    deinit {
        if let systemActivityObserver {
            Task { @MainActor in
                SystemSessionLifecycle.shared.removeActivityObserver(
                    systemActivityObserver
                )
            }
        }
        for observer in screenObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for monitor in pointerMonitors {
            NSEvent.removeMonitor(monitor)
        }
    }

    func install<Content: View>(@ViewBuilder content: () -> Content) {
        let hostingView = NSHostingView(rootView: content())
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(
            frame: NSRect(
                origin: .zero,
                size: HUDPhase.dormant.hudWindowSize
            )
        )
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        panel.contentView = container
        reposition()
    }

    func show() {
        isRequestedVisible = true
        guard systemInteractionIsActive else {
            panel.orderOut(nil)
            return
        }
        reposition()
        panel.orderFrontRegardless()
        refreshMousePassthrough()
    }

    func hide() {
        isRequestedVisible = false
        releaseKeyboardFocus()
        panel.orderOut(nil)
    }

    func reposition() {
        guard let screen = targetScreen() else { return }
        let frame = HUDPanelGeometry.windowFrame(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            phase: currentPhase
        )
        panel.setFrame(frame, display: true)
        refreshMousePassthrough()
    }

    func updateLayout(for phase: HUDPhase, animated: Bool) {
        currentPhase = phase
        guard let screen = targetScreen() else { return }

        let targetFrame = HUDPanelGeometry.windowFrame(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            phase: phase
        )

        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DesignMetrics.animationResponse
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.22,
                    0.86,
                    0.30,
                    1.0
                )
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }
        refreshMousePassthrough()
    }

    func focusControls() {
        guard
            currentPhase.isExpanded,
            isRequestedVisible,
            systemInteractionIsActive
        else {
            return
        }
        if !isKeyboardFocusMode {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousFrontmostApplication = isExternal(frontmost)
                ? frontmost
                : lastExternalApplication
        }
        isKeyboardFocusMode = true
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
    }

    func releaseKeyboardFocus() {
        guard isKeyboardFocusMode else { return }
        isKeyboardFocusMode = false
        if panel.isKeyWindow {
            panel.resignKey()
        }

        if let previousFrontmostApplication {
            let current = NSWorkspace.shared.frontmostApplication
            let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
            if current?.processIdentifier == ownProcessIdentifier
                || current?.processIdentifier
                    == previousFrontmostApplication.processIdentifier
            {
                previousFrontmostApplication.activate(options: [])
            }
        }
        previousFrontmostApplication = nil
        refreshMousePassthrough()
    }

    private func configurePanel() {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.isReleasedWhenClosed = false
        panel.worksWhenModal = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.setAccessibilityTitle("Codex voice HUD")
    }

    private func observeScreenChanges() {
        let center = NotificationCenter.default
        screenObservers = [
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reposition()
                }
            },
            center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reposition()
                }
            }
        ]
    }

    private func observeApplicationActivation() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.rememberExternalApplication(
                        NSWorkspace.shared.frontmostApplication
                    )
                }
            }
        )
    }

    private func observeSystemActivity(
        _ lifecycle: SystemSessionLifecycle
    ) {
        systemActivityObserver = lifecycle.observeActivity {
            [weak self] isActive in
            self?.setSystemInteractionActive(isActive)
        }
    }

    private func setSystemInteractionActive(_ isActive: Bool) {
        systemInteractionIsActive = isActive
        guard isActive else {
            releaseKeyboardFocus()
            panel.orderOut(nil)
            return
        }
        restoreRequestedVisibility()
    }

    private func restoreRequestedVisibility() {
        guard isRequestedVisible, systemInteractionIsActive else {
            return
        }
        reposition()
        panel.orderFrontRegardless()
        refreshMousePassthrough()
    }

    private func rememberExternalApplication(
        _ application: NSRunningApplication?
    ) {
        guard isExternal(application) else { return }
        lastExternalApplication = application
    }

    private func isExternal(
        _ application: NSRunningApplication?
    ) -> Bool {
        guard let application, !application.isTerminated else {
            return false
        }
        guard application.bundleIdentifier != "com.apple.loginwindow" else {
            return false
        }
        return application.processIdentifier
            != ProcessInfo.processInfo.processIdentifier
    }

    private func observePointerLocation() {
        let globalHandler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.refreshMousePassthrough()
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged],
            handler: globalHandler
        ) {
            pointerMonitors.append(global)
        }

        let localHandler: (NSEvent) -> NSEvent? = { [weak self] event in
            MainActor.assumeIsolated {
                self?.refreshMousePassthrough()
            }
            return event
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged],
            handler: localHandler
        ) {
            pointerMonitors.append(local)
        }
    }

    private func refreshMousePassthrough() {
        guard !isKeyboardFocusMode else {
            panel.ignoresMouseEvents = false
            return
        }

        let localPoint = panel.convertPoint(
            fromScreen: NSEvent.mouseLocation
        )
        panel.ignoresMouseEvents = !HUDPanelGeometry
            .surfaceFrame(for: currentPhase)
            .contains(localPoint)
    }

    private func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? panel.screen
            ?? NSScreen.main
    }

}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum HUDPanelGeometry {
    static func windowFrame(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        phase: HUDPhase
    ) -> CGRect {
        let windowSize = phase.hudWindowSize
        let surfaceTopInset = max(
            DesignMetrics.screenTopInset,
            safeAreaTop
        )
        return CGRect(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.maxY
                + phase.hudShadowTopPadding
                - surfaceTopInset
                - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    static func surfaceFrame(for phase: HUDPhase) -> CGRect {
        CGRect(
            x: DesignMetrics.shadowHorizontalPadding,
            y: phase.hudShadowBottomPadding,
            width: phase.hudVisualSize.width,
            height: phase.hudVisualSize.height
        )
    }
}
