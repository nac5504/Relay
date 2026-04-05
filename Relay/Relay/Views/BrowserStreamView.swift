import SwiftUI
import WebKit

/// Displays a live noVNC stream from a Docker container in a WKWebView.
/// Mouse and keyboard input is forwarded automatically by noVNC.
struct BrowserStreamView: NSViewRepresentable {
    let agent: BrowserAgent
    var onFPSUpdate: ((Double) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Hide noVNC header bar
        let hideHeaderScript = WKUserScript(
            source: Self.hideHeaderJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(hideHeaderScript)

        // FPS measurement script
        let fpsScript = WKUserScript(
            source: Self.fpsMonitorJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(fpsScript)
        config.userContentController.add(context.coordinator, name: "fpsReport")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        if let url = agent.noVNCURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let url = agent.noVNCURL else { return }
        // Reload if no URL loaded yet or port changed
        let currentPort = webView.url?.port
        if currentPort == nil || currentPort != agent.noVNCPort {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFPSUpdate: onFPSUpdate)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onFPSUpdate: ((Double) -> Void)?

        init(onFPSUpdate: ((Double) -> Void)?) {
            self.onFPSUpdate = onFPSUpdate
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let dict = message.body as? [String: Any] else { return }
            if let debug = dict["debug"] as? String {
                print("[noVNC] \(debug)")
            }
            if let fps = dict["fps"] as? Double, fps > 0 {
                Task { @MainActor in
                    self.onFPSUpdate?(fps)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // noVNC loaded
        }

        // Allow localhost connections without TLS
        func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if challenge.protectionSpace.host == "localhost" {
                return (.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
            }
            return (.performDefaultHandling, nil)
        }
    }

    /// Hides noVNC header bar only — does NOT touch canvas sizing
    private static let hideHeaderJS = """
    (function() {
        var style = document.createElement('style');
        style.textContent = `
            #top_bar { display: none !important; height: 0 !important; }
            #status { display: none !important; }
            body { margin: 0 !important; background: #1a1a1a !important; }
        `;
        document.head.appendChild(style);
    })();
    """

    /// Logs VNC connection state and auto-reconnects
    private static let autoReconnectJS = """
    (function() {
        var retries = 0;
        var maxRetries = 30;

        function log(msg) {
            try { window.webkit.messageHandlers.fpsReport.postMessage({debug: msg, fps: 0}); } catch(e) {}
        }

        function checkAndReconnect() {
            if (retries >= maxRetries) return;

            var rfb = window.rfb;
            if (!rfb) {
                retries++;
                log('noVNC: no RFB object yet (attempt ' + retries + ')');
                setTimeout(checkAndReconnect, 2000);
                return;
            }

            var state = rfb._rfbConnectionState;
            log('noVNC state: ' + state);

            if (state === 'disconnected') {
                retries++;
                log('noVNC: reconnecting (attempt ' + retries + ')');
                window.location.reload();
            } else if (state === 'connected') {
                retries = 0;
            }

            setTimeout(checkAndReconnect, 3000);
        }

        setTimeout(checkAndReconnect, 2000);
    })();
    """

    /// Measures the actual rendering frame rate of the noVNC canvas
    private static let fpsMonitorJS = """
    (function() {
        let frameCount = 0;
        let lastTime = performance.now();

        function measureFPS() {
            frameCount++;
            const now = performance.now();
            if (now - lastTime >= 1000) {
                const fps = (frameCount * 1000) / (now - lastTime);
                try {
                    window.webkit.messageHandlers.fpsReport.postMessage({
                        fps: parseFloat(fps.toFixed(1))
                    });
                } catch(e) {}
                frameCount = 0;
                lastTime = now;
            }
            requestAnimationFrame(measureFPS);
        }
        requestAnimationFrame(measureFPS);
    })();
    """
}
