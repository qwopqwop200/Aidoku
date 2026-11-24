import Foundation

/// Fitted tables in Resources/Translation/PipelineWeights.bin (TRAIN split only): style forests, then the
/// optional density-peak ranker and line-end regressor. Each table is a UInt32 element count followed by
/// little-endian elements, in the order read below; the first two (a retired S6 MLP) are skipped.
private enum PipelineWeightFile {
    struct Tables {
        let fillPass1: PipelineStyleForest, fillPass2: PipelineStyleForest, outline: PipelineStyleForest
        let fillPeaks: PipelineStyleForest?
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
        let fillPeaks = offset < data.count ? forest() : nil
        let tables = Tables(fillPass1: fillPass1, fillPass2: fillPass2, outline: outline,
                            fillPeaks: fillPeaks, lineEnds: offset < data.count ? forest() : nil)
        precondition(offset == data.count, "PipelineWeights.bin has trailing data")
        return tables
    }()
}

enum PipelineRemovalMaskWeights {
    static var lineEnds: PipelineStyleForest? { PipelineWeightFile.tables.lineEnds }
}

enum PipelineStyleParameters {
    static var fillPass1: PipelineStyleForest { PipelineWeightFile.tables.fillPass1 }
    static var fillPass2: PipelineStyleForest { PipelineWeightFile.tables.fillPass2 }
    static var outline: PipelineStyleForest { PipelineWeightFile.tables.outline }
    static var fillPeaks: PipelineStyleForest? { PipelineWeightFile.tables.fillPeaks }
    static let outlinePage: [Double] = [0.4094924613695863, 0.19954881908897934, -0.9404877504298349]
    static let outlineWidthRing: Double = 0.49653723604023625
    static let outlineWidthFont: Double = 0.042260916827793475
    static let outlineWidthBias: Double = -0.04776139182973868
    /// Bold when the fill body's ridge width / font and its line-polygon cover both reach these
    /// (`PipelineStyleEstimator.boldMeasure`; rule and thresholds from TRAIN-fold CV, `port-eval/bold/bo`).
    static let boldRidgeRatio: Double = 0.151
    static let boldLineCover: Double = 0.181
    static func isBold(_ m: PipelineStyleEstimator.BoldMeasure) -> Bool { m.ridge >= boldRidgeRatio && m.cover >= boldLineCover }
}
