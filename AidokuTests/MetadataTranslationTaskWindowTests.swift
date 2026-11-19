import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct MetadataTranslationTaskWindowTests {
    @Test func thousandSuspendedOperationsStayBoundedAndAllFinishInInputOrder() async throws {
        let input = Array(0..<1000)
        let probe = WindowProbe()
        let task = Task { await MetadataTranslationTaskWindow.map(input, fallback: { $0 }) { await probe.run($0) } }
        defer { task.cancel() }
        try await wait { await probe.started == MetadataTranslationTaskWindow.maximumTasks }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await probe.started == 64)
        #expect(await probe.active == 64)
        await probe.release()
        let result = await task.value
        #expect(result == input.map { $0 + 10_000 })
        #expect(await probe.started == 1000)
        #expect(await probe.peak <= 64)
        #expect(await probe.active == 0)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let limit = Date().addingTimeInterval(10)
        while !(await condition()) { try #require(Date() < limit); try await Task.sleep(for: .milliseconds(5)) }
    }
}

private actor WindowProbe {
    var started = 0, active = 0, peak = 0
    private var released = false
    func release() { released = true }
    func run(_ value: Int) async -> Int {
        started += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        while !released && !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return value }
        }
        return Task.isCancelled ? value : value + 10_000
    }
}
