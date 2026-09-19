//
//  WKWebView.swift
//  Aidoku
//
//  Created by Skitty on 5/21/25.
//

import WebKit

extension WKWebView {
    func loadSourceRequest(_ request: URLRequest) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await SourceNetwork.configure(configuration.websiteDataStore)
                load(request)
            } catch {
                // Never silently navigate directly when bypass setup fails.
                let message = NSLocalizedString("HTTPS_BYPASS_TEST_FAILED")
                loadHTMLString("<meta name='viewport' content='width=device-width'><p>\(message)</p>", baseURL: nil)
            }
        }
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
