import Foundation

/// Fitted tables in Resources/Translation/V2Weights.bin, exported from the out-of-repo research
/// scripts (scripts-mask/export_weights.py, scripts-style/export_swift.py; TRAIN split only). fillPass2 is a
/// LightGBM lambdarank over each block's candidates (`port-eval/colorfix/export_fill.py`; base 0, rate 1).
/// An optional fourth forest, fillPeaks, ranks the pick against its density peaks (`train_peaks.py`).
/// Each table is a UInt32 element count followed by little-endian elements, in the order read below. The
/// first two tables (the former S6 MLP, replaced by `V2MaskNet`) are unused and skipped.
private enum V2WeightFile {
    struct Tables {
        let fillPass1: V2StyleForest, fillPass2: V2StyleForest, outline: V2StyleForest
        /// Optional trailing forest: the density-peak ranker (absent in older files).
        let fillPeaks: V2StyleForest?
    }

    static let tables: Tables = {
        var urls = [Bundle.main.url(forResource: "V2Weights", withExtension: "bin")].compactMap { $0 }
        if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] {
            urls.append(URL(fileURLWithPath: root).appendingPathComponent("Aidoku/Resources/Translation/V2Weights.bin"))
        }
        guard let data = urls.lazy.compactMap({ try? Data(contentsOf: $0) }).first else {
            fatalError("V2Weights.bin is missing from the bundle")
        }
        var offset = 0
        func read<T>(_: T.Type) -> [T] {
            let count = Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }))
            let start = offset + 4, size = MemoryLayout<T>.stride
            offset = start + count * size
            precondition(offset <= data.count, "V2Weights.bin is truncated")
            return data.withUnsafeBytes { raw in
                (0..<count).map { raw.loadUnaligned(fromByteOffset: start + $0 * size, as: T.self) }
            }
        }
        func forest() -> V2StyleForest {
            let scalars = read(Double.self)
            return V2StyleForest(base: scalars[0], rate: scalars[1], roots: read(Int32.self), feature: read(Int16.self),
                                 threshold: read(Double.self), left: read(Int32.self), right: read(Int32.self),
                                 value: read(Double.self))
        }
        _ = read(Float.self); _ = read(Float.self)
        let fillPass1 = forest(), fillPass2 = forest(), outline = forest()
        let tables = Tables(fillPass1: fillPass1, fillPass2: fillPass2, outline: outline,
                            fillPeaks: offset < data.count ? forest() : nil)
        precondition(offset == data.count, "V2Weights.bin has trailing data")
        return tables
    }()
}

enum V2StyleParameters {
    static var fillPass1: V2StyleForest { V2WeightFile.tables.fillPass1 }
    static var fillPass2: V2StyleForest { V2WeightFile.tables.fillPass2 }
    static var outline: V2StyleForest { V2WeightFile.tables.outline }
    static var fillPeaks: V2StyleForest? { V2WeightFile.tables.fillPeaks }
    static let outlinePage: [Double] = [0.4094924613695863, 0.19954881908897934, -0.9404877504298349]
    static let outlineWidthRing: Double = 0.49653723604023625
    static let outlineWidthFont: Double = 0.042260916827793475
    static let outlineWidthBias: Double = -0.04776139182973868
    /// Bold when the fill body's ridge width / font and its line-polygon cover both reach these
    /// (`V2StyleEstimator.boldMeasure`; rule and thresholds from TRAIN-fold CV, `port-eval/bold/bo`).
    static let boldRidgeRatio: Double = 0.151
    static let boldLineCover: Double = 0.181
    static func isBold(_ m: V2StyleEstimator.BoldMeasure) -> Bool { m.ridge >= boldRidgeRatio && m.cover >= boldLineCover }
}
