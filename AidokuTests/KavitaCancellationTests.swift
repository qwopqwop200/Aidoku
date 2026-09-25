import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct KavitaCancellationTests {
    @Test func cancelledMirrorRequestStopsRetryAndPreservesWorkingMirror() async throws {
        let key = "kavita-cancellation-" + UUID().uuidString
        let defaults = UserDefaults.standard
        defaults.set("https://primary.invalid/", forKey: "\(key).server")
        defaults.set(["https://second.invalid/"], forKey: "\(key).mirrors")
        defaults.set("fixture", forKey: "\(key).token")
        defer { for field in ["server", "mirrors", "token"] { defaults.removeObject(forKey: "\(key).\(field)") } }
        let requests = KavitaCancellationRequests()
        let helper = KavitaHelper(sourceKey: key, transport: { request in
            await requests.record()
            withUnsafeCurrentTask { $0?.cancel() }
            throw URLError(.cancelled)
        })
        let previousMirror = URL(string: "https://working.invalid/")!
        let task = Task {
            var mirror: URL? = previousMirror
            do {
                let _: KavitaEmptyResponse = try await helper.request(path: "api/test", lastWorkingMirror: &mirror)
                Issue.record("Cancelled request unexpectedly completed")
            } catch let error as SourceError {
                #expect(error == SourceError.networkError)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
            return mirror
        }
        #expect(await task.value == previousMirror)
        #expect(await requests.count == 1)
    }

    @Test func alreadyCancelledRequestDoesNotResolveConfigurationOrRefreshAuthentication() async {
        let helper = KavitaHelper(sourceKey: "unconfigured-cancelled-source")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let _: KavitaEmptyResponse = try await helper.request(path: "api/test")
                Issue.record("Cancelled request unexpectedly completed")
            } catch let error as SourceError {
                #expect(error == SourceError.networkError)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
            do {
                _ = try await helper.refreshToken()
                Issue.record("Cancelled refresh unexpectedly completed")
            } catch let error as SourceError {
                #expect(error == SourceError.networkError)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
        await task.value
    }
}

private actor KavitaCancellationRequests {
    var count = 0
    func record() { count += 1 }
}
