import AppKit
import Foundation
import WebKit

enum RealtimeWebRTCFailure: Error, Equatable, Sendable {
    case pageLoadTimedOut
    case microphoneUnavailable(String)
    case invalidOffer
    case invalidAnswer
    case connectionFailed(String)
}

@MainActor
protocol RealtimeVoiceTransporting: AnyObject {
    var onFailure: (@MainActor (RealtimeWebRTCFailure) -> Void)? { get set }

    func start() async throws
    func prepareOffer() async throws -> String
    func acceptAnswer(_ sdp: String) async throws
    func interrupt() async throws
    func confirmMediaMuted() async throws
    func setMicrophoneMuted(_ muted: Bool)
    func setOutputMuted(_ muted: Bool)
    func stop()
}

@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: RealtimeWebRTCTransport?

    init(target: RealtimeWebRTCTransport) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.receiveScriptMessage(message)
    }
}

/// WebRTC is the subscription-preserving media path used by Codex Desktop.
///
/// Codex's websocket realtime path currently requires separate API-key auth.
/// Its WebRTC path deliberately delegates authentication to the official
/// desktop app-server, so this narrowly-scoped hidden web view supplies only
/// RTCPeerConnection and media transport. It neither records audio nor stores
/// transcripts.
@MainActor
final class RealtimeWebRTCTransport:
    NSObject,
    AudioMetering,
    RealtimeVoiceTransporting
{
    private(set) var level: Double = 0
    var onFailure: (@MainActor (RealtimeWebRTCFailure) -> Void)?

    private enum PeerState {
        case idle
        case preparing
        case offered(String)
        case connected
    }

    private var webView: WKWebView?
    private var mediaWindow: NSPanel?
    private var messageHandler: WeakScriptMessageHandler?
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    private var isPageReady = false
    private var peerState: PeerState = .idle
    private var readinessWaiters: [
        UUID: CheckedContinuation<Void, Error>
    ] = [:]
    private var muteConfirmationWaiters: [
        UUID: CheckedContinuation<Void, Error>
    ] = [:]

    override init() {
        super.init()
    }

    func start() async throws {
        switch peerState {
        case .idle:
            _ = try await prepareOffer()
        case .preparing, .offered, .connected:
            return
        }
    }

    func prepareOffer() async throws -> String {
        switch peerState {
        case let .offered(offer):
            return offer
        case .connected:
            throw RealtimeWebRTCFailure.invalidOffer
        case .preparing:
            throw RealtimeWebRTCFailure.connectionFailed(
                "A realtime WebRTC offer is already being prepared."
            )
        case .idle:
            peerState = .preparing
            do {
                let offer = try await makeOffer()
                peerState = .offered(offer)
                return offer
            } catch {
                peerState = .idle
                throw error
            }
        }
    }

    func acceptAnswer(_ sdp: String) async throws {
        guard
            case .offered = peerState,
            let webView,
            !sdp.isEmpty
        else {
            throw RealtimeWebRTCFailure.invalidAnswer
        }

        do {
            _ = try await webView.callAsyncJavaScript(
                "return await CodexHUD.acceptAnswer(sdp);",
                arguments: ["sdp": sdp],
                in: nil,
                contentWorld: .page
            )
            peerState = .connected
        } catch {
            peerState = .idle
            throw RealtimeWebRTCFailure.connectionFailed(error.localizedDescription)
        }
    }

    func interrupt() async throws {
        guard let webView else {
            throw RealtimeWebRTCFailure.connectionFailed(
                "The realtime media channel is unavailable."
            )
        }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return CodexHUD.interrupt();",
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            let succeeded = (result as? Bool)
                ?? (result as? NSNumber)?.boolValue
                ?? false
            guard succeeded else {
                throw RealtimeWebRTCFailure.connectionFailed(
                    "The realtime event channel is not open."
                )
            }
        } catch let failure as RealtimeWebRTCFailure {
            throw failure
        } catch {
            throw RealtimeWebRTCFailure.connectionFailed(error.localizedDescription)
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        guard let webView else {
            if !muted {
                reportFailure(
                    .connectionFailed("The realtime media page is unavailable.")
                )
            }
            return
        }
        webView.evaluateJavaScript(
            "CodexHUD.setMicrophoneMuted(\(muted ? "true" : "false"));"
        ) { [weak self, weak webView] _, error in
            guard let error else { return }
            Task { @MainActor [weak self, weak webView] in
                guard
                    let self,
                    let webView,
                    self.webView === webView
                else {
                    return
                }
                self.reportFailure(
                    .connectionFailed(error.localizedDescription)
                )
            }
        }
    }

    func setOutputMuted(_ muted: Bool) {
        guard let webView else {
            if !muted {
                reportFailure(
                    .connectionFailed("The realtime media page is unavailable.")
                )
            }
            return
        }
        webView.evaluateJavaScript(
            "CodexHUD.setOutputMuted(\(muted ? "true" : "false"));"
        ) { [weak self, weak webView] _, error in
            guard let error else { return }
            Task { @MainActor [weak self, weak webView] in
                guard
                    let self,
                    let webView,
                    self.webView === webView
                else {
                    return
                }
                self.reportFailure(
                    .connectionFailed(error.localizedDescription)
                )
            }
        }
    }

    func confirmMediaMuted() async throws {
        guard let webView else {
            // No media surface means there is no capture or playback to mute.
            return
        }
        let waiterID = UUID()
        try await withCheckedThrowingContinuation { continuation in
            muteConfirmationWaiters[waiterID] = continuation
            webView.evaluateJavaScript(
                "CodexHUD.confirmMediaMuted();"
            ) { [weak self, weak webView] result, error in
                Task { @MainActor [weak self, weak webView] in
                    guard
                        let self,
                        let webView,
                        self.webView === webView
                    else {
                        return
                    }
                    if let error {
                        self.finishMuteConfirmation(
                            waiterID,
                            result: .failure(
                                .connectionFailed(error.localizedDescription)
                            )
                        )
                        return
                    }
                    let confirmed = (result as? Bool)
                        ?? (result as? NSNumber)?.boolValue
                        ?? false
                    self.finishMuteConfirmation(
                        waiterID,
                        result: confirmed
                            ? .success(())
                            : .failure(
                                .connectionFailed(
                                    "The media page did not confirm mute."
                                )
                            )
                    )
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.finishMuteConfirmation(
                    waiterID,
                    result: .failure(
                        .connectionFailed(
                            "Timed out while confirming microphone pause."
                        )
                    )
                )
            }
        }
    }

    func stop() {
        peerState = .idle
        level = 0
        webView?.evaluateJavaScript("CodexHUD.stop();")
        teardownMediaSurface()
    }

    private func makeOffer() async throws -> String {
        try await waitUntilPageReady()
        guard let webView else {
            throw RealtimeWebRTCFailure.invalidOffer
        }

        do {
            let result = try await webView.callAsyncJavaScript(
                "return await CodexHUD.prepare();",
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            guard let offer = result as? String, !offer.isEmpty else {
                throw RealtimeWebRTCFailure.invalidOffer
            }
            return offer
        } catch let failure as RealtimeWebRTCFailure {
            throw failure
        } catch {
            throw RealtimeWebRTCFailure.microphoneUnavailable(
                error.localizedDescription
            )
        }
    }

    private func waitUntilPageReady() async throws {
        ensureWebView()
        if isPageReady {
            return
        }

        let waiterID = UUID()
        try await withCheckedThrowingContinuation { continuation in
            readinessWaiters[waiterID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, let waiter = self.readinessWaiters.removeValue(
                    forKey: waiterID
                ) else {
                    return
                }
                waiter.resume(throwing: RealtimeWebRTCFailure.pageLoadTimedOut)
            }
        }
    }

    private func ensureWebView() {
        guard webView == nil else {
            repositionMediaWindow()
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        let messageHandler = WeakScriptMessageHandler(target: self)
        configuration.userContentController.add(
            messageHandler,
            name: Self.messageHandlerName
        )

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 2, height: 2),
            configuration: configuration
        )
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityElement(false)

        let mediaOrigin = NSScreen.main?.frame.origin ?? .zero
        let window = NSPanel(
            contentRect: NSRect(
                x: mediaOrigin.x + 1,
                y: mediaOrigin.y + 1,
                width: 2,
                height: 2
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.001
        window.ignoresMouseEvents = true
        window.setAccessibilityElement(false)
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        window.contentView = webView
        window.orderBack(nil)

        self.webView = webView
        self.messageHandler = messageHandler
        mediaWindow = window
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionMediaWindow()
            }
        }
        webView.loadHTMLString(
            Self.transportPage,
            baseURL: URL(string: "https://codex-hud.invalid/")
        )
    }

    private func repositionMediaWindow() {
        guard let mediaWindow else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            mediaWindow.orderOut(nil)
            return
        }
        mediaWindow.setFrame(
            NSRect(
                x: screen.frame.minX + 1,
                y: screen.frame.minY + 1,
                width: 2,
                height: 2
            ),
            display: false
        )
        if !mediaWindow.isVisible {
            mediaWindow.orderBack(nil)
        }
    }

    private func markPageReady() {
        guard !isPageReady else { return }
        isPageReady = true
        let waiters = readinessWaiters.values
        readinessWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func failReadiness(_ message: String) {
        let waiters = readinessWaiters.values
        readinessWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(
                throwing: RealtimeWebRTCFailure.connectionFailed(message)
            )
        }
    }

    private func finishMuteConfirmation(
        _ identifier: UUID,
        result: Result<Void, RealtimeWebRTCFailure>
    ) {
        guard let waiter = muteConfirmationWaiters.removeValue(
            forKey: identifier
        ) else {
            return
        }
        switch result {
        case .success:
            waiter.resume()
        case let .failure(failure):
            waiter.resume(throwing: failure)
        }
    }

    private func teardownMediaSurface() {
        isPageReady = false
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }

        let failure = RealtimeWebRTCFailure.connectionFailed(
            "The realtime media surface stopped."
        )
        let pageWaiters = readinessWaiters.values
        readinessWaiters.removeAll()
        for waiter in pageWaiters {
            waiter.resume(throwing: failure)
        }
        let muteWaiters = muteConfirmationWaiters.values
        muteConfirmationWaiters.removeAll()
        for waiter in muteWaiters {
            waiter.resume(throwing: failure)
        }

        guard let webView else {
            mediaWindow?.orderOut(nil)
            mediaWindow?.close()
            mediaWindow = nil
            messageHandler = nil
            return
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.messageHandlerName)
        mediaWindow?.contentView = nil
        mediaWindow?.orderOut(nil)
        mediaWindow?.close()
        mediaWindow = nil
        self.webView = nil
        messageHandler = nil
    }

    fileprivate func reportFailure(_ failure: RealtimeWebRTCFailure) {
        peerState = .idle
        level = 0
        if case let .connectionFailed(message) = failure {
            failReadiness(message)
        }
        teardownMediaSurface()
        onFailure?(failure)
    }

    fileprivate func receiveScriptMessage(_ message: WKScriptMessage) {
        guard
            let payload = message.body as? [String: Any],
            let type = payload["type"] as? String
        else {
            return
        }

        switch type {
        case "ready":
            markPageReady()
        case "level":
            if let value = payload["value"] as? NSNumber {
                level = min(max(value.doubleValue, 0), 1)
            }
        case "error":
            let detail = payload["message"] as? String
                ?? "The WebRTC media page failed."
            reportFailure(.connectionFailed(detail))
        default:
            break
        }
    }
}

extension RealtimeWebRTCTransport: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        reportFailure(.connectionFailed(error.localizedDescription))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        reportFailure(.connectionFailed(error.localizedDescription))
    }
}

extension RealtimeWebRTCTransport: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        let isExpectedOrigin = origin.protocol == "https"
            && origin.host == "codex-hud.invalid"
        let isMicrophoneOnly = type == .microphone
        decisionHandler(isExpectedOrigin && isMicrophoneOnly ? .grant : .deny)
    }
}

private extension RealtimeWebRTCTransport {
    static let messageHandlerName = "codexHUD"

    static let transportPage = #"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta
        http-equiv="Content-Security-Policy"
        content="default-src 'none'; script-src 'unsafe-inline'; media-src blob: mediastream:">
    </head>
    <body>
      <audio id="remote-audio" autoplay playsinline></audio>
      <script>
        (() => {
          const bridge = window.webkit.messageHandlers.codexHUD;
          const remoteAudio = document.getElementById("remote-audio");
          let peer = null;
          let inputStream = null;
          let events = null;
          let audioContext = null;
          let inputAnalyser = null;
          let outputAnalyser = null;
          let meterTimer = null;
          let lastPostedLevel = 0;
          let microphoneMuted = true;
          let outputMuted = true;

          const post = payload => bridge.postMessage(payload);

          const rms = analyser => {
            if (!analyser) return 0;
            const values = new Float32Array(analyser.fftSize);
            analyser.getFloatTimeDomainData(values);
            let sum = 0;
            for (const value of values) sum += value * value;
            return Math.sqrt(sum / values.length);
          };

          const startMeter = () => {
            if (meterTimer !== null) clearInterval(meterTimer);
            const sample = () => {
              if (microphoneMuted && outputMuted) {
                if (lastPostedLevel !== 0) {
                  lastPostedLevel = 0;
                  post({type: "level", value: 0});
                }
                return;
              }
              const inputLevel = microphoneMuted ? 0 : rms(inputAnalyser);
              const outputLevel = outputMuted ? 0 : rms(outputAnalyser);
              const raw = Math.max(inputLevel, outputLevel);
              const normalized = Math.min(1, Math.max(0, raw * 5.5));
              if (Math.abs(normalized - lastPostedLevel) >= 0.003) {
                lastPostedLevel = normalized;
                post({type: "level", value: normalized});
              }
            };
            sample();
            meterTimer = setInterval(sample, 33);
          };

          const stopMeter = () => {
            if (meterTimer !== null) clearInterval(meterTimer);
            meterTimer = null;
            if (lastPostedLevel !== 0) {
              lastPostedLevel = 0;
              post({type: "level", value: 0});
            }
          };

          const updateMeterLifecycle = () => {
            if (microphoneMuted && outputMuted) {
              stopMeter();
            } else if (peer && meterTimer === null) {
              startMeter();
            }
          };

          const waitForIce = pc => new Promise(resolve => {
            if (pc.iceGatheringState === "complete") {
              resolve();
              return;
            }
            const timeout = setTimeout(resolve, 3000);
            const listener = () => {
              if (pc.iceGatheringState !== "complete") return;
              clearTimeout(timeout);
              pc.removeEventListener("icegatheringstatechange", listener);
              resolve();
            };
            pc.addEventListener("icegatheringstatechange", listener);
          });

          const stop = () => {
            stopMeter();
            if (inputStream) {
              for (const track of inputStream.getTracks()) track.stop();
            }
            inputStream = null;
            if (peer) peer.close();
            peer = null;
            events = null;
            inputAnalyser = null;
            outputAnalyser = null;
            microphoneMuted = true;
            outputMuted = true;
            remoteAudio.pause();
            remoteAudio.muted = true;
            remoteAudio.srcObject = null;
            if (audioContext) audioContext.close().catch(() => {});
            audioContext = null;
          };

          const prepare = async () => {
            stop();
            inputStream = await navigator.mediaDevices.getUserMedia({
              audio: {
                autoGainControl: true,
                channelCount: 1,
                echoCancellation: true,
                noiseSuppression: true
              },
              video: false
            });
            for (const track of inputStream.getAudioTracks()) {
              // getUserMedia begins capture immediately. Disable every input
              // before the next await; realtime/started is the only unmute.
              track.enabled = false;
            }

            audioContext = new AudioContext();
            await audioContext.resume();
            inputAnalyser = audioContext.createAnalyser();
            inputAnalyser.fftSize = 512;
            audioContext
              .createMediaStreamSource(inputStream)
              .connect(inputAnalyser);

            peer = new RTCPeerConnection();
            for (const track of inputStream.getAudioTracks()) {
              peer.addTrack(track, inputStream);
            }
            events = peer.createDataChannel("oai-events");

            peer.ontrack = event => {
              const stream = event.streams[0]
                ?? new MediaStream([event.track]);
              remoteAudio.srcObject = stream;
              remoteAudio.play().catch(() => {});
              outputAnalyser = audioContext.createAnalyser();
              outputAnalyser.fftSize = 512;
              audioContext
                .createMediaStreamSource(stream)
                .connect(outputAnalyser);
            };

            peer.onconnectionstatechange = () => {
              const state = peer?.connectionState ?? "closed";
              if (state === "failed") {
                post({
                  type: "error",
                  message: "The realtime WebRTC connection failed."
                });
              }
            };

            const offer = await peer.createOffer({
              offerToReceiveAudio: true
            });
            await peer.setLocalDescription(offer);
            await waitForIce(peer);
            updateMeterLifecycle();
            return peer.localDescription.sdp;
          };

          const acceptAnswer = async sdp => {
            if (!peer) throw new Error("No pending realtime peer.");
            await peer.setRemoteDescription({type: "answer", sdp});
            await remoteAudio.play().catch(() => {});
            return true;
          };

          const interrupt = () => {
            // Silence playback before the cancellation round trip.
            outputMuted = true;
            remoteAudio.muted = true;
            if (events?.readyState === "open") {
              events.send(JSON.stringify({type: "response.cancel"}));
              return true;
            }
            return false;
          };

          const setMicrophoneMuted = muted => {
            microphoneMuted = muted;
            for (const track of inputStream?.getAudioTracks() ?? []) {
              track.enabled = !muted;
            }
            updateMeterLifecycle();
            return true;
          };

          const setOutputMuted = muted => {
            outputMuted = muted;
            remoteAudio.muted = muted;
            updateMeterLifecycle();
            return true;
          };

          const confirmMediaMuted = () => {
            setMicrophoneMuted(true);
            setOutputMuted(true);
            const tracksStopped = [
              ...(inputStream?.getAudioTracks() ?? [])
            ].every(track => !track.enabled);
            return microphoneMuted
              && outputMuted
              && tracksStopped
              && remoteAudio.muted;
          };

          window.CodexHUD = {
            acceptAnswer,
            interrupt,
            prepare,
            confirmMediaMuted,
            setMicrophoneMuted,
            setOutputMuted,
            stop
          };
          post({type: "ready"});
        })();
      </script>
    </body>
    </html>
    """#
}
