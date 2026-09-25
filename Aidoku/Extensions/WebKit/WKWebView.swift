//
//  WKWebView.swift
//  Aidoku
//
//  Created by Skitty on 5/21/25.
//

import WebKit

extension WKWebView {
    @MainActor
    func loadSourceRequest(
        _ request: URLRequest,
        configure: @escaping @MainActor (WKWebsiteDataStore) async throws -> Void = { try await SourceNetwork.configure($0) }
    ) {
        cancelSourceRequest()
        let preparation = SourceNavigationPreparation()
        objc_setAssociatedObject(self, &SourceNavigationPreparation.key, preparation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let dataStore = configuration.websiteDataStore
        preparation.task = Task { @MainActor [weak self, weak preparation] in
            do {
                try await configure(dataStore)
                guard !Task.isCancelled, preparation != nil else { return }
                self?.load(request)
            } catch {
                guard !Task.isCancelled, preparation != nil else { return }
                // Never silently navigate directly when bypass setup fails.
                let message = NSLocalizedString("HTTPS_BYPASS_TEST_FAILED")
                self?.loadHTMLString("<meta name='viewport' content='width=device-width'><p>\(message)</p>", baseURL: nil)
            }
            preparation?.task = nil
        }
    }

    @MainActor
    func cancelSourceRequest() {
        let preparation = objc_getAssociatedObject(self, &SourceNavigationPreparation.key) as? SourceNavigationPreparation
        preparation?.task?.cancel()
        objc_setAssociatedObject(self, &SourceNavigationPreparation.key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func getCookies(for domain: String? = nil) async -> [String: String]  {
        await withCheckedContinuation { continuation in
            configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                var cookieDict = [String: String]()
                for cookie in cookies {
                    if let domain {
                        let host = domain.lowercased()
                        let cookieDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        if host == cookieDomain || host.hasSuffix("." + cookieDomain) {
                            cookieDict[cookie.name] = cookie.value
                        }
                    } else {
                        cookieDict[cookie.name] = cookie.value
                    }
                }
                continuation.resume(returning: cookieDict)
            }
        }
    }

    func getLocalStorage(keys: [String]) async -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        let js = """
        (function() {
            var result = {};
            var keys = \(keys);
            for (var i = 0; i < keys.length; i++) {
                var key = keys[i];
                var value = localStorage.getItem(key);
                if (value) { result[key] = value; }
            }
            return result;
        })();
        """
        do {
            let result = try await evaluateJavaScript(js) as? [String: String]
            return result ?? [:]
        } catch {
            return [:]
        }
    }
}


@MainActor
private final class SourceNavigationPreparation {
    static var key: UInt8 = 0
    var task: Task<Void, Never>?
    deinit { task?.cancel() }
}
