import SwiftUI
import WebKit

/// Displays a live noVNC stream from a Docker container in a WKWebView.
/// Fetches the noVNC page via URLSession (bypassing WKWebView sandbox)
/// then injects it via loadHTMLString so WebSocket connections work.
struct BrowserStreamView: NSViewRepresentable {
    let agent: BrowserAgent
    var onFPSUpdate: ((Double) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        config.userContentController.add(context.coordinator, name: "fpsReport")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        if agent.noVNCPort > 0 {
            context.coordinator.loadNoVNC(port: agent.noVNCPort)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard agent.noVNCPort > 0 else { return }
        if context.coordinator.currentPort == agent.noVNCPort { return }
        context.coordinator.loadNoVNC(port: agent.noVNCPort)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFPSUpdate: onFPSUpdate)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onFPSUpdate: ((Double) -> Void)?
        weak var webView: WKWebView?
        var currentPort: Int = 0

        init(onFPSUpdate: ((Double) -> Void)?) {
            self.onFPSUpdate = onFPSUpdate
        }

        /// Fetch noVNC HTML via URLSession, then inject into WebView
        func loadNoVNC(port: Int) {
            currentPort = port
            let baseURL = URL(string: "http://localhost:\(port)")!
            let pageURL = baseURL.appendingPathComponent("vnc_lite.html")

            Task {
                do {
                    // Fetch the HTML ourselves (not through the sandboxed WebContent)
                    let (data, _) = try await URLSession.shared.data(from: pageURL)
                    guard var html = String(data: data, encoding: .utf8) else { return }

                    // Inject connection params into the page
                    let connectScript = """
                    <script>
                    // Override WebUtil.getConfigVar to inject our params
                    window.addEventListener('load', function() {
                        // noVNC lite uses URL params — set them via the RFB object
                        setTimeout(function() {
                            if (typeof rfb !== 'undefined') {
                                // Already connected or connecting
                            }
                        }, 500);
                    });
                    </script>
                    """

                    // Add autoconnect params to the URL that vnc_lite reads
                    // vnc_lite.html reads params from the page URL, but since we're
                    // loading via loadHTMLString, we inject them directly
                    html = html.replacingOccurrences(
                        of: "</head>",
                        with: """
                        <script>
                        // Patch WebUtil.getConfigVar for loadHTMLString context
                        (function() {
                            const params = {
                                host: 'localhost',
                                port: '\(port)',
                                path: 'websockify',
                                autoconnect: 'true',
                                resize: 'scale',
                                encrypt: 'false'
                            };
                            const origGetConfig = window.WebUtil && window.WebUtil.getConfigVar;
                            if (window.WebUtil) {
                                window.WebUtil.getConfigVar = function(name, defVal) {
                                    return params[name] || (origGetConfig ? origGetConfig(name, defVal) : defVal);
                                };
                            }
                            // Also patch URLSearchParams for scripts that use it
                            const origGet = URLSearchParams.prototype.get;
                            URLSearchParams.prototype.get = function(name) {
                                return params[name] || origGet.call(this, name);
                            };
                        })();
                        </script>
                        </head>
                        """
                    )

                    await MainActor.run {
                        self.webView?.loadHTMLString(html, baseURL: baseURL)
                    }
                } catch {
                    // Retry after delay
                    try? await Task.sleep(for: .seconds(2))
                    await MainActor.run {
                        self.loadNoVNC(port: port)
                    }
                }
            }
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
    }
}
