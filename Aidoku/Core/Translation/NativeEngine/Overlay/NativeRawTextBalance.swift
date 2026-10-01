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

/// WebKit's paragraph balance DP. The caller supplies its legal soft-wrap
/// opportunities and sliding-width measurements; this helper never introduces
/// whitespace-only or whole-word preferences. Widths include LayoutUnit ceil.
/// Source: WebKit dd5fe1011df7e3438ac4889356abcab7681df46d,
/// InlineContentConstrainer.cpp balanceRangeWith[No]LineRequirement.
enum NativeRawTextBalance {
    struct Solution: Equatable {
        let breakOffsets: [Int]
        let lineWidths: [CGFloat]
        let preservesOriginalLineCount: Bool
    }
    private struct Entry {
        var cost: Float = .infinity
        var previous = 0
    }
    static let maximumLinesWithLineRequirement = 12

    /// `breakOffsets` excludes the dummy initial zero and includes text end.
    /// Nil retains the caller's original auto layout, including legal emergency
    /// Hangul breaks. It must not select a separate whole-word fallback.
    static func solve(originalLineWidths: [CGFloat], maximumWidth: CGFloat,
                      breakOffsets: [Int], width: (NSRange) -> CGFloat) -> Solution? {
        guard originalLineWidths.count > 1, originalLineWidths.count <= 512,
              originalLineWidths.allSatisfy({ $0.isFinite && $0 > 0 }),
              maximumWidth.isFinite, maximumWidth > 0,
              !breakOffsets.isEmpty, breakOffsets.count <= 512,
              breakOffsets[0] > 0,
              zip(breakOffsets, breakOffsets.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        let offsets = [0] + breakOffsets, count = offsets.count
        let total = originalLineWidths.reduce(Float(0)) { $0 + Float($1) }
        let ideal = total / Float(originalLineWidths.count)
        let maximum = Float(maximumWidth)
        var widths = [[Float]](repeating: [Float](repeating: .infinity, count: count), count: count)
        for index in 0..<count { widths[index][index] = 0 }
        for start in 0..<(count - 1) {
            for end in (start + 1)..<count {
                let measured = width(NSRange(location: offsets[start], length: offsets[end] - offsets[start]))
                guard measured.isFinite, measured >= 0 else { return nil }
                widths[start][end] = Float(measured)
            }
        }
        func cost(_ measured: Float) -> Float {
            let intermediate = (measured - ideal) / 15
            return Float(100 * abs(pow(Double(intermediate), 3)))
        }
        func essentiallyEqual(_ a: Float, _ b: Float) -> Bool {
            if a == b { return true }
            let delta = abs(a - b)
            return delta / abs(a) <= Float.ulpOfOne && delta / abs(b) <= Float.ulpOfOne
        }
        let bounded = originalLineWidths.count <= maximumLinesWithLineRequirement
        let rows = bounded ? originalLineWidths.count : 1
        var state = [[Entry]](repeating: [Entry](repeating: Entry(), count: rows + 1), count: count)
        state[0][0].cost = 0
        for end in 1..<count {
            if widths[0][end] > maximum { break }
            state[end][bounded ? 1 : 0].cost = cost(widths[0][end])
        }
        var firstStart = 1
        for end in 1..<count {
            while firstStart <= end && widths[firstStart][end] > maximum { firstStart += 1 }
            guard firstStart < end else { continue }
            for start in firstStart..<end {
                let candidateCost = cost(widths[start][end])
                if bounded {
                    for line in 1...rows {
                        let accumulated = candidateCost + state[start][line - 1].cost
                        if accumulated < state[end][line].cost || essentiallyEqual(accumulated, state[end][line].cost) {
                            state[end][line].cost = accumulated; state[end][line].previous = start
                        }
                    }
                } else {
                    let accumulated = candidateCost + state[start][0].cost
                    if accumulated < state[end][0].cost {
                        state[end][0].cost = accumulated; state[end][0].previous = start
                    }
                }
            }
        }
        guard state[count - 1][bounded ? rows : 0].cost.isFinite else { return nil }
        var positions: [Int] = [], end = count - 1
        if bounded {
            for line in stride(from: rows, through: 1, by: -1) {
                positions.append(end); end = state[end][line].previous
            }
            guard end == 0 else { return nil }
        } else {
            repeat {
                positions.append(end); end = state[end][0].previous
            } while end > 0 && positions.count <= count
            guard positions.count <= count else { return nil }
        }
        positions.reverse()
        var start = 0
        let constraints = positions.map { end -> CGFloat in
            defer { start = end }
            return CGFloat(widths[start][end])
        }
        return Solution(breakOffsets: positions.map { offsets[$0] }, lineWidths: constraints,
                        preservesOriginalLineCount: bounded)
    }
}
