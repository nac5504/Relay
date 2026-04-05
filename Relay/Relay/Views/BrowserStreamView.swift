import SwiftUI
import WebKit

/// Displays a live noVNC stream from a Docker container in a WKWebView.
/// Mouse and keyboard input is forwarded automatically by noVNC.
/// Agent cursor actions are rendered as an overlay injected into the page.
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

        // VNC status monitor
        let monitorScript = WKUserScript(
            source: Self.vncMonitorJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(monitorScript)

        // FPS measurement script
        let fpsScript = WKUserScript(
            source: Self.fpsMonitorJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(fpsScript)
        config.userContentController.add(context.coordinator, name: "fpsReport")

        // Cursor overlay injection
        let cursorScript = WKUserScript(
            source: Self.cursorOverlayJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(cursorScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        if let url = agent.noVNCURL {
            print("[noVNC] Initial load: \(url)")
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Reload if port changed
        if let url = agent.noVNCURL {
            let currentPort = webView.url?.port
            if currentPort == nil || currentPort != agent.noVNCPort {
                print("[noVNC] Port changed, reloading: \(url)")
                webView.load(URLRequest(url: url))
            }
        }

        // Push cursor updates into the page
        if agent.cursorVisible, let pos = agent.cursorPosition {
            let actionType = agent.cursorActionType ?? "left_click"
            let js = "window.__relayCursor?.update(\(pos.x), \(pos.y), '\(actionType)');"
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else if !agent.cursorVisible, context.coordinator.lastCursorVisible {
            webView.evaluateJavaScript("window.__relayCursor?.hide();", completionHandler: nil)
        }
        context.coordinator.lastCursorVisible = agent.cursorVisible
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFPSUpdate: onFPSUpdate)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onFPSUpdate: ((Double) -> Void)?
        weak var webView: WKWebView?
        var lastCursorVisible = false
        private var retryCount = 0
        private let maxRetries = 10

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
            if let needsReload = dict["needsReload"] as? Bool, needsReload {
                Task { @MainActor in
                    self.retryLoad()
                }
            }
            if let connected = dict["connected"] as? Bool, connected {
                Task { @MainActor in
                    self.retryCount = 0
                }
            }
        }

        private func retryLoad() {
            guard retryCount < maxRetries, let webView else { return }
            retryCount += 1
            let delay = min(Double(retryCount) * 1.5, 5.0)
            print("[noVNC] Retry \(retryCount)/\(maxRetries) in \(delay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let webView, let url = webView.url else { return }
                print("[noVNC] Reloading: \(url)")
                webView.load(URLRequest(url: url))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[noVNC] Page loaded: \(webView.url?.absoluteString ?? "nil")")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[noVNC] Navigation failed: \(error.localizedDescription)")
            retryLoad()
        }

        func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if challenge.protectionSpace.host == "localhost" {
                return (.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
            }
            return (.performDefaultHandling, nil)
        }
    }

    // MARK: - Injected JavaScript

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

    private static let vncMonitorJS = """
    (function() {
        function log(msg) {
            try { window.webkit.messageHandlers.fpsReport.postMessage({debug: msg, fps: 0}); } catch(e) {}
        }
        function requestReload() {
            try { window.webkit.messageHandlers.fpsReport.postMessage({needsReload: true, fps: 0}); } catch(e) {}
        }
        function signalConnected() {
            try { window.webkit.messageHandlers.fpsReport.postMessage({connected: true, fps: 0}); } catch(e) {}
        }

        log('monitor loaded, URL: ' + window.location.href);

        var checks = 0;
        function checkState() {
            checks++;
            var screen = document.getElementById('screen');
            var canvas = screen && screen.querySelector('canvas');
            var statusEl = document.getElementById('status');
            var statusText = statusEl ? statusEl.textContent : '';

            if (canvas && statusText.indexOf('Connected') >= 0) {
                log('VNC connected — canvas ' + canvas.width + 'x' + canvas.height);
                signalConnected();
                setTimeout(checkState, 10000);
                return;
            }

            if (statusText.indexOf('went wrong') >= 0 || statusText.indexOf('Disconnected') >= 0) {
                log('VNC failed: "' + statusText + '" — requesting reload');
                requestReload();
                return;
            }

            if (checks >= 5 && !canvas) {
                log('No canvas after ' + checks + ' checks — requesting reload');
                requestReload();
                return;
            }

            log('check ' + checks + ': canvas=' + !!canvas + ' status="' + statusText + '"');
            setTimeout(checkState, 1500);
        }

        setTimeout(checkState, 2000);
    })();
    """

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

    /// Cursor overlay — injected into the noVNC page. Renders on top of the VNC canvas.
    private static let cursorOverlayJS = """
    (function() {
        // Inject CSS
        var style = document.createElement('style');
        style.textContent = `
            #relay-cursor-overlay {
                position: fixed;
                top: 0; left: 0; right: 0; bottom: 0;
                pointer-events: none;
                z-index: 99999;
                overflow: hidden;
            }
            #relay-cursor {
                position: absolute;
                width: 32px; height: 32px;
                transform: translate(-50%, -50%);
                transition: left 0.25s cubic-bezier(0.22, 1, 0.36, 1),
                            top 0.25s cubic-bezier(0.22, 1, 0.36, 1),
                            opacity 0.4s ease;
                opacity: 0;
                filter: drop-shadow(0 0 8px var(--cursor-color, #00e5ff));
            }
            #relay-cursor.visible { opacity: 1; }

            /* Crosshair */
            #relay-cursor .crosshair-v,
            #relay-cursor .crosshair-h {
                position: absolute;
                background: var(--cursor-color, #00e5ff);
                opacity: 0.4;
            }
            #relay-cursor .crosshair-v {
                width: 1px; height: 28px;
                left: 50%; top: 50%;
                transform: translate(-50%, -50%);
            }
            #relay-cursor .crosshair-h {
                width: 28px; height: 1px;
                left: 50%; top: 50%;
                transform: translate(-50%, -50%);
            }

            /* Center dot */
            #relay-cursor .dot {
                position: absolute;
                width: 8px; height: 8px;
                border-radius: 50%;
                background: var(--cursor-color, #00e5ff);
                left: 50%; top: 50%;
                transform: translate(-50%, -50%);
                box-shadow: 0 0 6px var(--cursor-color, #00e5ff);
            }

            /* Ring */
            #relay-cursor .ring {
                position: absolute;
                width: 20px; height: 20px;
                border-radius: 50%;
                border: 2px solid var(--cursor-color, #00e5ff);
                opacity: 0.6;
                left: 50%; top: 50%;
                transform: translate(-50%, -50%);
            }

            /* Outer glow pulse */
            #relay-cursor .glow {
                position: absolute;
                width: 32px; height: 32px;
                border-radius: 50%;
                background: var(--cursor-color, #00e5ff);
                opacity: 0.15;
                left: 50%; top: 50%;
                transform: translate(-50%, -50%);
                animation: relay-pulse 1.2s ease-in-out infinite alternate;
            }
            @keyframes relay-pulse {
                0% { transform: translate(-50%, -50%) scale(1); opacity: 0.15; }
                100% { transform: translate(-50%, -50%) scale(1.4); opacity: 0.06; }
            }

            /* Ripple */
            .relay-ripple {
                position: absolute;
                pointer-events: none;
                transform: translate(-50%, -50%);
            }
            .relay-ripple .ring-outer {
                width: 50px; height: 50px;
                border-radius: 50%;
                border: 2px solid var(--ripple-color, #00e5ff);
                opacity: 0;
                animation: relay-ripple-expand 0.7s ease-out forwards;
            }
            .relay-ripple .ring-inner {
                position: absolute;
                top: 50%; left: 50%;
                width: 30px; height: 30px;
                border-radius: 50%;
                border: 1.5px solid var(--ripple-color, #00e5ff);
                opacity: 0;
                transform: translate(-50%, -50%);
                animation: relay-ripple-expand 0.7s ease-out 0.05s forwards;
            }
            .relay-ripple .flash {
                position: absolute;
                top: 50%; left: 50%;
                width: 50px; height: 50px;
                border-radius: 50%;
                background: var(--ripple-color, #00e5ff);
                opacity: 0;
                transform: translate(-50%, -50%);
                animation: relay-ripple-flash 0.5s ease-out forwards;
            }
            @keyframes relay-ripple-expand {
                0% { transform: translate(-50%, -50%) scale(0.3); opacity: 0.7; }
                100% { transform: translate(-50%, -50%) scale(2.2); opacity: 0; }
            }
            @keyframes relay-ripple-flash {
                0% { transform: translate(-50%, -50%) scale(0.4); opacity: 0.25; }
                100% { transform: translate(-50%, -50%) scale(1.2); opacity: 0; }
            }

            /* Action label */
            #relay-cursor-label {
                position: absolute;
                transform: translate(18px, -8px);
                font: 600 10px/1 -apple-system, monospace;
                color: var(--cursor-color, #00e5ff);
                background: rgba(0,0,0,0.7);
                padding: 2px 6px;
                border-radius: 3px;
                white-space: nowrap;
                opacity: 0.8;
                transition: opacity 0.3s;
                pointer-events: none;
            }
        `;
        document.head.appendChild(style);

        // Create overlay container
        var overlay = document.createElement('div');
        overlay.id = 'relay-cursor-overlay';
        overlay.innerHTML = `
            <div id="relay-cursor">
                <div class="glow"></div>
                <div class="crosshair-v"></div>
                <div class="crosshair-h"></div>
                <div class="ring"></div>
                <div class="dot"></div>
                <span id="relay-cursor-label"></span>
            </div>
        `;
        document.body.appendChild(overlay);

        var cursor = document.getElementById('relay-cursor');
        var label = document.getElementById('relay-cursor-label');
        var hideTimer = null;

        var colorMap = {
            'left_click': '#00e5ff',
            'double_click': '#ff4081',
            'triple_click': '#ff4081',
            'right_click': '#ff9100',
            'scroll': '#ffea00',
            'mouse_move': 'rgba(255,255,255,0.5)',
            'left_click_drag': '#e040fb',
            'type': '#69f0ae',
            'key': '#69f0ae'
        };

        var labelMap = {
            'left_click': 'click',
            'double_click': 'double click',
            'triple_click': 'triple click',
            'right_click': 'right click',
            'scroll': 'scroll',
            'mouse_move': 'move',
            'left_click_drag': 'drag',
            'type': 'typing',
            'key': 'key'
        };

        var clickActions = ['left_click', 'right_click', 'double_click', 'triple_click', 'left_click_drag'];

        function getCanvasRect() {
            var screen = document.getElementById('screen');
            var canvas = screen && screen.querySelector('canvas');
            if (canvas) return canvas.getBoundingClientRect();
            return { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight };
        }

        function spawnRipple(px, py, color) {
            var el = document.createElement('div');
            el.className = 'relay-ripple';
            el.style.left = px + 'px';
            el.style.top = py + 'px';
            el.style.setProperty('--ripple-color', color);
            el.innerHTML = '<div class="ring-outer"></div><div class="ring-inner"></div><div class="flash"></div>';
            overlay.appendChild(el);
            setTimeout(function() { el.remove(); }, 800);
        }

        window.__relayCursor = {
            update: function(normX, normY, actionType) {
                var rect = getCanvasRect();
                var px = rect.left + normX * rect.width;
                var py = rect.top + normY * rect.height;
                var color = colorMap[actionType] || '#00e5ff';

                cursor.style.left = px + 'px';
                cursor.style.top = py + 'px';
                cursor.style.setProperty('--cursor-color', color);
                cursor.classList.add('visible');

                label.textContent = labelMap[actionType] || actionType;

                if (clickActions.indexOf(actionType) >= 0) {
                    spawnRipple(px, py, color);
                }

                clearTimeout(hideTimer);
                hideTimer = setTimeout(function() {
                    cursor.classList.remove('visible');
                }, 3000);
            },
            hide: function() {
                cursor.classList.remove('visible');
            }
        };
    })();
    """
}
