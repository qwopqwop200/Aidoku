import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct ReaderTranslationSourceRasterArchiveTests {
    @Test func diskLookupChecksClaimBeforeReusingEvenEmptyResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let settings = ReaderTranslationSettings()
        let sourceA = try #require(ReaderTranslationSourceRasterClaim(processedFullSourceSHA256: String(repeating: "a", count: 64)))
        let sourceB = try #require(ReaderTranslationSourceRasterClaim(processedFullSourceSHA256: String(repeating: "b", count: 64)))
        let page = "same-url-and-dimensions"
        let key = ReaderTranslationCacheIdentity.translation(page: page, settings: settings)
        try await disk.storeRegions([], for: key, kind: .translation, generation: await disk.currentGeneration(settings: settings))
        #expect(try await disk.translatedRegionRecord(page: page, settings: settings, matching: sourceA) == nil)
        #expect(try await disk.translatedRegions(page: page, settings: settings)?.isEmpty == true)

        try await disk.storeRegions([], for: key, kind: .translation, generation: await disk.currentGeneration(settings: settings),
                                    sourceRasterClaim: sourceA)
        let reopened = ReaderTranslationDiskCache(directory: directory)
        #expect(try await reopened.translatedRegionRecord(page: page, settings: settings, matching: sourceB) == nil)
        let match = try #require(try await reopened.translatedRegionRecord(page: page, settings: settings, matching: sourceA))
        #expect(match.regions.isEmpty && match.sourceRasterClaim == sourceA)
    }

    @Test func claimedArchiveSharesLegacyBaseAndPreservesTranslationState() throws {
        var region = ReaderTranslationRegion(id: "one", rect: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: "source", translation: "translated")
        region.keepsClassifiedSFXSource = true
        region.translationRecoveryFailure = "fixture"
        let claim = try #require(ReaderTranslationSourceRasterClaim(processedFullSourceSHA256: String(repeating: "a", count: 64)))
        let claimed = try ReaderTranslationRegionArchive([region], sourceRasterClaim: claim)
        let unclaimed = try ReaderTranslationRegionArchive([region])
        #expect(claimed.base == unclaimed.base)
        let record = try ReaderTranslationRegionArchive.record(base: claimed.base, variant: claimed.variant)
        #expect(record.regions == [region])
        #expect(record.sourceRasterClaim == claim)
        #expect(try ReaderTranslationRegionArchive.regions(base: claimed.base, variant: claimed.variant) == [region])
        let restoredLegacyData = try ReaderTranslationRegionArchive.restore(base: claimed.base, variant: claimed.variant)
        let restored = try ReaderTranslationRegionArchive.record(legacy: restoredLegacyData)
        #expect(restored.regions == [region] && restored.sourceRasterClaim == nil)
    }

    @Test func legacySharedAndRawRecordsStayUnclaimedWhileBoundEmptyRetainsProof() throws {
        let empty = Data("[]".utf8)
        let oldVariant = Data(#"{"k":[],"r":[],"s":[],"t":[],"v":1}"#.utf8)
        let oldRaw = try ReaderTranslationRegionArchive.record(legacy: empty)
        let oldShared = try ReaderTranslationRegionArchive.record(base: empty, variant: oldVariant)
        #expect(oldRaw.regions.isEmpty && oldRaw.sourceRasterClaim == nil)
        #expect(oldShared.regions.isEmpty && oldShared.sourceRasterClaim == nil)
        #expect(try ReaderTranslationRegionArchive([]).variant == oldVariant)
        let claim = try #require(ReaderTranslationSourceRasterClaim(processedFullSourceSHA256: String(repeating: "b", count: 64)))
        let bound = try ReaderTranslationRegionArchive([], sourceRasterClaim: claim)
        #expect(bound.base == empty)
        let record = try ReaderTranslationRegionArchive.record(base: bound.base, variant: bound.variant)
        #expect(record.regions.isEmpty && record.sourceRasterClaim == claim)
    }

    @Test func malformedClaimRejectsTheWholeRecord() throws {
        for proof in [["v": "wrong", "s": String(repeating: "a", count: 64)],
                      ["v": "processed-source-visible-rows-v2-upright-ocr-v1", "s": "not-a-sha"]] {
            let variant: [String: Any] = ["k": [String](), "r": [String](), "s": [String](), "t": [String](), "v": 1, "p": proof]
            let bytes = try JSONSerialization.data(withJSONObject: variant)
            #expect(throws: DecodingError.self) {
                try ReaderTranslationRegionArchive.record(base: Data("[]".utf8), variant: bytes)
            }
        }
    }
}
