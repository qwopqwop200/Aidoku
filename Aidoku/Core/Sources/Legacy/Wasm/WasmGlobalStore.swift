//
//  Wasmswift
//  Aidoku
//
//  Created by Skitty on 3/30/22.
//

import Foundation
import Wasm3

class WasmGlobalStore {
    var id: String
    var vm: Module

    var chapterCounter = 0
    var currentManga = ""

    // std
    var stdDescriptorPointer: Int32 = -1
    var stdDescriptors: [Int32: Any?] = [:]
//    var stdReferences: [Int32: [Int32]] = [:]

    // net
    var requestsPointer: Int32 = -1
    var requests: [Int32: WasmRequestObject] = [:]

    init(id: String, vm: Module) {
        self.id = id
        self.vm = vm
    }

    func readStdValue(_ descriptor: Int32) -> Any? {
        stdDescriptors[descriptor] as Any?
    }

    func storeStdValue(_ data: Any?) -> Int32 {
        stdDescriptorPointer += 1
        stdDescriptors[stdDescriptorPointer] = data
        return stdDescriptorPointer
    }

    func removeStdValue(_ descriptor: Int32) {
        stdDescriptors.removeValue(forKey: descriptor)
    }
}

// MARK: - Memory R/W
extension WasmGlobalStore {
    // Wasm3's range helper adds UInt32 values without checking overflow, and its
    // typed reader checks element counts as bytes. Validate byte spans here.
    private func validSpan(offset: Int32, bytes: UInt64) -> Bool {
        UInt64(UInt32(bitPattern: offset)) + bytes <= UInt64(UInt32.max)
    }

    func readString(offset: Int32, length: Int32) -> String? {
        guard let data = readData(offset: offset, length: length) else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func readData(offset: Int32, length: Int32) -> Data? {
        guard validSpan(offset: offset, bytes: UInt64(UInt32(bitPattern: length))) else { return nil }
        return try? vm.runtime.memory().readData(offset: UInt32(bitPattern: offset), length: UInt32(bitPattern: length))
    }

    func readValues<T: WasmType & FixedWidthInteger>(offset: Int32, length: Int32) -> [T]? {
        let count = UInt64(UInt32(bitPattern: length))
        let bytes = count * UInt64(MemoryLayout<T>.stride)
        guard validSpan(offset: offset, bytes: bytes),
              let data = try? vm.runtime.memory().readData(offset: UInt32(bitPattern: offset), length: UInt32(bytes))
        else { return nil }
        return data.withUnsafeBytes { buffer in
            (0..<Int(count)).map { buffer.loadUnaligned(fromByteOffset: $0 * MemoryLayout<T>.stride, as: T.self) }
        }
    }

    func readBytes(offset: Int32, length: Int32) -> [UInt8]? {
        readData(offset: offset, length: length).map { Array($0) }
    }

    func write(bytes: [UInt8], offset: Int32) {
        guard validSpan(offset: offset, bytes: UInt64(bytes.count)) else { return }
        try? vm.runtime.memory().write(bytes: bytes, offset: UInt32(bitPattern: offset))
    }
}
