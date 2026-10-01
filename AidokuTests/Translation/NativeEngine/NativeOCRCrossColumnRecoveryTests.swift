import CoreGraphics
import Testing
@testable import Aidoku

struct NativeOCRCrossColumnRecoveryTests {
    @Test func pageEdgeDoesNotBlockEstablishedVerticalColumns() throws {
        let width = 180, height = 240
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // Four outlined ink columns touch the page's left margin. Their heads
        // were read across the page, although the ink continues below them.
        for column in 0..<4 {
            for row in 0..<5 {
                for y in (12 + row * 36)..<(32 + row * 36) {
                    for x in (5 + column * 40)..<(17 + column * 40) {
                        let offset = (y * width + x) * 4
                        bytes[offset] = 24; bytes[offset + 1] = 24; bytes[offset + 2] = 24
                    }
                }
            }
        }
        let frame = try #require(NativeOCRRGBAFrame(width: width, height: height, bytes: bytes))
        let seed = CGRect(x: 0, y: 10, width: 160, height: 40)
        let regions = (0..<4).map { index in
            NativeCoreMLRecognitionRegion(sourceIndex: index + 10, polygon: [
                CGPoint(x: index * 40, y: 10), CGPoint(x: index * 40 + 40, y: 10),
                CGPoint(x: index * 40 + 40, y: 50), CGPoint(x: index * 40, y: 50)
            ])
        }
        let proposal = NativeOCRGridColumnRecovery.Proposal(replaced: [0], regions: regions,
            evidence: ["あ", "い", "う", "え"], suffixes: ["", "", "", ""],
            suffixScores: [0, 0, 0, 0], singleRow: true)
        for includeLeft in [false, true] {
            let refined = try #require(NativeOCRGridColumnRecovery.pixelRefined(proposal, reads: [],
                frame: frame, addedID: 20, verticalSeed: seed, includeLeft: includeLeft))
            #expect(refined.regions.map(\.sourceIndex) == [10, 11, 12, 13])
            #expect(refined.pixelAdded.isEmpty)
            for region in refined.regions {
                let box = try #require(NativeOCRScopeGeometry.bounds(for: region.polygon))
                #expect(box.minX >= 0 && box.maxX <= CGFloat(width))
                #expect(box.maxY > 175 && box.maxY <= CGFloat(height))
            }
        }
    }

    private func read(_ id: Int, _ text: String, _ box: CGRect, score: Double = 0.95) -> NativeCoreMLRecognizedRegion {
        .init(sourceIndex: id, polygon: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)], text: text, confidence: score)
    }

    @Test func crosswiseHeadsRequireEveryCompleteColumnToConfirmItsText() throws {
        let rows = [read(0, "お待", CGRect(x: 203, y: 2224, width: 197, height: 84)),
                    read(1, "はよう", CGRect(x: 234, y: 2276, width: 95, height: 466)),
                    read(2, "っている", CGRect(x: 317, y: 2279, width: 85, height: 399))]
        let proposal = try #require(NativeOCRCrossColumnRecovery.proposals(rows).first)
        #expect(proposal.regions.count == 2)
        let complete = zip(proposal.regions, ["おはよう", "待っている"]).map {
            NativeCoreMLRecognizedRegion(sourceIndex: $0.sourceIndex, polygon: $0.polygon, text: $1, confidence: 0.98)
        }
        #expect(NativeOCRCrossColumnRecovery.replacements(proposal, reads: complete)?.map(\.text) == ["おはよう", "待っている"])
        let smallKana = [rows[0], read(1, "きやく", CGRect(x: 234, y: 2276, width: 95, height: 466)), rows[2]]
        let smallProposal = try #require(NativeOCRCrossColumnRecovery.proposals(smallKana).first)
        let confirmed = [read(1, "おきゃく", CGRect(x: 234, y: 2224, width: 95, height: 518)), complete[1]]
        #expect(NativeOCRCrossColumnRecovery.replacements(smallProposal, reads: confirmed)?.first?.text == "おきゃく")
        #expect(NativeOCRCrossColumnRecovery.replacements(proposal, reads: Array(complete.prefix(1))) == nil)
        let wrong = [complete[0], read(2, "別の文章", CGRect(x: 317, y: 2224, width: 85, height: 454))]
        #expect(NativeOCRCrossColumnRecovery.replacements(proposal, reads: wrong) == nil)
        let low = [complete[0], read(2, "待っている", CGRect(x: 317, y: 2224, width: 85, height: 454), score: 0.7)]
        #expect(NativeOCRCrossColumnRecovery.replacements(proposal, reads: low) == nil)
        #expect(NativeOCRCrossColumnRecovery.proposals(Array(rows.prefix(2))).isEmpty)
        let detached = [rows[0], rows[1], read(2, "っている", CGRect(x: 450, y: 2279, width: 85, height: 399))]
        #expect(NativeOCRCrossColumnRecovery.proposals(detached).isEmpty)
    }
    @Test func repeatedCrosswiseGridRequiresConfirmedColumnsAndVerticalPageEvidence() throws {
        let rows = [read(0, "上下左右", CGRect(x: 100, y: 100, width: 280, height: 90)),
                    read(1, "中央方向", CGRect(x: 100, y: 160, width: 280, height: 90)),
                    read(2, "線文数字", CGRect(x: 100, y: 220, width: 280, height: 90))]
        let anchor = read(3, "ありがとう", CGRect(x: 800, y: 100, width: 80, height: 400))
        let proposal = try #require(NativeOCRGridColumnRecovery.proposals(rows + [anchor], width: 1200, height: 1200).first)
        #expect(proposal.replaced == Set([0, 1, 2]))
        #expect(proposal.evidence == ["上中線", "下央文", "左方数", "右向字"])
        // Rejected detector boxes still own their IDs even though absent from accepted reads.
        let reserved = try #require(NativeOCRGridColumnRecovery.proposals(rows + [anchor],
            width: 1200, height: 1200, startingID: 20).first)
        #expect(reserved.regions.map(\.sourceIndex) == [20, 21, 22, 23])
        let lowStart = try #require(NativeOCRGridColumnRecovery.proposals(rows + [anchor],
            width: 1200, height: 1200, startingID: 2).first)
        #expect(lowStart.regions.map(\.sourceIndex) == [4, 5, 6, 7])
        let complete = zip(proposal.regions, proposal.evidence).map {
            NativeCoreMLRecognizedRegion(sourceIndex: $0.sourceIndex, polygon: $0.polygon, text: $1, confidence: 0.95)
        }
        #expect(NativeOCRGridColumnRecovery.replacements(proposal, reads: complete)?.count == 4)
        #expect(NativeOCRGridColumnRecovery.replacements(proposal, reads: Array(complete.dropLast())) == nil)
        let mismatch = complete.dropLast() + [read(complete.last!.sourceIndex, "異なる文", CGRect(x: 310, y: 100, width: 70, height: 210))]
        #expect(NativeOCRGridColumnRecovery.replacements(proposal, reads: Array(mismatch)) == nil)
        #expect(NativeOCRGridColumnRecovery.proposals(rows, width: 1200, height: 1200).isEmpty)
        #expect(NativeOCRGridColumnRecovery.proposals(Array(rows.prefix(2)) + [anchor], width: 1200, height: 1200).isEmpty)
        let spaced = rows.enumerated().map { index, value in
            read(value.sourceIndex, value.text, CGRect(x: 100, y: 100 + index * 120, width: 280, height: 90))
        }
        #expect(NativeOCRGridColumnRecovery.proposals(spaced + [anchor], width: 1200, height: 1200).isEmpty)
    }

    @Test func gridRereadPreservesJapaneseSuffixWhenWeakLatinReadIsReplaced() {
        let region = NativeCoreMLRecognitionRegion(sourceIndex: 20,
            polygon: [CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 0), CGPoint(x: 80, y: 400), CGPoint(x: 0, y: 400)])
        let proposal = NativeOCRGridColumnRecovery.Proposal(replaced: [1, 2, 3], regions: [region],
            evidence: ["すか"], suffixes: ["UWよ……"], suffixScores: [0.7])
        let corrected = NativeCoreMLRecognizedRegion(sourceIndex: 20, polygon: region.polygon, text: "ずかよ……", confidence: 0.9)
        #expect(NativeOCRGridColumnRecovery.replacements(proposal, reads: [corrected])?.first?.text == "ずかよ……")
        let wrongEnding = NativeCoreMLRecognizedRegion(sourceIndex: 20, polygon: region.polygon, text: "ずかね", confidence: 0.99)
        #expect(NativeOCRGridColumnRecovery.replacements(proposal, reads: [wrongEnding]) == nil)
        let strongSuffix = NativeOCRGridColumnRecovery.Proposal(replaced: [1, 2, 3], regions: [region],
            evidence: ["すか"], suffixes: ["UWよ……"], suffixScores: [0.95])
        #expect(NativeOCRGridColumnRecovery.replacements(strongSuffix, reads: [corrected]) == nil)
    }

    @Test func shortenedThirdRowKeepsItsColumnOffset() throws {
        // Geometry from the device-cache failure, with neutral test characters.
        let rows = [read(0, "上下左右中央", CGRect(x: 513, y: 1610, width: 388, height: 86)),
                    read(1, "方向文字番号", CGRect(x: 508, y: 1670, width: 403, height: 102)),
                    read(2, "東西南北端", CGRect(x: 569, y: 1787, width: 343, height: 108))]
        let anchor = read(3, "ありがとう", CGRect(x: 1800, y: 100, width: 80, height: 400))
        let proposal = try #require(NativeOCRGridColumnRecovery.proposals(rows + [anchor], width: 3497, height: 2235).first)
        #expect(proposal.evidence == ["上方", "下向東", "左文西", "右字南", "中番北", "央号端"])
        #expect(proposal.replaced == [0, 1, 2])
        let complete = zip(proposal.regions, proposal.evidence).map {
            NativeCoreMLRecognizedRegion(sourceIndex: $0.sourceIndex, polygon: $0.polygon, text: $1, confidence: 0.95)
        }
        #expect(NativeOCRGridColumnRecovery.replacements(proposal, reads: complete)?.count == 6)
        // A shifted row must not silently be assigned to column zero.
        let wrong = complete.dropLast() + [read(complete.last!.sourceIndex, "別の文", CGRect(x: 830, y: 1610, width: 80, height: 300))]
        #expect(NativeOCRGridColumnRecovery.replacements(proposal, reads: Array(wrong)) == nil)
        #expect(NativeOCRGridColumnRecovery.replacements(proposal, reads: Array(complete.dropLast())) == nil)
        let offGrid = Array(rows.prefix(2)) + [read(2, "東西南北端", CGRect(x: 545, y: 1787, width: 343, height: 108)), anchor]
        #expect(NativeOCRGridColumnRecovery.proposals(offGrid, width: 3497, height: 2235).isEmpty)
        let detached = Array(rows.prefix(2)) + [read(2, "東西南北端", CGRect(x: 569, y: 1900, width: 343, height: 108)), anchor]
        #expect(NativeOCRGridColumnRecovery.proposals(detached, width: 3497, height: 2235).isEmpty)
        #expect(NativeOCRGridColumnRecovery.proposals(rows, width: 3497, height: 2235).isEmpty)
    }

    @Test func inlineNumeralsOccupyOneCorroboratedVerticalCell() throws {
        let rows = [read(0, "あな10", CGRect(x: 132, y: 958, width: 200, height: 78)),
                    read(1, "うっ万", CGRect(x: 134, y: 1024, width: 199, height: 74), score: 0.68),
                    read(2, "たた円", CGRect(x: 128, y: 1079, width: 205, height: 84)),
                    read(3, "ら羽目に", CGRect(x: 244, y: 1195, width: 92, height: 264), score: 0.96),
                    read(4, "ありがとう", CGRect(x: 800, y: 100, width: 80, height: 400))]
        let p = try #require(NativeOCRGridColumnRecovery.proposals(rows, width: 3497, height: 2235).first)
        #expect(p.regions.count == 3)
        #expect(p.evidence == ["あうた", "なった", "10万円"])
        let withShortTail = try #require(NativeOCRGridColumnRecovery.proposals(rows + [
            read(5, "とが", CGRect(x: 194, y: 1196, width: 72, height: 143))
        ], width: 3497, height: 2235).first)
        #expect(withShortTail.suffixes[1] == "とが")
        let middle = try #require(NativeOCRScopeGeometry.bounds(for: withShortTail.regions[1].polygon))
        let right = try #require(NativeOCRScopeGeometry.bounds(for: withShortTail.regions[2].polygon))
        #expect(middle.maxY < right.maxY - 100)

        let complete = zip(p.regions, ["あったもんでなぁ", "なったことが", "10万円払う羽目に"]).map {
            NativeCoreMLRecognizedRegion(sourceIndex: $0.sourceIndex, polygon: $0.polygon, text: $1, confidence: 0.98)
        }
        #expect(NativeOCRGridColumnRecovery.replacements(p, reads: complete)?.count == 3)
        var wrong = complete
        wrong[2] = read(p.regions[2].sourceIndex, "10万円払う別の場所", CGRect(x: 244, y: 958, width: 92, height: 501))
        #expect(NativeOCRGridColumnRecovery.replacements(p, reads: wrong) == nil)
        wrong[2] = read(p.regions[2].sourceIndex, "10万円払う羽目に", CGRect(x: 244, y: 958, width: 92, height: 501), score: 0.94)
        #expect(NativeOCRGridColumnRecovery.replacements(p, reads: wrong) == nil)
    }

}
