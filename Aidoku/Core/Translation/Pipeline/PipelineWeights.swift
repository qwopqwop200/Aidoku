import Foundation

/// Fitted tables in Resources/Translation/PipelineWeights.bin (TRAIN split only): style forests, then the
/// optional old density-peak ranker (unused) and line-end regressor. Each table is a UInt32 element count followed
/// by little-endian elements, in the order read below; the first two (a retired S6 MLP) are skipped.
private enum PipelineWeightFile {
    struct Tables {
        let fillPass1: PipelineStyleForest, fillPass2: PipelineStyleForest, outline: PipelineStyleForest
        let lineEnds: PipelineStyleForest?
    }

    static let tables: Tables = {
        var urls = [Bundle.main.url(forResource: "PipelineWeights", withExtension: "bin")].compactMap { $0 }
        if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] {
            urls.append(URL(fileURLWithPath: root).appendingPathComponent("Aidoku/Resources/Translation/PipelineWeights.bin"))
        }
        guard let data = urls.lazy.compactMap({ try? Data(contentsOf: $0) }).first else {
            fatalError("PipelineWeights.bin is missing from the bundle")
        }
        var offset = 0
        func read<T>(_: T.Type) -> [T] {
            let count = Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }))
            let start = offset + 4, size = MemoryLayout<T>.stride
            offset = start + count * size
            precondition(offset <= data.count, "PipelineWeights.bin is truncated")
            return data.withUnsafeBytes { raw in
                (0..<count).map { raw.loadUnaligned(fromByteOffset: start + $0 * size, as: T.self) }
            }
        }
        func forest() -> PipelineStyleForest {
            let scalars = read(Double.self)
            return PipelineStyleForest(base: scalars[0], rate: scalars[1], roots: read(Int32.self), feature: read(Int16.self),
                                 threshold: read(Double.self), left: read(Int32.self), right: read(Int32.self),
                                 value: read(Double.self))
        }
        _ = read(Float.self); _ = read(Float.self)
        let fillPass1 = forest(), fillPass2 = forest(), outline = forest()
        // The old fill density-peak forest: read past and left unused (PipelineFillPeakRanker replaces it).
        if offset < data.count { _ = forest() }
        let tables = Tables(fillPass1: fillPass1, fillPass2: fillPass2, outline: outline,
                            lineEnds: offset < data.count ? forest() : nil)
        precondition(offset == data.count, "PipelineWeights.bin has trailing data")
        return tables
    }()
}

/// S8 outline constants beside the width model in Resources/Translation/PipelineOutlineWidth.json (fit on TRAIN pages,
/// `Scripts/pipeline/tools/retrain/outline`): `presencePage` (the page-consensus logistic of the outline score) and
/// `ringLine` (the ring-line width). Read from the bundle, then $AIDOKU_PIPELINE_ROOT.
private enum PipelineOutlineConstants {
    struct File: Decodable {
        let presencePage: [Double]
        let ringLine: [Double]
    }

    static let file: File = {
        var urls = [Bundle.main.url(forResource: "PipelineOutlineWidth", withExtension: "json")].compactMap { $0 }
        if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] {
            urls.append(URL(fileURLWithPath: root).appendingPathComponent("Aidoku/Resources/Translation/PipelineOutlineWidth.json"))
        }
        guard let file = urls.lazy.compactMap({ try? Data(contentsOf: $0) })
            .compactMap({ try? JSONDecoder().decode(File.self, from: $0) }).first,
            file.presencePage.count == 3, file.ringLine.count == 3
        else { fatalError("PipelineOutlineWidth.json (presencePage, ringLine) is missing from the bundle") }
        return file
    }()
}

enum PipelineRemovalMaskWeights {
    static var lineEnds: PipelineStyleForest? { PipelineWeightFile.tables.lineEnds }
}

enum PipelineStyleParameters {
    static var fillPass1: PipelineStyleForest { PipelineWeightFile.tables.fillPass1 }
    static var fillPass2: PipelineStyleForest { PipelineWeightFile.tables.fillPass2 }
    static var outline: PipelineStyleForest { PipelineWeightFile.tables.outline }
    /// Page consensus of the outline score (score, page median score, bias), from PipelineOutlineWidth.json.
    static let outlinePage: [Double] = PipelineOutlineConstants.file.presencePage
    /// Ring-line outline width (ring, font, bias): an input of `PipelineOutlineWidthModel` and its fallback.
    static let outlineWidthRing: Double = PipelineOutlineConstants.file.ringLine[0]
    static let outlineWidthFont: Double = PipelineOutlineConstants.file.ringLine[1]
    static let outlineWidthBias: Double = PipelineOutlineConstants.file.ringLine[2]
    /// Bold when the fill body's ridge width / font and its line-polygon cover both reach these
    /// (`PipelineStyleEstimator.boldMeasure`; rule and thresholds from TRAIN-fold CV, `port-eval/bold/bo`).
    static let boldRidgeRatio: Double = 0.151
    static let boldLineCover: Double = 0.181
    static func isBold(_ m: PipelineStyleEstimator.BoldMeasure) -> Bool { m.ridge >= boldRidgeRatio && m.cover >= boldLineCover }
}
