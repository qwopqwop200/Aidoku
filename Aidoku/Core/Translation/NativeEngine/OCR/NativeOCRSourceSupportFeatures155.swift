import Foundation

/// Source-support admission ABI: raw DET/private CC + ALL17 measured RF planes.
/// No OCR, RGB decode, GT, source IDs, candidate election or ownership inference.
/// Keep the complete raw inventory as context; only the caller schedules queries.
enum NativeOCRSourceSupportFeatures155 {
    static let abi = "source-support155-native17-f32-v1"
    static let featureCount = 155
    static let featureNames: [String] = {
        let sides = ["edge01", "edge12", "edge23", "edge30"]
        let classes = ["text", "soundEffect", "textOrSoundEffect"]
        let stats = ["insideMean", "outsideMean", "insideMinusOutside", "insideSupportHalf", "outsideSupportHalf",
                     "outsideSupportMassFraction", "insideOutsideAgreement"]
        var boundary = sides.flatMap { side in classes.flatMap { cls in stats.map { "\(side).\(cls).\($0)" } } }
        for side in sides {
            boundary += ["insideEvidenceMargin", "outsideEvidenceMargin", "insideWeightedMeanAgreement",
                         "outsideWeightedMeanAgreement", "validSampleFraction"].map { "\(side).\($0)" }
        }
        for cls in classes {
            boundary += ["minimumBoundaryDrop", "meanBoundaryDrop", "maximumOutsideMassFraction"].map { "allSides.\(cls).\($0)" }
        }
        return ["DETconfidence", "completeCCScan", "ownedCCMeanProbability", "coveredOwnedCCFraction",
                "ambiguousCCFraction", "CCEvidenceAvailable", "RFmaxTextOrSFX", "RFNontextMargin"]
            + (0..<17).map { "RFplane\($0):mean" }
            + (0..<17).map { "RFplane\($0):supportHalf" } + boundary
    }()

    /// Prepare once per immutable source. Native17 is five classes, each with
    /// max-mask / weighted-mean-mask / max-box-confidence, then margin/uncertainty.
    /// A four-class SemanticGrid cannot reconstruct the other nine fields.
    struct PreparedRF: Sendable {
        let width: Int
        let height: Int
        fileprivate let fields: [Float]
        init?(width: Int, height: Int, native17Fields: [Float], allQueryCount: Int = 300) {
            let cells = 162 * 162
            guard width > 0, height > 0, allQueryCount == 300,
                  native17Fields.count == 17 * cells,
                  native17Fields.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
            self.width = width; self.height = height; fields = native17Fields
        }
    }
    struct Result: Sendable {
        /// Float32 exactly as the frozen Python155 training cache; missing stays NaN.
        let features: [Float]
        let featureAvailable: [Bool]
        let rfAvailable: Bool
        let detectorEvidenceAvailable: Bool

    }

    /// Exact scalar6 for the simple REC agreement consumer. The other155
    /// fields (CC scans,15 RF planes and boundary quadrature) are NOT produced.
    /// Same original-polygon16x16 quadrature, Double interpolation/reduction,
    /// and final Float32 cast as extract(). Missing remains unavailable.
    static func recognitionRFSupport(rawPolygon polygon: [[Double]], sourceWidth: Int, sourceHeight: Int,
                                     rf: PreparedRF) -> Float? {
        guard sourceWidth > 0, sourceHeight > 0, rf.width == sourceWidth, rf.height == sourceHeight,
              polygon.count == 4, polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let crosses = (0..<4).map { i -> Double in
            let a = polygon[i], b = polygon[(i+1)%4], c = polygon[(i+2)%4]
            return (b[0]-a[0])*(c[1]-b[1]) - (b[1]-a[1])*(c[0]-b[0])
        }
        guard crosses.allSatisfy({ $0 > 0 }) || crosses.allSatisfy({ $0 < 0 }) else { return nil }
        let cells = 162 * 162
        var text = [Double](repeating: 0, count: 256)
        var soundEffect = [Double](repeating: 0, count: 256)
        for yy in 0..<16 {
            let v = (Double(yy) + 0.5) / 16
            for xx in 0..<16 {
                let u = (Double(xx) + 0.5) / 16
                let x = polygon[0][0] * (1-u) * (1-v) + polygon[1][0] * u * (1-v)
                    + polygon[2][0] * u * v + polygon[3][0] * (1-u) * v
                let y = polygon[0][1] * (1-u) * (1-v) + polygon[1][1] * u * (1-v)
                    + polygon[2][1] * u * v + polygon[3][1] * (1-u) * v
                guard x.isFinite, y.isFinite else { return nil }
                let gx = min(161, max(0, x * 162 / Double(sourceWidth) - 0.5))
                let gy = min(161, max(0, y * 162 / Double(sourceHeight) - 0.5))
                let x0 = Int(gx), y0 = Int(gy), x1 = min(161, x0 + 1), y1 = min(161, y0 + 1)
                let dx = gx - Double(x0), dy = gy - Double(y0)
                func sample(_ plane: Int) -> Double {
                    let offset = plane * cells
                    return (Double(rf.fields[offset + y0 * 162 + x0]) * (1-dx)
                          + Double(rf.fields[offset + y0 * 162 + x1]) * dx) * (1-dy)
                        + (Double(rf.fields[offset + y1 * 162 + x0]) * (1-dx)
                           + Double(rf.fields[offset + y1 * 162 + x1]) * dx) * dy
                }
                text[yy * 16 + xx] = sample(0)
                soundEffect[yy * 16 + xx] = sample(3)
            }
        }
        return Float(max(numpySum(text) / 256, numpySum(soundEffect) / 256))
    }

    /// Invalid/mismatched evidence returns nil; retain the source query. No
    /// data are synthesized from the eight-plane native semantic projection.
    static func extract(rawPolygon polygon: [[Double]], detectorConfidence: Double,
                        detectorSeed: NativeOCRDetectorSeedEvidence?, sourceWidth: Int, sourceHeight: Int,
                        rf: PreparedRF?) -> Result? {
        guard sourceWidth > 0, sourceHeight > 0, polygon.count == 4,
              polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }),
              detectorConfidence.isFinite, (0...1).contains(detectorConfidence),
              let rf, rf.width == sourceWidth, rf.height == sourceHeight else { return nil }
        let crosses = (0..<4).map { i -> Double in
            let a = polygon[i], b = polygon[(i+1)%4], c = polygon[(i+2)%4]
            return (b[0]-a[0])*(c[1]-b[1]) - (b[1]-a[1])*(c[0]-b[0])
        }
        guard crosses.allSatisfy({ $0 > 0 }) || crosses.allSatisfy({ $0 < 0 }) else { return nil }
        var complete = 0.0, meanProbability = 0.0, coverage = 0.0, ambiguous = 0.0, available = 0.0
        if let seed = detectorSeed {
            guard seed.sourceWidth == sourceWidth, seed.sourceHeight == sourceHeight,
                  seed.mapFullWidth > 0, seed.mapFullHeight > 0, seed.components.count <= 256 else { return nil }
            complete = seed.completeCCScan == true ? 1 : 0
            var pixels = 0, hit = 0, weighted = 0.0
            let sx = Double(sourceWidth) / Double(seed.mapFullWidth)
            let sy = Double(sourceHeight) / Double(seed.mapFullHeight)
            for component in seed.components {
                guard component.pixelCount > 0, component.pixelCount <= 262_144,
                      component.meanProbability.isFinite, (0...1).contains(component.meanProbability),
                      component.runs.count <= 4096, pixels <= 1_048_576 - component.pixelCount else { return nil }
                pixels += component.pixelCount
                weighted += component.meanProbability * Double(component.pixelCount)
                var measured = 0
                for run in component.runs {
                    guard run.x >= 0, run.y >= 0, run.y < seed.mapFullHeight, run.count > 0,
                          run.x < seed.mapFullWidth, run.count <= seed.mapFullWidth - run.x,
                          measured <= component.pixelCount - run.count else { return nil }
                    measured += run.count
                    let y = (Double(run.y) + 0.5) * sy
                    for x in run.x..<(run.x + run.count) {
                        if inside(polygon, x: (Double(x) + 0.5) * sx, y: y) { hit += 1 }
                    }
                }
                guard measured == component.pixelCount else { return nil }
            }
            let other = (seed.ambiguousComponents ?? []) + (seed.candidateComponents ?? []).map(\.component)
            guard other.count <= 256, other.allSatisfy({ $0.pixelCount > 0 && $0.pixelCount <= 262_144 }) else { return nil }
            let ambiguousPixels = other.reduce(0.0) { $0 + Double($1.pixelCount) }
            meanProbability = weighted / Double(max(1, pixels))
            coverage = Double(hit) / Double(max(1, pixels))
            ambiguous = ambiguousPixels / max(1, Double(pixels) + ambiguousPixels)
            available = !seed.components.isEmpty && seed.ownershipVersion == 2 ? 1 : 0
        }
        var values = [Float(detectorConfidence), Float(complete), Float(meanProbability), Float(coverage),
                      Float(ambiguous), Float(available)]
        var samples = [[Double]](repeating: [Double](repeating: 0, count: 256), count: 17)
        var support = [Int](repeating: 0, count: 17)
        let cells = 162 * 162
        // Interior quadrature CLAMPS to RF frame edges, matching field_samples.
        // The separate RF113 border quadrature abstains outside the frame.
        for yy in 0..<16 {
            let v = (Double(yy) + 0.5) / 16
            for xx in 0..<16 {
                let u = (Double(xx) + 0.5) / 16
                let x = polygon[0][0] * (1-u) * (1-v) + polygon[1][0] * u * (1-v)
                    + polygon[2][0] * u * v + polygon[3][0] * (1-u) * v
                let y = polygon[0][1] * (1-u) * (1-v) + polygon[1][1] * u * (1-v)
                    + polygon[2][1] * u * v + polygon[3][1] * (1-u) * v
                guard x.isFinite, y.isFinite else { return nil }
                let gx = min(161, max(0, x * 162 / Double(sourceWidth) - 0.5))
                let gy = min(161, max(0, y * 162 / Double(sourceHeight) - 0.5))
                let x0 = Int(gx), y0 = Int(gy), x1 = min(161, x0 + 1), y1 = min(161, y0 + 1)
                let dx = gx - Double(x0), dy = gy - Double(y0)
                for plane in 0..<17 {
                    let offset = plane * cells
                    let sample = (Double(rf.fields[offset + y0 * 162 + x0]) * (1-dx)
                                  + Double(rf.fields[offset + y0 * 162 + x1]) * dx) * (1-dy)
                        + (Double(rf.fields[offset + y1 * 162 + x0]) * (1-dx)
                           + Double(rf.fields[offset + y1 * 162 + x1]) * dx) * dy
                    samples[plane][yy * 16 + xx] = sample
                    if sample >= 0.5 { support[plane] += 1 }
                }
            }
        }
        let means = samples.map { numpySum($0) / 256 }
        let text = max(means[0], means[3]), nontext = max(means[6], means[9]) - text
        values += [Float(text), Float(nontext)]
        values += means.map(Float.init)
        values += support.map { Float(Double($0) / 256) }
        values += boundaryFeatures(polygon, rf)
        guard values.count == featureCount else { return nil }
        return .init(features: values, featureAvailable: values.map(\.isFinite), rfAvailable: true,
                     detectorEvidenceAvailable: available == 1)
    }

    /// NumPy contiguous Double add.reduce: eight accumulators through128,
    /// recursively split larger blocks. Retain zero slots for NaNs, as nansum
    /// does, so cancellation-sensitive boundary contrasts keep their Float bits.
    private static func numpySum(_ values: [Double]) -> Double {
        func sum(_ start: Int, _ count: Int) -> Double {
            if count < 8 {
                var result = -0.0
                for i in start..<(start + count) { result += values[i] }
                return result
            }
            if count <= 128 {
                var r = Array(values[start..<(start + 8)])
                var i = 8
                while i < count - count % 8 {
                    for k in 0..<8 { r[k] += values[start + i + k] }
                    i += 8
                }
                var result = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
                while i < count { result += values[start + i]; i += 1 }
                return result
            }
            var middle = count / 2
            middle -= middle % 8
            return sum(start, middle) + sum(start + middle, count - middle)
        }
        return sum(0, values.count)
    }
    private static func nanMean(_ values: [Double]) -> Double {
        let count = values.filter(\.isFinite).count
        return count > 0 ? numpySum(values.map { $0.isFinite ? $0 : 0 }) / Double(count) : .nan
    }
    private static func boundaryFeatures(_ polygon: [[Double]], _ rf: PreparedRF) -> [Float] {
        let cells = 162 * 162
        let depths = [-0.02, -0.06, -0.12, 0.02, 0.06, 0.12]
        var fields = Array(repeating: Array(repeating: [Double](repeating: .nan, count: 96), count: 5), count: 4)
        var validCounts = [Int](repeating: 0, count: 4)
        for side in 0..<4 { for position in 0..<16 { for depthIndex in 0..<6 {
            let t = (Double(position) + 0.5) / 16, d = depths[depthIndex]
            let u: Double, v: Double
            switch side {
            case 0: u = t; v = d
            case 1: u = 1-d; v = t
            case 2: u = 1-t; v = 1-d
            default: u = d; v = 1-t
            }
            let x = polygon[0][0]*(1-u)*(1-v) + polygon[1][0]*u*(1-v)
                + polygon[2][0]*u*v + polygon[3][0]*(1-u)*v
            let y = polygon[0][1]*(1-u)*(1-v) + polygon[1][1]*u*(1-v)
                + polygon[2][1]*u*v + polygon[3][1]*(1-u)*v
            guard x.isFinite, y.isFinite, x >= 0, x <= Double(rf.width), y >= 0, y <= Double(rf.height) else { continue }
            validCounts[side] += 1
            let gx = min(161, max(0, x*162/Double(rf.width)-0.5)), gy = min(161, max(0, y*162/Double(rf.height)-0.5))
            let x0 = Int(gx), y0 = Int(gy), x1 = min(161, x0+1), y1 = min(161, y0+1)
            let dx = gx-Double(x0), dy = gy-Double(y0), slot = position*6+depthIndex
            func sample(_ plane: Int) -> Double {
                let offset = plane * cells
                return (Double(rf.fields[offset+y0*162+x0])*(1-dx) + Double(rf.fields[offset+y0*162+x1])*dx)*(1-dy)
                    + (Double(rf.fields[offset+y1*162+x0])*(1-dx) + Double(rf.fields[offset+y1*162+x1])*dx)*dy
            }
            let text = sample(0), sfx = sample(3)
            fields[side][0][slot] = text; fields[side][1][slot] = sfx
            fields[side][2][slot] = max(text, sfx)
            fields[side][3][slot] = max(sample(6), sample(9))
            fields[side][4][slot] = max(sample(1), sample(4))
        }}}
        func half(_ values: [Double], _ inside: Bool) -> [Double] {
            var result = [Double](); result.reserveCapacity(48)
            for position in 0..<16 { for depth in (inside ? 3..<6 : 0..<3) { result.append(values[position*6+depth]) } }
            return result
        }
        var output = [Double](), drops = [[Double]](repeating: [], count: 3), masses = drops
        for side in 0..<4 { for cls in 0..<3 {
            let ins = half(fields[side][cls], true), out = half(fields[side][cls], false)
            let im = nanMean(ins), om = nanMean(out), total = im+om
            let ih = nanMean(ins.map { $0.isFinite ? ($0 >= 0.5 ? 1 : 0) : .nan })
            let oh = nanMean(out.map { $0.isFinite ? ($0 >= 0.5 ? 1 : 0) : .nan })
            let fraction: Double = total.isFinite ? (total > 1e-8 ? om/total : 0) : .nan
            let agreement = nanMean(zip(ins, out).map { 1-abs($0-$1) })
            output += [im, om, im-om, ih, oh, fraction, agreement]
            drops[cls].append(im-om); masses[cls].append(fraction)
        }}
        for side in 0..<4 {
            let margin = zip(fields[side][2], fields[side][3]).map(-)
            let agreement = zip(fields[side][2], fields[side][4]).map { 1-abs($0-$1) }
            output += [nanMean(half(margin, true)), nanMean(half(margin, false)),
                       nanMean(half(agreement, true)), nanMean(half(agreement, false)), Double(validCounts[side])/96]
        }
        for cls in 0..<3 {
            output += [drops[cls].filter(\.isFinite).min() ?? .nan, nanMean(drops[cls]), masses[cls].filter(\.isFinite).max() ?? .nan]
        }
        return output.map { $0.isFinite ? Float($0) : .nan }
    }

    private static func inside(_ q: [[Double]], x: Double, y: Double) -> Bool {
        var positive = true, negative = true
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4]
            let cross = (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0])
            positive = positive && cross >= -1e-8
            negative = negative && cross <= 1e-8
        }
        return positive || negative
    }
}

extension NativeOCRSourceSupportFeatures155 {
    /// Narrow read-only measurement API. The RF buffer stays fileprivate in
    /// its owning file; only four real Float32 scalars cross the file boundary.
    /// Arithmetic is unchanged from the proven dedicated boundary producer.
    static func boundaryTextOutsideMassFractions(rawPolygon polygon: [[Double]], sourceWidth width: Int,
                                                sourceHeight height: Int, rf: PreparedRF) -> [Float]? {
        guard width > 0, height > 0, rf.width == width, rf.height == height, polygon.count == 4,
              polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let crosses = (0..<4).map { i -> Double in
            let a = polygon[i], b = polygon[(i+1)%4], c = polygon[(i+2)%4]
            return (b[0]-a[0])*(c[1]-b[1]) - (b[1]-a[1])*(c[0]-b[0])
        }
        guard crosses.allSatisfy({ $0 > 0 }) || crosses.allSatisfy({ $0 < 0 }) else { return nil }
        let cells = 162*162, depths = [-0.02,-0.06,-0.12,0.02,0.06,0.12]
        var result = [Float](); result.reserveCapacity(4)
        for side in 0..<4 {
            var inside = [Double](), outside = [Double](); inside.reserveCapacity(48); outside.reserveCapacity(48)
            for position in 0..<16 { for depthIndex in 0..<6 {
                let t = (Double(position)+0.5)/16, d = depths[depthIndex]
                let u: Double, v: Double
                switch side { case 0: u=t; v=d; case 1: u=1-d; v=t; case 2: u=1-t; v=1-d; default: u=d; v=1-t }
                let x = polygon[0][0]*(1-u)*(1-v) + polygon[1][0]*u*(1-v) + polygon[2][0]*u*v + polygon[3][0]*(1-u)*v
                let y = polygon[0][1]*(1-u)*(1-v) + polygon[1][1]*u*(1-v) + polygon[2][1]*u*v + polygon[3][1]*(1-u)*v
                var value = Double.nan
                if x.isFinite && y.isFinite && x >= 0 && x <= Double(width) && y >= 0 && y <= Double(height) {
                    let gx = min(161,max(0,x*162/Double(width)-0.5)), gy = min(161,max(0,y*162/Double(height)-0.5))
                    let x0=Int(gx), y0=Int(gy), x1=min(161,x0+1), y1=min(161,y0+1), dx=gx-Double(x0), dy=gy-Double(y0)
                    func sample(_ plane: Int) -> Double {
                        let offset = plane*cells
                        return (Double(rf.fields[offset+y0*162+x0])*(1-dx) + Double(rf.fields[offset+y0*162+x1])*dx)*(1-dy)
                            + (Double(rf.fields[offset+y1*162+x0])*(1-dx) + Double(rf.fields[offset+y1*162+x1])*dx)*dy
                    }
                    value = max(sample(0),sample(3))
                }
                if depthIndex < 3 { outside.append(value) } else { inside.append(value) }
            }}
            let im = mean(inside), om = mean(outside), total = im+om
            result.append(total.isFinite ? Float(total > 1e-8 ? om/total : 0) : .nan)
        }
        return result
    }
    private static func mean(_ values: [Double]) -> Double {
        let count = values.filter(\.isFinite).count
        return count > 0 ? sum(values.map { $0.isFinite ? $0 : 0 })/Double(count) : .nan
    }
    private static func sum(_ values: [Double]) -> Double {
        var r = Array(values[0..<8]), i = 8
        while i < values.count-values.count%8 { for k in 0..<8 { r[k] += values[i+k] }; i += 8 }
        var result = ((r[0]+r[1])+(r[2]+r[3])) + ((r[4]+r[5])+(r[6]+r[7]))
        while i < values.count { result += values[i]; i += 1 }; return result
    }
}
