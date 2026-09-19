import XCTest
import wasm3_c
@testable import Wasm3

final class CoreMemorySafetyTests: XCTestCase {
    private func branchModule(body: [UInt8], result: Bool) -> [UInt8] {
        let signature: [UInt8] = result ? [1,5,1,96,0,1,127] : [1,4,1,96,0,0]
        return [0,97,115,109,1,0,0,0] + signature + [3,2,1,0,7,7,1,3,114,117,110,0,0]
            + [10, UInt8(body.count + 2), 1, UInt8(body.count)] + body
    }

    func testOversizedBranchTableFailsWithoutAllocatingHugeCodePage() throws {
        let runtime = try Environment().createRuntime(stackSize: 4096)
        let module = try runtime.parseAndLoadModule(bytes: branchModule(
            body: [0,65,0,14,255,255,255,255,15,0,11], result: false))
        XCTAssertThrowsError(try module.findFunction(name: "run"))
    }

    func testInvalidBranchResultRestoresCompilationPageOnFailure() throws {
        for _ in 0..<20 {
            let runtime = try Environment().createRuntime(stackSize: 4096)
            let module = try runtime.parseAndLoadModule(bytes: branchModule(
                body: [0,65,0,14,0,0,11], result: true))
            // br_table consumes the sole i32 as its selector, leaving no return value.
            XCTAssertThrowsError(try module.findFunction(name: "run"))
        }
    }

    func testLazyCompileFailureRemainsRetryable() throws {
        // Exported void function calls an invalid void callee leaving an i32 on its stack.
        let bytes: [UInt8] = [0,97,115,109,1,0,0,0,1,4,1,96,0,0,3,3,2,0,0,
            7,7,1,3,114,117,110,0,0,10,11,2,4,0,16,1,11,4,0,65,1,11]
        let runtime = try Environment().createRuntime(stackSize: 4096)
        let module = try runtime.parseAndLoadModule(bytes: bytes)
        let function = try module.findFunction(name: "run")
        for _ in 0..<5 {
            XCTAssertNotNil(m3_Call(function.raw, 0, nil))
        }
    }

    func testLibcPrintfChecksStringsBeforeReadingPastMemory() throws {
        // Imported printf and exported run(fmt,args).
        let bytes: [UInt8] = [0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,
            2,14,1,3,101,110,118,6,112,114,105,110,116,102,0,0,
            3,2,1,0,5,3,1,0,1,7,7,1,3,114,117,110,0,1,
            10,10,1,8,0,32,0,32,1,16,0,11]
        let runtime = try Environment().createRuntime(stackSize: 4096)
        let module = try runtime.parseAndLoadModule(bytes: bytes)
        XCTAssertNil(m3_LinkLibC(module.raw))
        let function = try module.findFunction(name: "run")
        let memory = try runtime.memory()
        func call(_ format: Int32, _ arguments: Int32) -> M3Result? {
            var format = format
            var arguments = arguments
            return withUnsafePointer(to: &format) { formatPointer in
                withUnsafePointer(to: &arguments) { argumentPointer in
                    var pointers: [UnsafeRawPointer?] = [UnsafeRawPointer(formatPointer), UnsafeRawPointer(argumentPointer)]
                    return pointers.withUnsafeMutableBufferPointer { m3_Call(function.raw, 2, $0.baseAddress) }
                }
            }
        }
        try memory.write(bytes: [65], offset: 65_535)
        XCTAssertNotNil(call(65_535, 0))
        try memory.write(bytes: [37,115,0], offset: 8)
        try memory.write(bytes: [255,255,255,255], offset: 16)
        XCTAssertNotNil(call(8, 16))
        try memory.write(bytes: [37,0], offset: 65_534)
        XCTAssertNil(call(65_534, 0))
    }

    func testExplicitZeroMaximumMemoryCannotGrow() throws {
        let runtime = try Environment().createRuntime(stackSize: 4096)
        _ = try runtime.parseAndLoadModule(bytes: [0,97,115,109,1,0,0,0,5,4,1,1,0,0])
        XCTAssertThrowsError(try runtime.resizeMemory(numPages: 1))
    }

    func testOverlongIntegerPayloadCannotTruncateToValidMemorySize() throws {
        let bytes: [UInt8] = [0,97,115,109,1,0,0,0,5,7,1,0,128,128,128,128,16]
        XCTAssertThrowsError(try Environment().parseModule(bytes: bytes))
    }

    func testEmptyMemoryGettersReturnZero() throws {
        let runtime = try Environment().createRuntime(stackSize: 4096)
        XCTAssertEqual(m3_GetMemorySize(runtime.raw), 0)
        var size: UInt32 = 99
        XCTAssertNil(m3_GetMemory(nil, &size, 0))
        XCTAssertEqual(size, 0)
    }

    func testTruncatedMemoryDeclarationFailsParsing() throws {
        // Memory section: one memory, flags=0, missing initial page count.
        let bytes: [UInt8] = [0,97,115,109,1,0,0,0,5,2,1,0]
        XCTAssertThrowsError(try Environment().parseModule(bytes: bytes))
    }

    func testInvalidCustomPageSizeFailsParsing() throws {
        // Shift exponent 32 cannot be represented by the engine's u32 page size.
        let bytes: [UInt8] = [0,97,115,109,1,0,0,0,5,4,1,8,1,32]
        XCTAssertThrowsError(try Environment().parseModule(bytes: bytes))
    }

    func testPageByteCountDoesNotWrapAtFourGiB() throws {
        let runtime = try Environment().createRuntime(stackSize: 4096)
        runtime.raw.pointee.memory.pageSize = 65_536
        runtime.raw.pointee.memory.maxPages = 65_536
        // Exercise 65536 * 65536 without allocating 4 GiB.
        runtime.raw.pointee.memoryLimit = 64
        try runtime.resizeMemory(numPages: 65_536)
        XCTAssertEqual(m3_GetMemorySize(runtime.raw), 64)
        XCTAssertEqual(try runtime.memory().readBytes(offset: 0, length: 64), Array(repeating: 0, count: 64))
    }

    func testGrowingClampedMemoryZeroesNewBytes() throws {
        let runtime = try Environment().createRuntime(stackSize: 4096)
        runtime.raw.pointee.memory.pageSize = 65_536
        runtime.raw.pointee.memory.maxPages = 2
        runtime.raw.pointee.memoryLimit = 16
        try runtime.resizeMemory(numPages: 1)
        try runtime.memory().write(bytes: Array(repeating: 7, count: 16), offset: 0)
        runtime.raw.pointee.memoryLimit = 32
        try runtime.resizeMemory(numPages: 2)
        XCTAssertEqual(try runtime.memory().readBytes(offset: 0, length: 16), Array(repeating: 7, count: 16))
        XCTAssertEqual(try runtime.memory().readBytes(offset: 16, length: 16), Array(repeating: 0, count: 16))
    }
}
