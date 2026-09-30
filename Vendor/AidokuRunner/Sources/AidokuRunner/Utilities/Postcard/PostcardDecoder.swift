//
//  PostcardDecoder.swift
//  AidokuRunner
//
//  Created by Skitty on 1/5/25.
//

import Combine
import Foundation

public class PostcardDecoder: TopLevelDecoder {
    private let maximumSequenceElements: Int

    /// Bounds cumulative declared sequence entries before standard Codable arrays allocate.
    public init(maximumSequenceElements: Int = 1_000_000) {
        self.maximumSequenceElements = max(0, maximumSequenceElements)
    }

    public func decode<T>(_: T.Type, from data: Data) throws -> T where T: Decodable {
        let decodingContainer = DecodingContainer(data: data, maximumSequenceElements: maximumSequenceElements)
        return try decodingContainer.decode(T.self)
    }
}

private class DecodingContainer {
    var data: Data
    var currentIndex: Data.Index

    private var remainingSequenceElements: Int

    init(data: Data, maximumSequenceElements: Int) {
        self.data = data
        self.currentIndex = data.startIndex
        self.remainingSequenceElements = maximumSequenceElements
    }

    func decodeSequenceLength(elementsPerEntry: Int = 1) throws -> Int {
        let length = try decode(UInt64.self)
        guard let length = Int(exactly: length), length <= remainingSequenceElements / elementsPerEntry else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Sequence element budget exceeded"))
        }
        remainingSequenceElements -= length * elementsPerEntry
        return length
    }

    func decodeNil() throws -> Bool {
        guard currentIndex < data.endIndex else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Out of bytes")
            )
        }
        let byte = data[currentIndex]
        currentIndex += 1
        guard byte <= 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid optional discriminant"))
        }
        return byte == 0
    }

    func decode(_: Bool.Type) throws -> Bool {
        guard currentIndex < data.endIndex else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Out of bytes")
            )
        }
        let byte = data[currentIndex]
        currentIndex += 1
        guard byte <= 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid boolean discriminant"))
        }
        return byte == 1
    }

    func decode(_: String.Type) throws -> String {
        let length: UInt64 = try decodeVarInt(data, currentIndex: &currentIndex)
        guard let length = Int(exactly: length), length <= data.endIndex - currentIndex else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Invalid string length")
            )
        }
        let endIndex = currentIndex + length
        let stringData = data[currentIndex..<endIndex]
        currentIndex = endIndex
        guard let value = String(data: stringData, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid UTF-8"))
        }
        return value
    }

    func decode(_: Double.Type) throws -> Double {
        let endIndex = currentIndex.advanced(by: MemoryLayout<Double>.size)
        guard endIndex <= data.endIndex else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Invalid double length")
            )
        }
        let value = Data(data[currentIndex..<endIndex])
        currentIndex = endIndex
        return Double(bitPattern: value.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian)
    }

    func decode(_: Float.Type) throws -> Float {
        let endIndex = currentIndex.advanced(by: MemoryLayout<Float>.size)
        guard endIndex <= data.endIndex else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Invalid float length")
            )
        }
        let value = Data(data[currentIndex..<endIndex])
        currentIndex = endIndex
        return Float(bitPattern: value.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
    }

    func decode(_: Int.Type) throws -> Int {
        Int(try decode(Int64.self))
    }

    func decode(_: Int8.Type) throws -> Int8 {
        let value: UInt8 = try decode(UInt8.self)
        return Int8(bitPattern: value)
    }

    func decode(_: Int16.Type) throws -> Int16 {
        let value: UInt16 = try decode(UInt16.self)
        return Int16(bitPattern: value >> 1) ^ -Int16(value & 1)
    }

    func decode(_: Int32.Type) throws -> Int32 {
        let value: UInt32 = try decode(UInt32.self)
        return Int32(bitPattern: value >> 1) ^ -Int32(value & 1)
    }

    func decode(_: Int64.Type) throws -> Int64 {
        let value: UInt64 = try decode(UInt64.self)
        return Int64(bitPattern: value >> 1) ^ -Int64(value & 1)
    }

    func decode(_: UInt.Type) throws -> UInt {
        UInt(try decode(UInt64.self))
    }

    func decode(_: UInt8.Type) throws -> UInt8 {
        guard currentIndex < data.endIndex else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Ran out of bytes")
            )
        }
        let byte = data[currentIndex]
        currentIndex += 1
        return byte
    }

    func decode(_: UInt16.Type) throws -> UInt16 {
        try decodeVarInt(data, currentIndex: &currentIndex)
    }

    func decode(_: UInt32.Type) throws -> UInt32 {
        try decodeVarInt(data, currentIndex: &currentIndex)
    }

    func decode(_: UInt64.Type) throws -> UInt64 {
        try decodeVarInt(data, currentIndex: &currentIndex)
    }

    func decode<T>(_: T.Type) throws -> T where T: Decodable {
        if let dictionaryType = T.self as? any PostcardDictionaryDecoding.Type {
            guard let value = try dictionaryType.decodePostcard(from: self) as? T else {
                throw DecodingError.typeMismatch(T.self, .init(codingPath: [], debugDescription: "Invalid dictionary type"))
            }
            return value
        }
        return try T(from: PostcardDecoding(decodingContainer: self))
    }
}

// Dictionary's keyed Codable path requires all keys up front. Postcard has no value
// type tags to scan past arbitrary values, so decode its known key/value types directly.
private protocol PostcardDictionaryDecoding {
    static func decodePostcard(from container: DecodingContainer) throws -> Any
}

extension Dictionary: PostcardDictionaryDecoding where Key: Decodable, Value: Decodable {
    fileprivate static func decodePostcard(from container: DecodingContainer) throws -> Any {
        guard Key.self == String.self || Key.self == Int.self else {
            // Other key types already use an unkeyed sequence of alternating keys and values.
            return try Self(from: PostcardDecoding(decodingContainer: container))
        }
        let count = try container.decodeSequenceLength(elementsPerEntry: 2)
        var result = Self()
        for _ in 0..<count {
            let string = try container.decode(String.self)
            // Match the encoder's historical numeric coding-key metadata, even for String keys.
            if Int(string) != nil { _ = try container.decode(UInt64.self) }
            let key = Key.self == String.self ? string as? Key : Int(string) as? Key
            guard let key else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid dictionary key"))
            }
            result[key] = try container.decode(Value.self)
        }
        return result
    }
}

protocol OptionalProtocol {}

extension Optional: OptionalProtocol {}

private class PostcardDecoding: Decoder {
    let decodingContainer: DecodingContainer

    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    init(decodingContainer: DecodingContainer) {
        self.decodingContainer = decodingContainer
    }

    func container<Key>(keyedBy _: Key.Type) -> KeyedDecodingContainer<Key> where Key: CodingKey {
        KeyedDecodingContainer(
            PostcardKeyedDecoding<Key>(
                decodingContainer: decodingContainer,
                codingPath: codingPath,
                userInfo: userInfo
            )
        )
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try PostcardUnkeyedDecoding(
            decodingContainer: decodingContainer,
            codingPath: codingPath,
            userInfo: userInfo
        )
    }

    func singleValueContainer() -> any SingleValueDecodingContainer {
        PostcardSingleValueDecoding(
            decodingContainer: decodingContainer,
            codingPath: codingPath,
            userInfo: userInfo
        )
    }
}

private class PostcardKeyedDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decodingContainer: DecodingContainer

    let usesKeys = false

    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any]
    var allKeys: [Key] = []

    init(
        decodingContainer: DecodingContainer,
        codingPath: [CodingKey],
        userInfo: [CodingUserInfoKey: Any]
    ) {
        self.decodingContainer = decodingContainer
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    func contains(_: Key) -> Bool {
        false
    }

    func decodeNil(forKey _: Key) throws -> Bool {
        try decodingContainer.decodeNil()
    }

    func decode(_ type: Bool.Type, forKey _: Key) throws -> Bool {
        try decodingContainer.decode(type)
    }

    func decode(_ type: String.Type, forKey _: Key) throws -> String {
        try decodingContainer.decode(type)
    }

    func decode(_ type: Double.Type, forKey _: Key) throws -> Double {
        try decodingContainer.decode(type)
    }

    func decode(_ type: Float.Type, forKey _: Key) throws -> Float {
        try decodingContainer.decode(type)
    }

    func decode(_ type: Int.Type, forKey _: Key) throws -> Int {
        try decodingContainer.decode(type)
    }

    func decode(_ type: Int8.Type, forKey _: Key) throws -> Int8 {
        try decodingContainer.decode(type)
    }

    func decode(_ type: Int16.Type, forKey _: Key) throws -> Int16 {
        try decodingContainer.decode(type)
    }

    func decode(_ type: Int32.Type, forKey _: Key) throws -> Int32 {
        try decodingContainer.decode(type)
    }

    func decode(_ type: Int64.Type, forKey _: Key) throws -> Int64 {
        try decodingContainer.decode(type)
    }

    func decode(_ type: UInt.Type, forKey _: Key) throws -> UInt {
        try decodingContainer.decode(type)
    }

    func decode(_ type: UInt8.Type, forKey _: Key) throws -> UInt8 {
        try decodingContainer.decode(type)
    }

    func decode(_ type: UInt16.Type, forKey _: Key) throws -> UInt16 {
        try decodingContainer.decode(type)
    }

    func decode(_ type: UInt32.Type, forKey _: Key) throws -> UInt32 {
        try decodingContainer.decode(type)
    }

    func decode(_ type: UInt64.Type, forKey _: Key) throws -> UInt64 {
        try decodingContainer.decode(type)
    }

    func decode<T>(_: T.Type, forKey _: Key) throws -> T where T: Decodable {
        try decodingContainer.decode(T.self)
    }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent<T>(_: T.Type, forKey key: Key) throws -> T? where T: Decodable {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            return nil
        }
        return try decode(T.self, forKey: key)
    }

    func nestedContainer<NestedKey>(
        keyedBy _: NestedKey.Type,
        forKey _: Key
    ) -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        KeyedDecodingContainer(
            PostcardKeyedDecoding<NestedKey>(
                decodingContainer: decodingContainer,
                codingPath: codingPath,
                userInfo: userInfo
            )
        )
    }

    func nestedUnkeyedContainer(forKey _: Key) throws -> UnkeyedDecodingContainer {
        try PostcardUnkeyedDecoding(
            decodingContainer: decodingContainer,
            codingPath: codingPath,
            userInfo: userInfo
        )
    }

    func superDecoder() -> Decoder {
        PostcardDecoding(decodingContainer: decodingContainer)
    }

    func superDecoder(forKey _: Key) -> Decoder {
        PostcardDecoding(decodingContainer: decodingContainer)
    }
}

private class PostcardUnkeyedDecoding: UnkeyedDecodingContainer {
    var decodingContainer: DecodingContainer
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any]

    var currentIndex: Int {
        currentCount
    }

    var count: Int?
    var currentCount = 0

    var isAtEnd: Bool {
        currentCount >= (count ?? 0)
    }

    init(
        decodingContainer: DecodingContainer,
        codingPath: [CodingKey],
        userInfo: [CodingUserInfoKey: Any]
    ) throws {
        self.decodingContainer = decodingContainer
        self.codingPath = codingPath
        self.userInfo = userInfo

        count = try decodingContainer.decodeSequenceLength()
    }

    func decodeNil() throws -> Bool {
        let isNil = try decodingContainer.decodeNil()
        if isNil { currentCount += 1 }
        return isNil
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: String.Type) throws -> String {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Double.Type) throws -> Double {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Float.Type) throws -> Float {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Int.Type) throws -> Int {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        currentCount += 1
        return try decodingContainer.decode(type)
    }

    func decode<T>(_: T.Type) throws -> T where T: Decodable {
        currentCount += 1
        return try decodingContainer.decode(T.self)
    }

    func decodeIfPresent(_ type: Bool.Type) throws -> Bool? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: String.Type) throws -> String? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: Double.Type) throws -> Double? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: Float.Type) throws -> Float? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: Int.Type) throws -> Int? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: Int8.Type) throws -> Int8? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: Int16.Type) throws -> Int16? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: Int32.Type) throws -> Int32? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: Int64.Type) throws -> Int64? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: UInt.Type) throws -> UInt? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: UInt8.Type) throws -> UInt8? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: UInt16.Type) throws -> UInt16? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: UInt32.Type) throws -> UInt32? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent(_ type: UInt64.Type) throws -> UInt64? {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(type)
    }

    func decodeIfPresent<T>(_: T.Type) throws -> T? where T: Decodable {
        let isNil = try decodingContainer.decodeNil()
        if isNil {
            currentCount += 1
            return nil
        }
        return try decode(T.self)
    }

    func nestedContainer<NestedKey>(
        keyedBy _: NestedKey.Type
    ) -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        currentCount += 1
        return KeyedDecodingContainer(
            PostcardKeyedDecoding<NestedKey>(
                decodingContainer: decodingContainer,
                codingPath: codingPath,
                userInfo: userInfo
            )
        )
    }

    func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        currentCount += 1
        return try PostcardUnkeyedDecoding(
            decodingContainer: decodingContainer,
            codingPath: codingPath,
            userInfo: userInfo
        )
    }

    func superDecoder() -> Decoder {
        currentCount += 1
        return PostcardDecoding(decodingContainer: decodingContainer)
    }
}

private class PostcardSingleValueDecoding: SingleValueDecodingContainer {
    var decodingContainer: DecodingContainer
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any]

    init(
        decodingContainer: DecodingContainer,
        codingPath: [CodingKey],
        userInfo: [CodingUserInfoKey: Any]
    ) {
        self.decodingContainer = decodingContainer
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    private var nilDecodingError: (any Error)?

    func decodeNil() -> Bool {
        do {
            return try decodingContainer.decodeNil()
        } catch {
            nilDecodingError = error
            return false
        }
    }

    private func checkNilError() throws {
        if let nilDecodingError { throw nilDecodingError }
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: String.Type) throws -> String {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Double.Type) throws -> Double {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Float.Type) throws -> Float {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Int.Type) throws -> Int {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try checkNilError()
        return try decodingContainer.decode(type)
    }

    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        try checkNilError()
        return try decodingContainer.decode(type)
    }
}
