import Foundation
import Testing
@testable import Aidoku

@MainActor
struct ReauditCloudflareTests {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func queuedOldBrowserEffectsCannotMutateTheNextGeneration() async throws {
        let owner = CloudflareBrowserOwnership()
        let first = UUID()
        let second = UUID()
        var effects: [String] = []
        var pending: CheckedContinuation<Void, Never>?
        #expect(owner.begin(first))
        let oldTask = Task {
            // Pause after the actor's generation check and before its UI effect.
            guard owner.isCurrent(first) else { return false }
            await withCheckedContinuation { pending = $0 }
            return owner.perform(expectedID: first) { effects.append("stale-load") }
        }
        try await waitUntil { pending != nil }
        #expect(owner.end(expectedID: first) { effects.append("first-cleanup") })
        #expect(owner.begin(second))
        pending?.resume()
        #expect(await oldTask.value == false)
        #expect(!owner.reservePopup(expectedID: first))
        #expect(!owner.end(expectedID: first) { effects.append("stale-cleanup") })
        #expect(owner.perform(expectedID: second) { effects.append("second-load") })
        #expect(effects == ["first-cleanup", "second-load"])
        #expect(owner.isCurrent(second))
    }

    @Test func duplicateCaptchaChecksReserveOnlyOnePopupBeforeAwaiting() async throws {
        let owner = CloudflareBrowserOwnership()
        let id = UUID()
        var pending: CheckedContinuation<Void, Never>?
        var presentations = 0
        #expect(owner.begin(id))
        let first = Task {
            guard owner.reservePopup(expectedID: id) else { return false }
            await withCheckedContinuation { pending = $0 }
            return owner.perform(expectedID: id) { presentations += 1 }
        }
        try await waitUntil { pending != nil }
        // A second check reaches presentation while the first awaits the handler actor.
        let second = Task {
            guard owner.reservePopup(expectedID: id) else { return false }
            return owner.perform(expectedID: id) { presentations += 1 }
        }
        #expect(await second.value == false)
        pending?.resume()
        #expect(await first.value)
        #expect(presentations == 1)
        #expect(owner.end(expectedID: id) {})
        let next = UUID()
        #expect(owner.begin(next))
        #expect(owner.reservePopup(expectedID: next))
    }

    @Test func endingOwnershipInvalidatesCallbacksBeforeCleanupRuns() {
        let owner = CloudflareBrowserOwnership()
        let id = UUID()
        #expect(owner.begin(id))
        var obsoleteEffects = 0
        var currentDuringCleanup = true
        var callbackAllowedDuringCleanup = true
        var popupAllowedDuringCleanup = true
        let ended = owner.end(expectedID: id) {
            currentDuringCleanup = owner.isCurrent(id)
            callbackAllowedDuringCleanup = owner.perform(expectedID: id) { obsoleteEffects += 1 }
            popupAllowedDuringCleanup = owner.reservePopup(expectedID: id)
        }
        #expect(ended)
        #expect(!currentDuringCleanup)
        #expect(!callbackAllowedDuringCleanup)
        #expect(!popupAllowedDuringCleanup)
        #expect(obsoleteEffects == 0)
        #expect(!owner.end(expectedID: id) { obsoleteEffects += 1 })
        #expect(!owner.perform(expectedID: nil) { obsoleteEffects += 1 })
        #expect(obsoleteEffects == 0)
    }

    @Test func bodyStreamsAreRejectedBeforeBrowserOrNativeReplay() async {
        let handler = CloudflareHandler()
        var request = URLRequest(url: URL(string: "https://verification.invalid/upload")!)
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: Data("fixture body".utf8))
        do {
            _ = try await handler.handle(request: request)
            Issue.record("A consumed body stream must not be replayed")
        } catch CloudflareHandler.HandleError.invalidRequest {
        } catch {
            Issue.record("Unexpected stream rejection: \(error)")
        }
    }

    private func cookie(_ name: String, value: String, domain: String = "verification.invalid",
                        path: String = "/", secure: Bool = false, expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return try #require(HTTPCookie(properties: properties))
    }

    @Test func verificationCommitPreservesNewNativeSessionsAndSourceRequestCookies() throws {
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let url = URL(string: "https://verification.invalid/api/items")!
        storage.setCookie(try cookie("session", value: "new-native-session"))
        storage.setCookie(try cookie("source_custom", value: "native-custom"))
        storage.setCookie(try cookie("cf_clearance", value: "old-clearance"))
        let browserSnapshot = [
            try cookie("session", value: "stale-browser-session"),
            try cookie("source_custom", value: "stale-browser-custom"),
            try cookie("cf_clearance", value: "new-clearance"),
            try cookie("__cf_bm", value: "new-bot-management"),
            try cookie("_cfuvid", value: "new-visitor")
        ]
        // Exercise the exact production commit helper with an isolated native cookie store.
        CloudflareResponsePolicy.commitVerificationCookies(browserSnapshot, for: url, storage: storage)
        let values = SourceLoginBrowserPolicy.cookieValues(storage.cookies ?? [], for: url)
        #expect(values["session"] == "new-native-session")
        #expect(values["source_custom"] == "native-custom")
        #expect(values["cf_clearance"] == "new-clearance")
        #expect(values["__cf_bm"] == "new-bot-management")
        #expect(values["_cfuvid"] == "new-visitor")
        var original = URLRequest(url: url)
        original.setValue("session=explicit-source-session; source_custom=explicit-custom; cf_clearance=old-clearance",
                          forHTTPHeaderField: "Cookie")
        let clearance = try #require(CloudflareResponsePolicy.usableClearance(for: url, storage: storage))
        let retried = CloudflareResponsePolicy.request(original, applying: clearance)
        #expect(retried.value(forHTTPHeaderField: "Cookie") ==
            "session=explicit-source-session; source_custom=explicit-custom; cf_clearance=new-clearance")
    }

    @Test func verificationCommitRejectsEmptyExpiredAndOutOfScopeCookies() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let url = URL(string: "http://verification.invalid/api/items")!
        let browserSnapshot = [
            try cookie("cf_clearance", value: ""),
            try cookie("__cf_bm", value: "expired", expires: now.addingTimeInterval(-1)),
            try cookie("_cfuvid", value: "secure-only", secure: true),
            try cookie("cf_clearance", value: "wrong-host", domain: "other.invalid"),
            try cookie("__cf_bm", value: "wrong-path", path: "/apian"),
            try cookie("CF_CLEARANCE", value: "wrong-name"),
            try cookie("provider_token", value: "credential")
        ]
        CloudflareResponsePolicy.commitVerificationCookies(browserSnapshot, for: url, storage: storage, now: now)
        #expect((storage.cookies ?? []).isEmpty)
        let subdomain = URL(string: "http://sub.verification.invalid/api/items")!
        CloudflareResponsePolicy.commitVerificationCookies([try cookie("_cfuvid", value: "host-only-parent")],
                                                           for: subdomain, storage: storage, now: now)
        #expect((storage.cookies ?? []).isEmpty)
    }

    @Test func anotherAcquisitionCannotReplaceAnOwnedBrowser() {
        let owner = CloudflareBrowserOwnership()
        let first = UUID()
        #expect(owner.begin(first))
        #expect(!owner.begin(UUID()))
        #expect(owner.isCurrent(first))
    }
}
