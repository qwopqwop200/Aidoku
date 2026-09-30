import Foundation

/// Read-only metadata for historical database entries. This does not create a runtime.
struct LegacySourceManifest: Decodable {
    struct Info: Decodable {
        let id: String
        let lang: String
        let name: String
        let version: Int
        let nsfw: Int?
    }
    struct Language: Decodable {
        let code: String
    }
    let info: Info
    let languages: [Language]?
}
