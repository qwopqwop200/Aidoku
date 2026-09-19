//
//  IsolatedJSContext.swift
//  AidokuRunner
//
//  Created by skitty on 6/26/26.
//

import JavaScriptCore

actor IsolatedJSContext {
    let context: JSContext

    init(exceptionHandler: ((JSContext?, JSValue?) -> Void)? = nil) {
        context = .init()
        if let exceptionHandler {
            context.exceptionHandler = { context, exception in
                context?.exception = exception
                exceptionHandler(context, exception)
            }
        }
    }

    func evaluateScript(_ script: String) -> String? {
        context.evaluateScript(script)?.toString()
    }

    func evaluateAsyncScript(_ script: String) async throws -> String {
        try Task.checkCancellation()
        // Callback arguments belong to this invocation; concurrent evaluations
        // must never overwrite another suspended promise's completion functions.
        context.exception = nil
        let function = context.evaluateScript("""
        (function(resolve, reject) {
            (async () => {
                try { resolve(String(await (\(script)))); }
                catch (error) { reject(String(error.message || error)); }
            })();
        })
        """)
        if let exception = context.exception {
            throw Self.scriptError(exception.toString() ?? "Invalid JavaScript")
        }
        guard let function, !function.isUndefined else {
            throw Self.scriptError("Invalid JavaScript")
        }
        let completion = ScriptCompletion()
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { return }
            completion.finish(.failure(Self.scriptError("JavaScript promise timed out")))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let resolve: @convention(block) (String) -> Void = { value in
                    completion.finish(.success(value))
                }
                let reject: @convention(block) (String) -> Void = { message in
                    completion.finish(.failure(Self.scriptError(message)))
                }
                let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let resolveKey = "__aidokuResolve" + token
                let rejectKey = "__aidokuReject" + token
                context.setObject(resolve, forKeyedSubscript: resolveKey as NSString)
                context.setObject(reject, forKeyedSubscript: rejectKey as NSString)
                defer {
                    context.globalObject.deleteProperty(resolveKey)
                    context.globalObject.deleteProperty(rejectKey)
                }
                if let resolveFunction = context.objectForKeyedSubscript(resolveKey),
                   let rejectFunction = context.objectForKeyedSubscript(rejectKey) {
                    function.call(withArguments: [resolveFunction, rejectFunction])
                } else {
                    completion.finish(.failure(Self.scriptError("Could not create promise callbacks")))
                }
                if let exception = context.exception {
                    completion.finish(.failure(Self.scriptError(exception.toString() ?? "JavaScript failed")))
                }
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
    }

    private static func scriptError(_ message: String) -> NSError {
        NSError(domain: "IsolatedJSContext", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func objectForKeyedSubscript(_ key: Any) -> String? {
        context.objectForKeyedSubscript(key)?.toString()
    }
}

// Completion may race cancellation and JavaScript resolution. Resume exactly once,
// including cancellation that arrives before continuation installation.
private final class ScriptCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    func install(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
