import AppKit
import CoreGraphics

/// Process-lifetime session truth established during app startup. Ephemeral
/// animated views can be created after a lock/sleep notification, so they must
/// not assume the user session and displays are currently active.
@MainActor
final class SystemSessionLifecycle {
    struct Snapshot: Equatable, Sendable {
        let sessionIsActive: Bool
        let screensAreAwake: Bool

        var isInteractionActive: Bool {
            sessionIsActive && screensAreAwake
        }
    }

    enum Signal: Equatable, Sendable {
        case sessionResigned
        case screensSlept
        case revalidate
    }

    static let shared = SystemSessionLifecycle()
    private static let loginWindowBundleIdentifier = "com.apple.loginwindow"

    private(set) var sessionIsActive = false
    private(set) var screensAreAwake = false
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var displayObservers: [NSObjectProtocol] = []
    private var activityObservers: [UUID: (Bool) -> Void] = [:]
    private var revalidationTask: Task<Void, Never>?
    private var revalidationGeneration: UInt64 = 0

    var isInteractionActive: Bool {
        sessionIsActive && screensAreAwake
    }

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyNegative(.sessionResigned)
                }
            },
            center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.revalidateUntilSettled()
                }
            },
            center.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyNegative(.screensSlept)
                }
            },
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.revalidateUntilSettled()
                }
            },
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.revalidateUntilSettled()
                }
            }
        ]
        displayObservers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.revalidateUntilSettled()
                }
            }
        ]

        // Notifications describe transitions, not current truth. Register them
        // first so a transition cannot fall between this process-lifetime
        // snapshot and observer installation.
        applySnapshot(Self.currentSnapshot())
        scheduleRevalidationRetries()
    }

    static func currentSnapshot() -> Snapshot {
        let dictionary = CGSessionCopyCurrentDictionary()
            as? [String: Any]
        let mainDisplay = CGMainDisplayID()
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmostIsLoginWindow = loginWindowState(
            bundleIdentifier: frontmostApplication?.bundleIdentifier,
            localizedName: frontmostApplication?.localizedName
        )
        return resolveSnapshot(
            sessionIsOnConsole: dictionary?[
                kCGSessionOnConsoleKey as String
            ] as? Bool,
            sessionLoginIsDone: dictionary?[
                kCGSessionLoginDoneKey as String
            ] as? Bool,
            frontmostIsLoginWindow: frontmostIsLoginWindow,
            mainDisplayIsOnline: CGDisplayIsOnline(mainDisplay) != 0,
            mainDisplayIsActive: CGDisplayIsActive(mainDisplay) != 0,
            mainDisplayIsAsleep: CGDisplayIsAsleep(mainDisplay) != 0
        )
    }

    static func loginWindowState(
        bundleIdentifier: String?,
        localizedName: String?
    ) -> Bool? {
        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            normalizedBundleIdentifier?.isEmpty == false
                || normalizedName?.isEmpty == false
        else {
            return nil
        }
        return normalizedBundleIdentifier == loginWindowBundleIdentifier
            || normalizedName?.caseInsensitiveCompare("loginwindow")
                == .orderedSame
    }

    static func resolveSnapshot(
        sessionIsOnConsole: Bool?,
        sessionLoginIsDone: Bool?,
        frontmostIsLoginWindow: Bool?,
        mainDisplayIsOnline: Bool,
        mainDisplayIsActive: Bool,
        mainDisplayIsAsleep: Bool
    ) -> Snapshot {
        let sessionIsActive = sessionIsOnConsole == true
            && sessionLoginIsDone == true
            && frontmostIsLoginWindow == false
        return Snapshot(
            sessionIsActive: sessionIsActive,
            screensAreAwake: mainDisplayIsOnline
                && mainDisplayIsActive
                && !mainDisplayIsAsleep
        )
    }

    static func resolve(
        _ signal: Signal,
        current: Snapshot,
        verifiedSnapshot: Snapshot? = nil
    ) -> Snapshot {
        switch signal {
        case .sessionResigned:
            Snapshot(
                sessionIsActive: false,
                screensAreAwake: current.screensAreAwake
            )
        case .screensSlept:
            Snapshot(
                sessionIsActive: current.sessionIsActive,
                screensAreAwake: false
            )
        case .revalidate:
            verifiedSnapshot
                ?? Snapshot(
                    sessionIsActive: false,
                    screensAreAwake: false
                )
        }
    }

    @discardableResult
    func observeActivity(
        _ observer: @escaping (Bool) -> Void
    ) -> UUID {
        let identifier = UUID()
        activityObservers[identifier] = observer
        observer(isInteractionActive)
        return identifier
    }

    func removeActivityObserver(_ identifier: UUID) {
        activityObservers[identifier] = nil
    }

    private func apply(
        _ signal: Signal,
        verifiedSnapshot: Snapshot? = nil
    ) {
        let current = Snapshot(
            sessionIsActive: sessionIsActive,
            screensAreAwake: screensAreAwake
        )
        applySnapshot(
            Self.resolve(
                signal,
                current: current,
                verifiedSnapshot: verifiedSnapshot
            )
        )
    }

    private func applyNegative(_ signal: Signal) {
        cancelRevalidation()
        apply(signal)
    }

    private func revalidateUntilSettled() {
        cancelRevalidation()
        apply(
            .revalidate,
            verifiedSnapshot: Self.currentSnapshot()
        )
        scheduleRevalidationRetries()
    }

    private func scheduleRevalidationRetries() {
        revalidationGeneration &+= 1
        let generation = revalidationGeneration
        revalidationTask = Task { @MainActor [weak self] in
            for delay in [
                Duration.milliseconds(50),
                Duration.milliseconds(200),
                Duration.milliseconds(600)
            ] {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard
                    let self,
                    generation == self.revalidationGeneration
                else {
                    return
                }
                self.apply(
                    .revalidate,
                    verifiedSnapshot: Self.currentSnapshot()
                )
                if self.isInteractionActive {
                    break
                }
            }
            guard
                let self,
                generation == self.revalidationGeneration
            else {
                return
            }
            self.revalidationTask = nil
        }
    }

    private func cancelRevalidation() {
        revalidationGeneration &+= 1
        revalidationTask?.cancel()
        revalidationTask = nil
    }

    private func applySnapshot(_ snapshot: Snapshot) {
        guard
            sessionIsActive != snapshot.sessionIsActive
                || screensAreAwake != snapshot.screensAreAwake
        else {
            return
        }
        sessionIsActive = snapshot.sessionIsActive
        screensAreAwake = snapshot.screensAreAwake
        notifyActivityObservers()
    }

    private func notifyActivityObservers() {
        let isActive = isInteractionActive
        let currentObservers = Array(activityObservers.values)
        for observer in currentObservers {
            observer(isActive)
        }
    }

    deinit {
        revalidationTask?.cancel()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in displayObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
