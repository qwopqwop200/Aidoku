import Darwin
import XCTest
import wasm3_c
@testable import Wasm3

final class WASIMemorySafetyTests: XCTestCase {
    private func leb(_ value: Int) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            let next = UInt8(value & 127)
            value >>= 7
            bytes.append(next | (value == 0 ? 0 : 128))
        } while value != 0
        return bytes
    }

    private func module(_ name: String, types: [UInt8]) throws -> (Runtime, Module, Function) {
        func string(_ value: String) -> [UInt8] { leb(value.utf8.count) + value.utf8 }
        func section(_ id: UInt8, _ contents: [UInt8]) -> [UInt8] { [id] + leb(contents.count) + contents }
        var bytes: [UInt8] = [0, 97, 115, 109, 1, 0, 0, 0]
        bytes += section(1, [1, 96] + leb(types.count) + types + [1, 127])
        bytes += section(2, [1] + string("wasi_snapshot_preview1") + string(name) + [0, 0])
        bytes += section(3, [1, 0])
        bytes += section(5, [1, 0, 1])
        bytes += section(7, [1] + string("run") + [0, 1])
        var body: [UInt8] = [0]
        for index in types.indices { body += [32] + leb(index) }
        body += [16, 0, 11]
        bytes += section(10, [1] + leb(body.count) + body)
        let runtime = try Environment().createRuntime(stackSize: 4096)
        let module = try runtime.parseAndLoadModule(bytes: bytes)
        try module.linkWasi()
        return (runtime, module, try module.findFunction(name: "run"))
    }

    private func call(_ function: Function, _ values: [UInt64]) -> M3Result? {
        values.withUnsafeBufferPointer { buffer in
            var args: [UnsafeRawPointer?] = values.indices.map { UnsafeRawPointer(buffer.baseAddress!.advanced(by: $0)) }
            return args.withUnsafeMutableBufferPointer { m3_Call(function.raw, UInt32(values.count), $0.baseAddress) }
        }
    }

    private func result(_ function: Function) -> UInt32 {
        var value: UInt32 = 999
        withUnsafeMutablePointer(to: &value) { pointer in
            var raw: UnsafeRawPointer? = UnsafeRawPointer(pointer)
            XCTAssertNil(m3_GetResults(function.raw, 1, &raw))
        }
        return value
    }

    func testArgumentTerminatorMustFitGuestMemory() throws {
        let (runtime, module, function) = try module("args_get", types: [127, 127])
        _ = module
        let context = try XCTUnwrap(m3_GetWasiContext())
        let text = strdup("A")!
        defer { free(text) }
        var argument: UnsafePointer<CChar>? = UnsafePointer(text)
        try withUnsafePointer(to: &argument) { arguments in
            let old = context.pointee
            defer { context.pointee = old }
            context.pointee.argc = 1
            context.pointee.argv = arguments
            XCTAssertNotNil(call(function, [0, 65_535]))
            XCTAssertNil(call(function, [0, 65_534]))
            XCTAssertEqual(result(function), 0)
            XCTAssertEqual(try runtime.memory().readBytes(offset: 65_534, length: 2), [65, 0])
        }
    }

    func testOversizedVectorsReturnInvalidWithoutHostStackAllocation() throws {
        for name in ["fd_read", "fd_write"] {
            let (runtime, module, function) = try module(name, types: [127, 127, 127, 127])
            _ = runtime; _ = module
            XCTAssertNil(call(function, [UInt64(UInt32.max), 0, UInt64(UInt32.max), 16]))
            XCTAssertEqual(result(function), 28)
        }
    }

    func testInvalidPreopenIndexReturnsBadDescriptor() throws {
        let (runtime, module, function) = try module("path_open", types: [127, 127, 127, 127, 127, 126, 126, 127, 127])
        _ = runtime; _ = module
        XCTAssertNil(call(function, [UInt64(UInt32.max), 0, 8, 0, 0, 2, 0, 0, 16]))
        XCTAssertEqual(result(function), 8)
    }

    func testInvalidCloseReturnsWasiErrorInsteadOfNegativePosixValue() throws {
        let (runtime, module, function) = try module("fd_close", types: [127])
        _ = runtime; _ = module
        XCTAssertNil(call(function, [UInt64(UInt32.max)]))
        XCTAssertEqual(result(function), 8)
    }

    func testRepeatedLinkingDoesNotLeakPreopenDescriptors() throws {
        let (_, module, _) = try module("args_sizes_get", types: [127, 127])
        func descriptorCount() -> Int { (0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
        let baseline = descriptorCount()
        for _ in 0..<100 { try module.linkWasi() }
        XCTAssertEqual(descriptorCount(), baseline)
    }
    func testPreopenNameIsNotNulTerminatedAndRejectsShortBuffer() throws {
        let (runtime, module, function) = try module("fd_prestat_dir_name", types: [127, 127, 127])
        _ = module
        try runtime.memory().write(bytes: [99, 99, 99], offset: 8)
        XCTAssertNil(call(function, [4, 8, 1]))
        XCTAssertEqual(result(function), 37)
        XCTAssertNil(call(function, [4, 8, 3]))
        XCTAssertEqual(result(function), 0)
        XCTAssertEqual(try runtime.memory().readBytes(offset: 8, length: 3), [46, 47, 99])
    }

    func testSetFlagsDoesNotReportSuccessForInvalidDescriptor() throws {
        let (runtime, module, function) = try module("fd_fdstat_set_flags", types: [127, 127])
        _ = runtime; _ = module
        XCTAssertNil(call(function, [UInt64(UInt32.max), 0]))
        XCTAssertEqual(result(function), 8)
    }

}
