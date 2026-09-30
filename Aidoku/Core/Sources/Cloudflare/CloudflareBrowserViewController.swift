import UIKit
import WebKit

/// Browser UI for server-required verification, independent of the source interpreter.
@MainActor
final class CloudflareBrowserViewController: BaseViewController, WKNavigationDelegate {
    private let request: URLRequest
    private var handler: PopupWebViewHandler?

    init(request: URLRequest, handler: PopupWebViewHandler) {
        self.request = request
        self.handler = handler
        super.init()
    }

    override func configure() {
        view.backgroundColor = .systemBackground
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        handler?.navigated(webView: webView, for: request)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let handler = handler
        self.handler = nil
        handler?.canceled(request: request)
    }
}
