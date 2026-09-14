import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationConnectionTestModelTests {
    @Test func showsTranslatedResultAndPreventsDoubleTapButAllowsExplicitRetest() async throws {
        let gate = ConnectionTestGate()
        let model = ReaderTranslationConnectionTest { _, _ in await gate.run() }
        model.start(settings: ReaderTranslationSettings(), apiKey: "")
        model.start(settings: ReaderTranslationSettings(), apiKey: "")
        try await waitUntil { await gate.calls == 1 }
        #expect(model.state == .running)
        await gate.release()
        try await waitUntil { model.state == .success("연결 테스트") }
        model.start(settings: ReaderTranslationSettings(), apiKey: "")
        try await waitUntil { await gate.calls == 2 }
        try await waitUntil { model.state == .success("연결 테스트") }
    }

    @Test func editingOrLeavingCancelsAndRejectsLateResult() async throws {
        let gate = ConnectionTestGate()
        var completed = false
        let model = ReaderTranslationConnectionTest { _, _ in await gate.run() }
        model.start(settings: ReaderTranslationSettings(), apiKey: "") { _ in completed = true }
        try await waitUntil { await gate.calls == 1 }
        model.reset()
        await gate.release()
        try await Task.sleep(nanoseconds: 15_000_000)
        #expect(model.state == .idle)
        #expect(!completed)
    }

    @Test func failureShowsErrorAndCanBeRetried() async throws {
        let error = RemoteTranslationError.httpStatus(401, requestID: nil)
        let model = ReaderTranslationConnectionTest { _, _ in throw error }
        model.start(settings: ReaderTranslationSettings(), apiKey: "")
        try await waitUntil { model.state == .failure(error.localizedDescription) }
        model.reset()
        #expect(model.state == .idle)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
private actor ConnectionTestGate {
    private(set) var calls = 0
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func run() async -> String {
        calls += 1
        if !released { await withCheckedContinuation { continuation = $0 } }
        return "연결 테스트"
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
