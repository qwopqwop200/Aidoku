@testable import AidokuRunner
import Foundation
import Testing
import Wasm3
import CoreGraphics

struct LifecycleTests {
    @Test func blockingTaskPreservesPriorityAndReusableOptionalResult() async {
        for priority in [TaskPriority.background, .low, .medium, .high] {
            // Awaiting the detached task's value would donate this test's priority.
            let observed: TaskPriority = await withCheckedContinuation { continuation in
                Task.detached(priority: priority) {
                    let task = BlockingTask { Task.currentPriority }
                    let first = task.get()
                    #expect(task.get() == first)
                    continuation.resume(returning: first)
                }
            }
            #expect(observed == priority)
        }
        let overridden: TaskPriority = await withCheckedContinuation { continuation in
            Task.detached(priority: .high) {
                continuation.resume(returning: BlockingTask(priority: .background) { Task.currentPriority }.get())
            }
        }
        #expect(overridden == .background)
        let optional = BlockingTask<Int?> { nil }
        #expect(optional.get() == nil)
        #expect(optional.get() == nil)
    }

    @Test func blockingTaskPreservesSynchronousDispatchPriority() async {
        let priorities: [(DispatchQoS.QoSClass, TaskPriority)] = [
            (.background, .background), (.utility, .low), (.default, .medium),
            (.userInitiated, .high), (.userInteractive, TaskPriority(rawValue: 33))
        ]
        for (qos, expected) in priorities {
            let observed: TaskPriority = await withCheckedContinuation { continuation in
                let work = DispatchWorkItem(qos: DispatchQoS(qosClass: qos, relativePriority: 0), flags: .enforceQoS) {
                    #expect(withUnsafeCurrentTask { $0 == nil })
                    continuation.resume(returning: BlockingTask { Task.currentPriority }.get())
                }
                DispatchQueue.global(qos: qos).async(execute: work)
            }
            #expect(observed == expected)
        }
    }

    @Test @MainActor func webViewFailureWakesWaitersAndHandlerIsReleased() async throws {
        weak var released: WebViewHandler?
        do {
            let handler = WebViewHandler(id: "audit-lifecycle")
            released = handler
            _ = try await handler.evaluateAsyncJavaScript("Promise.resolve('ready')")
            handler.beginLoading()
            handler.webView(handler.webView, didFailProvisionalNavigation: nil,
                withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
            #expect(!handler.waitForLoad())
        }
        #expect(released == nil)
    }

    @Test func closedCanvasSubpathsAreAllRendered() throws {
        let context = try #require(CGContext(data: nil, width: 12, height: 6,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        Path(ops: [
            .moveTo(Point(x: 1, y: 1)), .lineTo(Point(x: 4, y: 1)),
            .lineTo(Point(x: 4, y: 4)), .lineTo(Point(x: 1, y: 4)), .close,
            .moveTo(Point(x: 7, y: 1)), .lineTo(Point(x: 10, y: 1)),
            .lineTo(Point(x: 10, y: 4)), .lineTo(Point(x: 7, y: 4)), .close
        ]).fill(in: context, color: Color(red: 1, green: 0, blue: 0, alpha: 1))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(pixels[2 * context.bytesPerRow + 2 * 4 + 3] == 255)
        #expect(pixels[2 * context.bytesPerRow + 8 * 4 + 3] == 255)
    }

    @Test func javascriptSyntaxErrorsAndCancellationFinish() async throws {
        let context = IsolatedJSContext(exceptionHandler: { _, _ in })
        await #expect(throws: (any Error).self) {
            try await context.evaluateAsyncScript("invalid syntax (")
        }
        let pending = Task { try await context.evaluateAsyncScript("new Promise(() => {})") }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await context.evaluateAsyncScript("Promise.resolve('ready')") == "ready")
    }

    @Test func concurrentJavascriptPromisesKeepSeparateCallbacks() async throws {
        let context = IsolatedJSContext()
        let first = Task { try await context.evaluateAsyncScript("new Promise(resolve => { globalThis.firstDone = resolve; })") }
        let second = Task { try await context.evaluateAsyncScript("new Promise(resolve => { globalThis.secondDone = resolve; })") }
        for _ in 0..<1000 {
            if await context.evaluateScript("typeof firstDone + ',' + typeof secondDone") == "function,function" { break }
            await Task.yield()
        }
        #expect(await context.evaluateScript("typeof firstDone + ',' + typeof secondDone") == "function,function")
        _ = await context.evaluateScript("firstDone('first'); secondDone('second');")
        #expect(try await first.value == "first")
        #expect(try await second.value == "second")
    }

    @Test func removingCallbackReleasesStoredPartial() async {
        let handler = CallbackHandler()
        let id = await handler.registerCallback { _, _ in Data(repeating: 1, count: 1024) }
        await handler.triggerCallbacks(with: Data())
        #expect(await handler.getData(for: id) != nil)
        await handler.removeCallback(id: id)
        #expect(await handler.getData(for: id) == nil)
    }

    @Test func removingSuspendedCallbackDoesNotRestorePartial() async {
        let handler = CallbackHandler()
        let gate = CallbackGate()
        let id = await handler.registerCallback { _, _ in
            await gate.suspend()
            return Data([1])
        }
        let trigger = Task { await handler.triggerCallbacks(with: Data()) }
        await gate.waitUntilSuspended()
        await handler.removeCallback(id: id)
        await gate.resume()
        await trigger.value
        #expect(await handler.getData(for: id) == nil)
    }

    @Test func sourceImportsReleaseModuleAndStore() throws {
        for _ in 0..<100 {
            weak var releasedModule: Module?
            weak var releasedStore: GlobalStore?
            try autoreleasepool {
                let (runtime, module) = try AidokuRunnerTests().module()
                let store = GlobalStore()
                releasedModule = module
                releasedStore = store
                Net(store: store, requestHandler: nil).link(to: module)
                Std(store: store).link(to: module)
                Env(partialValueHandler: CallbackHandler(), printHandler: { _ in }).link(to: module)
                _ = runtime
            }
            #expect(releasedModule == nil)
            #expect(releasedStore == nil)
        }
    }

    @Test func failedMangaUpdateReleasesInterpreter() async throws {
        weak var released: Interpreter?
        do {
            let url = try #require(Bundle.module.url(forResource: "Payload/main", withExtension: "wasm"))
            let interpreter = try await Interpreter(sourceKey: "test", bytes: Array(Data(contentsOf: url)))
            released = interpreter
            await #expect(throws: (any Error).self) {
                try await interpreter.getMangaUpdate(manga: .init(sourceKey: "", key: "", title: ""), needsDetails: false, needsChapters: false)
            }
        }
        #expect(released == nil)
    }

    @Test func partialResultUsesPayloadLengthWithoutHeader() async throws {
        let (runtime, module) = try AidokuRunnerTests().module()
        let memory = try runtime.memory()
        let pointer: Int32 = 0
        defer { withExtendedLifetime(module) {} }
        try memory.write(values: [UInt32(11), UInt32(0)], offset: UInt32(pointer))
        try memory.write(data: Data([1, 2, 3]), offset: UInt32(pointer) + 8)
        let handler = CallbackHandler()
        let id = await handler.registerCallback { _, data in data }
        Env(partialValueHandler: handler, printHandler: { _ in })
            .sendPartialResult(memory: memory, valuePointer: pointer)
        let payload = await handler.getData(for: id) as? Data
        #expect(payload == Data([1, 2, 3]))
    }

    @Test func invalidSourceArgumentsReturnErrorsInsteadOfTrapping() throws {
        let (runtime, module) = try AidokuRunnerTests().module()
        let memory = try runtime.memory()
        let store = GlobalStore()
        let defaults = Defaults(store: store, defaultNamespace: "audit")
        defer { withExtendedLifetime(module) {} }
        let key: Int32 = 16
        let length: Int32 = 4
        try memory.write(string: "test", offset: UInt32(key))
        #expect(defaults.set(memory: memory, keyPointer: key, length: length, valueKind: -1, valuePointer: 0)
            == Defaults.Result.invalidValue.rawValue)
        #expect(defaults.set(memory: memory, keyPointer: key, length: length, valueKind: 0, valuePointer: -1)
            == Defaults.Result.failedDecoding.rawValue)
        Env(partialValueHandler: CallbackHandler(), printHandler: { _ in }).sleep(seconds: -1)
        let canvas = Canvas(store: store)
        let context = canvas.newContext(width: 10, height: 10)
        #expect(canvas.fill(memory: memory, contextPtr: context, pathPtr: -1, r: 0, g: 0, b: 0, a: 1)
            == Canvas.Result.invalidPath.rawValue)
        #expect(canvas.systemFont(weight: -1) >= 0)
    }

    @Test func canvasesReturnTheirOwnImagesAndRejectInvalidDimensions() {
        let store = GlobalStore()
        let canvas = Canvas(store: store)
        #expect(canvas.newContext(width: .nan, height: 10) == Canvas.Result.invalidBounds.rawValue)
        #expect(canvas.newContext(width: .infinity, height: 10) == Canvas.Result.invalidBounds.rawValue)
        let first = canvas.newContext(width: 13, height: 17)
        let second = canvas.newContext(width: 23, height: 29)
        let firstImage = canvas.getImage(contextPtr: first)
        let secondImage = canvas.getImage(contextPtr: second)
        #expect(canvas.getImageWidth(imagePtr: firstImage) == 13)
        #expect(canvas.getImageHeight(imagePtr: firstImage) == 17)
        #expect(canvas.getImageWidth(imagePtr: secondImage) == 23)
        #expect(canvas.getImageHeight(imagePtr: secondImage) == 29)
        #expect(canvas.getImageWidth(imagePtr: canvas.getImage(contextPtr: first)) == 13)
    }
}

private actor CallbackGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            pending = continuation
            waiting?.resume()
            waiting = nil
        }
    }

    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func resume() {
        pending?.resume()
        pending = nil
    }
}

struct ReturnedPageImageOwnershipTests {
    @Test func duplicateReturnedImagesPreserveOrderMetadataAndPixelsAndReleaseDescriptors() throws {
        let store = GlobalStore()
        let canvas = Canvas(store: store)
        let context = canvas.newContext(width: 3, height: 5)
        let pointer = canvas.getImage(contextPtr: context)
        store.remove(at: context)
        let image = try #require(store.fetchImage(from: pointer))
        let original = try #require(image.pngData())
        let pages = [
            PageCodable(content: .image(pointer), thumbnail: nil, hasDescription: true, description: "first"),
            PageCodable(content: .text("middle"), thumbnail: nil, hasDescription: false, description: nil),
            PageCodable(content: .image(pointer), thumbnail: nil, hasDescription: true, description: "last")
        ]
        let decoded = try PostcardDecoder().decode([PageCodable].self, from: PostcardEncoder().encode(pages))
        let result = PageCodable.consume(decoded, store: store)
        #expect(result.count == 3)
        #expect(result.map(\.description) == ["first", nil, "last"])
        #expect(store.storage.isEmpty)
        #expect(result[1].content == .text("middle"))
        for index in [0, 2] {
            guard case let .image(output) = result[index].content else {
                Issue.record("Returned image was lost")
                return
            }
            #expect(output.size == image.size)
            #expect(output.pngData() == original)
        }
    }

    @Test func repeatedReturnedImagesDoNotAccumulateStoreEntries() throws {
        let store = GlobalStore()
        let canvas = Canvas(store: store)
        for _ in 0..<50 {
            let context = canvas.newContext(width: 2, height: 2)
            let pointer = canvas.getImage(contextPtr: context)
            store.remove(at: context)
            let page = PageCodable(content: .image(pointer), thumbnail: nil, hasDescription: false, description: nil)
            #expect(PageCodable.consume([page], store: store).count == 1)
            #expect(store.storage.isEmpty)
        }
    }
}
