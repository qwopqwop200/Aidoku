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

    // frees values created after the given pointers, which a trapped wasm call can never destroy
    func removeValues(after std: Int32, requests request: Int32) -> Int32 {
        stdDescriptors = stdDescriptors.filter { $0.key <= std }
        requests = requests.filter { $0.key <= request }
        return -1
    }
}

// MARK: - Memory R/W
extension WasmGlobalStore {

//    func readString(offset: Int, length: Int) -> String? {
//        try? vm.runtime.memory().readString(offset: UInt32(offset), length: UInt32(length))
//    }

    func readString(offset: Int32, length: Int32) -> String? {
        guard offset >= 0, length >= 0 else { return nil }
        return try? vm.runtime.memory().readString(offset: UInt32(offset), length: UInt32(length))
    }

    func readData(offset: Int32, length: Int32) -> Data? {
        guard offset >= 0, length >= 0 else { return nil }
        return try? vm.runtime.memory().readData(offset: UInt32(offset), length: UInt32(length))
    }

    func readValues<T: WasmType>(offset: Int32, length: Int32) -> [T]? {
        // Memory.readValues only bounds-checks `length` bytes, so check the full byte range first
        guard offset >= 0, length >= 0, length <= Int32.max / 8,
              readBytes(offset: offset, length: length * Int32(MemoryLayout<T>.stride)) != nil else { return nil }
        return try? vm.runtime.memory().readValues(offset: UInt32(offset), length: UInt32(length))
    }

    func readBytes(offset: Int32, length: Int32) -> [UInt8]? {
        guard offset >= 0, length >= 0 else { return nil }
        return try? vm.runtime.memory().readBytes(offset: UInt32(offset), length: UInt32(length))
    }

//    func write<T: WasmType & FixedWidthInteger>(value: T, offset: Int32) {
//        try? vm.runtime.memory().write(values: [value], offset: UInt32(offset))
//    }

    func write(bytes: [UInt8], offset: Int32) {
        guard offset >= 0 else { return }
        try? vm.runtime.memory().write(bytes: bytes, offset: UInt32(offset))
    }

//    func write(data: Data, offset: Int32) {
//        try? vm.runtime.memory().write(data: data, offset: UInt32(offset))
//    }
}
