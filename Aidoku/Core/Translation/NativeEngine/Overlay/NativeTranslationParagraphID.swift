import Foundation

/// Preserve upstream paragraph identity exactly across typed layout persistence.
/// Numeric 7 and string "7" are distinct keys, not permission to merge owners.
enum NativeTranslationParagraphID: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value) }
        else { self = .integer(try container.decode(Int.self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        }
    }
}
