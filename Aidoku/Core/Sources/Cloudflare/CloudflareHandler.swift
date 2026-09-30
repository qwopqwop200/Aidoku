//
//  CloudflareHandler.swift
//  Aidoku
//
//  Created by Skitty on 6/15/25.
//

import WebKit

// handles requests blocked by cloudflare, retrieving new cookies from a webview
// and showing a popup to complete a captcha if necessary
actor CloudflareHandler: NSObject {
    static let shared = CloudflareHandler()

    private struct ChallengeKey: Hashable {
        let origin: String
        let userAgent: String
        let authorization: String
        let cookies: String

        init?(request: URLRequest) {
            guard let url = request.url, let host = url.host?.lowercased(),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
            origin = "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
            userAgent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            cookies = request.value(forHTTPHeaderField: "Cookie") ?? ""
        }
    }
    private struct ChallengeTask {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Void, Error>]
    }
    private var challenges: [ChallengeKey: ChallengeTask] = [:]

    private var shouldTimeout = true
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var proxy: Proxy?
    private var isChallengeActive = false
    private var challengeWaiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var activeChallengeID: UUID?

    @MainActor
    private lazy var webView = WKWebView(frame: .zero)

    @MainActor
    private lazy var browserOwnership = CloudflareBrowserOwnership()

    @MainActor
    private var hiddenConstraints: [NSLayoutConstraint] = []

    @MainActor
    private var popupController: CloudflareBrowserViewController?

    @MainActor
    private var popupShown: Bool {
        popupController?.presentingViewController != nil
    }

    @MainActor
    private var parent: UIViewController? {
        UIApplication.shared.appDelegate?.visibleViewController
    }

    @MainActor
    private var parentView: UIView? {
        parent?.view
    }

    enum HandleError: Error {
        case invalidRequest
        case missingParentView
        case timedOut
        case canceled
        case solveFailed
    }

    nonisolated func shouldHandle(response: HTTPURLResponse, data: Data) -> Bool {
        CloudflareResponsePolicy.isChallenge(response: response, data: data)
    }

    func handle(request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, request.httpBodyStream == nil else { throw HandleError.invalidRequest }

        // Another request may have obtained clearance since this request was sent.
        // Only safe reads get this extra native retry; writes are replayed once below.
        if CloudflareResponsePolicy.mayRetryCachedClearance(request),
           let clearance = CloudflareResponsePolicy.usableClearance(for: url),
           clearance.value != CloudflareResponsePolicy.clearance(in: request) {
            let result = try await SourceNetwork.shared.data(for: CloudflareResponsePolicy.request(request, applying: clearance))
            try Task.checkCancellation()
            if let response = result.1 as? HTTPURLResponse, !shouldHandle(response: response, data: result.0) {
                return result
            }
        }

        try await awaitChallenge(for: request)
        try Task.checkCancellation()
        let newRequest = CloudflareResponsePolicy.usableClearance(for: url).map {
            CloudflareResponsePolicy.request(request, applying: $0)
        } ?? request
        let (data, response) = try await SourceNetwork.shared.data(for: newRequest)
        try Task.checkCancellation()
        if
            let response = response as? HTTPURLResponse,
            shouldHandle(response: response, data: data)
        {
            throw HandleError.solveFailed
        }
        return (data, response)
    }
}

extension CloudflareHandler {
    private func completeChallenge(for request: URLRequest, challengeID: UUID) async throws {
        shouldTimeout = true

        do {
            guard await addWebView(for: request, challengeID: challengeID) else { throw HandleError.missingParentView }
            try await SourceNetwork.configure(webView.configuration.websiteDataStore)
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.finishContinuation = continuation
                let id = challengeID
                Task {
                    guard self.isCurrentChallenge(id) else { return }
                    await self.loadBrowser(for: request, challengeID: id)
                }
                // Timeout only hidden verification, never an interactive captcha.
                timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    guard !Task.isCancelled else { return }
                    if self.shouldTimeout, self.isCurrentChallenge(id) {
                        await self.finishChallenge(expectedID: id, with: .failure(HandleError.timedOut))
                    }
                }
            }
        } catch {
            await cleanupBrowser(expectedID: challengeID)
            proxy = nil
            throw error
        }
    }

    @MainActor
    private func loadBrowser(for request: URLRequest, challengeID: UUID) {
        browserOwnership.perform(expectedID: challengeID) {
            webView.load(CloudflareResponsePolicy.browserRequest(for: request))
        }
    }

    private func cleanupBrowser(expectedID: UUID) async {
        await MainActor.run {
            browserOwnership.end(expectedID: expectedID) {
                webView.stopLoading()
                webView.navigationDelegate = nil
                NSLayoutConstraint.deactivate(hiddenConstraints)
                hiddenConstraints = []
                webView.removeFromSuperview()
                popupController?.dismiss(animated: true)
                popupController = nil
            }
        }
    }

    private func finishChallenge(expectedID: UUID?, with result: Result<Void, Error> = .success(())) async {
        // Check the generation and take its continuation in one actor-isolated step.
        // A callback may have suspended while another challenge acquired the browser.
        guard let expectedID, activeChallengeID == expectedID, let continuation = finishContinuation else { return }

        // Clear first, so queued browser callbacks cannot finish this continuation twice.
        finishContinuation = nil
        await cleanupBrowser(expectedID: expectedID)

        timeoutTask?.cancel()
        finishContinuation = nil
        timeoutTask = nil
        proxy = nil

        continuation.resume(with: result)
    }

    private func proxy(for request: URLRequest, expectedID: UUID?) async -> Proxy? {
        guard let expectedID, activeChallengeID == expectedID else { return nil }
        if let proxy { return proxy }
        let proxy = await Proxy(request: request, handler: self, challengeID: expectedID)
        // Proxy construction hops to MainActor; cancellation may replace the generation.
        guard activeChallengeID == expectedID else { return nil }
        if let existing = self.proxy { return existing }
        self.proxy = proxy
        return proxy
    }

    // add hidden web view to a visible view controller
    @MainActor
    private func addWebView(for request: URLRequest, challengeID: UUID?) async -> Bool {
        guard let challengeID, let parentView, browserOwnership.begin(challengeID) else { return false }

        // match web view rendering mode with user agent
        let userAgent = request.value(forHTTPHeaderField: "User-Agent")
        let config = WKWebViewConfiguration()
        if let userAgent, userAgent.contains("iPhone") || userAgent.contains("iPad") {
            config.defaultWebpagePreferences.preferredContentMode = .mobile
        }
        webView = WKWebView(frame: .zero, configuration: config)
        guard let handlerProxy = await proxy(for: request, expectedID: challengeID) else { return false }
        return browserOwnership.perform(expectedID: challengeID) {
            webView.navigationDelegate = handlerProxy
            webView.customUserAgent = userAgent
            webView.translatesAutoresizingMaskIntoConstraints = false
            parentView.addSubview(webView)

            hiddenConstraints = [
                webView.widthAnchor.constraint(equalToConstant: 0),
                webView.heightAnchor.constraint(equalToConstant: 0),
                webView.centerXAnchor.constraint(equalTo: parentView.centerXAnchor),
                webView.centerYAnchor.constraint(equalTo: parentView.centerYAnchor)
            ]
            NSLayoutConstraint.activate(hiddenConstraints)
        }
    }

    private func awaitChallenge(for request: URLRequest) async throws {
        guard let key = ChallengeKey(request: request) else { throw HandleError.invalidRequest }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if var challenge = challenges[key] {
                    challenge.waiters[waiterID] = continuation
                    challenges[key] = challenge
                    return
                }
                let id = UUID()
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.runChallenge(for: request, key: key, id: id)
                }
                challenges[key] = .init(id: id, task: task, waiters: [waiterID: continuation])
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelWaiter(key: key, id: waiterID) }
        }
    }

    // Keep challenge state mutations on this actor; the shared Task only dispatches work.
    private func runChallenge(for request: URLRequest, key: ChallengeKey, id: UUID) async {
        let result: Result<Void, Error>
        do {
            try await acquire(id: id)
            activeChallengeID = id
            do {
                try Task.checkCancellation()
                try await completeChallenge(for: request, challengeID: id)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            activeChallengeID = nil
            release()
        } catch {
            result = .failure(error)
        }
        completeWaiters(key: key, id: id, result: result)
    }

    private func completeWaiters(key: ChallengeKey, id: UUID, result: Result<Void, Error>) {
        guard let challenge = challenges[key], challenge.id == id else { return }
        challenges[key] = nil
        for continuation in challenge.waiters.values { continuation.resume(with: result) }
    }

    private func cancelWaiter(key: ChallengeKey, id: UUID) async {
        guard var challenge = challenges[key], let continuation = challenge.waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
        if challenge.waiters.isEmpty {
            challenges[key] = nil
            challenge.task.cancel()
            if activeChallengeID == challenge.id {
                await finishChallenge(expectedID: challenge.id, with: .failure(CancellationError()))
            }
        } else {
            challenges[key] = challenge
        }
    }

    private func acquire(id: UUID) async throws {
        try Task.checkCancellation()
        guard isChallengeActive else {
            isChallengeActive = true
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                challengeWaiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelAcquisition(id: id) }
        }
    }

    private func cancelAcquisition(id: UUID) {
        guard let index = challengeWaiters.firstIndex(where: { $0.0 == id }) else { return }
        challengeWaiters.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func release() {
        if !challengeWaiters.isEmpty {
            challengeWaiters.removeFirst().1.resume()
        } else {
            isChallengeActive = false
        }
    }
}

extension CloudflareHandler {
    @MainActor
    final class Proxy: NSObject, PopupWebViewHandler, WKNavigationDelegate {
        let request: URLRequest

        let challengeID: UUID?
        weak var handler: CloudflareHandler?

        init(request: URLRequest, handler: CloudflareHandler, challengeID: UUID?) {
            self.request = request
            self.handler = handler
            self.challengeID = challengeID
        }

        func navigated(webView: WKWebView, for request: URLRequest) {
            Task { [weak handler] in
                await handler?.navigated(webView: webView, for: request, challengeID: self.challengeID)
            }
        }

        func canceled(request: URLRequest) {
            Task { [weak handler] in
                await handler?.canceled(request: request, challengeID: self.challengeID)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            navigated(webView: webView, for: request)
        }
    }

    // handle web view reload/redirect
    nonisolated func navigated(webView: WKWebView, for request: URLRequest, challengeID: UUID?) async {
        guard await isCurrentChallenge(challengeID) else { return }
        guard let url = request.url else { return }

        await MainActor.run {
            self.browserOwnership.perform(expectedID: challengeID) {
                guard self.webView === webView, self.popupController == nil else { return }
                // Delayed checks are generation-bound and popup reservation coalesces them.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.checkForCaptcha(for: request, challengeID: challengeID)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    self?.checkForCaptcha(for: request, challengeID: challengeID)
                }
            }
        }

        let webViewCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()

        // check for old (expired) clearance cookie
        let oldClearance = CloudflareResponsePolicy.clearance(in: request)

        // check for clearance cookie
        let hasClearance = webViewCookies.contains { cookie in
            cookie.name == "cf_clearance" && !cookie.value.isEmpty && cookie.value != oldClearance
                && CloudflareResponsePolicy.cookie(cookie, appliesTo: url)
        }
        guard hasClearance else { return }

        let isCaptcha = await isCaptchaPage(challengeID: challengeID, expectedWebView: webView)
        guard !isCaptcha else { return }
        guard await commitCookies(webViewCookies, for: url, challengeID: challengeID) else { return }
        await self.finishChallenge(expectedID: challengeID)
    }

    private func commitCookies(_ cookies: [HTTPCookie], for url: URL, challengeID: UUID?) -> Bool {
        guard isCurrentChallenge(challengeID) else { return false }
        CloudflareResponsePolicy.commitVerificationCookies(cookies, for: url)
        return true
    }

    // handle user popover dismiss
    nonisolated func canceled(request: URLRequest, challengeID: UUID?) async {
        guard await isCurrentChallenge(challengeID) else { return }
        await self.finishChallenge(expectedID: challengeID, with: .failure(HandleError.canceled))
    }
}

extension CloudflareHandler {
    private func isCurrentChallenge(_ id: UUID?) -> Bool {
        id != nil && activeChallengeID == id && finishContinuation != nil
    }

    private func disableTimeout(expectedID: UUID?) -> Bool {
        guard isCurrentChallenge(expectedID) else { return false }
        shouldTimeout = false
        return true
    }

    // show captcha sheet view to user
    @MainActor
    private func showPopup(for request: URLRequest, challengeID: UUID?) async {
        guard browserOwnership.reservePopup(expectedID: challengeID) else { return }

        // Reservation occurs before actor hops so repeated checks cannot create two sheets.
        guard await disableTimeout(expectedID: challengeID) else { return }
        guard let parent else {
            await self.finishChallenge(expectedID: challengeID, with: .failure(HandleError.missingParentView))
            return
        }
        guard let handlerProxy = await proxy(for: request, expectedID: challengeID) else { return }
        browserOwnership.perform(expectedID: challengeID) {
            let popup = CloudflareBrowserViewController(request: request, handler: handlerProxy)
            popupController = popup

            NSLayoutConstraint.deactivate(hiddenConstraints)
            hiddenConstraints = []
            webView.navigationDelegate = popup
            webView.removeFromSuperview()
            popup.view.addSubview(webView)

            NSLayoutConstraint.activate([
                webView.widthAnchor.constraint(equalTo: popup.view.widthAnchor),
                webView.heightAnchor.constraint(equalTo: popup.view.heightAnchor),
                webView.centerXAnchor.constraint(equalTo: popup.view.centerXAnchor),
                webView.centerYAnchor.constraint(equalTo: popup.view.centerYAnchor)
            ])
            parent.present(popup, animated: true)
        }
    }

    // check if captcha or verify button is shown, and show the popup if it is
    @MainActor
    private func checkForCaptcha(for request: URLRequest, challengeID: UUID?) {
        guard !popupShown else { return }
        Task {
            guard await isCurrentChallenge(challengeID) else { return }
            let found = await isCaptchaPage(challengeID: challengeID)
            if found, await isCurrentChallenge(challengeID) {
                await showPopup(for: request, challengeID: challengeID)
            }
        }
    }

    @MainActor
    private func isCaptchaPage(challengeID: UUID?, expectedWebView: WKWebView? = nil) async -> Bool {
        guard browserOwnership.isCurrent(challengeID), expectedWebView == nil || expectedWebView === webView else { return true }
        let checkedWebView = webView
        let js = """
        (document.querySelector('input[name="cf-turnstile-response"]') !== null
            || document.getElementById('challenge-error-title') !== null
            || document.getElementById('challenge-error-text') !== null) ? 1 : 0
            || document.title === "Just a moment..."
        """
        let result = try? await checkedWebView.evaluateJavaScript(js)
        guard browserOwnership.isCurrent(challengeID), checkedWebView === webView else { return true }
        guard let result = result as? Int else { return false }
        return result == 1
    }
}

extension HTTPCookieStorage {
    /// Keep historical header ordering, but only include cookies Foundation allows
    /// on this request's scheme, host and path. Cache clearing uses allCookies below.
    func requestCookies(for url: URL) -> [HTTPCookie]? {
        guard let allowed = cookies(for: url) else { return nil }
        return allCookies(for: url)?.filter { cookie in
            allowed.contains {
                $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path
            }
        }
    }

    func allCookies(for url: URL) -> [HTTPCookie]? {
        guard let host = url.host?.lowercased() else { return nil }
        return cookies?.filter { cookie in
            let domain = cookie.domain
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }
    }
}
