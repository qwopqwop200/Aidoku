import XCTest
@testable import Wasm3

final class RuntimeLifetimeTests: XCTestCase {
    // (module (import "env" "value" (func (result i32)))
    //   (memory 1) (func (export "run") (result i32) call 0))
    private let bytes: [UInt8] = [
        0,97,115,109,1,0,0,0,
        1,5,1,96,0,1,127,
        2,13,1,3,101,110,118,5,118,97,108,117,101,0,0,
        3,2,1,0,
        5,3,1,0,1,
        7,7,1,3,114,117,110,0,1,
        10,6,1,4,0,16,0,11
    ]
    private final class Probe { let value: Int32 = 42 }

    func testCallbacksReleaseAfterLastFunctionHandle() throws {
        weak var weakRuntime: Runtime?
        weak var weakProbe: Probe?
        var function: Function?
        do {
            let runtime = try Environment().createRuntime(stackSize: 4096)
            weakRuntime = runtime
            let module = try runtime.parseAndLoadModule(bytes: bytes)
            let probe = Probe()
            weakProbe = probe
            try module.linkFunction(name: "value", namespace: "env", function: { probe.value })
            function = try module.findFunction(name: "run")
        }
        XCTAssertNotNil(weakRuntime)
        let value: Int32 = try XCTUnwrap(function).call()
        XCTAssertEqual(value, 42)
        function = nil
        XCTAssertNil(weakRuntime)
        XCTAssertNil(weakProbe)
    }

    func testMemoryCallbackSurvivesModuleWrapper() throws {
        var function: Function?
        weak var weakRuntime: Runtime?
        do {
            let runtime = try Environment().createRuntime(stackSize: 4096)
            weakRuntime = runtime
            let module = try runtime.parseAndLoadModule(bytes: bytes)
            try module.linkFunction(name: "value", namespace: "env", function: { (memory: Memory) -> Int32 in
                (try? memory.readValues(offset: 0, length: 1) as [Int32])?.first ?? -1
            })
            try runtime.memory().write(bytes: [42, 0, 0, 0], offset: 0)
            function = try module.findFunction(name: "run")
        }
        let value: Int32 = try XCTUnwrap(function).call()
        XCTAssertEqual(value, 42)
        function = nil
        XCTAssertNil(weakRuntime)
    }

    func testInt64FunctionResultUsesCorrectType() throws {
        var wideBytes = bytes
        wideBytes[14] = 126 // i64 return type
        let runtime = try Environment().createRuntime(stackSize: 4096)
        let module = try runtime.parseAndLoadModule(bytes: wideBytes)
        try module.linkFunction(name: "value", namespace: "env", function: { Int64.max })
        let value: Int64 = try module.findFunction(name: "run").call()
        XCTAssertEqual(value, Int64.max)
    }

    func testParsedModuleTransfersOwnershipOnlyOnce() throws {
        let env = try Environment()
        let parsed = try env.parseModule(bytes: bytes)
        let other = try Environment().createRuntime(stackSize: 4096)
        XCTAssertThrowsError(try other.loadModule(module: parsed))
        XCTAssertNotNil(parsed.raw)
        let runtime = try env.createRuntime(stackSize: 4096)
        _ = try runtime.loadModule(module: parsed)
        XCTAssertNil(parsed.raw)
        XCTAssertThrowsError(try runtime.loadModule(module: parsed))
    }

    func testGlobalKeepsRuntimeAndChecksType() throws {
        // (global (export "g") (mut i64) (i64.const 42))
        let globalBytes: [UInt8] = [0,97,115,109,1,0,0,0,6,6,1,126,1,66,42,11,7,5,1,1,103,3,0]
        var global: Global<Int64>?
        weak var weakRuntime: Runtime?
        do {
            let runtime = try Environment().createRuntime(stackSize: 4096)
            weakRuntime = runtime
            let module = try runtime.parseAndLoadModule(bytes: globalBytes)
            XCTAssertNil(module.findGlobal(name: "g", type: Int32.self))
            global = module.findGlobal(name: "g", type: Int64.self)
        }
        XCTAssertEqual(try XCTUnwrap(global).value(), 42)
        try global?.set(Int64.max)
        XCTAssertEqual(try global?.value(), Int64.max)
        global = nil
        XCTAssertNil(weakRuntime)
    }

    func testRepeatedRuntimeReleaseDoesNotAccumulateCallbacks() throws {
        for _ in 0..<100 {
            weak var weakProbe: Probe?
            do {
                let runtime = try Environment().createRuntime(stackSize: 4096)
                let module = try runtime.parseAndLoadModule(bytes: bytes)
                let probe = Probe()
                weakProbe = probe
                try module.linkFunction(name: "value", namespace: "env", function: { probe.value })
                let value: Int32 = try module.findFunction(name: "run").call()
                XCTAssertEqual(value, 42)
            }
            XCTAssertNil(weakProbe)
        }
    }

    func testMemoryBeforeModuleLoadingFailsSafely() throws {
        let runtime = try Environment().createRuntime(stackSize: 4096)
        XCTAssertThrowsError(try runtime.memory())
    }

    func testMemoryRejectsOverflowAndTypedOutOfBounds() throws {
        let runtime = try Environment().createRuntime(stackSize: 4096)
        _ = try runtime.parseAndLoadModule(bytes: bytes)
        let memory = try runtime.memory()
        XCTAssertThrowsError(try memory.readData(offset: UInt32.max - 2, length: 8))
        XCTAssertThrowsError(try memory.readValues(offset: 65_532, length: 2) as [Int32])
        try memory.write(bytes: [1, 0, 0, 0], offset: 1)
        let values: [Int32] = try memory.readValues(offset: 1, length: 1)
        XCTAssertEqual(values, [1])
    }
}
