import Testing
@testable import CodexHUD

@MainActor
@Suite("System session lifecycle bootstrap")
struct SystemSessionLifecycleTests {
    @Test("Frontmost loginwindow keeps an on-console session inactive")
    func loginWindowIsConservative() {
        let snapshot = SystemSessionLifecycle.resolveSnapshot(
            sessionIsOnConsole: true,
            sessionLoginIsDone: true,
            frontmostIsLoginWindow: true,
            mainDisplayIsOnline: true,
            mainDisplayIsActive: true,
            mainDisplayIsAsleep: false
        )

        #expect(!snapshot.sessionIsActive)
        #expect(snapshot.screensAreAwake)
        #expect(!snapshot.isInteractionActive)
    }

    @Test("Only a logged-in console session outside loginwindow is active")
    func activeSessionRequiresEverySignal() {
        let active = SystemSessionLifecycle.resolveSnapshot(
            sessionIsOnConsole: true,
            sessionLoginIsDone: true,
            frontmostIsLoginWindow: false,
            mainDisplayIsOnline: true,
            mainDisplayIsActive: true,
            mainDisplayIsAsleep: false
        )
        let switchedUser = SystemSessionLifecycle.resolveSnapshot(
            sessionIsOnConsole: false,
            sessionLoginIsDone: true,
            frontmostIsLoginWindow: false,
            mainDisplayIsOnline: true,
            mainDisplayIsActive: true,
            mainDisplayIsAsleep: false
        )
        let unknownSession = SystemSessionLifecycle.resolveSnapshot(
            sessionIsOnConsole: nil,
            sessionLoginIsDone: nil,
            frontmostIsLoginWindow: nil,
            mainDisplayIsOnline: true,
            mainDisplayIsActive: true,
            mainDisplayIsAsleep: false
        )

        #expect(active.sessionIsActive)
        #expect(active.isInteractionActive)
        #expect(!switchedUser.sessionIsActive)
        #expect(!unknownSession.sessionIsActive)
    }

    @Test("An offline or sleeping main display is never interactive")
    func displayStateIsConservative() {
        let asleep = SystemSessionLifecycle.resolveSnapshot(
            sessionIsOnConsole: true,
            sessionLoginIsDone: true,
            frontmostIsLoginWindow: false,
            mainDisplayIsOnline: true,
            mainDisplayIsActive: false,
            mainDisplayIsAsleep: true
        )
        let offline = SystemSessionLifecycle.resolveSnapshot(
            sessionIsOnConsole: true,
            sessionLoginIsDone: true,
            frontmostIsLoginWindow: false,
            mainDisplayIsOnline: false,
            mainDisplayIsActive: false,
            mainDisplayIsAsleep: false
        )

        #expect(!asleep.screensAreAwake)
        #expect(!asleep.isInteractionActive)
        #expect(!offline.screensAreAwake)
        #expect(!offline.isInteractionActive)
    }

    @Test("An online awake display must also be drawable")
    func inactiveDisplayIsConservative() {
        let snapshot = SystemSessionLifecycle.resolveSnapshot(
            sessionIsOnConsole: true,
            sessionLoginIsDone: true,
            frontmostIsLoginWindow: false,
            mainDisplayIsOnline: true,
            mainDisplayIsActive: false,
            mainDisplayIsAsleep: false
        )

        #expect(!snapshot.screensAreAwake)
        #expect(!snapshot.isInteractionActive)
    }

    @Test("Missing frontmost identity fails closed")
    func missingFrontmostIdentityIsUnknown() {
        #expect(
            SystemSessionLifecycle.loginWindowState(
                bundleIdentifier: nil,
                localizedName: nil
            ) == nil
        )
        #expect(
            SystemSessionLifecycle.loginWindowState(
                bundleIdentifier: "  ",
                localizedName: ""
            ) == nil
        )
        #expect(
            SystemSessionLifecycle.loginWindowState(
                bundleIdentifier: "com.example.Editor",
                localizedName: nil
            ) == false
        )
        #expect(
            SystemSessionLifecycle.loginWindowState(
                bundleIdentifier: nil,
                localizedName: "loginwindow"
            ) == true
        )
    }

    @Test("Negative signals are immediate and positives require a snapshot")
    func lifecycleSignalReductionIsFailClosed() {
        let active = SystemSessionLifecycle.Snapshot(
            sessionIsActive: true,
            screensAreAwake: true
        )
        let inactive = SystemSessionLifecycle.Snapshot(
            sessionIsActive: false,
            screensAreAwake: false
        )

        #expect(
            SystemSessionLifecycle.resolve(
                .sessionResigned,
                current: active
            ) == .init(
                sessionIsActive: false,
                screensAreAwake: true
            )
        )
        #expect(
            SystemSessionLifecycle.resolve(
                .screensSlept,
                current: active
            ) == .init(
                sessionIsActive: true,
                screensAreAwake: false
            )
        )
        #expect(
            SystemSessionLifecycle.resolve(
                .revalidate,
                current: active
            ) == inactive
        )
        #expect(
            SystemSessionLifecycle.resolve(
                .revalidate,
                current: inactive,
                verifiedSnapshot: active
            ) == active
        )
    }
}
