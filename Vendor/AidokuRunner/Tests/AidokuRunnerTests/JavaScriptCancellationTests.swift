import Foundation
import Testing
import Wasm3
@testable import AidokuRunner

struct JavaScriptCancellationTests {
    @Test(arguments: [false, true])
    func sourceImportCancelsNeverResolvingPromise(webView: Bool) async throws {
        let started = ImportStarted()
        let worker = Task.detached {
            let url = try #require(Bundle.module.url(forResource: "Payload/main", withExtension: "wasm"))
            let env = try Environment()
            let runtime = try env.createRuntime(stackSize: 1024 * 200)
            let module = try runtime.parseAndLoadModule(bytes: [UInt8](Data(contentsOf: url)))
            defer { withExtendedLifetime(module) {} }
            let store = GlobalStore()
            let library = JavaScript(store: store, printHandler: { _ in }, webViewNamespace: "cancel-" + UUID().uuidString)
            let descriptor = webView ? library.webViewCreate() : library.contextCreate()
            let memory = try runtime.memory()
            let script = Data("new Promise(() => {})".utf8)
            try memory.write(data: script, offset: 0)
            await started.mark()
            let result = webView
                ? library.webViewEvalAsync(memory: memory, descriptor: descriptor, stringPointer: 0, length: Int32(script.count))
                : library.contextEvalAsync(memory: memory, descriptor: descriptor, stringPointer: 0, length: Int32(script.count))
            return result
        }
        defer { worker.cancel() }
        for _ in 0..<2_000 {
            if await started.value { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await started.value)
        // Let the bridge enter its suspension; this is a cancellation deadline
        // check, not a performance benchmark of WebKit startup.
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        worker.cancel()
        #expect(try await worker.value == JavaScript.Result.missingResult.rawValue)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
private actor ImportStarted {
    var value = false
    func mark() { value = true }
}
