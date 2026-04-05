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

        // Hide noVNC header and make canvas fill
        let hideHeaderScript = WKUserScript(
            source: Self.hideHeaderJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(hideHeaderScript)

        // Auto-reconnect script: monitors noVNC connection state and retries on failure
        let reconnectScript = WKUserScript(
            source: Self.autoReconnectJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(reconnectScript)

        // FPS measurement script
        let fpsScript = WKUserScript(
            source: Self.fpsMonitorJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(fpsScript)
        config.userContentController.add(context.coordinator, name: "fpsReport")

        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        if let url = agent.noVNCURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Don't reload if already loading or loaded with the correct port
        guard let currentPort = webView.url?.port, currentPort != agent.noVNCPort else { return }
        if let url = agent.noVNCURL {
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
            guard let dict = message.body as? [String: Any],
                  let fps = dict["fps"] as? Double else { return }
            Task { @MainActor in
                self.onFPSUpdate?(fps)
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

    /// Hides noVNC chrome and makes canvas fill the view
    private static let hideHeaderJS = """
    (function() {
        var style = document.createElement('style');
        style.textContent = `
            #top_bar { display: none !important; }
            #status { display: none !important; }
            #noVNC_control_bar { display: none !important; }
            #noVNC_status_bar { display: none !important; }
            body { margin: 0 !important; overflow: hidden !important; background: #1a1a1a !important; }
            #noVNC_container { width: 100vw !important; height: 100vh !important; }
            #noVNC_screen { width: 100vw !important; height: 100vh !important; }
            #screen { position: fixed !important; top: 0 !important; left: 0 !important; width: 100vw !important; height: 100vh !important; }
            canvas { width: 100% !important; height: 100% !important; object-fit: contain !important; }
        `;
        document.head.appendChild(style);
    })();
    """

    /// Monitors noVNC connection state and forces reconnect on initial failure
    private static let autoReconnectJS = """
    (function() {
        let retryCount = 0;
        const maxRetries = 20;
        const retryInterval = 1500;

        function tryConnect() {
            if (retryCount >= maxRetries) return;
            // noVNC exposes its UI object on the page
            const connectBtn = document.getElementById('noVNC_connect_button');
            const statusEl = document.querySelector('#noVNC_status');
            const isDisconnected = document.querySelector('.noVNC_status_error') ||
                                   (statusEl && statusEl.textContent.toLowerCase().includes('disconnect')) ||
                                   (statusEl && statusEl.textContent.toLowerCase().includes('failed'));

            if (connectBtn && isDisconnected) {
                retryCount++;
                connectBtn.click();
            }
        }

        // Poll for disconnection/failure and auto-click connect
        setInterval(tryConnect, retryInterval);
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
