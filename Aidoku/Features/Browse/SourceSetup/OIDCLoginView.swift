//
//  OIDCLoginView.swift
//  Aidoku
//
//  Created by Skitty on 10/23/25.
//

import SwiftUI
import WebKit

struct OIDCLoginView: View {
    let loginURL: URL
    let cookieURL: URL
    let cookieHandler: ([HTTPCookie]) -> Void

    @State private var webViewURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlatformNavigationStack {
            OIDCLoginControllerView(loginURL: loginURL, cookieURL: cookieURL, webViewURL: $webViewURL) { cookies in
                cookieHandler(cookies)
                dismiss()
            }
            .ignoresSafeArea()
            .navigationTitle(webViewURL?.host ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct OIDCLoginControllerView: UIViewControllerRepresentable {
    let loginURL: URL
    let cookieURL: URL
    @Binding var webViewURL: URL?
    let cookieHandler: ([HTTPCookie]) -> Void

    func makeUIViewController(context: Context) -> OIDCLoginController {
        .init(loginURL: loginURL, cookieURL: cookieURL, cookieHandler: cookieHandler)
    }

    static func dismantleUIViewController(_ controller: OIDCLoginController, coordinator: ()) {
        controller.cancel()
    }

    func updateUIViewController(_ uiViewController: OIDCLoginController, context: Context) {
        webViewURL = uiViewController.webView.url
    }
}

@MainActor
private class OIDCLoginController: UIViewController, WKNavigationDelegate {
    let loginURL: URL
    let cookieURL: URL
    let cookieHandler: ([HTTPCookie]) -> Void

    private var isActive = true
    private var isCompleting = false

    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        // Setup has no source key yet. Isolate credentials from every previous browser login.
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: self.view.bounds, configuration: config)
        webView.navigationDelegate = self
        return webView
    }()

    init(loginURL: URL, cookieURL: URL, cookieHandler: @escaping ([HTTPCookie]) -> Void) {
        self.loginURL = loginURL
        self.cookieURL = cookieURL
        self.cookieHandler = cookieHandler
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.addSubview(webView)
        let request = URLRequest(url: loginURL)
        webView.loadSourceRequest(request)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard isActive, !isCompleting, let url = navigationAction.request.url else { return .cancel }
        if SourceLoginBrowserPolicy.isOIDCCallback(url) {
            guard navigationAction.targetFrame?.isMainFrame ?? navigationAction.sourceFrame.isMainFrame else { return .cancel }
            isCompleting = true
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard isActive, !Task.isCancelled else { return .cancel }
            let scopedCookies = SourceLoginBrowserPolicy.cookies(cookies, for: cookieURL)
            guard !scopedCookies.isEmpty else {
                isCompleting = false
                return .cancel
            }
            isActive = false
            cookieHandler(scopedCookies)
            return .cancel
        }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return .cancel }
        return .allow
    }

    func cancel() {
        isActive = false
        webView.cancelSourceRequest()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }
}
