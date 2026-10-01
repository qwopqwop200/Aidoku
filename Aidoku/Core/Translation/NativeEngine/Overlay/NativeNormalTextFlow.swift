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

/// Native ordinary auto + balance for an explicitly authored normal/collapsed
/// CSS text node. Callers must select this by whitespace provenance, not script.
/// Unsupported TAB/LF/soft-hyphen/bidi keeps the established caller fallback.
enum NativeNormalTextFlow {
    struct Result {
        let sourceRanges: [NSRange]
        let displayRows: [String]
        let autoRanges: [NSRange]
    }
    static func layout(text: String, maximumWidth: CGFloat, balances: Bool,
                       width: (NSRange) -> CGFloat,
                       emergencyBreak: (NSRange, CGFloat) -> Int?) -> Result? {
        guard let analysis = NativeNormalBreakOpportunities.analyze(text: text) else { return nil }
        let offsets = analysis.items.map { NSMaxRange($0.range) }
        guard let auto = NativeNormalAutoLines.greedy(text: text, maximumWidth: maximumWidth,
            primaryOffsets: offsets, width: width, emergencyBreak: emergencyBreak) else { return nil }
        let balance = balances ? NativeNormalTextBalance.solve(text: text, originalAutoRanges: auto,
            maximumWidth: maximumWidth, primaryOffsets: offsets, itemWidth: { Float(width($0)) }) : nil
        let ranges = balance?.flowRanges ?? auto
        let source = text as NSString
        // CSS normal changes only document ASCII spaces here. NBSP and other
        // Unicode separator characters remain original text content.
        let rows = ranges.map { source.substring(with: $0).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
        guard rows.contains(where: { !$0.isEmpty }) else { return nil }
        return Result(sourceRanges: ranges, displayRows: rows, autoRanges: auto)
    }
}

import Foundation
import CoreGraphics

/// Ordinary single-node pre-wrap/keep-all line decisions. Font shaping and
/// emergency grapheme fitting remain explicit caller callbacks. Source:
/// WebKit InlineContentBreaker processOverflowingContent/wordBreakBehavior,
/// InlineLineBuilder candidateContentForLine and TextUtil breakWord.
private enum NativeNormalAutoLines {
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

import Foundation
import CoreGraphics

/// Shaper-independent bridge for one raw same-bidi pre-wrap keep-all paragraph.
/// The caller supplies genuine ordinary auto ranges (including emergency
/// overflow wrapping), rather than a preferred-word or already-balanced layout.
private enum NativeNormalTextBalance {
    struct Result: Equatable {
        /// Abstract inline-item boundaries selected by the balance DP.
        let ranges: [NSRange]
        /// Pre-wrap flow allocates a hanging ASCII whitespace group to the
        /// preceding line even when its abstract opportunity is before it.
        let flowRanges: [NSRange]
        let lineWidths: [CGFloat]
        let originalLineWidths: [CGFloat]
        let preservesOriginalLineCount: Bool
    }

    /// itemWidth measures the exact original UTF16 substring including CSS
    /// letter spacing. No whitespace collapse or NBSP normalization is applied.
    /// Nil keeps the supplied ordinary auto layout; it must not trigger a
    /// different whole-word fallback. Forced paragraphs and preserved tabs
    /// remain caller-owned; this bridge declines them instead of altering them.
    static func solve(text: String, originalAutoRanges: [NSRange], maximumWidth: CGFloat,
                      hyphensNone: Bool = false, primaryOffsets: [Int],
                      itemWidth: (NSRange) -> Float) -> Result? {
        let units = Array(text.utf16), count = units.count
        guard count > 0, count <= 8192, maximumWidth.isFinite, maximumWidth > 0,
              originalAutoRanges.count > 1, originalAutoRanges.count <= 512 else { return nil }
        var previous = 0
        for range in originalAutoRanges {
            guard range.location == previous, range.length > 0,
                  range.location <= count, range.length <= count - range.location else { return nil }
            previous = NSMaxRange(range)
        }
        guard previous == count else { return nil }
        var offset = 0
        let items = primaryOffsets.map { end -> NativeKeepAllBreakOpportunities.Item in
            defer { offset = end }
            let range = NSRange(location: offset, length: end - offset)
            let whitespace = units[offset..<end].allSatisfy { $0 == 32 || $0 == 9 }
            return .init(range: range, kind: whitespace ? .whitespace : .text)
        }
        let opportunities = NativeKeepAllBreakOpportunities.Analysis(items: items,
            paragraphs: [.init(range: NSRange(location: 0,length: count),softOffsets: primaryOffsets)],
            hasPreservedTab: false,hasSoftHyphen: units.contains(0x00AD))
        guard !opportunities.hasPreservedTab, opportunities.paragraphs.count == 1,
              opportunities.items.count <= 512 else { return nil }
        guard hyphensNone || !items.contains(where: {
            $0.kind == .text && units[NSMaxRange($0.range) - 1] == 0x00AD
        }) else { return nil }
        let widths = items.map { item in
            itemWidth(item.kind == .whitespace ? NSRange(location:item.range.location,length:1) : item.range)
        }
        guard widths.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }

        func measured(_ range: NSRange) -> CGFloat {
            var total: Float = 0, leading: Float = 0, trailing: Float = 0
            var encounteredContent = false
            for (index,item) in items.enumerated() {
                let intersection = NSIntersectionRange(item.range,range)
                if intersection.length == 0 { continue }
                let width = intersection == item.range ? widths[index] : itemWidth(intersection)
                guard width.isFinite, width >= 0 else { return .nan }
                total += width
                // Preserve first-line leading whitespace in this chunk only.
                let trimsLeading = item.kind == .whitespace
                if !encounteredContent {
                    if trimsLeading { leading += width; continue }
                    encounteredContent = true; continue
                }
                if item.kind == .whitespace { trailing += width }
                else { trailing = 0 }
            }
            let raw = total - leading - trailing
            return CGFloat(ceil((raw + Float(1.0 / 64.0)) * 64) / 64)
        }
        let originalWidths = originalAutoRanges.map(measured)
        guard let solution = NativeRawTextBalance.solve(originalLineWidths: originalWidths,
            maximumWidth: maximumWidth, breakOffsets: opportunities.paragraphs[0].softOffsets,
            width: measured) else { return nil }
        var start = 0
        let ranges = solution.breakOffsets.map { end -> NSRange in
            defer { start = end }
            return NSRange(location: start,length: end - start)
        }
        var flowStart = 0, flowRanges: [NSRange] = []
        for range in ranges {
            var end = NSMaxRange(range)
            while end < count && (units[end] == 0x20 || units[end] == 0x09) { end += 1 }
            // The caller must reflow pathological zero-content constraints;
            // this direct row transport cannot invent a visible empty row.
            guard end > flowStart else { return nil }
            flowRanges.append(NSRange(location: flowStart,length: end - flowStart));flowStart = end
        }
        return Result(ranges: ranges,flowRanges: flowRanges,lineWidths: solution.lineWidths,originalLineWidths: originalWidths,
                      preservesOriginalLineCount: solution.preservesOriginalLineCount)
    }
}
