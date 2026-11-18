import Foundation
import CoreGraphics

extension NativeParagraphFragmentGrouping {
    /// The same operating choice is used by the iOS reader and saved macOS route.
    /// Rollback is explicit; missing source receipts never trigger model work.
    static var simpleGroupingEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_PARAGRAPH_GROUPING"] != "incumbent"
    }
    enum SimpleOutcome: String, Sendable {
        case empty, noMatch, coalesced, sourceUnavailable, invalidGeometry
    }
    struct SimpleResult: Sendable {
        let regions: [ReaderTranslationRegion]
        let outcome: SimpleOutcome
        let inputAtoms: Int
        let outputOwners: Int
    }
    /// Optional stage instrumentation; the actual grouping result is reused,
    /// never recomputed. Nil adds no observer-specific row copies or work.
    @TaskLocal static var simpleNativeObserver: (@Sendable ([ReaderTranslationRegion], SimpleResult) -> Void)?
    enum SimpleIngressError: Error {
        case invalidDimensions
        case invalidNativeGeometry(Int)
    }

    /// Literal accepted native reads, not a second merge/recovery/admission pass.
    /// Shared by the live Reader and observed-core host replay. Invalid ingress
    /// throws rather than silently thinning a page or pretending an empty result.
    @available(iOS 18.0, *)
    static func simpleNativeResult(_ lines: [NativeCoreMLOCRLine], width: Int, height: Int,
                                   scopes: [TextScope], balloons: [TextScope] = []) throws -> SimpleResult {
        guard width > 0, height > 0 else { throw SimpleIngressError.invalidDimensions }
        guard lines.allSatisfy({ line in
            guard let membership = line.acceptedSource.membership else { return true }
            return membership.table.width == width && membership.table.height == height
        }) else { throw SimpleIngressError.invalidDimensions }
        let w = CGFloat(width), h = CGFloat(height)
        var relationPolygons: [Int: [CGPoint]] = [:]
        let rows = try lines.enumerated().map { index, line -> ReaderTranslationRegion in
            guard line.polygon.count >= 3, line.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), line.score.isFinite else {
                throw SimpleIngressError.invalidNativeGeometry(index)
            }
            let polygon = line.polygon.map { CGPoint(x: $0.x/w, y: $0.y/h) }
            if let measured = line.preCalibrationPolygon {
                relationPolygons[index] = measured.map { CGPoint(x: $0.x/w, y: $0.y/h) }
            }
            let xs = polygon.map(\.x), ys = polygon.map(\.y)
            let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()!-xs.min()!, height: ys.max()!-ys.min()!)
            guard rect.width > 0, rect.height > 0 else { throw SimpleIngressError.invalidNativeGeometry(index) }
            var row = ReaderTranslationRegion(id: "native-line-\(index)", rect: rect, source: line.text,
                polygon: polygon, confidence: line.score, sourceImageAspectRatio: Double(width)/Double(height),
                sourceOrientation: line.orientation, detectorSeedEvidence: line.detectorSeedEvidence)
            row.acceptedSource = line.acceptedSource
            row.auxiliaryInkPolygons = line.erasurePolygons.map { $0.map { CGPoint(x: $0.x/w, y: $0.y/h) } }
            return row
        }
        let result = simpleResult(rows, scopes: scopes, balloons: balloons, relationPolygons: relationPolygons)
        simpleNativeObserver?(rows, result)
        return result
    }

    static func simpleResult(_ original: [ReaderTranslationRegion], scopes: [TextScope], balloons: [TextScope] = [],
                             relationPolygons: [Int: [CGPoint]] = [:],
                             didCoalesce: (([String]) -> Void)? = nil) -> SimpleResult {
        func unchanged(_ outcome: SimpleOutcome) -> SimpleResult {
            .init(regions: original, outcome: outcome, inputAtoms: original.count, outputOwners: original.count)
        }
        guard !original.isEmpty else { return unchanged(.empty) }
        guard original.allSatisfy({ $0.translation == nil }),
              Set(original.map(\.id)).count == original.count else { return unchanged(.invalidGeometry) }
        let memberships = original.compactMap { $0.acceptedSource.membership }
        guard memberships.count == original.count, let first = memberships.first,
              first.table.width > 0, first.table.height > 0,
              memberships.allSatisfy({ $0.table.width == first.table.width && $0.table.height == first.table.height &&
                  $0.body.union($0.readings).union($0.unknownDedup).allSatisfy($0.table.packets.indices.contains) })
        else { return unchanged(.sourceUnavailable) }
        let width = CGFloat(first.table.width), height = CGFloat(first.table.height)
        var operations: [ObjectIdentifier: Int] = [:]
        let inputs = original.enumerated().map { index, region -> NativeSimpleParagraphGrouping.Input in
            let key = ObjectIdentifier(memberships[index].table)
            if operations[key] == nil { operations[key] = operations.count }
            let adjacency = relationPolygons[index] ?? region.polygon
            return .init(polygon: adjacency.map { .init(x: $0.x*width, y: $0.y*height) },
                orientation: region.sourceOrientation,
                operation: 2 * operations[key]! + (memberships[index].isLegacyComplement ? 1 : 0),
                confidence: region.confidence, source: region.source)
        }
        func scaled(_ values: [TextScope]) -> [NativeSimpleParagraphGrouping.Scope] {
            values.map { .init(owner: $0.owner,
                box: CGRect(x: $0.box.minX*width, y: $0.box.minY*height, width: $0.box.width*width, height: $0.box.height*height),
                confidence: $0.confidence) }
        }
        guard let groups = NativeSimpleParagraphGrouping.group(inputs, textScopes: scaled(scopes), balloons: scaled(balloons))
        else { return unchanged(.invalidGeometry) }
        let result = groups.map { group -> ReaderTranslationRegion in
            let primary = original[group.representative]
            if group.members.count == 1 {
                var singleton = primary
                singleton.sourceOrientation = group.orientation
                singleton.sourceSingleVerticalColumn = group.singleVerticalColumn
                return singleton
            }
            // A singleton keeps its exact normalized IEEE754 polygon.
            let polygon = group.polygon.map { CGPoint(x: $0.x/width, y: $0.y/height) }
            let xs = polygon.map(\.x), ys = polygon.map(\.y)
            let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()!-xs.min()!, height: ys.max()!-ys.min()!)
            var output = ReaderTranslationRegion(id: "simple-"+primary.id, rect: rect,
                source: group.readingOrder.map { original[$0].source }.joined(separator: "\n"),
                polygon: polygon, confidence: group.members.map { original[$0].confidence }.min()!,
                sourceImageAspectRatio: primary.sourceImageAspectRatio,
                translationOrder: primary.translationOrder, translationOrderVersion: primary.translationOrderVersion,
                sourceOrientation: group.orientation, sourceSingleVerticalColumn: group.singleVerticalColumn)
            output.keepsClassifiedSFXSource = primary.keepsClassifiedSFXSource
            output.rendersUnchangedSymbols = primary.rendersUnchangedSymbols
            output.translationRecoveryFailure = primary.translationRecoveryFailure
            output.auxiliaryInkRects = group.members.flatMap { original[$0].auxiliaryInkRects }
            output.auxiliaryInkPolygons = group.members.flatMap { original[$0].auxiliaryInkPolygons }
            output.cachedSourceMemberPolygons = group.members.flatMap { original[$0].cachedSourceMemberPolygons }
            output.isOccludedFinePrint = primary.isOccludedFinePrint
            output.isRecoveredLine = primary.isRecoveredLine
            if group.members.count > 1 {
                output.unitMemberRects = group.readingOrder.flatMap { original[$0].unitMemberRects.isEmpty ? [original[$0].rect] : original[$0].unitMemberRects }
                output.detectorSeedEvidence = nil
                output.balloonInterior = nil
                didCoalesce?(group.members.map { original[$0].id })
            }
            // Union retains the exact original packet table and nonvoting aliases.
            // Aggregate layout/detector ownership is intentionally not inherited.
            output.acceptedSource = NativeOCRSourceMetadata.union(group.members.map { original[$0].acceptedSource })
            output.sourceOCRAlternatives = group.members.flatMap { original[$0].sourceOCRAlternatives }
            return output
        }
        return .init(regions: result, outcome: result.count < original.count ? .coalesced : .noMatch,
            inputAtoms: original.count, outputOwners: result.count)
    }
}
