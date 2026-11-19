import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct ReaderTranslationSourceRasterArchiveTests {

    @Test func archivePreservesTranslationStateAndRestoresLegacyData() throws {
        var region = ReaderTranslationRegion(id: "one", rect: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: "source", translation: "translated")
        region.keepsClassifiedSFXSource = true
        region.translationRecoveryFailure = "fixture"
        let archive = try ReaderTranslationRegionArchive([region])
        #expect(try ReaderTranslationRegionArchive.record(base: archive.base, variant: archive.variant).regions == [region])
        let restoredLegacyData = try ReaderTranslationRegionArchive.restore(base: archive.base, variant: archive.variant)
        #expect(try ReaderTranslationRegionArchive.record(legacy: restoredLegacyData).regions == [region])
    }

    @Test func legacySharedAndRawEmptyRecordsStayReadable() throws {
        let empty = Data("[]".utf8)
        let oldVariant = Data(#"{"k":[],"r":[],"s":[],"t":[],"v":1}"#.utf8)
        #expect(try ReaderTranslationRegionArchive.record(legacy: empty).regions.isEmpty)
        #expect(try ReaderTranslationRegionArchive.record(base: empty, variant: oldVariant).regions.isEmpty)
        #expect(try ReaderTranslationRegionArchive([]).variant == oldVariant)
    }
}
