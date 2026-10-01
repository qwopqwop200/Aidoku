import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Replay only OCR/render preferences and recorded provider responses. No account
/// configuration or credential is imported into the simulator's shared defaults.
enum RecordedTranslationReplay {
    @MainActor static func settings(in directory: URL) throws -> ReaderTranslationSettings {
        let recorded = try preferences(in: directory)
        let name = "RecordedTranslationReplay." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.setPersistentDomain(recorded, forName: name)
        return ReaderTranslationSettings(defaults: defaults)
    }

    /// Reader defaults intentionally clamp mobile resolution. Historical replay
    /// identities instead require the exact explicit configuration used to capture them.
    static func ocrConfiguration(in directory: URL) throws -> ReaderOCRConfiguration {
        let recorded = try preferences(in: directory)
        let data = try #require(recorded["Reader.translation.ocr"] as? Data)
        return try JSONDecoder().decode(ReaderOCRConfiguration.self, from: data)
    }

    @MainActor static func recognizer(configuration: ReaderOCRConfiguration, loader: ReaderTranslationImageLoader)
        -> ReaderTranslationPreloader.Recognizer {
        { page, _ in
            // Exercise the real loader and OCR engine using the captured resolution;
            // only the provider response is replayed by the calling test.
            let image = try await loader.load(page, cacheInMemory: false)
            try #require(image.imageOrientation == .up, "Recorded PNG fixtures must retain their captured orientation")
            let pixels = try #require(image.cgImage)
            return try await ReaderOCRService.shared.recognize(image: pixels, configuration: configuration)
        }
    }

    private static func preferences(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("recorded-settings.plist"))
        let recorded = try #require(PropertyListSerialization.propertyList(from: data, options: .init(), format: nil) as? [String: Any])
        let allowed = Set(["ocr", "overlay", "sourceLanguage", "targetLanguage", "translationSourceLanguages",
                           "modelTier", "concurrency", "includePageImage"].map { "Reader.translation." + $0 })
        try #require(Set(recorded.keys).isSubset(of: allowed), "Replay preferences must not import an account")
        return recorded
    }

    /// A deterministic provider double for pipeline timing and cancellation tests.
    /// Each source scalar influences the reply; spacing/punctuation and content
    /// length remain representative, without treating old OCR wording as a contract.
    /// This Korean alphabet substitution is test data, not a semantic translation.
    nonisolated static func deterministicKoreanResponse(for source: String) -> String {
        let scalars = source.unicodeScalars.map { scalar -> UnicodeScalar in
            if scalar.properties.isWhitespace || CharacterSet.punctuationCharacters.contains(scalar) { return scalar }
            // Every value in this range is a valid modern Hangul syllable.
            return UnicodeScalar(0xAC00 + scalar.value % 11_172)!
        }
        return "시험 " + String(String.UnicodeScalarView(scalars))
    }

    nonisolated static func deterministicResponses(to recognized: [ReaderTranslationRegion]) -> [ReaderTranslationRegion] {
        recognized.map { current in
            var output = current
            output.translation = deterministicKoreanResponse(for: current.source)
            output.translationReuseIdentity = nil
            return output
        }
    }

    /// Diagnose encoding-only differences separately from genuine native output
    /// changes. The caller retains the original golden assertion and source PNG.
    nonisolated static func decodedPixelComparison(
        actual: CGImage, reference: CGImage, diagnoseFinalDisplacement: Bool = false
    ) throws -> [String: Any] {
        var report: [String: Any] = ["actualSize": [actual.width, actual.height],
                                     "referenceSize": [reference.width, reference.height]]
        guard actual.width == reference.width && actual.height == reference.height else {
            report["equalDimensions"] = false
            report["equalDecodedPixels"] = false
            return report
        }
        func rgba(_ image: CGImage) throws -> Data {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw ReplayError.pixelConversion }
            var data = Data(count: image.width * image.height * 4)
            try data.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                else { throw ReplayError.pixelConversion }
                context.setBlendMode(.copy)
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return data
        }
        let left = try rgba(actual), right = try rgba(reference)
        var changed = 0, oneLSB = 0, maximum = 0, pixelsOverLowDeltaLimit = 0
        var minX = actual.width, minY = actual.height, maxX = -1, maxY = -1
        for offset in stride(from: 0, to: left.count, by: 4) {
            var delta = 0
            for channel in 0..<4 { delta = max(delta, abs(Int(left[offset + channel]) - Int(right[offset + channel]))) }
            guard delta > 0 else { continue }
            changed += 1
            if delta == 1 { oneLSB += 1 }
            if delta > NativeFinalExportRasterAcceptance.unrestrictedChannelDeltaLimit { pixelsOverLowDeltaLimit += 1 }
            maximum = max(maximum, delta)
            let pixel = offset / 4, x = pixel % actual.width, y = pixel / actual.width
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
        report["equalDimensions"] = true
        report["equalDecodedPixels"] = changed == 0
        report["changedPixels"] = changed
        report["pixelsOverLowDeltaLimit"] = pixelsOverLowDeltaLimit
        report["oneLSBPixels"] = oneLSB
        report["largerDifferencePixels"] = changed - oneLSB
        report["maximumChannelDifference"] = maximum
        report["differenceBounds"] = changed == 0 ? [] : [minX, minY, maxX + 1, maxY + 1]
        report["pixelFormat"] = "sRGB premultiplied RGBA8"
        if diagnoseFinalDisplacement, maximum > NativeFinalExportRasterAcceptance.sparseChannelDeltaLimit,
           let evidence = NativeFinalExportRasterAcceptance.displacement(reference: right, actual: left,
               width: reference.width, height: reference.height, actualWidth: actual.width, actualHeight: actual.height) {
            report["commonDisplacement"] = evidence.report
        }
        return report
    }

    enum ReplayError: Error, CustomStringConvertible {
        case emptyRequest
        case pixelConversion
        case sourceIdentity(requestCount: Int, matchingPages: Int)

        var description: String {
            switch self {
            case .emptyRequest:
                return "Recorded provider replay received an empty current request"
            case .pixelConversion:
                return "Recorded pixel replay could not create a canonical sRGB pixel buffer"
            case let .sourceIdentity(requestCount, matchingPages):
                return "Recorded provider replay requires one page with a unique exact source/geometry match for each " +
                    "of \(requestCount) current regions; found \(matchingPages) matching pages"
            }
        }
    }

    /// Throughput and handoff replay the provider boundary, not a historical OCR
    /// implementation. Match every current request by exact source and geometry,
    /// preserving its current IDs, confidence, polygons and image evidence. Old
    /// records absent from the current request never become synthetic OCR output.
    nonisolated static func applyingBySourceGeometry(
        _ responses: [[ReaderTranslationRegion]], to recognized: [ReaderTranslationRegion]
    ) throws -> [ReaderTranslationRegion] {
        guard !recognized.isEmpty else { throw ReplayError.emptyRequest }
        let candidates = responses.compactMap { stored -> [ReaderTranslationRegion]? in
            var mapped: [ReaderTranslationRegion] = []
            var used: Set<Int> = []
            for current in recognized {
                let matches = stored.indices.filter {
                    stored[$0].source == current.source && stored[$0].rect == current.rect
                }
                guard matches.count == 1, let index = matches.first, used.insert(index).inserted else { return nil }
                mapped.append(stored[index])
            }
            return mapped
        }
        guard candidates.count == 1 else {
            throw ReplayError.sourceIdentity(requestCount: recognized.count, matchingPages: candidates.count)
        }
        return zip(recognized, candidates[0]).map { current, stored in
            var output = current
            output.translation = stored.translation
            output.translationReuseIdentity = stored.translationReuseIdentity
            return output
        }
    }

    nonisolated static func applying(_ responses: [[ReaderTranslationRegion]], to recognized: [ReaderTranslationRegion]) throws
        -> [ReaderTranslationRegion] {
        let matching = responses.first { stored in
            stored.count == recognized.count && zip(stored, recognized).allSatisfy {
                $0.id == $1.id && $0.source == $1.source && $0.rect == $1.rect
            }
        }
        let expected = try #require(matching, "Recorded responses must match independently captured OCR identity and geometry")
        return try zip(recognized, expected).map { current, stored in
            try #require(abs(current.confidence - stored.confidence) <= 0.001)
            var output = current
            output.translation = stored.translation
            output.translationReuseIdentity = stored.translationReuseIdentity
            return output
        }
    }
}
