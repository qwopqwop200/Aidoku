import CoreGraphics
import CryptoKit
import Foundation

/// Fresh native observations shared by the app and host appearance constructor.
/// This is the selected frozen source producer, before context83/style78 final refinement.
enum NativeSourceSegmentationObservations {
    enum Failure: Error { case artifactMismatch, missingAcceptedAssets }
    struct Models: Sendable {
        let primary: NativePixelRFForest
        let boundary: NativePixelRFForest
        /// Only cleanup-safe operational assets are searched on either platform.
        init(assetDirectory: URL? = nil, bundle: Bundle = .main) throws {
            let directory: URL
            if let assetDirectory { directory = assetDirectory }
            else { directory = try Self.acceptedAssetDirectory(bundle: bundle) }
            let jsonURL = directory.appendingPathComponent("primary-forest.json")
            let boundaryURL = directory.appendingPathComponent("boundary-forest.json")
            if assetDirectory == nil,
               let resource = NativePixelRFForest.primaryResource(in: directory),
               resource.pathExtension == "pr62" {
                let boundaryData = try Data(contentsOf: boundaryURL)
                guard Self.isExpectedBoundary(boundaryData),
                      let model = try NativePixelRFForest.readPackedPrimary(at: resource) else { throw Failure.artifactMismatch }
                self.init(primary: model, boundary: try NativePixelRFForest(data: boundaryData))
            } else {
                try self.init(primaryData: Data(contentsOf: jsonURL), boundaryData: Data(contentsOf: boundaryURL),
                    optionalPackedURL: assetDirectory == nil ? jsonURL.deletingPathExtension().appendingPathExtension("pr62") : nil)
            }
        }
        static func acceptedAssetDirectory(bundle: Bundle = .main) throws -> URL {
            var candidates: [URL] = []
            if let resources = bundle.resourceURL {
                candidates += [resources.appendingPathComponent("Translation/SegmentationAcceptedFinal"),
                    resources.appendingPathComponent("SegmentationAcceptedFinal"),
                    resources.appendingPathComponent("Resources/Translation/SegmentationAcceptedFinal"), resources]
            }
            #if os(macOS)
            // Host launchers compile relocated source copies. Their #filePath
            // cannot identify the checkout, so use the configured operational
            // root before the source-location fallback. Model SHA checks below
            // remain the authority for either location.
            if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"], !root.isEmpty {
                candidates.append(URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent("Aidoku/Resources/Translation/SegmentationAcceptedFinal"))
            }
            var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            for _ in 0..<5 { repository.deleteLastPathComponent() }
            candidates.append(repository.appendingPathComponent("Aidoku/Resources/Translation/SegmentationAcceptedFinal"))
            #endif
            guard let directory = candidates.first(where: {
                NativePixelRFForest.primaryResource(in: $0) != nil &&
                    FileManager.default.fileExists(atPath: $0.appendingPathComponent("boundary-forest.json").path)
            }) else { throw Failure.missingAcceptedAssets }
            return directory
        }
        private static func isExpectedBoundary(_ data: Data) -> Bool {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() ==
                "3df521613d2981c412c3c9a38878128d1450bb1016e7baaaddad5f3a0d3a36ea"
        }

        private init(primary: NativePixelRFForest, boundary: NativePixelRFForest) {
            self.primary = primary
            self.boundary = boundary
        }

        init(primaryData: Data, boundaryData: Data) throws {
            try self.init(primaryData: primaryData, boundaryData: boundaryData, optionalPackedURL: nil)
        }

        private init(primaryData: Data, boundaryData: Data, optionalPackedURL: URL?) throws {
            let sourceHash = SHA256.hash(data: primaryData).map { String(format: "%02x", $0) }.joined()
            guard sourceHash == NativePixelRFForest.primarySourceFileSHA256, Self.isExpectedBoundary(boundaryData) else {
                throw Failure.artifactMismatch
            }
            if let optionalPackedURL, let packed = try? NativePixelRFForest.readPackedPrimary(at: optionalPackedURL) {
                primary = packed
            } else {
                primary = try NativePixelRFForest(data: primaryData)
            }
            boundary = try NativePixelRFForest(data: boundaryData)
        }
    }
    struct Output {
        let primary: [Float]
        let boundary: [Float]
        let rawNative: [UInt8]
        let completed: NativePixelRFSegmentation.Result
    }
    static func sourceCrop(rgb: [UInt8], width: Int, height: Int, polygons: [[CGPoint]], fontPixels: Double,
                           coarseRF: [Float], fullRF: [Float], rfModelWeightsSHA256: String, models: Models) throws -> Output {
        guard rfModelWeightsSHA256 == "03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255",
              models.primary.sourceModelSHA256 == models.boundary.primarySourceModelSHA256 else {
            throw Failure.artifactMismatch
        }
        var primary: [Float] = [], raw: [UInt8] = [], boundary: [Float] = []
        _ = try NativePixelRFSegmentation.segmentCrop(rgb: rgb, width: width, height: height, polygons: polygons,
            fontPixels: fontPixels, coarseRF: coarseRF, fullRF: fullRF, model: models.primary,
            captureClassifier: { primary = $0; raw = $1 })
        let completed = try NativePixelRFBoundarySegmentation.refine(rgb: rgb, primary: primary,
            nativeMask: raw, coarseRF: coarseRF, fullRF: fullRF, width: width, height: height,
            fontPixels: fontPixels, model: models.boundary, captureBoundary: { boundary = $0 })
        return Output(primary: primary, boundary: boundary, rawNative: raw, completed: completed)
    }
}
