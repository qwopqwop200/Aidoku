import CoreFoundation
import CoreGraphics
import Foundation

/// Reads the exporter's exact numeric leaves DIRECTLY. No decimal JSON
/// re-encoding, Float32 coercion or non-finite-value imputation is involved.
enum HostTaggedObservationDecoder {
    typealias Blob = (Any) throws -> Data

    static func decode<T: Decodable>(_ type: T.Type, value: Any, blob: @escaping Blob) throws -> T {
        try Node(value: value, codingPath: [], blob: blob).decode(type)
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int?
        init(_ value: String) { stringValue = value; intValue = Int(value) }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { self.init(String(intValue)) }
    }

    private struct Node: Decoder, SingleValueDecodingContainer {
        let value: Any
        let codingPath: [any CodingKey]
        let blob: Blob
        var userInfo: [CodingUserInfoKey: Any] { [:] }
        func failure(_ reason: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: codingPath, debugDescription: reason))
        }
        func child(_ value: Any, key: String) -> Node {
            .init(value: value, codingPath: codingPath + [Key(key)], blob: blob)
        }
        func container<K: CodingKey>(keyedBy: K.Type) throws -> KeyedDecodingContainer<K> {
            guard let object = value as? [String: Any] else { throw failure("expected object") }
            return .init(Keyed<K>(node: self, object: object))
        }
        func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
            guard let array = value as? [Any] else { throw failure("expected array") }
            return Unkeyed(node: self, array: array)
        }
        func singleValueContainer() throws -> any SingleValueDecodingContainer { self }
        func decodeNil() -> Bool { value is NSNull }
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            if type == Data.self { return try blob(value) as! T }
            if type == CGPoint.self {
                guard let object = value as? [String: Any], let x = object["x"], let y = object["y"] else {
                    throw failure("expected reflected point")
                }
                return CGPoint(x: try child(x, key: "x").decode(Double.self),
                    y: try child(y, key: "y").decode(Double.self)) as! T
            }
            if type == CGSize.self {
                guard let object = value as? [String: Any], let width = object["width"], let height = object["height"] else {
                    throw failure("expected reflected size")
                }
                return CGSize(width: try child(width, key: "width").decode(Double.self),
                    height: try child(height, key: "height").decode(Double.self)) as! T
            }
            if type == CGRect.self {
                guard let object = value as? [String: Any], let origin = object["origin"], let size = object["size"] else {
                    throw failure("expected reflected rectangle")
                }
                return CGRect(origin: try child(origin, key: "origin").decode(CGPoint.self),
                    size: try child(size, key: "size").decode(CGSize.self)) as! T
            }
            if type == Double.self {
                guard let object = value as? [String: String], object.count == 1,
                      let hex = object["$f64"], hex.count == 16,
                      hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      let bits = UInt64(hex, radix: 16) else { throw failure("expected exact f64 bits") }
                return Double(bitPattern: bits) as! T
            }
            if type == Float.self {
                guard let object = value as? [String: String], object.count == 1,
                      let hex = object["$f32"], hex.count == 8,
                      hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      let bits = UInt32(hex, radix: 16) else { throw failure("expected exact f32 bits") }
                return Float(bitPattern: bits) as! T
            }
            if type == Bool.self {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw failure("expected bool") }
                return number.boolValue as! T
            }
            if type == String.self {
                guard let string = value as? String else { throw failure("expected string") }
                return string as! T
            }
            if [Int.self, Int8.self, Int16.self, Int32.self, Int64.self, UInt.self, UInt8.self, UInt16.self, UInt32.self, UInt64.self]
                .contains(where: { $0 == type }) {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      !["f", "d"].contains(String(cString: number.objCType)) else { throw failure("expected integral scalar") }
                // Integer JSON is never routed through Double.
                return try JSONDecoder().decode(type, from: Data(number.stringValue.utf8))
            }
            return try T(from: self)
        }
    }

    private struct Keyed<K: CodingKey>: KeyedDecodingContainerProtocol {
        let node: Node
        let object: [String: Any]
        var codingPath: [any CodingKey] { node.codingPath }
        var allKeys: [K] { object.keys.compactMap(K.init(stringValue:)) }
        func contains(_ key: K) -> Bool { object[key.stringValue] != nil }
        func get(_ key: K) throws -> Node {
            guard let value = object[key.stringValue] else {
                throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "missing observed field"))
            }
            return node.child(value, key: key.stringValue)
        }
        func decodeNil(forKey key: K) throws -> Bool { try get(key).decodeNil() }
        func decode<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T { try get(key).decode(type) }
        func nestedContainer<N: CodingKey>(keyedBy: N.Type, forKey key: K) throws -> KeyedDecodingContainer<N> {
            try get(key).container(keyedBy: N.self)
        }
        func nestedUnkeyedContainer(forKey key: K) throws -> any UnkeyedDecodingContainer { try get(key).unkeyedContainer() }
        func superDecoder() throws -> any Decoder { node }
        func superDecoder(forKey key: K) throws -> any Decoder { try get(key) }
    }

    private struct Unkeyed: UnkeyedDecodingContainer {
        let node: Node
        let array: [Any]
        var currentIndex = 0
        var codingPath: [any CodingKey] { node.codingPath }
        var count: Int? { array.count }
        var isAtEnd: Bool { currentIndex == array.count }
        mutating func next() throws -> Node {
            guard !isAtEnd else { throw node.failure("array ended") }
            defer { currentIndex += 1 }
            return node.child(array[currentIndex], key: String(currentIndex))
        }
        mutating func decodeNil() throws -> Bool {
            if !isAtEnd, array[currentIndex] is NSNull { currentIndex += 1; return true }
            return false
        }
        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try next().decode(type) }
        mutating func nestedContainer<K: CodingKey>(keyedBy: K.Type) throws -> KeyedDecodingContainer<K> {
            try next().container(keyedBy: K.self)
        }
        mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer { try next().unkeyedContainer() }
        mutating func superDecoder() throws -> any Decoder { try next() }
    }
}
