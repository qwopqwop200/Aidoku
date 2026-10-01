/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
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

/// Regular opportunities of one raw, same-direction text node with pre-wrap,
/// word-break: keep-all, line-break: auto and normal NBSP handling. Emergency
/// overflow-wrap:anywhere is deliberately not a regular opportunity here.
/// Source: WebKit dd5fe1011df7e3438ac4889356abcab7681df46d,
/// InlineItemsBuilder, BreakLines keep-all character rules, InlineFormattingUtils.
enum NativeKeepAllBreakOpportunities {
    enum Kind: Int, Equatable { case text, whitespace, forcedBreak }
    struct Item: Equatable {
        let range: NSRange
        let kind: Kind
    }
    struct Paragraph: Equatable {
        /// Original UTF16 range, excluding the preserved LF.
        let range: NSRange
        /// Relative to range.location, excludes zero and includes content end.
        let softOffsets: [Int]
    }
    struct Analysis: Equatable {
        let items: [Item]
        let paragraphs: [Paragraph]
        let hasPreservedTab: Bool
        let hasSoftHyphen: Bool
    }

    static func analyze(text: String) -> Analysis {
        let units = Array(text.utf16)
        var items: [Item] = [], position = 0
        while position < units.count {
            let start = position
            if units[position] == 0x0A {
                position += 1
                items.append(Item(range: NSRange(location: start, length: 1), kind: .forcedBreak))
                continue
            }
            if units[position] == 0x20 || units[position] == 0x09 {
                repeat { position += 1 }
                while position < units.count && (units[position] == 0x20 || units[position] == 0x09)
                items.append(Item(range: NSRange(location: start, length: position - start), kind: .whitespace))
                continue
            }
            // Keep-all segments end before ASCII white space/ZWSP and after
            // ideographic space. A boundary at this segment's own start is
            // skipped, exactly as the inline-item builder skips empty items.
            var cursor = start
            while cursor < units.count {
                let character = units[cursor]
                let boundary: Int?
                switch character {
                case 0x20, 0x09, 0x0A, 0x200B: boundary = cursor
                case 0x3000: boundary = cursor + 1
                default: boundary = nil
                }
                if let boundary, boundary > start { position = boundary; break }
                cursor += 1
            }
            if cursor == units.count { position = units.count }
            items.append(Item(range: NSRange(location: start, length: position - start), kind: .text))
        }
        var paragraphs: [Paragraph] = [], start = 0, offsets: [Int] = []
        for item in items {
            if item.kind == .forcedBreak {
                let length = item.range.location - start
                if length > 0, offsets.last != length { offsets.append(length) }
                paragraphs.append(Paragraph(range: NSRange(location: start, length: length), softOffsets: offsets))
                start = NSMaxRange(item.range); offsets = []
            } else {
                offsets.append(NSMaxRange(item.range) - start)
            }
        }
        paragraphs.append(Paragraph(range: NSRange(location: start, length: units.count - start), softOffsets: offsets))
        return Analysis(items: items, paragraphs: paragraphs,
                        hasPreservedTab: units.contains(0x09), hasSoftHyphen: units.contains(0x00AD))
    }
}
