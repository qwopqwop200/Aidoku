@testable import AidokuRunner
import Foundation
import Testing
import Wasm3

struct AidokuRunnerTests {
    private enum TestError: Error {
        case missingResource
        case invalidSource
    }

    func source() async throws -> Source {
        guard let url = Bundle.module.url(forResource: "Payload", withExtension: nil)
        else { throw TestError.missingResource }
        return try await Source(url: url)
    }

    func module() throws -> (Runtime, Module) {
        // Fixture used for source lifecycle tests and import memory access.
        guard let url = Bundle.module.url(forResource: "Payload/main", withExtension: "wasm")
        else { throw TestError.missingResource }
        let data = try Data(contentsOf: url)
        let env = try Environment()
        let runtime = try env.createRuntime(stackSize: 1024 * 200)
        let module = try runtime.parseAndLoadModule(bytes: [UInt8](data))
        return (runtime, module)
    }

    @Test func testLoadSource() async throws {
        let source = try await self.source()
        #expect(source.key == "test")
        #expect(source.name == "Test")
        #expect(source.version == 1)
    }

    @Test func testSourcePanic() async throws {
        let source = try await self.source()
        await #expect(throws: Wasm3Error.trap(.unreachable)) {
            try await source.getMangaUpdate(manga: .init(sourceKey: "", key: "", title: ""), needsDetails: false, needsChapters: false)
        }
        await #expect(throws: Wasm3Error.runtimeDisabled) {
            try await source.getHome()
        }
        try await source.restart()
        _ = try await source.getHome() // should not throw after restart
    }
}

extension AidokuRunnerTests {
    @Test func testJavascript() async throws {
        let (runtime, module) = try module()
        let store = GlobalStore()
        let writer = TestMemoryWriter(memory: try runtime.memory())
        defer { withExtendedLifetime(module) {} }
        let library = JavaScript(
            store: store,
            printHandler: { print("JS Print:", $0) },
            webViewNamespace: "test"
        )

        let ctx = library.contextCreate()
        let wv = library.webViewCreate()

        // basic js eval
        if true {
            let (ptr, length) = try writer.write(string: "1+1")
            let memory = try runtime.memory()

            let rid = library.contextEval(memory: memory, descriptor: ctx, stringPointer: ptr, length: length)
            let result = store.fetch(from: rid) as? String
            #expect(result == "2")

            let rid2 = library.webViewEval(memory: memory, descriptor: wv, stringPointer: ptr, length: length)
            let result2 = store.fetch(from: rid2) as? String
            #expect(result2 == "2")
        }

        // async js eval
        if true {
            let js = """
                new Promise((resolve) => {
                    resolve("async test");
                })
            """
            let (ptr, length) = try writer.write(string: js)
            let memory = try runtime.memory()

            let rid = library.contextEvalAsync(memory: memory, descriptor: ctx, stringPointer: ptr, length: length)
            let result = store.fetch(from: rid) as? String
            #expect(result == "async test")

            let rid2 = library.webViewEvalAsync(memory: memory, descriptor: wv, stringPointer: ptr, length: length)
            let result2 = store.fetch(from: rid2) as? String
            #expect(result2 == "async test")

            let rid3 = library.contextEvalAsync(memory: memory, descriptor: ctx, stringPointer: ptr, length: length)
            let result3 = store.fetch(from: rid3) as? String
            #expect(result3 == "async test")

            let rid4 = library.webViewEvalAsync(memory: memory, descriptor: wv, stringPointer: ptr, length: length)
            let result4 = store.fetch(from: rid4) as? String
            #expect(result4 == "async test")
        }

        // rule list blocking
        if true {
            let html = """
                <!doctype html>
                <html>
                <body>
                <script>
                window.blockTestResult = "pending";

                const img = new Image();
                img.onload = () => { window.blockTestResult = "loaded"; };
                img.onerror = () => { window.blockTestResult = "blocked-or-failed"; };
                img.src = "https://aidoku.app/images/aidoku.svg";

                document.body.appendChild(img);
                </script>
                </body>
                </html>
            """
            let js = "window.blockTestResult"
            let ruleList = """
                [
                  {
                    "trigger": {
                      "url-filter": ".*aidoku.svg*",
                      "resource-type": ["image"]
                    },
                    "action": {
                      "type": "block"
                    }
                  }
                ]
            """
            let (htmlPtr, htmlLength) = try writer.write(string: html)
            let (jsPtr, jsLength) = try writer.write(string: js)
            let (rulesPtr, rulesLength) = try writer.write(string: ruleList)
            let memory = try runtime.memory()

            #expect(library.webViewLoadHtml(
                memory: memory,
                descriptor: wv,
                stringPointer: htmlPtr,
                length: htmlLength,
                urlStringPointer: -1,
                urlLength: 0
            ) == 0)
            #expect(library.webViewWaitForLoad(descriptor: wv) == 0)

            let rid = library.webViewEval(memory: memory, descriptor: wv, stringPointer: jsPtr, length: jsLength)
            let result = store.fetch(from: rid) as? String
            #expect(result == "loaded")

            #expect(library.webViewSetRuleList(
                memory: memory,
                descriptor: wv,
                stringPointer: rulesPtr,
                length: rulesLength
            ) == 0)
            #expect(library.webViewLoadHtml(
                memory: memory,
                descriptor: wv,
                stringPointer: htmlPtr,
                length: htmlLength,
                urlStringPointer: -1,
                urlLength: 0
            ) == 0)
            #expect(library.webViewWaitForLoad(descriptor: wv) == 0)

            let rid2 = library.webViewEval(memory: memory, descriptor: wv, stringPointer: jsPtr, length: jsLength)
            let result2 = store.fetch(from: rid2) as? String
            #expect(result2 == "blocked-or-failed")
        }

        // user script
        if true {
            let html = "<!doctype html><html><body></body></html>"
            let script = "window.userScriptTestResult = 'injected';"
            let js = "window.userScriptTestResult"

            let (htmlPtr, htmlLength) = try writer.write(string: html)
            let (scriptPtr, scriptLength) = try writer.write(string: script)
            let (jsPtr, jsLength) = try writer.write(string: js)
            let memory = try runtime.memory()

            #expect(library.webViewAddUserScript(
                memory: memory,
                descriptor: wv,
                stringPointer: scriptPtr,
                length: scriptLength,
                atDocumentEnd: 0,
                forMainFrameOnly: 0
            ) == 0)

            #expect(library.webViewLoadHtml(
                memory: memory,
                descriptor: wv,
                stringPointer: htmlPtr,
                length: htmlLength,
                urlStringPointer: -1,
                urlLength: 0
            ) == 0)
            #expect(library.webViewWaitForLoad(descriptor: wv) == 0)

            let rid2 = library.webViewEvalAsync(memory: memory, descriptor: wv, stringPointer: jsPtr, length: jsLength)
            let result2 = store.fetch(from: rid2) as? String
            #expect(result2 == "injected")
        }
    }
}

// The fixture no longer exports alloc. Import tests do not execute source code,
// so reserve disjoint slices of its memory directly, preserving every payload.
private final class TestMemoryWriter {
    let memory: Memory
    private var nextOffset: UInt32 = 0

    init(memory: Memory) { self.memory = memory }

    func write(string: String) throws -> (Int32, Int32) {
        let bytes = Data(string.utf8)
        let offset = nextOffset
        try memory.write(data: bytes, offset: offset)
        nextOffset += UInt32(bytes.count)
        return (Int32(offset), Int32(bytes.count))
    }
}
