import WebKit

/// Retain at most one idle browser across serialized fixtures. Concurrent
/// checkouts still receive distinct views. Load a fresh document before each
/// case: navigation resets globals, prototype patches and DOM state.
@MainActor final class RegressionWebFixture {
    private static var idle: WKWebView?
    private var restoreAppearance: (() -> Void)?
    private var acquired = false

    func acquire(frame: CGRect = .zero) -> WKWebView {
        precondition(!acquired, "Only use this fixture from a serialized suite")
        acquired = true
        let webView = Self.idle ?? WKWebView(frame: frame)
        Self.idle = nil
        let insetBehavior = webView.scrollView.contentInsetAdjustmentBehavior
        let opaque = webView.isOpaque
        let background = webView.backgroundColor
        let style = webView.overrideUserInterfaceStyle
        restoreAppearance = { [weak webView] in
            webView?.scrollView.contentInsetAdjustmentBehavior = insetBehavior
            webView?.isOpaque = opaque
            webView?.backgroundColor = background
            webView?.overrideUserInterfaceStyle = style
        }
        webView.frame = frame
        return webView
    }

    func release(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        restoreAppearance?()
        restoreAppearance = nil
        Self.idle = webView
        acquired = false
    }

    static func load(_ html: String, in webView: WKWebView) async throws {
        let navigation = RegressionNavigationWaiter()
        try await navigation.load(html, in: webView)
    }
}

@MainActor private final class RegressionNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var presentationTask: Task<Void, Never>?

    func load(_ html: String, in webView: WKWebView) async throws {
        webView.superview?.layoutIfNeeded()
        webView.layoutIfNeeded()
        webView.navigationDelegate = self
        let timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.finish(.failure(URLError(.timedOut)))
        }
        defer {
            timeout.cancel()
            presentationTask?.cancel()
            presentationTask = nil
            webView.navigationDelegate = nil
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A reused view can finish navigation before its resized native viewport
        // reaches WebKit. Fence presentation before callers measure or render.
        // Detached fixtures have no presentation lifecycle to wait for.
        guard webView.window != nil else { finish(.success(())); return }
        presentationTask = Task { @MainActor [weak self] in
            do {
                _ = try await webView.callAsyncJavaScript(
                    """
                    await new Promise((resolve, reject) => {
                        let frame = 0;
                        const timer = setTimeout(() => {
                            cancelAnimationFrame(frame);
                            reject(new Error('Fixture presentation timed out'));
                        }, 19000);
                        frame = requestAnimationFrame(() => {
                            frame = requestAnimationFrame(() => { clearTimeout(timer); resolve(); });
                        });
                    });
                    """,
                    arguments: [:], in: nil, contentWorld: .page)
                try Task.checkCancellation()
                self?.finish(.success(()))
            } catch { self?.finish(.failure(error)) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(URLError(.networkConnectionLost)))
    }
}
