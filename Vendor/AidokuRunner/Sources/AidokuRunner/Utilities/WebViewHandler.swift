//
//  WebViewHandler.swift
//  AidokuRunner
//
//  Created by skitty on 6/26/26.
//

import CryptoKit
import WebKit

@MainActor
class WebViewHandler: NSObject {
    let webView: WKWebView

    private let loadState = WebViewLoadState()
    private var continuations: [String: CheckedContinuation<Any?, Error>] = [:]
    private var addedAsyncEvalHandler = false
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    private static let asyncEvalHandlerName = "asyncEval"

    var cookieStore: WKHTTPCookieStore {
        webView.configuration.websiteDataStore.httpCookieStore
    }

    init(id: String) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .forSource(key: id)
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func beginLoading() {
        failPending(with: CancellationError())
        loadState.reset()
    }

    nonisolated func waitForLoad() -> Bool {
        loadState.wait()
    }

    func setRuleList(_ json: String) async throws {
        let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "RuleList",
            encodedContentRuleList: json
        )
        guard let ruleList else { return }
        webView.configuration.userContentController.add(ruleList)
    }

    func evaluateAsyncJavaScript(_ javaScriptString: String) async throws -> Any? {
        let callbackID = UUID().uuidString

        if !addedAsyncEvalHandler {
            webView.configuration.userContentController.add(WeakScriptMessageHandler(self), name: Self.asyncEvalHandlerName)
            addedAsyncEvalHandler = true
        }

        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            continuations[callbackID] = continuation
            timeoutTasks[callbackID] = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                self?.finish(callbackID, result: .failure(URLError(.timedOut)))
            }

            let wrappedScript = """
            (async () => {
                try {
                    const result = await (\(javaScriptString));
                    window.webkit.messageHandlers.\(Self.asyncEvalHandlerName).postMessage({
                        id: '\(callbackID)',
                        ok: true,
                        value: result ?? null
                    });
                } catch (e) {
                    window.webkit.messageHandlers.\(Self.asyncEvalHandlerName).postMessage({
                        id: '\(callbackID)',
                        ok: false,
                        error: String(e?.message ?? e)
                    });
                }
            })();
            """

            webView.evaluateJavaScript(wrappedScript) { _, error in
                if let error {
                    self.finish(callbackID, result: .failure(error))
                }
            }
          }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(callbackID, result: .failure(CancellationError()))
            }
        }
    }

    private func failPending(with error: Error) {
        for id in Array(continuations.keys) {
            finish(id, result: .failure(error))
        }
    }

    private func finish(_ id: String, result: sending Result<Any?, Error>) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        continuations.removeValue(forKey: id)?.resume(with: result)
    }
}

extension WebViewHandler: WKNavigationDelegate {
    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        loadState.finish(success: false)
        failPending(with: error)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        loadState.finish(success: false)
        failPending(with: error)
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        loadState.finish(success: false)
        for id in Array(continuations.keys) {
            finish(id, result: .failure(NSError(domain: "WebViewHandler", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Web content process terminated"])))
        }
    }

    func webView(_: WKWebView, didFinish _: WKNavigation) {
        loadState.finish(success: true)
    }
}

extension WebViewHandler: WKScriptMessageHandler {
    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            message.name == Self.asyncEvalHandlerName,
            let body = message.body as? [String: Any],
            let id = body["id"] as? String,
            let ok = body["ok"] as? Bool
        else {
            return
        }

        if ok {
            finish(id, result: .success(body["value"]))
        } else {
            let errorMessage = body["error"] as? String ?? "JS evaluation failed"
            finish(id, result: .failure(NSError(
                    domain: "WebViewHandler",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                )))
        }
    }
}

// WKUserContentController retains its handlers; keep that edge weak.
@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebViewHandler?

    init(_ target: WebViewHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

private final class WebViewLoadState: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Bool?

    func reset() {
        condition.lock()
        result = nil
        condition.unlock()
    }

    func finish(success: Bool) {
        condition.lock()
        result = success
        condition.broadcast()
        condition.unlock()
    }

    func wait() -> Bool {
        let deadline = Date(timeIntervalSinceNow: 60)
        condition.lock()
        defer { condition.unlock() }
        while result == nil {
            guard condition.wait(until: deadline) else { return false }
        }
        return result == true
    }
}
