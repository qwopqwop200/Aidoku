//
//  WebView.swift
//  Aidoku
//
//  Created by Skitty on 5/21/25.
//

import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let url: URL
    let localStorageKeys: [String]
    let sourceKey: String?

    @Binding var cookies: [String: String]
    @Binding var localStorage: [String: String]
    @Binding var reloadToggle: Bool

    init(
        _ url: URL,
        key: String? = nil,
        localStorageKeys: [String] = [],
        cookies: Binding<[String: String]> = .constant([:]),
        localStorage: Binding<[String: String]> = .constant([:]),
        reloadToggle: Binding<Bool> = .constant(false)
    ) {
        self.url = url
        self.localStorageKeys = localStorageKeys
        self._cookies = cookies
        self._localStorage = localStorage
        self._reloadToggle = reloadToggle
        self.sourceKey = key
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        if let sourceKey { config.websiteDataStore = .forSource(key: sourceKey) }
        let webView = WKWebView(frame: .zero, configuration: config)
        context.coordinator.startObserving(webView)
        webView.navigationDelegate = context.coordinator
        webView.loadSourceRequest(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if reloadToggle {
            reloadToggle = false
            uiView.reload()
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObservingCookies()
        uiView.cancelSourceRequest()
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }

    func makeCoordinator() -> Coordinator {
        .init(parent: self)
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        var parent: WebView

        private var cookieStore: WKHTTPCookieStore?
        private weak var webView: WKWebView?
        private var isObservingCookies = false
        private var refreshTask: Task<Void, Never>?
        private var revision = UUID()
        private var needsRefresh = false
        typealias Snapshot = (cookies: [String: String], storage: [String: String])
        private let extract: @MainActor (WKWebView, String?, [String]) async -> Snapshot

        init(
            parent: WebView,
            extract: @escaping @MainActor (WKWebView, String?, [String]) async -> Snapshot = { webView, host, keys in
                let cookies = await webView.getCookies(for: host)
                let storage = await webView.getLocalStorage(keys: keys)
                return (cookies, storage)
            }
        ) {
            self.parent = parent
            self.extract = extract
            super.init()
        }

        func startObserving(_ webView: WKWebView) {
            self.webView = webView
            cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            cookieStore?.add(self)
            isObservingCookies = true
        }

        @MainActor
        func stopObservingCookies() {
            revision = UUID()
            refreshTask?.cancel()
            refreshTask = nil
            needsRefresh = false
            if isObservingCookies { cookieStore?.remove(self) }
            isObservingCookies = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            requestRefresh()
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            requestRefresh()
        }

        func requestRefresh() {
            guard isObservingCookies, webView != nil else { return }
            needsRefresh = true
            guard refreshTask == nil else { return }
            let current = revision
            refreshTask = Task { [weak self] in
                var deferredSnapshot = false
                while let self, self.isObservingCookies, self.revision == current, self.needsRefresh {
                    self.needsRefresh = false
                    guard let webView = self.webView else { break }
                    let url = self.parent.url
                    let keys = self.parent.localStorageKeys
                    let snapshot = await self.extract(webView, url.host, keys)
                    guard !Task.isCancelled, self.revision == current, self.isObservingCookies else { return }
                    guard self.parent.url == url, self.parent.localStorageKeys == keys else {
                        self.needsRefresh = true
                        continue
                    }
                    // Collapse a burst, but do not starve publication during continuous cookie changes.
                    if !self.needsRefresh || deferredSnapshot {
                        deferredSnapshot = false
                        if self.parent.cookies != snapshot.cookies { self.parent.cookies = snapshot.cookies }
                        if self.parent.localStorage != snapshot.storage { self.parent.localStorage = snapshot.storage }
                    } else {
                        deferredSnapshot = true
                    }
                }
                if self?.revision == current { self?.refreshTask = nil }
            }
        }

        deinit { refreshTask?.cancel() }
    }
}
