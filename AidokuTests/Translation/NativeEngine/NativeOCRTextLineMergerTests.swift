// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import Aidoku

struct NativeOCRTextLineMergerTests {
    @Test func capturedHorizontalJapaneseGlyphsJoinWithoutSkippingTheMiddle() {
        for scale: CGFloat in [0.5, 1, 2] {
            let boxes: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                ("どした", 468, 161, 150, 70), ("ん", 588, 166, 72, 61),
                ("話", 635, 164, 65, 64), ("聞", 684, 164, 57, 65),
                ("こ", 731, 167, 47, 60), ("か？", 763, 161, 103, 71)]
            let input = boxes.map { text, x, y, w, h in
                NativeCoreMLOCRLine(polygon: [CGPoint(x: x*scale, y: y*scale), CGPoint(x: (x+w)*scale, y: y*scale),
                    CGPoint(x: (x+w)*scale, y: (y+h)*scale), CGPoint(x: x*scale, y: (y+h)*scale)],
                    text: text, score: 0.99, orientation: text == "こ" ? .vertical : .horizontal)
            }
            for rows in [input, Array(input.reversed())] {
                #expect(merge(rows, width: Int(1290*scale), height: Int(1824*scale)).map(\.text) == ["どしたん話聞こか？"])
            }
        }
    }

    @Test func slantedComicPosterPreservesRowsAndParagraphGaps() {
        // Real detector quads: Pepper&Carrot E03P03 Chinese, David Revoy and
        // translators, CC BY 4.0. Text is replaced; geometry is unmodified.
        let quads: [[CGPoint]] = [
            [CGPoint(x: 272, y: 825), CGPoint(x: 377, y: 798), CGPoint(x: 386, y: 833), CGPoint(x: 281, y: 859)],
            [CGPoint(x: 292, y: 855), CGPoint(x: 397, y: 829), CGPoint(x: 406, y: 863), CGPoint(x: 300, y: 890)],
            [CGPoint(x: 313, y: 922), CGPoint(x: 450, y: 887), CGPoint(x: 457, y: 915), CGPoint(x: 321, y: 950)],
            [CGPoint(x: 321, y: 952), CGPoint(x: 475, y: 912), CGPoint(x: 482, y: 942), CGPoint(x: 329, y: 982)],
            [CGPoint(x: 359, y: 975), CGPoint(x: 471, y: 947), CGPoint(x: 478, y: 978), CGPoint(x: 366, y: 1005)]
        ]
        let texts = ["甲甲甲甲", "乙乙乙乙", "丙丙丙丙丙", "丁丁丁丁丁丁丁", "戊戊戊戊戊"]
        for scale: CGFloat in [0.5, 1, 2] {
            let input = zip(quads, texts).map { polygon, text in
                NativeCoreMLOCRLine(
                    polygon: polygon.map { CGPoint(x: $0.x * scale, y: $0.y * scale) },
                    text: text, score: 0.98, orientation: .horizontal
                )
            }
            for shuffled in [input, Array(input.reversed()), [input[2], input[0], input[4], input[1], input[3]]] {
                let output = merge(shuffled, width: Int(1200 * scale), height: Int(1660 * scale))
                #expect(Set(output.map(\.text)) == [texts[0] + texts[1], texts[2] + texts[3] + texts[4]])
                #expect(output.allSatisfy { $0.sourceOrientation == .horizontal })
                #expect(output.allSatisfy { $0.poly.count == 4 && $0.boundingRect.minX > 0 && $0.boundingRect.minY > 0 })
            }
        }
    }

    @Test func rotatedParagraphsKeepReadingOrderAcrossSlopes() {
        for slope: CGFloat in [-0.45, -0.25, 0.15, 0.4] {
            for scale: CGFloat in [0.5, 1, 2] {
                let input = (0..<3).map { index in
                    let y = CGFloat(index) * 28
                    let polygon = [CGPoint(x: 0, y: y), CGPoint(x: 120, y: y),
                                   CGPoint(x: 120, y: y + 24), CGPoint(x: 0, y: y + 24)].map {
                        CGPoint(x: 400 + scale * ($0.x * cos(slope) - $0.y * sin(slope)),
                                y: 300 + scale * ($0.x * sin(slope) + $0.y * cos(slope)))
                    }
                    return NativeCoreMLOCRLine(polygon: polygon, text: ["第一行", "第二行", "第三行"][index],
                                               score: 0.98, orientation: .horizontal)
                }
                let result = merge(Array(input.reversed()), width: 1200, height: 1660)
                #expect(result.map(\.text) == ["第一行第二行第三行"])
                let bounds = result[0].boundingRect
                #expect(input.flatMap(\.polygon).allSatisfy {
                    bounds.insetBy(dx: -0.01, dy: -0.01).contains($0)
                })
            }
        }
    }

    @Test func overlappingTilesWithDifferentWordSpacesKeepOnePhysicalLine() {
        let input = [line("On Azarday, 3 Pinkmoon", 100, 100, 280, 40, score: 0.995),
                     line("OnAzarday, 3 Pinkmoon", 99, 99, 282, 42, score: 0.979)]
        #expect(merge(input, width: 1200, height: 1660).map(\.text) == [input[0].text])
        let separate = [input[0], line("OnAzarday, 3 Pinkmoon", 100, 250, 280, 40)]
        #expect(merge(separate, width: 1200, height: 1660).count == 2)
        let different = [input[0], line("On Azarday, 4 Pinkmoon", 100, 100, 280, 40)]
        #expect(merge(different, width: 1200, height: 1660).count == 2)
    }

    @Test func skewedVerticalComicColumnKeepsBalloonReadingOrder() {
        // Actual low-resolution official preview detector geometry, Frieren
        // chapter 1 p5. Text replaced: all three columns were recognized intact.
        let input = [
            NativeCoreMLOCRLine(polygon: [CGPoint(x: 294, y: 30), CGPoint(x: 312, y: 30),
                CGPoint(x: 312, y: 133), CGPoint(x: 294, y: 133)], text: "最後の文章です。", score: 0.95,
                orientation: .vertical, orientationIsEstimated: true),
            NativeCoreMLOCRLine(polygon: [CGPoint(x: 311, y: 30), CGPoint(x: 327, y: 30),
                CGPoint(x: 327, y: 98), CGPoint(x: 311, y: 98)], text: "真ん中の文章", score: 0.90,
                orientation: .vertical, orientationIsEstimated: true),
            NativeCoreMLOCRLine(polygon: [CGPoint(x: 324, y: 27), CGPoint(x: 350, y: 29),
                CGPoint(x: 344, y: 101), CGPoint(x: 318, y: 98)], text: "最初の文章は", score: 0.63,
                orientation: .vertical, orientationIsEstimated: true)
        ]
        for order in [input, Array(input.reversed())] {
            #expect(merge(order, width: 403, height: 579).map(\.text)
                == ["最初の文章は真ん中の文章最後の文章です。"])
        }
    }

    @Test func fullSizeEstimatedSingletonJoinsVerticalComicBalloon() {
        // SPY x FAMILY chapter 1 p4: square final column was estimated horizontal.
        let columns = [line("何してる", 89, 181, 21, 51, orientation: .vertical),
                       line("おい", 107, 182, 18, 27, orientation: .vertical)]
        let glyph = line("前", 76, 183, 17, 15, orientation: .horizontal, orientationIsEstimated: true)
        for input in [[glyph] + columns, columns.reversed() + [glyph]] {
            #expect(merge(input, width: 367, height: 579).map(\.text) == ["おい何してる前"])
        }
        let protected = [
            line("前", 76, 183, 17, 15, orientation: .horizontal),
            line("前", 80, 183, 8, 8, orientation: .horizontal, orientationIsEstimated: true),
            line("前", 76, 205, 17, 15, orientation: .horizontal, orientationIsEstimated: true)
        ]
        for glyph in protected {
            #expect(merge([glyph] + columns, width: 367, height: 579).count == 2)
        }
    }

    @Test func duplicateTilesStraddlingDeskewThresholdStayDeduplicated() {
        let input = [CGFloat(0.099), 0.101].map { angle in
            NativeCoreMLOCRLine(polygon: [CGPoint(x: 0, y: 0), CGPoint(x: 120, y: 0),
                CGPoint(x: 120, y: 20), CGPoint(x: 0, y: 20)].map {
                    CGPoint(x: 100 + $0.x * cos(angle) - $0.y * sin(angle),
                            y: 100 + $0.x * sin(angle) + $0.y * cos(angle))
                }, text: "A shared line", score: 0.95, orientation: .horizontal)
        }
        for order in [input, Array(input.reversed())] {
            #expect(merge(order, width: 1000, height: 1000).map(\.text) == ["A shared line"])
        }
    }

    @Test func localBaselineGroupsDoNotDependOnDetectorEnumeration() {
        let input = [CGFloat(0.11), 0.17, 0.23].enumerated().map { index, angle in
            NativeCoreMLOCRLine(polygon: [CGPoint(x: 0, y: 0), CGPoint(x: 120, y: 0),
                CGPoint(x: 120, y: 20), CGPoint(x: 0, y: 20)].map {
                    CGPoint(x: 100 + $0.x * cos(angle) - $0.y * sin(angle),
                            y: 100 + CGFloat(index) * 24 + $0.x * sin(angle) + $0.y * cos(angle))
                }, text: ["第一行", "第二行", "第三行"][index], score: 0.95, orientation: .horizontal)
        }
        let expected = Set(merge(input, width: 1000, height: 1000).map(\.text))
        for order in [Array(input.reversed()), [input[1], input[0], input[2]], [input[2], input[0], input[1]]] {
            #expect(Set(merge(order, width: 1000, height: 1000).map(\.text)) == expected)
        }
    }

    @Test func userPageQuoteIsNotRenderedTwice() {
        // The actual two regions read back from the Phone's OCR cache.
        let input = [
            line("”それを応援するのが\"大人の役目\"だから", 305, 467, 473, 34, score: 0.9692),
            line("”それを応援するのが\"大人の役目\"だから", 310, 468, 466, 31, score: 0.952),
        ]
        for lines in [input, Array(input.reversed())] {
            #expect(merge(lines, width: 1_200, height: 1_735).map(\.text) == [input[0].text])
        }
    }

    @Test func userPageTruncatedGlyphsDoNotSurviveBesideCompleteBalloon() {
        // First tile cuts the balloon at y=1536. The next tile sees both full
        // columns. One cut glyph is even misrecognized as the digit 4.
        let firstTile = CGRect(x: 0, y: 0, width: 1_200, height: 1_536)
        let secondTile = CGRect(x: 0, y: 199, width: 1_200, height: 1_536)
        let input = [
            line("で", 97, 1_494, 40, 42, orientation: .horizontal, orientationIsEstimated: true, sourceTileBounds: firstTile),
            line("4", 133, 1_491, 41, 45, orientation: .horizontal, orientationIsEstimated: true, sourceTileBounds: firstTile),
            line("ですね…", 96, 1_494, 40, 112, orientation: .vertical, sourceTileBounds: secondTile),
            line("しようがない", 135, 1_495, 35, 156, orientation: .vertical, sourceTileBounds: secondTile),
        ]
        for lines in [input, Array(input.reversed()), [input[1], input[3], input[0], input[2]]] {
            let output = merge(lines, width: 1_200, height: 1_735)
            #expect(output.map(\.text) == ["しようがないですね…"])
            #expect(output.first?.singleVerticalColumn == false)
            #expect(output.first?.boundingRect == CGRect(x: 96, y: 1_494, width: 74, height: 157))
        }
    }

    @Test func userPageCroppedColumnDoesNotRepeatInsideMergedSentence() {
        let input = [
            line("います！", 952, 158, 36, 112, orientation: .vertical),
            line("こう言って", 990, 159, 35, 135, orientation: .vertical),
            line("ます！", 952, 199, 38, 72, orientation: .vertical),
            line("う言って", 987, 199, 41, 97, orientation: .vertical),
        ]
        for lines in [input, Array(input.reversed())] {
            #expect(merge(lines, width: 1_200, height: 1_735).map(\.text) == ["こう言っています！"])
        }
    }

    @Test func partialGlyphSuppressionNeedsMatchingPositionOrInteriorTileCut() {
        let full = line("ですね…", 96, 1_494, 40, 112, orientation: .vertical)
        let cases = [
            line("で", 96, 1_564, 40, 42), // Wrong character position.
            line("別", 96, 1_494, 40, 42), // Different text, no tile evidence.
            line("で", 96, 1_494, 40, 42, orientation: .horizontal), // Explicit direction.
            line("で", 139, 1_494, 40, 42), // A neighbouring column.
            line("で", 105, 1_494, 12, 18), // Smaller ruby / annotation.
            line("4", 96, 1_494, 40, 42, sourceTileBounds: CGRect(x: 0, y: 0, width: 1_200, height: 1_735)),
        ]
        for fragment in cases {
            let result = merge([full, fragment], width: 1_200, height: 1_735)
            #expect(result.map(\.text).joined().count == full.text.count + fragment.text.count)
        }
    }

    @Test func estimatedSquareGlyphIsRemovedAtItsPositionWithoutTileMetadata() {
        let output = merge([
            line("で", 96, 1_494, 41, 42, orientation: .horizontal, orientationIsEstimated: true),
            line("ですね…", 96, 1_495, 40, 112, orientation: .vertical),
        ], width: 1_200, height: 1_735)
        #expect(output.map(\.text) == ["ですね…"])
    }

    @Test func clippedHorizontalGlyphUsesTheSameContainmentRules() {
        let output = merge([
            line("4", 1_494, 97, 42, 40, orientation: .vertical, orientationIsEstimated: true,
                 sourceTileBounds: CGRect(x: 0, y: 0, width: 1_536, height: 1_200)),
            line("ですね…", 1_494, 96, 112, 40, orientation: .horizontal,
                 sourceTileBounds: CGRect(x: 199, y: 0, width: 1_536, height: 1_200)),
        ], width: 1_735, height: 1_200)
        #expect(output.map(\.text) == ["ですね…"])
    }


    @Test func suppressesSameLineDetectedWithDifferentTilePadding() throws {
        // Actual detections from the user's page, once in each overlapping tile.
        let quotes = [
            line("”出来る、出来ないはやってみないと解らない”", 348, 305, 562, 34, score: 0.994),
            line("”出来る、出来ないはやってみないと解らない”", 349, 303, 562, 38, score: 0.993),
        ]
        let vertical = [
            line("大丈夫です", 970, 803, 45, 152, score: 0.99935),
            line("大丈夫です", 972, 805, 41, 149, score: 0.99936),
        ]
        for pair in [quotes, vertical] {
            for scale in [CGFloat(0.5), 1, 2] {
                let scaled = pair.map { item in
                    NativeCoreMLOCRLine(polygon: item.polygon.map { CGPoint(x: $0.x * scale, y: $0.y * scale) },
                                        text: item.text, score: item.score, orientation: item.orientation)
                }
                for input in [scaled, Array(scaled.reversed())] {
                    let output = merge(input, width: Int(1_300 * scale), height: Int(1_900 * scale))
                    #expect(output.count == 1)
                    #expect(try #require(output.first).score == pair.map(\.score).max())
                }
            }
        }
    }

    @Test func tileDeduplicationKeepsRepeatedDialogueOnSeparateLines() {
        let output = merge([
            line("同じ台詞", 10, 10, 100, 20),
            line("同じ台詞", 12, 27, 98, 22), // Slight overlap is not the same baseline.
            line("同じ台詞", 145, 10, 100, 20),
        ], width: 300, height: 100)
        #expect(output.reduce(0) { $0 + $1.text.components(separatedBy: "同じ台詞").count - 1 } == 3)
    }

    @Test func sharedSubstringDoesNotDeleteEitherContainingLine() {
        let chunks = [
            line("甲乙丙丁", 20, 20, 100, 20),
            line("丙丁", 70, 20, 50, 20),
            line("丙丁戊己", 70, 20, 100, 20),
        ]
        for input in [chunks, Array(chunks.reversed()), [chunks[1], chunks[2], chunks[0]]] {
            let output = merge(input, width: 240, height: 100)
            #expect(Set(output.map(\.text)) == ["甲乙丙丁", "丙丁戊己"])
        }
    }

    @Test func keepsUniqueSuffixWhenADuplicateBridgesOverlappingChunks() throws {
        let chunks = [
            line("甲乙丙丁戊", 20, 20, 125, 24),
            line("丙丁戊", 70, 20, 75, 24),
            line("丙丁戊己庚", 70, 20, 125, 24),
        ]
        for input in [chunks, Array(chunks.reversed())] {
            let output = merge(input, width: 260, height: 100)
            #expect(output.count == 1)
            #expect(try #require(output.first).text == "甲乙丙丁戊己庚")
        }
    }

    @Test func invalidBoxDoesNotDisableValidFragmentMerging() {
        let invalid = line("kept", 500, 500, 0, 20)
        let fragments = [line("設定", 10, 10, 30, 20), line("画面", 45, 10, 30, 20)]
        #expect(merge([invalid] + fragments, width: 600, height: 600).map(\.text) == ["kept", "設定画面"])
        #expect(merge(fragments + [invalid], width: 600, height: 600).map(\.text) == ["設定画面", "kept"])
        #expect(merge([invalid, fragments[0]], width: 600, height: 600).map(\.text) == ["kept", "設定"])
    }

    @Test func continuesMergingAndDeduplicatingBeyond1024Detections() {
        let noise = (0..<1_100).map {
            line("雑音\($0)", 500, CGFloat($0 * 50), 80, 20)
        }
        let target = [
            line("設定", 10, 1_020, 30, 20),
            line("設定", 10, 1_020, 30, 20),
            line("画面", 45, 1_020, 30, 20),
        ]
        for input in [noise + target, Array((noise + target).reversed())] {
            let output = merge(input, width: 700, height: 60_000)
            #expect(output.count == noise.count + 1)
            #expect(output.filter { $0.text == "設定画面" }.count == 1)
            #expect(Set(output.filter { $0.text.hasPrefix("雑音") }.map(\.text)) == Set(noise.map(\.text)))
        }
    }

    @Test func longPageStillMergesRegionsAndFindsEnglishWordCandidates() {
        let noise = (0..<1_100).map { line("雑音\($0)", 500, CGFloat($0 * 50), 80, 20) }
        let input = noise + [
            line("Open the", 10, 1_020, 100, 20),
            line("settings.", 10, 1_044, 100, 20),
            line("trans", 10, 2_020, 50, 20),
            line("lation", 62, 2_020, 50, 20),
        ]
        let words = NativeOCRTextLineMerger.latinWordCandidates(input)
        #expect(words == ["trans", "lation", "translation"])
        let output = merge(input, width: 700, height: 60_000, recognizedLatinWords: ["translation"])
        #expect(output.contains { $0.text == "Open the settings." })
        #expect(output.contains { $0.text == "translation" })
        #expect(output.count == noise.count + 2)
    }

    @Test func stitchesWidthVariantsWhilePreservingOriginalGlyphs() throws {
        let chunks = [line("ＡＢＣ１２", 20, 20, 125, 24), line("C12DE", 70, 20, 125, 24)]
        for input in [chunks, Array(chunks.reversed())] {
            let output = merge(input, width: 260, height: 100)
            #expect(output.count == 1)
            #expect(try #require(output.first).text == "ＡＢＣ１２DE")
        }
    }

    @Test func stitchesHalfwidthKanaIncludingVoicingMarks() throws {
        let output = merge([
            line("アイガギグ", 20, 20, 125, 24),
            line("ｶﾞｷﾞｸﾞケコ", 70, 20, 125, 24),
        ], width: 260, height: 100)
        #expect(output.count == 1)
        #expect(try #require(output.first).text == "アイガギグケコ")
    }

    @Test func overlapNormalizationDoesNotEraseSemanticNumberDistinctions() {
        let output = merge([
            line("ab①23", 20, 20, 125, 24),
            line("123de", 70, 20, 125, 24),
        ], width: 260, height: 100)
        #expect(output.map(\.text) == ["ab①23", "123de"])
    }

    @Test func spatialQueriesMatchExhaustiveSearchAcrossSizesAndBoundaries() {
        var boxes: [CGRect] = (0..<600).map { index in
            let x = CGFloat(index * 37 % 1_009 - 500)
            let y = CGFloat(index * 131 % 4_009 - 2_000)
            let width = CGFloat(1 + index * 17 % 700)
            let height = CGFloat(1 + index * 43 % 1_100)
            return CGRect(x: x, y: y, width: width, height: height)
        }
        boxes.append(CGRect(x: -2_000, y: -10_000, width: 4_000, height: 20_000))
        let spatialIndex = NativeOCRSpatialIndex(boxes: boxes)
        var queries: [CGRect] = (0..<100).map { index in
            let x = CGFloat(index * 53 % 1_009 - 500)
            let y = CGFloat(index * 137 % 4_009 - 2_000)
            let width = CGFloat(1 + index * 19 % 300)
            let height = CGFloat(1 + index * 29 % 500)
            return CGRect(x: x, y: y, width: width, height: height)
        }
        queries.append(contentsOf: boxes.prefix(20))
        for query in queries {
            let expected = Set(boxes.indices.filter { boxes[$0].intersects(query) })
            let actual = spatialIndex.indices(intersecting: query)
            #expect(Set(actual) == expected)
            #expect(actual.count == Set(actual).count)
        }
        #expect(NativeOCRSpatialIndex(boxes: []).indices(intersecting: boxes[0]).isEmpty)
    }

    @Test func invalidConfidenceIsIsolatedAndPreservedWithoutNaN() {
        let input = [
            line("kept", 300, 10, 40, 20, score: .nan),
            line("設定", 10, 10, 30, 20),
            line("画面", 45, 10, 30, 20),
        ]
        let output = merge(input, width: 400, height: 100)
        #expect(output.map(\.text) == ["kept", "設定画面"])
        #expect(output.allSatisfy { $0.score.isFinite })
        #expect(output.first?.score == 0)
    }

    @Test func widthVariantOverlapPreservesAnOriginalRightHandSuffix() throws {
        let output = merge([
            line("ABC12", 20, 20, 125, 24),
            line("Ｃ１２ＤＥ", 70, 20, 125, 24),
        ], width: 260, height: 100)
        #expect(output.count == 1)
        #expect(try #require(output.first).text == "ABC12ＤＥ")
    }

    @Test func preservesExplicitOrientationWhenUnrelatedLinesAreAdded() throws {
        let horizontal = line("A", 10, 10, 15, 25, orientation: .horizontal)
        let vertical = line("縦", 100, 10, 30, 20, orientation: .vertical)
        for target in [horizontal, vertical] {
            let alone = try #require(merge([target], width: 800, height: 800).first)
            let together = merge([
                target, line("Far away", 500, 500, 100, 20),
            ], width: 800, height: 800)
            let unchanged = try #require(together.first { $0.text == target.text })
            #expect(unchanged.sourceOrientation == alone.sourceOrientation)
            #expect(unchanged.singleVerticalColumn == alone.singleVerticalColumn)
        }
    }

    @Test func resolvesEstimatedSquareGlyphsFromVerticalNeighbours() throws {
        let input = "縦書文章".enumerated().map { index, glyph in
            line(String(glyph), 100, 10 + CGFloat(index * 27), 24, 24,
                 orientation: .horizontal, orientationIsEstimated: true)
        }
        let output = merge(input, width: 220, height: 160)
        #expect(output.count == 1)
        #expect(try #require(output.first).text == "縦書文章")
        #expect(try #require(output.first).sourceOrientation == .vertical)
    }

    @Test func doesNotOverrideExplicitVerticalHintForWrappedTail() {
        let output = merge([
            line("小さい文字と低いコントラス", 20, 20, 170, 22, orientation: .horizontal),
            line("ト", 20, 44, 12, 20, orientation: .vertical),
        ], width: 240, height: 100)
        #expect(output.count == 2)
        #expect(output.last?.sourceOrientation == .vertical)
    }

    @Test func removesRawDuplicateBeforeItCanJoinAFragmentChain() throws {
        let first = line("設定", 10, 10, 30, 20, score: 0.8)
        let duplicate = line("設定", 10, 10, 30, 20, score: 0.99)
        let second = line("画面", 45, 10, 30, 20)
        for input in [[first, duplicate, second], [second, duplicate, first]] {
            let output = merge(input, width: 200, height: 100)
            #expect(output.count == 1)
            #expect(try #require(output.first).text == "設定画面")
        }
    }

    @Test func stitchesOverlappingVerticalTextWithoutRepeatingTheSeam() throws {
        let first = line("今日はいい", 100, 20, 24, 125, orientation: .vertical)
        let second = line("はいい天気", 100, 70, 24, 125, orientation: .vertical)
        for input in [[first, second], [second, first]] {
            let output = merge(input, width: 240, height: 240)
            let merged = try #require(output.first)
            #expect(output.count == 1)
            #expect(merged.text == "今日はいい天気")
            #expect(merged.singleVerticalColumn == true)
            #expect(merged.boundingRect == CGRect(x: 100, y: 20, width: 24, height: 175))
        }
    }

    @Test func stitchesHorizontalTileOverlapAndThreePartChains() throws {
        let chunks = [
            line("今日はいい", 20, 20, 125, 24, orientation: .horizontal),
            line("はいい天気", 70, 20, 125, 24, orientation: .horizontal),
            line("いい天気だよ", 95, 20, 150, 24, orientation: .horizontal),
        ]
        for input in [chunks, Array(chunks.reversed()), [chunks[1], chunks[0], chunks[2]]] {
            let output = merge(input, width: 300, height: 100)
            #expect(output.count == 1)
            #expect(try #require(output.first).text == "今日はいい天気だよ")
        }
    }

    @Test func keepsRepeatedTextInAdjacentVerticalColumns() throws {
        let output = merge([
            line("今日はいい", 100, 20, 24, 125, orientation: .vertical),
            line("はいい天気", 70, 20, 24, 125, orientation: .vertical),
        ], width: 240, height: 240)
        #expect(output.count == 1)
        #expect(try #require(output.first).text == "今日はいいはいい天気")
        #expect(output.first?.singleVerticalColumn == false)
    }

    @Test func keepsTextWhenItsMatchingSeamDoesNotMatchTheGeometry() {
        let output = merge([
            line("今日はいい", 20, 20, 125, 24, orientation: .horizontal),
            line("はいい天気", 135, 20, 125, 24, orientation: .horizontal),
        ], width: 300, height: 100)
        #expect(output.map(\.text) == ["今日はいい", "はいい天気"])
    }

    @Test func doesNotEraseRepeatedGlyphsOrPunctuationInOverlappingChunks() {
        for texts in [("あああああ", "ああああっ"), ("え……！？", "…！？本当")] {
            let output = merge([
                line(texts.0, 100, 20, 24, 125, orientation: .vertical),
                line(texts.1, 100, 70, 24, 125, orientation: .vertical),
            ], width: 240, height: 240)
            #expect(output.map(\.text).joined().filter { !$0.isWhitespace } == texts.0 + texts.1)
        }
    }

    @Test func joinsTightLatinWordOnlyWithDictionaryEvidence() throws {
        let input = [line("trans", 10, 10, 50, 20), line("lation", 62, 10, 50, 20)]
        let conservative = merge(input, width: 200, height: 100)
        #expect(conservative.first?.text == "trans lation")
        let output = merge(input, width: 200, height: 100, recognizedLatinWords: ["translation"])
        #expect(output.count == 1)
        #expect(try #require(output.first).text == "translation")
        #expect(NativeOCRTextLineMerger.latinWordCandidates(input) == ["trans", "lation", "translation"])
    }

    @Test func preservesTwoValidWordsEvenWhenTheirCompoundIsKnown() throws {
        let output = merge([
            line("some", 10, 10, 40, 20), line("thing", 52, 10, 50, 20),
        ], width: 200, height: 100, recognizedLatinWords: ["some", "thing", "something"])
        #expect(try #require(output.first).text == "some thing")
    }

    @Test func preservesExplicitWhitespaceAndNormalWordGaps() throws {
        for input in [
            [line("trans ", 10, 10, 50, 20), line("lation", 62, 10, 50, 20)],
            [line("trans", 10, 10, 50, 20), line("lation", 65, 10, 50, 20)],
        ] {
            let output = merge(input, width: 200, height: 100, recognizedLatinWords: ["translation"])
            #expect(try #require(output.first).text == "trans lation")
            #expect(NativeOCRTextLineMerger.latinWordCandidates(input).isEmpty)
        }
    }

    @Test func excludesDifferentRowsFromWordDictionaryCandidates() {
        let input = [line("trans", 10, 10, 50, 20), line("lation", 62, 80, 50, 20)]
        #expect(NativeOCRTextLineMerger.latinWordCandidates(input).isEmpty)
    }

    @Test(arguments: [0.5, 1.0, 2.0, 3.0])
    func overlapReconciliationIsScaleInvariant(scale: Double) throws {
        let input = [
            line("今日はいい", 100 * scale, 20 * scale, 24 * scale, 125 * scale, orientation: .vertical),
            line("はいい天気", 100 * scale, 70 * scale, 24 * scale, 125 * scale, orientation: .vertical),
        ]
        let output = merge(input, width: Int(240 * scale), height: Int(240 * scale))
        #expect(output.count == 1)
        #expect(try #require(output.first).text == "今日はいい天気")
    }

    @Test func dictionaryCandidateWorkIsBoundedOnDensePages() {
        let input = (0..<200).flatMap { index in
            let suffix = String(UnicodeScalar(97 + index / 26)!)
                + String(UnicodeScalar(97 + index % 26)!)
            return [line("fragment" + suffix, 10, CGFloat(index * 30), 100, 20),
                    line("continuation" + suffix, 112, CGFloat(index * 30), 140, 20)]
        }
        let candidates = NativeOCRTextLineMerger.latinWordCandidates(input)
        #expect(candidates.count >= 250 && candidates.count <= 256)
        #expect(NativeOCRTextLineMerger.latinWordCandidates(Array(repeating: input[0], count: 1_025)).isEmpty)
    }

    #if canImport(UIKit)
    @Test @MainActor func resolvesTightLatinSeamsWithTheDeviceDictionary() throws {
        let input = [line("trans", 10, 10, 50, 20), line("lation", 62, 10, 50, 20)]
        let words = ReaderOCRWordBoundaryResolver.recognizedWords(
            in: NativeOCRTextLineMerger.latinWordCandidates(input)
        )
        let output = merge(input, width: 200, height: 100, recognizedLatinWords: words)
        if UITextChecker.availableLanguages.contains(where: { $0.hasPrefix("en") }) {
            #expect(words.contains("translation"))
            #expect(!words.contains("lation"))
            #expect(try #require(output.first).text == "translation")
        } else {
            #expect(try #require(output.first).text == "trans lation")
        }
        #expect(ReaderOCRWordBoundaryResolver.recognizedWords(in: []).isEmpty)
    }
    #endif

    @Test func joinsAlignedHorizontalCJKFragmentsWithoutSpaces() throws {
        let output = merge([
            line("設定", 10, 10, 30, 20),
            line("画面", 45, 11, 30, 20),
        ], width: 200, height: 100)

        let merged = try #require(output.first)
        #expect(output.count == 1)
        #expect(merged.text == "設定画面")
        #expect(merged.boundingRect == CGRect(x: 10, y: 10, width: 65, height: 21))
    }

    @Test func addsSpaceBetweenAlignedLatinFragments() throws {
        let output = merge([
            line("Open", 10, 10, 36, 20),
            line("Settings", 50, 10, 62, 20),
        ], width: 200, height: 100)

        let merged = try #require(output.first)
        #expect(output.count == 1)
        #expect(merged.text == "Open Settings")
        #expect(merged.sourceOrientation == .horizontal)
    }

    @Test func joinsCenteredCyrillicSpeechWithDifferentGlyphHeights() {
        // Geometry follows the real Russian comic balloon; content is varied
        // so the rule cannot rely on a particular title or phrase.
        for text in [["Доброе утро, сэр,", "мне, пожалуйста,", "восемь тыквенных", "звёздочек"],
                     ["Good morning, sir,", "could you bring", "a few ripe", "apples"]] {
            let output = merge([
                line(text[0], 142, 1024, 170, 32),
                line(text[1], 138, 1060, 176, 19),
                line(text[2], 138, 1086, 176, 24),
                line(text[3], 178, 1118, 96, 25),
            ], width: 1200, height: 1660)
            #expect(output.map(\.text) == [text.joined(separator: " ")])
        }
    }

    @Test func centeredParagraphAllowsInkHeightVariationAcrossIndividuallyCompatibleRows() {
        // Whole-page Vision bounds differ from its tiled bounds on the same
        // real balloon. Scale invariance guards against a resolution-specific fix.
        for scale in [CGFloat(0.5), 1, 2] {
            let values: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                ("Доброе утро, сэр,", 142.03, 1024.69, 168.95, 32.85),
                ("мне, пожалуйста,", 142.17, 1059, 166.27, 27),
                ("восемь тыквенных", 142.17, 1090.58, 171.08, 16.89),
                ("звёздочек", 175.9, 1119.53, 98.8, 24.13),
            ]
            let output = merge(values.map { line($0.0, $0.1 * scale, $0.2 * scale, $0.3 * scale, $0.4 * scale) },
                               width: Int(1200 * scale), height: Int(1660 * scale))
            #expect(output.map(\.text) == [values.map { $0.0 }.joined(separator: " ")])
        }
    }

    @Test func centeredContinuationKeepsSeparateScriptsSentencesAndBalloons() {
        for (upper, lower) in [("Good morning, sir,", "доброе утро"),
                               ("Good morning, sir.", "another balloon"),
                               ("Good morning, sir,", "Another balloon")] {
            let output = merge([line(upper, 142, 1024, 170, 32), line(lower, 138, 1060, 176, 19)],
                               width: 1200, height: 1660)
            #expect(output.count == 2)
        }
        let distant = merge([line("Доброе утро, сэр,", 142, 1024, 170, 32),
                             line("мне, пожалуйста,", 138, 1090, 176, 19)], width: 1200, height: 1660)
        #expect(distant.count == 2)
    }

    @Test func deduplicatesArabicBalloonRowsDespiteOptionalVowelMarks() {
        let full = "حسن حظي، لا يزالُ لدي يومَّ كاملٌ للتحضير!"
        let output = merge([
            line(full, 635, 1272, 291, 67),
            line("حسنٍ حظي،", 718, 1271, 123, 36),
            line("لا يزالُ لدي يومَّ كاملَ للتحضير!", 636, 1296, 290, 40),
        ], width: 1200, height: 1660)
        #expect(output.map(\.text) == [full])
    }

    @Test func multilineDuplicateRowsRequireTheirPhysicalEdge() {
        let full = "Good morning to all our visitors, welcome to our quiet village and enjoy your stay"
        let output = merge([
            line(full, 100, 100, 300, 90),
            // This matching phrase is in the middle, not the top row.
            line("Good morning", 200, 135, 100, 20),
        ], width: 500, height: 300)
        #expect(output.count == 2)
        let distant = merge([
            line("حسن حظي", 10, 10, 100, 20),
            line("حسنٍ حظي", 300, 100, 100, 20),
        ], width: 500, height: 200)
        #expect(distant.count == 2)
    }

    @Test func duplicateComparisonPreservesArabicLettersAndLatinAccents() {
        for (first, second) in [("أمان", "امان"), ("آثار", "اثار"), ("résumé", "resume")] {
            let output = merge([line(first, 10, 10, 100, 20), line(second, 10, 10, 100, 20)],
                               width: 200, height: 100)
            #expect(output.count == 2)
        }
    }

    @Test func joinsWrappedHorizontalParagraph() throws {
        let output = merge([
            line("Open the", 10, 10, 100, 20),
            line("settings screen.", 12, 34, 110, 20),
        ], width: 240, height: 120)

        let merged = try #require(output.first)
        #expect(output.count == 1)
        #expect(merged.text == "Open the settings screen.")
        #expect(merged.sourceOrientation == .horizontal)
        #expect(merged.singleVerticalColumn == false)
        #expect(merged.boundingRect == CGRect(x: 10, y: 10, width: 112, height: 44))
    }

    @Test func joinsPhysicalIPhoneTallLatinFixtureWithFinalRow() throws {
        let output = merge([
            line("中文", 92, 758, 92, 42),
            line("English", 708, 758, 148, 42),
            line("请打开设置页面。", 92, 830, 430, 150),
            line("Open the settings", 708, 830, 360, 158, score: 0.98),
            line("screen.", 708, 1018, 242, 62, score: 0.99),
        ], width: 1290, height: 2193)

        let texts = output.map(\.text)
        #expect(texts.contains("Open the settings screen."))
        #expect(!texts.contains("screen."))
        #expect(texts.contains("English"))
        #expect(texts.contains("请打开设置页面。"))
        let merged = try #require(output.first {
            $0.text == "Open the settings screen."
        })
        #expect(merged.boundingRect == CGRect(
            x: 708, y: 830, width: 360, height: 250
        ))
    }

    @Test func keepsTallWrappedContinuationsInTheirColumns() {
        let output = merge([
            line("Open the account", 20, 20, 135, 48),
            line("details.", 21, 74, 62, 18),
            line("Review the profile", 190, 20, 145, 48),
            line("settings.", 191, 74, 68, 18),
        ], width: 370, height: 120)

        #expect(output.map(\.text) == [
            "Open the account details.",
            "Review the profile settings.",
        ])
    }

    @Test func rejectsNewSentenceAndDistantLowercaseRow() {
        let output = merge([
            line("Read the introduction.", 20, 20, 150, 48),
            line("Continue below.", 21, 74, 100, 18),
            line("Open the settings", 210, 20, 135, 48),
            line("screen.", 211, 116, 60, 18),
        ], width: 380, height: 160)

        #expect(output.map(\.text) == [
            "Read the introduction.",
            "Continue below.",
            "Open the settings",
            "screen.",
        ])
    }

    @Test func inheritsHorizontalFlowForShortCJKWrappedTail() throws {
        let output = merge([
            line("小さい文字と低いコントラス", 20, 20, 170, 22, score: 0.96),
            line("ト", 20, 44, 12, 20, score: 0.99),
        ], width: 240, height: 100)

        let merged = try #require(output.first)
        #expect(output.count == 1)
        #expect(merged.text == "小さい文字と低いコントラスト")
        #expect(merged.sourceOrientation == .horizontal)
        #expect(merged.boundingRect == CGRect(x: 20, y: 20, width: 170, height: 44))
    }

    @Test func joinsVerticalTopToBottomChain() throws {
        let output = merge([
            line("縦", 100, 10, 20, 25),
            line("書", 101, 38, 20, 25),
            line("き", 100, 66, 20, 25),
        ], width: 200, height: 120)

        let merged = try #require(output.first)
        #expect(output.count == 1)
        #expect(merged.text == "縦書き")
        #expect(merged.sourceOrientation == .vertical)
        #expect(merged.singleVerticalColumn == true)
    }

    @Test func joinsLongSquareGlyphVerticalChain() throws {
        let text = "縦書き文章を正しく一行に結合する"
        let input = text.enumerated().map { index, glyph in
            line(String(glyph), 100 + CGFloat(index % 2),
                 10 + CGFloat(index * 27), 24, 24)
        }
        let output = merge(input, width: 240, height: 480)

        #expect(output.count == 1)
        #expect(try #require(output.first).text == text)
    }

    @Test func joinsAdjacentVerticalColumnsRightToLeft() throws {
        let right = "日本語".enumerated().map { index, glyph in
            line(String(glyph), 100, 10 + CGFloat(index * 27), 24, 24)
        }
        let left = "字幕列".enumerated().map { index, glyph in
            line(String(glyph), 68, 10 + CGFloat(index * 27), 24, 24)
        }
        let output = merge(left + right, width: 200, height: 120)

        let merged = try #require(output.first)
        #expect(output.count == 1)
        #expect(merged.text == "日本語字幕列")
        #expect(merged.sourceOrientation == .vertical)
        #expect(merged.singleVerticalColumn == false)
        #expect(merged.boundingRect == CGRect(x: 68, y: 10, width: 56, height: 78))
    }

    @Test func joinsOverlappingMangaChunksInOneVerticalColumn() throws {
        let output = merge([
            line("お腹っ…苦しっ♡やだぁっ…", 100, 20, 46, 230,
                 orientation: .vertical),
            line("痛SOSっ♡", 120, 180, 28, 150,
                 orientation: .vertical),
        ], width: 240, height: 380)

        let merged = try #require(output.first)
        #expect(output.count == 1)
        #expect(merged.text == "お腹っ…苦しっ♡やだぁっ…痛SOSっ♡")
        #expect(merged.singleVerticalColumn == true)
    }

    @Test func joinsUnequalWidthMangaColumnsRightToLeft() throws {
        let output = merge([
            line("幼い少女", 164, 20, 28, 72, orientation: .vertical),
            line("この血が誘惑するのは", 96, 20, 56, 250,
                 orientation: .vertical),
        ], width: 240, height: 300)

        let merged = try #require(output.first)
        #expect(output.count == 1)
        #expect(merged.text == "幼い少女この血が誘惑するのは")
        #expect(merged.singleVerticalColumn == false)
    }

    @Test func keepsSeparatedMangaBalloonsIndependent() {
        let output = merge([
            line("右の吹き出し", 150, 10, 28, 100, orientation: .vertical),
            line("左の吹き出し", 70, 10, 56, 180, orientation: .vertical),
        ], width: 240, height: 220)

        #expect(output.count == 2)
    }

    @Test func keepsSquareGlyphHorizontalSentenceHorizontal() throws {
        let text = "横書文章"
        let input = text.enumerated().map { index, glyph in
            line(String(glyph), 10 + CGFloat(index * 27), 20, 24, 24)
        }
        let output = merge(input, width: 180, height: 100)

        let merged = try #require(output.first)
        #expect(output.count == 1)
        #expect(merged.text == text)
        #expect(merged.sourceOrientation == .horizontal)
        #expect(merged.boundingRect == CGRect(x: 10, y: 20, width: 105, height: 24))
    }

    @Test func keepsUnrelatedWrappedCardsInTwoColumns() {
        let output = merge([
            line("Left", 10, 10, 80, 20),
            line("card", 12, 34, 76, 20),
            line("Right", 110, 10, 80, 20),
            line("card", 112, 34, 76, 20),
        ], width: 220, height: 100)

        #expect(output.map(\.text) == ["Left card", "Right card"])
    }

    @Test func doesNotMergeDistantMisalignedOrDifferentlySizedRegions() {
        let output = merge([
            line("近い", 10, 10, 30, 20),
            line("遠い", 90, 10, 30, 20),
            line("別行", 43, 36, 30, 20),
            line("大見出し", 42, 10, 80, 40),
        ], width: 220, height: 120)

        #expect(output.count == 4)
    }

    @Test func suppressesContainedFullAndPartialDuplicate() throws {
        let full = line("가격 12,345엔", 20, 20, 180, 44, score: 0.8)
        let partial = line("12,345엔", 70, 28, 100, 28, score: 0.99)
        for input in [[full, partial], [partial, full]] {
            let output = merge(input, width: 240, height: 120)
            let merged = try #require(output.first)
            #expect(output.count == 1)
            #expect(merged.text == "가격 12,345엔")
            #expect(merged.score == 0.8)
        }
    }

    @Test func keepsCanonicalFullPriceDespiteStrongerFragment() throws {
        let full = line("価格 12,345円 · 95%", 20, 20, 190, 44, score: 0.72)
        let amount = line("12,345円", 78, 28, 90, 26, score: 0.99)
        for input in [[full, amount], [amount, full]] {
            let output = merge(input, width: 240, height: 120)
            let merged = try #require(output.first)
            #expect(output.count == 1)
            #expect(merged.text == "価格 12,345円 · 95%")
            #expect(merged.score == 0.72)
        }
    }

    @Test func keepsStrongestExactOverlappingDuplicate() throws {
        let output = merge([
            line("가격 12,345엔", 20, 20, 180, 44, score: 0.82),
            line("가격  12,345엔", 21, 20, 180, 44, score: 0.97),
        ], width: 240, height: 120)

        #expect(output.count == 1)
        #expect(try #require(output.first).score == 0.97)
    }

    @Test func doesNotSuppressDifferentOverlappingText() {
        let output = merge([
            line("가격 12,345엔", 20, 20, 180, 44, score: 0.94),
            line("세금 포함", 70, 28, 100, 28, score: 0.99),
        ], width: 240, height: 120)

        #expect(output.count == 2)
    }

    @Test func doesNotSuppressAccidentalLatinSubstring() {
        let output = merge([
            line("discard", 20, 20, 180, 44, score: 0.94),
            line("card", 70, 28, 100, 28, score: 0.96),
        ], width: 240, height: 120)

        #expect(output.count == 2)
    }

    @Test func keepsIdenticalTextInNonOverlappingBoxes() {
        let output = merge([
            line("12,345엔", 10, 20, 80, 24),
            line("12,345엔", 100, 20, 80, 24),
        ], width: 220, height: 100)

        #expect(output.count == 2)
    }

    @Test func resolvesUnknownOrientationWithoutMutatingInput() throws {
        let input = line("縦", 100, 10, 20, 30, orientation: .unknown)
        let output = merge([input], width: 200, height: 100)

        let merged = try #require(output.first)
        #expect(merged.text == "縦")
        #expect(merged.sourceOrientation == .vertical)
        #expect(merged.singleVerticalColumn == true)
        #expect(input.orientation == .unknown)
    }

    @Test func invalidNativeGeometryFallsBackWithoutDiscardingOCR() {
        let invalid = NativeCoreMLOCRLine(
            polygon: [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 30)],
            text: "kept",
            score: 0.9,
            orientation: .horizontal
        )
        let valid = line("also kept", 30, 10, 80, 20)
        let output = merge([invalid, valid], width: 200, height: 100)

        #expect(output.map(\.text) == ["kept", "also kept"])
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func joinsRegularlySpacedCJKGlyphsWithoutDependingOnDetectionOrder(scale: Double) throws {
        let text = "ひとつの文"
        let input = text.enumerated().map { index, glyph in
            line(String(glyph), (100 + CGFloat(index % 2)) * scale,
                 (20 + CGFloat(index * 38)) * scale, 24 * scale, 24 * scale)
        }
        for lines in [input, Array(input.reversed()), [input[2], input[0], input[4], input[1], input[3]]] {
            let output = merge(lines, width: Int(240 * scale), height: Int(300 * scale))
            #expect(output.count == 1)
            #expect(try #require(output.first).text == text)
            #expect(output.first?.singleVerticalColumn == true)
        }
    }

    @Test func joinsRegularMultiCharacterFragmentsOnTheSameVerticalLine() throws {
        let input = [
            line("これは", 100, 20, 24, 72, orientation: .vertical),
            line("ひとつの", 101, 106, 24, 96, orientation: .vertical),
            line("文章です。", 100, 216, 24, 120, orientation: .vertical)
        ]
        let output = merge(Array(input.reversed()), width: 200, height: 380)
        #expect(output.count == 1)
        #expect(try #require(output.first).text == "これはひとつの文章です。")
        #expect(output.first?.singleVerticalColumn == true)
    }

    @Test func looseRunRejectsChangingFontSizesAndAlternatingAlignment() {
        let fontChanges = [
            line("小さい文字", 20, 20, 140, 20, orientation: .horizontal),
            line("大きな見出し", 20, 52, 140, 30, orientation: .horizontal),
            line("小さい文字", 20, 94, 140, 20, orientation: .horizontal)
        ]
        let drifting: [NativeCoreMLOCRLine] = (0..<3).map { index in
            let x = CGFloat(20 + index * 30)
            let y = CGFloat(20 + index * 32)
            return line("ずれた文章", x, y, 140, 20, orientation: .horizontal)
        }
        #expect(merge(fontChanges, width: 260, height: 160).count == 3)
        #expect(merge(drifting, width: 260, height: 160).count == 3)
    }

    @Test func looseSpacingDoesNotCombineDifferentScriptsBeforeLanguageFiltering() {
        let lines = [
            line("日本語の文章", 20, 20, 180, 20, orientation: .horizontal),
            line("English caption", 20, 52, 180, 20, orientation: .horizontal),
            line("日本語の文章", 20, 84, 180, 20, orientation: .horizontal)
        ]
        #expect(merge(lines, width: 240, height: 140).map(\.text) == lines.map(\.text))
    }

    @Test func joinsCenteredJapaneseParagraphWithRegularLooseLineSpacing() throws {
        let output = merge([
            line("これはひとつの", 30, 20, 160, 20, orientation: .horizontal),
            line("文章として読む", 20, 52, 180, 20, orientation: .horizontal),
            line("ためのテストです。", 40, 84, 140, 20, orientation: .horizontal)
        ], width: 260, height: 160)
        #expect(output.count == 1)
        #expect(try #require(output.first).text == "これはひとつの文章として読むためのテストです。")
        #expect(output.first?.boundingRect == CGRect(x: 20, y: 20, width: 180, height: 84))
    }

    @Test func joinsThreeRegularVerticalColumnsInReadingOrder() throws {
        let lines = [
            line("最初の列から", 146, 20, 24, 150, orientation: .vertical),
            line("次の列へと", 103, 20, 24, 170, orientation: .vertical),
            line("続く文章です。", 60, 20, 24, 140, orientation: .vertical)
        ]
        for input in [lines, Array(lines.reversed())] {
            let output = merge(input, width: 220, height: 230)
            #expect(output.count == 1)
            #expect(try #require(output.first).text == "最初の列から次の列へと続く文章です。")
            #expect(output.first?.singleVerticalColumn == false)
        }
    }

    @Test func joinsOrdinaryLatinWrappedContinuationWithLooserLeading() throws {
        let output = merge([
            line("This sentence continues", 20, 20, 220, 20, orientation: .horizontal),
            line("on the following line.", 21, 52, 190, 20, orientation: .horizontal)
        ], width: 280, height: 110)
        #expect(output.count == 1)
        #expect(try #require(output.first).text == "This sentence continues on the following line.")
    }

    @Test func looseSpacingNeedsContinuationOrThreeAlignedRows() {
        let cases: [[NativeCoreMLOCRLine]] = [
            [line("別の文章です。", 20, 20, 180, 20), line("こちらも別です。", 20, 52, 180, 20)],
            [line("This sentence ends.", 20, 20, 180, 20), line("another caption", 20, 52, 180, 20)],
            [line("This sentence continues", 20, 20, 220, 20), line("on another panel", 100, 52, 170, 20)],
            [line("ひ", 100, 20, 24, 24), line("と", 100, 58, 24, 24)],
            [line("ひ", 100, 20, 24, 24), line("と", 100, 82, 24, 24), line("つ", 100, 144, 24, 24)]
        ]
        for lines in cases { #expect(merge(lines, width: 320, height: 240).count == lines.count) }
    }

    @Test func regularParagraphsStayInTheirOwnColumns() {
        let left = (0..<3).map { line("左側の文章", 20, CGFloat(20 + $0 * 32), 100, 20, orientation: .horizontal) }
        let right = (0..<3).map { line("右側の文章", 160, CGFloat(20 + $0 * 32), 100, 20, orientation: .horizontal) }
        let output = merge(left + right, width: 300, height: 150)
        #expect(Set(output.map(\.text)) == [String(repeating: "左側の文章", count: 3), String(repeating: "右側の文章", count: 3)])
    }

    @Test func aLargerGapBetweenTwoTightParagraphsRemainsABoundary() {
        let lines = [
            line("一つ目の", 20, 20, 140, 20, orientation: .horizontal),
            line("文章です。", 20, 44, 140, 20, orientation: .horizontal),
            line("二つ目の", 20, 76, 140, 20, orientation: .horizontal),
            line("文章です。", 20, 100, 140, 20, orientation: .horizontal)
        ]
        #expect(merge(lines, width: 220, height: 160).map(\.text) == ["一つ目の文章です。", "二つ目の文章です。"])
    }

    @Test func horizontalRubyIsRemovedFromActualHaikyuNameCaption() {
        for scale: CGFloat in [0.5, 1, 2] {
            let rows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                ("北川第一中学3年", 26, 472, 204, 33),
                ("きたがわだいいちちゅうがく", 28, 465, 133, 14),
                ("影山飛雄", 55, 512, 142, 42),
                ("かげやま", 58, 503, 72, 16),
                ("とびお", 131, 505, 53, 12)
            ]
            let input = rows.map { line($0.0, $0.1 * scale, $0.2 * scale,
                $0.3 * scale, $0.4 * scale, orientation: .horizontal) }
            for ordered in [input, Array(input.reversed())] {
                let result = merge(ordered, width: Int(760 * scale), height: Int(1200 * scale)).map(\.text).joined()
                #expect(result.contains("北川第一中学3年"))
                #expect(result.contains("影山飛雄"))
                #expect(!result.contains("きたがわ"))
                #expect(!result.contains("かげやま"))
                #expect(!result.contains("とびお"))
            }
        }
    }

    @Test func horizontalRubyPreservesActualSakamotoSignSuffix() {
        for scale: CGFloat in [0.5, 1, 2] {
            let rows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                ("お酒", 411, 298, 47, 39), ("00", 465, 304, 29, 29),
                ("から", 469, 335, 21, 15), ("年齡確認", 406, 349, 89, 37)
            ]
            let input = rows.map { line($0.0, $0.1 * scale, $0.2 * scale,
                $0.3 * scale, $0.4 * scale, orientation: .horizontal) }
            for order in [input, Array(input.reversed())] {
                #expect(merge(order, width: Int(800 * scale), height: Int(1200 * scale))
                    .map(\.text).joined().contains("から"))
            }
        }
    }

    @Test func horizontalRubyFilterPreservesIndependentCaptionsAndSemanticReadings() {
        let candidates: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            ("かげやま", 58, 470, 72, 16), // Detached above the title.
            ("かげやま", 58, 560, 72, 16), // Below the title.
            ("かげやま", 210, 503, 72, 16), // Other text column.
            ("かげやま", 58, 495, 140, 32), // Full-size dialogue.
            ("カゲヤマ", 58, 503, 72, 16), // Semantic reading is not discarded.
            ("え", 58, 503, 12, 16), // A single reaction.
            ("かげやま？", 58, 503, 72, 16) // Punctuation indicates uncertain speech.
        ]
        for item in candidates {
            let result = merge([
                line("影山飛雄", 55, 512, 142, 42, orientation: .horizontal),
                line(item.0, item.1, item.2, item.3, item.4, orientation: .horizontal)
            ], width: 760, height: 1200).map(\.text).joined()
            #expect(result.contains(item.0))
        }
    }

    @Test func separateRubyDoesNotInterruptActualSpyDialogue() {
        // SPY x FAMILY, chapter 2 page 8: the reading of 話 previously
        // stole the neighboring また column during fragment assembly.
        for scale: CGFloat in [0.5, 1, 2] {
            let rows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                ("その話…", 104, 693, 37, 98),
                ("また", 141, 694, 30, 57),
                ("はなし", 129, 737, 24, 34)
            ]
            let input = rows.map { line($0.0, $0.1 * scale, $0.2 * scale, $0.3 * scale, $0.4 * scale, orientation: .vertical, orientationIsEstimated: true) }
            for ordered in [input, Array(input.reversed())] {
                #expect(merge(ordered, width: Int(800 * scale), height: Int(1200 * scale)).map(\.text) == ["またその話…"])
            }
        }
    }

    @Test func separateRubyIsRemovedFromActualSpyAndOnePieceColumns() {
        let fixtures: [(String, CGFloat, CGFloat, CGFloat, CGFloat, String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            ("災難だね", 81, 569, 27, 83, "さいなん", 100, 572, 18, 46),
            ("私たちってさ", 215, 945, 24, 108, "いたし", 235, 949, 11, 20),
            ("一度くらい", 569, 126, 23, 90, "いちど", 588, 128, 13, 34),
            ("誰か船を", 292, 139, 25, 80, "だれ", 314, 144, 9, 19),
            ("30手前くらいの", 412, 681, 26, 113, "てまえ", 431, 700, 11, 34),
            ("10歳年とったら", 655, 671, 28, 129, "さいとし", 675, 687, 14, 42)
        ]
        for item in fixtures {
            let output = merge([
                line(item.0, item.1, item.2, item.3, item.4, orientation: .vertical),
                line(item.5, item.6, item.7, item.8, item.9, orientation: .vertical)
            ], width: 800, height: 1200)
            #expect(output.map(\.text) == [item.0])
        }
    }

    @Test func rubyFilterPreservesDetachedAndFullSizeKanaDialogue() {
        let cases: [(String, CGFloat, CGFloat, CGFloat, CGFloat, BrowserOCRSourceOrientation)] = [
            ("また", 141, 694, 30, 57, .vertical), // Same size adjacent dialogue.
            ("はなし", 180, 737, 16, 34, .vertical), // Detached annotation.
            ("はなし", 85, 737, 16, 34, .vertical), // Left-side text.
            ("はなし", 129, 820, 16, 34, .vertical), // Different row.
            ("え", 129, 737, 16, 34, .vertical), // Single-character dialogue.
            ("ハナシ", 129, 737, 16, 34, .vertical), // Semantic alternative reading.
            ("はなし", 129, 737, 16, 34, .horizontal)
        ]
        for item in cases {
            let output = merge([
                line("その話…", 104, 693, 37, 98, orientation: .vertical),
                line(item.0, item.1, item.2, item.3, item.4, orientation: item.5)
            ], width: 800, height: 1200).map(\.text).joined()
            #expect(output.contains(item.0))
        }
        let dandadan = merge([
            line("何て？", 78, 395, 41, 94, orientation: .vertical),
            line("え？", 117, 398, 32, 63, orientation: .vertical),
            line("超", 500, 651, 43, 43, orientation: .vertical),
            line("ウケる～", 463, 652, 36, 135, orientation: .vertical)
        ], width: 800, height: 1200).map(\.text).joined()
        #expect(dandadan.contains("え？"))
        #expect(dandadan.contains("超"))
    }

    @Test func slantedParentCannotMakeFullSizeKanaLookLikeRuby() {
        let slanted = NativeCoreMLOCRLine(
            polygon: [CGPoint(x: 100, y: 100), CGPoint(x: 120, y: 100),
                      CGPoint(x: 160, y: 220), CGPoint(x: 140, y: 220)],
            text: "その話", score: 0.9, orientation: .vertical,
            orientationIsEstimated: true
        )
        let result = merge([
            slanted, line("それ", 150, 140, 20, 40, orientation: .vertical)
        ], width: 400, height: 400).map(\.text).joined()
        #expect(result.contains("それ"))
    }

    @Test func parentContainingRubyCannotSuppressAdjacentTanyaDialogue() {
        let cases: [(String, CGFloat, CGFloat, CGFloat, CGFloat, String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            ("側前の老人を仮に", 80, 526, 23, 92, "よって", 99, 528, 15, 40),
            ("困ったぞ", 262, 138, 22, 50, "さあ", 278, 140, 16, 27)
        ]
        for item in cases {
            let result = merge([
                line(item.0, item.1, item.2, item.3, item.4, orientation: .vertical, orientationIsEstimated: true),
                line(item.5, item.6, item.7, item.8, item.9, orientation: .vertical, orientationIsEstimated: true)
            ], width: 493, height: 698).map(\.text).joined()
            #expect(result.contains(item.5))
        }
    }

    @Test func clippedTileContinuationReconcilesTwoDistinctGlyphs() {
        let input = [
            line("して、その", 1206, 2461, 101, 380, orientation: .vertical,
                 sourceTileBounds: CGRect(x: 0, y: 1305, width: 1536, height: 1536)),
            line("その者の名は？", 1210, 2630, 93, 548, orientation: .vertical,
                 sourceTileBounds: CGRect(x: 0, y: 2610, width: 1536, height: 1536))
        ]
        for order in [input, Array(input.reversed())] {
            #expect(merge(order, width: 3496, height: 4961).map(\.text).joined() == "して、その者の名は？")
        }
    }

    @Test func shortOverlapWithoutTileEvidenceKeepsRepeatedDialogue() {
        let input = [
            line("して、その", 1206, 2461, 101, 380, orientation: .vertical),
            line("その者の名は？", 1210, 2630, 93, 548, orientation: .vertical)
        ]
        let result = merge(input, width: 3496, height: 4961).map(\.text).joined()
        #expect(result.contains("して、その"))
        #expect(result.contains("その者の名は？"))
        #expect(result.count == input.map(\.text).joined().count)
    }

    @Test func completeShortSuffixAtTileEdgeIsNotAppendedTwice() {
        // Real CG detector geometry, substituted text. The second tile contains
        // only the last two glyphs, extending past the first tile through padding.
        for scale: CGFloat in [0.5, 1, 2] {
            let a = CGRect(x: 0, y: 0, width: 1536 * scale, height: 1536 * scale)
            let b = CGRect(x: 0, y: 1305 * scale, width: 1536 * scale, height: 1536 * scale)
            let input = [
                line("あいうえおかきくけこ", 1085 * scale, 288 * scale, 177 * scale, 1248 * scale,
                     orientation: .vertical, sourceTileBounds: a),
                line("けこ", 1087 * scale, 1305 * scale, 171 * scale, 271 * scale,
                     orientation: .vertical, sourceTileBounds: b)
            ]
            for order in [input, Array(input.reversed())] {
                #expect(merge(order, width: Int(3838 * scale), height: Int(2904 * scale)).map(\.text).joined()
                        == input[0].text)
            }
        }
    }

    @Test func completeSuffixStillNeedsActualTileEndingAndPhysicalOverlap() {
        let a = CGRect(x: 0, y: 0, width: 1536, height: 1536)
        let b = CGRect(x: 0, y: 1305, width: 1536, height: 1536)
        let original = line("あいうえおかきくけこ", 1085, 288, 177, 1248,
                            orientation: .vertical, sourceTileBounds: a)
        for other in [
            line("けこ", 1087, 1510, 171, 271, orientation: .vertical, sourceTileBounds: b),
            line("けこ", 1400, 1305, 171, 271, orientation: .vertical, sourceTileBounds: b)
        ] {
            let text = merge([original, other], width: 3838, height: 2904).map(\.text).joined()
            #expect(text.count == original.text.count + other.text.count)
        }
        // This line touches the tile's left edge, not its text-ending edge.
        let nonEndingTile = CGRect(x: 1085, y: 200, width: 1536, height: 1536)
        let text = merge([
            line(original.text, 1085, 288, 177, 1248, orientation: .vertical, sourceTileBounds: nonEndingTile),
            line("けこ", 1087, 1305, 171, 271, orientation: .vertical, sourceTileBounds: b)
        ], width: 3838, height: 2904).map(\.text).joined()
        #expect(text.count == original.text.count + 2)
    }

    @Test func neighbouringTilesDeduplicateUnequalPaddingButKeepSeparateRepetitions() {
        let a = CGRect(x: 0, y: 0, width: 1536, height: 1536)
        let b = CGRect(x: 283, y: 0, width: 1536, height: 1536)
        let first = line("淡い光を放っていた", 1222, 786, 41, 323, orientation: .vertical, sourceTileBounds: a)
        let padded = line("淡い光を放っていた", 1222, 787, 43, 407, orientation: .vertical, sourceTileBounds: b)
        for input in [[first, padded], [padded, first]] {
            #expect(merge(input, width: 1819, height: 2551).map(\.text).joined() == first.text)
        }
        let separate = line(first.text, 1350, 786, 41, 323, orientation: .vertical, sourceTileBounds: b)
        #expect(merge([first, separate], width: 1819, height: 2551).map(\.text).joined().components(separatedBy: first.text).count == 3)
        let later = line(first.text, 1222, 1250, 41, 323, orientation: .vertical, sourceTileBounds: b)
        #expect(merge([first, later], width: 1819, height: 2551).map(\.text).joined().components(separatedBy: first.text).count == 3)
    }

    @Test func onlyClippedPunctuationYieldsToOverlappingTileRead() {
        let a = CGRect(x: 0, y: 0, width: 1536, height: 1536)
        let b = CGRect(x: 0, y: 1305, width: 1536, height: 1536)
        let input = [
            line("なんだけどさ・", 67, 1059, 98, 477, orientation: .vertical, sourceTileBounds: a),
            line("けどさ…", 70, 1305, 92, 284, orientation: .vertical, sourceTileBounds: b)
        ]
        for order in [input, Array(input.reversed())] {
            #expect(merge(order, width: 3496, height: 4961).map(\.text).joined() == "なんだけどさ…")
        }
        let separate = line("けどさ…", 300, 1305, 92, 284, orientation: .vertical, sourceTileBounds: b)
        let result = merge([input[0], separate], width: 3496, height: 4961).map(\.text).joined()
        #expect(result.contains("なんだけどさ・"))
        #expect(result.contains("けどさ…"))
    }

    @Test func tileClippedPrefixDoesNotSurviveWhenFullColumnTouchesSideEdge() {
        let a = CGRect(x: 1305, y: 0, width: 1536, height: 1536)
        let b = CGRect(x: 1305, y: 512, width: 1536, height: 1536)
        let fragment = line("確認", 2740, 1331, 101, 205, orientation: .vertical, sourceTileBounds: a)
        let full = line("確認しました", 2738, 1329, 103, 559, orientation: .vertical, sourceTileBounds: b)
        for input in [[fragment, full], [full, fragment]] {
            #expect(merge(input, width: 3208, height: 2048).map(\.text).joined() == full.text)
        }
        let other = line("確認", 2500, 1331, 101, 205, orientation: .vertical, sourceTileBounds: a)
        #expect(merge([other, full], width: 3208, height: 2048).map(\.text).joined().components(separatedBy: "確認").count == 3)
    }

    @Test func clippedLatinWordPrefixUsesTileEvidenceNotWordBoundary() {
        let a = CGRect(x: 0, y: 512, width: 1536, height: 1536)
        let b = CGRect(x: 512, y: 512, width: 1536, height: 1536)
        let part = line("BIRTHD", 918, 1707, 618, 197, orientation: .horizontal, sourceTileBounds: a)
        let full = line("BIRTHDAY", 910, 1684, 899, 234, orientation: .horizontal, sourceTileBounds: b)
        #expect(merge([part, full], width: 2048, height: 2048).map(\.text).joined() == full.text)
    }

    private func merge(
        _ lines: [NativeCoreMLOCRLine],
        width: Int,
        height: Int,
        recognizedLatinWords: Set<String> = []
    ) -> [PaddleOCRLine] {
        NativeOCRTextLineMerger.merge(
            lines,
            imageWidth: width,
            imageHeight: height,
            recognizedLatinWords: recognizedLatinWords
        )
    }

    private func line(
        _ text: String,
        _ x: CGFloat,
        _ y: CGFloat,
        _ width: CGFloat,
        _ height: CGFloat,
        score: Double = 0.9,
        orientation: BrowserOCRSourceOrientation = .unknown,
        orientationIsEstimated: Bool = false,
        sourceTileBounds: CGRect? = nil
    ) -> NativeCoreMLOCRLine {
        NativeCoreMLOCRLine(
            polygon: [
                CGPoint(x: x, y: y),
                CGPoint(x: x + width, y: y),
                CGPoint(x: x + width, y: y + height),
                CGPoint(x: x, y: y + height),
            ],
            text: text,
            score: score,
            orientation: orientation,
            orientationIsEstimated: orientationIsEstimated,
            sourceTileBounds: sourceTileBounds
        )
    }
}
