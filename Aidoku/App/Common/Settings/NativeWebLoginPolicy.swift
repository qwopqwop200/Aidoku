import Foundation

/// Source settings declare the authentication contract. Cookie/localStorage contracts must remain
/// in the source-isolated browser; system OAuth sessions cannot export that browser state.
enum NativeWebLoginPolicy {
    static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    static func callbackParameters(_ callback: URL) -> [URLQueryItem]? {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            guard let fragmentComponents = URLComponents(string: "?" + fragment) else { return nil }
            items += fragmentComponents.queryItems ?? []
        }
        // Ambiguous security parameters must not be resolved by arbitrary first/last selection.
        for name in ["code", "state", "error", "access_token"] where items.filter({ $0.name == name }).count > 1 {
            return nil
        }
        return items
    }

    static func validatesCallback(_ callback: URL, scheme: String, redirectURI: String?, expectedState: String?) -> Bool {
        guard callback.scheme?.lowercased() == scheme.lowercased(), callback.user == nil, callback.password == nil,
              let items = callbackParameters(callback), !items.contains(where: { $0.name == "error" }) else { return false }
        if let redirectURI {
            guard let redirect = URL(string: redirectURI),
                  redirect.scheme?.lowercased() == callback.scheme?.lowercased(),
                  redirect.host?.lowercased() == callback.host?.lowercased(),
                  redirect.port == callback.port,
                  let redirectComponents = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
                  let callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  redirectComponents.percentEncodedPath == callbackComponents.percentEncodedPath else { return false }
            let fixedItems = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let callbackQuery = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            for fixed in fixedItems {
                let actual = callbackQuery.filter { $0.name == fixed.name }
                guard actual.count == 1, actual.first?.value == fixed.value,
                      items.filter({ $0.name == fixed.name }).count == 1 else { return false }
            }
        }
        if let expectedState {
            guard !expectedState.isEmpty, items.first(where: { $0.name == "state" })?.value == expectedState else { return false }
        }
        return true
    }
}
