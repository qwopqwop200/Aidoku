import Foundation

/// Physical35 plus actual colour-conditioned primary9. This extractor does not
/// construct a rich209 packet or execute boundary/context/OCR feature producers.
enum NativeM1SourceStyleFeatures44 {
    static let revision = "actual-m1-physical35-primary-context9-native-v1"
    enum Failure: Error { case invalidImageOperation, invalidPacket }

    static func extract(_ input: NativeMinimalSourceStyleInput,
                        ops: any NativeAppearanceImageOperations) throws -> NativeAppearanceSourceFeatures209.Packet {
        try input.validate()
        let w = input.width, h = input.height, n = w * h
        let measured = try NativeAppearanceSourceFeatures209.extractPhysicalWithLabs(.init(width: w, height: h,
            rgb: input.rgb, ownMask: input.ownMask, fontPriorSourcePixels: input.fontPriorSourcePixels), ops: ops)
        var packet = measured.packet
        let radius = max(2, min(24, Int((max(1, input.fontPriorSourcePixels) * 0.12).rounded(.toNearestOrEven))))
        let near = radius == measured.radius ? measured.near : try ops.dilate(
            input.ownMask.map { $0 == 0 ? UInt8(0) : 1 }, width: w, height: h, radius: radius, ellipse: true)
        let pixelLab = try ops.lab(rgb: input.rgb, width: w, height: h)
        let labs = measured.labs
        guard near.count == n, pixelLab.count == n * 3, labs.count == packet.colors.count,
              packet.features.count == packet.colors.count else { throw Failure.invalidImageOperation }
        // Avoid a full crop-sized Int region map (up to 12 MB at the crop cap).
        // The same observed mask/near predicates supply exact integer counts.
        var counts = [Int](repeating: 0, count: 3)
        for p in 0..<n { counts[input.ownMask[p] != 0 ? 0 : near[p] != 0 ? 1 : 2] += 1 }
        for index in packet.colors.indices {
            guard packet.features[index].count == 35 else { throw Failure.invalidPacket }
            var sums = [Float](repeating: 0, count: 3), hits = [Int](repeating: 0, count: 3)
            for p in 0..<n {
                let dl = pixelLab[p * 3] - labs[index][0]
                let da = pixelLab[p * 3 + 1] - labs[index][1]
                let db = pixelLab[p * 3 + 2] - labs[index][2]
                guard (dl * dl + da * da) + db * db <= 100 else { continue }
                let region = input.ownMask[p] != 0 ? 0 : near[p] != 0 ? 1 : 2
                sums[region] += input.primary[p]
                hits[region] += 1
            }
            for region in 0..<3 {
                packet.features[index] += [hits[region] > 0 ? sums[region] / Float(hits[region]) : 0,
                    Float(Double(hits[region]) / Double(max(1, counts[region]))), hits[region] > 0 ? 1 : 0]
            }
        }
        return packet
    }
}
