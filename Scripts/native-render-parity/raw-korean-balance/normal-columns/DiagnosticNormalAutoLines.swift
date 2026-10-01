/*
 * Copyright (C) 2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

import Foundation
import CoreGraphics

/// Ordinary single-node pre-wrap/keep-all line decisions. Font shaping and
/// emergency grapheme fitting remain explicit caller callbacks. Source:
/// WebKit InlineContentBreaker processOverflowingContent/wordBreakBehavior,
/// InlineLineBuilder candidateContentForLine and TextUtil breakWord.
enum DiagnosticNormalAutoLines {
    static func greedy(text: String, maximumWidth: CGFloat,
                       overflowAnywhere: Bool = true, primaryOffsets: [Int],
                       width: (NSRange) -> CGFloat,
                       emergencyBreak: (NSRange, CGFloat) -> Int?) -> [NSRange]? {
        let source = text as NSString, length = source.length
        guard length > 0, length <= 8192, maximumWidth.isFinite, maximumWidth > 0 else { return nil }
        // Experimental ordinary-normal caller: regular items come from exact
        // primary BreakLines/InlineItemsBuilder surrounding the public CF backend.
        // Only ASCII spaces collapse; NBSP remains a non-whitespace text item.
        let units = Array(text.utf16)
        // This staged caller handles one LTR text node only; explicit bidi
        // runs/controls stay with the established fallback until a real run
        // model is supplied. The detector is intentionally conservative.
        guard !text.unicodeScalars.contains(where: { scalar in
            let value = scalar.value
            return (0x0590...0x08FF).contains(value) || (0xFB1D...0xFDFF).contains(value) ||
                (0xFE70...0xFEFF).contains(value) || (0x10800...0x10FFF).contains(value) ||
                (0x1E800...0x1EEFF).contains(value) || (0x202A...0x202E).contains(value) ||
                (0x2066...0x2069).contains(value)
        }) else { return nil }
        guard !units.contains(9), !units.contains(10), !units.contains(13),
              !units.contains(0x00AD), primaryOffsets.last == length else { return nil }
        var offset = 0
        let items = primaryOffsets.map { end -> NativeKeepAllBreakOpportunities.Item in
            defer { offset = end }
            let range = NSRange(location: offset,length: end - offset)
            return .init(range: range,kind: units[offset..<end].allSatisfy { $0 == 32 } ? .whitespace : .text)
        }
        let maximum = Float(maximumWidth)
        var ranges: [NSRange] = [], lineStart = 0, total: Float = 0
        var hasWrapOpportunity = false, cursor = 0
        func finish(_ end: Int) -> Bool {
            guard end > lineStart else { return false }
            ranges.append(NSRange(location: lineStart,length: end - lineStart))
            lineStart = end;total = 0;hasWrapOpportunity = false
            return ranges.count <= 512
        }
        for item in items {
            cursor = item.range.location
            if item.kind == .whitespace {
                // CSS normal collapses a contiguous ASCII whitespace group
                // to a single separator, then removes leading whitespace.
                if total == 0 { continue }
                let measured = Float(width(NSRange(location: item.range.location,length: 1)))
                guard measured.isFinite, measured >= 0 else { return nil }
                // A fully trimmable whitespace-only candidate is kept even
                // when its advance exceeds the remaining line width.
                total += measured
                hasWrapOpportunity = true
                continue
            }
            while cursor < NSMaxRange(item.range) {
                let remaining = NSRange(location: cursor,length: NSMaxRange(item.range) - cursor)
                let measured = Float(width(remaining))
                guard measured.isFinite, measured >= 0 else { return nil }
                if total + measured <= maximum {
                    total += measured;cursor = NSMaxRange(item.range)
                    hasWrapOpportunity = true
                    continue
                }
                // Anywhere emergency wrapping applies only when no otherwise
                // acceptable wrap position exists on this line. Move the whole
                // run to the next line before splitting it when one exists.
                if hasWrapOpportunity {
                    guard finish(cursor) else { return nil }
                    continue
                }
                if !overflowAnywhere {
                    total += measured;cursor = NSMaxRange(item.range)
                    hasWrapOpportunity = true
                    continue
                }
                let available = CGFloat(max(0,maximum - total))
                guard let candidate = emergencyBreak(remaining,available), candidate >= 0,
                      candidate <= remaining.length else { return nil }
                let taken: Int
                if candidate == 0 {
                    // An empty line must keep its first user-perceived
                    // character even when that character itself overflows.
                    taken = source.rangeOfComposedCharacterSequence(at: cursor).length
                } else { taken = candidate }
                guard taken > 0, taken <= remaining.length else { return nil }
                cursor += taken
                guard finish(cursor) else { return nil }
            }
        }
        if lineStart < length { guard finish(length) else { return nil } }
        return ranges
    }
}
