import CoreText
import Foundation

/// Reuse immutable primary fonts without caching glyph clusters or fallback runs.
enum NativeTypographyFontCache {
    struct Key: Hashable {
        let name: String?
        let script: String
        let size: UInt64
        let bold: Bool
        let vertical: Bool
    }

    private static let lock = NSLock()
    private static let generationCapacity = 64
    nonisolated(unsafe) private static var current: [Key: CTFont] = [:]
    nonisolated(unsafe) private static var previous: [Key: CTFont] = [:]

    static func get(_ key: Key, create: () -> CTFont) -> CTFont {
        lock.lock()
        if let font = current[key] { lock.unlock(); return font }
        if let font = previous[key] {
            storeLocked(font, key: key)
            lock.unlock()
            return font
        }
        lock.unlock()
        // Font registration and named-face fallback can recursively ask for a
        // different font. Never call Core Text/the factory while holding the lock.
        let font = create()
        lock.lock()
        defer { lock.unlock() }
        if let existing = current[key] ?? previous[key] { return existing }
        storeLocked(font, key: key)
        return font
    }

    private static func storeLocked(_ font: CTFont, key: Key) {
        if current.count >= generationCapacity {
            previous = current
            current.removeAll(keepingCapacity: true)
        }
        current[key] = font
    }
}
