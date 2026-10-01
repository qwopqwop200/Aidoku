import Foundation
import CoreGraphics

/// Literal CSS `white-space: pre` tabs. Locations are relative to each block
/// span's inline origin; raw text and UTF16 indices are never replaced.
enum NativePreformattedTabs {
    struct Row: Equatable {
        let range: NSRange
        let stops: [CGFloat]
        let tabOffsets: [Int]
        let advance: CGFloat
    }
    struct Plan: Equatable { let rows: [Row] }

    /// WebKit uses float arithmetic and the raw primary space advance for the
    /// grid. Letter spacing follows the tab, rather than changing grid spacing.
    static func advance(position: CGFloat, spaceAdvance: CGFloat, zeroAdvance: CGFloat,
                        tabSize: CGFloat = 8) -> CGFloat? {
        guard [position,spaceAdvance,zeroAdvance,tabSize].allSatisfy(\.isFinite),
              spaceAdvance > 0, zeroAdvance >= 0, tabSize > 0 else { return nil }
        let base = Float(spaceAdvance) * Float(tabSize)
        guard base.isFinite, base > 0 else { return nil }
        var remainder = Float(position).truncatingRemainder(dividingBy: base)
        if remainder < 0 { remainder += base }
        var result = base - remainder
        if result < Float(spaceAdvance) / 2 { result += base }
        return result.isFinite ? CGFloat(result) : nil
    }

    /// The closure shapes TAB-free fragments with the final font and tracking.
    /// Explicit stops cover every literal tab, including a close stop the frozen engine
    /// skips to keep at least half of the primary space glyph recognizable.
    /// WebKit c479f0fb22bf0e4c7b15074191592c3d5bf1b75d uses this
    /// half-space rule; the later half-zero rule changes reference pixels.
    static func plan(text: String, spaceAdvance: CGFloat, zeroAdvance: CGFloat,
                     letterSpacing: CGFloat, tabSize: CGFloat = 8,
                     measure: (String) -> CGFloat) -> Plan? {
        let utf16 = Array(text.utf16)
        guard utf16.count <= 65_536, utf16.filter({ $0 == 9 }).count <= 4096,
              letterSpacing.isFinite else { return nil }
        var rows: [Row] = [], start = 0
        for end in 0...utf16.count where end == utf16.count || utf16[end] == 10 {
            var stops: [CGFloat] = [], offsets: [Int] = [], position: Float = 0, fragmentStart = start
            for index in start..<end where utf16[index] == 9 {
                let fragment = String(decoding: utf16[fragmentStart..<index], as: UTF16.self)
                let width = measure(fragment)
                guard width.isFinite, width >= 0 else { return nil }
                position += Float(width)
                guard let distance = advance(position: CGFloat(position), spaceAdvance: spaceAdvance,
                    zeroAdvance: zeroAdvance, tabSize: tabSize) else { return nil }
                position += Float(distance) + Float(letterSpacing)
                guard position.isFinite, position >= 0, position <= 16_777_216 else { return nil }
                stops.append(CGFloat(position)); offsets.append(index)
                fragmentStart = index + 1
            }
            let width = measure(String(decoding: utf16[fragmentStart..<end], as: UTF16.self))
            guard width.isFinite, width >= 0 else { return nil }
            position += Float(width)
            guard position.isFinite, position >= 0, position <= 16_777_216 else { return nil }
            let includesBreak = end < utf16.count ? 1 : 0
            rows.append(.init(range: NSRange(location: start, length: end-start+includesBreak),
                stops: stops, tabOffsets: offsets, advance: CGFloat(position)))
            start = end + 1
        }
        return .init(rows: rows)
    }
}
