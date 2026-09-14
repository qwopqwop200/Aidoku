import Foundation

/// Reframes a ClientHello across TLS records without changing handshake bytes.
/// TLS and certificate validation remain entirely in URLSession / WebKit.
enum TLSClientHello {
    enum Inspection: Equatable {
        case incomplete
        case passthrough
        case split(Data, Data)
    }
    static let maximumBytes = 131_072
    private struct Record {
        let start: Int
        let length: Int
        let offset: Int
    }

    static func inspect(_ data: Data) -> Inspection {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return .incomplete }
        guard bytes[0] == 22 else { return .passthrough }
        guard bytes.count <= maximumBytes else { return .passthrough }
        var handshake: [UInt8] = []
        var records: [Record] = []
        var cursor = 0
        while cursor < bytes.count {
            guard cursor + 5 <= bytes.count else { return .incomplete }
            guard bytes[cursor] == 22, bytes[cursor + 1] == 3 else { return .passthrough }
            let length = Int(bytes[cursor + 3]) * 256 + Int(bytes[cursor + 4])
            guard length > 0, length <= 18_432 else { return .passthrough }
            guard cursor + 5 + length <= bytes.count else { return .incomplete }
            records.append(Record(start: cursor, length: length, offset: handshake.count))
            handshake += bytes[(cursor + 5)..<(cursor + 5 + length)]
            cursor += 5 + length
            guard handshake.count >= 4 else { continue }
            guard handshake[0] == 1 else { return .passthrough }
            let size = Int(handshake[1]) * 65_536 + Int(handshake[2]) * 256 + Int(handshake[3]) + 4
            guard size <= maximumBytes else { return .passthrough }
            guard handshake.count >= size else { continue }
            guard let name = serverNameRange(Array(handshake.prefix(size))) else { return .passthrough }
            let cut = name.lowerBound + max(1, name.count / 2)
            guard let record = records.first(where: { cut > $0.offset && cut < $0.offset + $0.length }) else {
                return .passthrough // Already split at a record boundary.
            }
            let prefixLength = cut - record.offset
            let suffixLength = record.length - prefixLength
            func header(_ length: Int) -> [UInt8] {
                [22, bytes[record.start + 1], bytes[record.start + 2], UInt8(length >> 8), UInt8(length & 255)]
            }
            let body = record.start + 5
            let first = Data(bytes[..<record.start] + header(prefixLength) + bytes[body..<(body + prefixLength)])
            let second = Data(header(suffixLength) + bytes[(body + prefixLength)..<(body + record.length)] + bytes[(body + record.length)...])
            return .split(first, second)
        }
        return .incomplete
    }

    private static func serverNameRange(_ bytes: [UInt8]) -> Range<Int>? {
        // Handshake header, legacy version, random, session ID.
        guard bytes.count >= 39 else { return nil }
        var cursor = 38
        func length16(_ index: Int) -> Int { Int(bytes[index]) * 256 + Int(bytes[index + 1]) }
        let sessionLength = Int(bytes[cursor])
        cursor += 1 + sessionLength
        guard cursor + 2 <= bytes.count else { return nil }
        let cipherLength = length16(cursor)
        cursor += 2 + cipherLength
        guard cursor < bytes.count else { return nil }
        let compressionLength = Int(bytes[cursor])
        cursor += 1 + compressionLength
        guard cursor + 2 <= bytes.count else { return nil }
        let end = cursor + 2 + length16(cursor)
        cursor += 2
        guard end <= bytes.count else { return nil }
        while cursor + 4 <= end {
            let type = length16(cursor)
            let size = length16(cursor + 2)
            cursor += 4
            guard cursor + size <= end else { return nil }
            if type == 0 {
                guard size >= 5, length16(cursor) == size - 2 else { return nil }
                let listEnd = cursor + size
                cursor += 2
                while cursor + 3 <= listEnd {
                    let nameType = bytes[cursor]
                    let length = length16(cursor + 1)
                    cursor += 3
                    guard length > 0, cursor + length <= listEnd else { return nil }
                    if nameType == 0, length >= 2 { return cursor..<(cursor + length) }
                    cursor += length
                }
                return nil
            }
            cursor += size
        }
        return nil
    }
}
