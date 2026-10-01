import Foundation

/// The late, polarity-preserving plate tone policy. Decisions are collected
/// before any owner changes, so neighboring captions see the original page.
enum NativePolarityLegibility {
    struct Entry {
        var plate: [Double]?
        var fill: [Double]?
        var source: [Double]?
        var backing: [Double]?
        var confidence: Double
        var font: Double
        var strokeWidth: Double
        var strokePreserved = false
        var ringAction: String?
        var ringKind: String?
        var ringCore: [Double]?
        var sharedOwner = false
        var foreignOwner = false
        var otherInks: [[Double]?] = []
    }
    struct Decision {
        var fill: [Double]?
        var plate: [Double]?
        var contrast: Double?
        var rejection: String?
    }

    static func resolve(_ entry: Entry) -> Decision {
        func no(_ rejection: String? = nil) -> Decision { .init(rejection: rejection) }
        if let action = entry.ringAction, !action.isEmpty, action != "none" { return no() }
        guard let plate = entry.plate, let fill = entry.fill, let source = entry.source, let back = entry.backing,
              valid(plate), valid(fill), valid(source), valid(back), entry.confidence >= 0.55 else { return no() }
        if entry.strokeWidth > 0 && entry.strokePreserved { return no() }
        let light = luminance(source) > luminance(plate)
        if light == (luminance(fill) > luminance(plate)) || delta(fill, source) <= 40 { return no() }
        if gap(plate, back) > 32 || ratio(source, back) < 1.6 || ratio(source, plate) < 1.4 { return no("surface") }
        if entry.ringKind == "outline" || entry.ringCore.map({ valid($0) && gap($0, source) > 48 }) == true { return no("ring") }
        let font = entry.font.isFinite && entry.font != 0 ? entry.font : 10, required = font >= 18 ? 3.0 : 4.5
        let extreme = source.map { light ? max($0, min(255, $0 + 24)) : min($0, max(0, $0 - 24)) }
        let ink = (source.max()! >= 224 && light) || (source.min()! <= 32 && !light) ? extreme : source
        let li = luminance(ink)
        let target = light ? (li + 0.05) / (required * 1.02) - 0.05 : (li + 0.05) * required * 1.02 - 0.05
        if target <= 0 || target >= 1 { return no("target") }
        let toned = (light && luminance(plate) <= target) || (!light && luminance(plate) >= target) ? plate : tone(plate, target: target)
        let difference = delta(toned, plate), contrast = ratio(ink, toned)
        if contrast < required - 0.01 || difference > 30 { return no("cap:\(Int(floor(difference + 0.5)))") }
        if entry.sharedOwner { return no("shared") }
        if entry.foreignOwner { return no("foreign") }
        if entry.otherInks.contains(where: { color in color.map { !valid($0) || ratio($0, toned) < 3 } ?? true }) { return no("other") }
        return .init(fill: ink, plate: toned, contrast: contrast)
    }

    private static func valid(_ rgb: [Double]) -> Bool { rgb.count == 3 && rgb.allSatisfy { $0.isFinite && (0...255).contains($0) } }
    private static func linear(_ value: Double) -> Double {
        let v = value / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    private static func luminance(_ rgb: [Double]) -> Double {
        let v = rgb.map(linear)
        return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
    }
    private static func ratio(_ a: [Double], _ b: [Double]) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    private static func gap(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map { abs($0 - $1) }.max()! }
    private static func lab(_ rgb: [Double]) -> [Double] {
        let v = rgb.map(linear), r = v[0], g = v[1], b = v[2]
        func f(_ value: Double) -> Double { value > 0.008856 ? cbrt(value) : 7.787 * value + 16.0 / 116 }
        let x = f((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047)
        let y = f(0.2126 * r + 0.7152 * g + 0.0722 * b), z = f((0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883)
        return [116 * y - 16, 500 * (x - y), 200 * (y - z)]
    }
    private static func delta(_ a: [Double], _ b: [Double]) -> Double {
        let p = lab(a), q = lab(b)
        return hypot(hypot(p[0] - q[0], p[1] - q[1]), p[2] - q[2])
    }
    private static func tone(_ rgb: [Double], target: Double) -> [Double] {
        let l = luminance(rgb)
        return rgb.map(linear).map { v in
            let out = target <= l ? v * target / max(1e-6, l) : v + (1 - v) * (target - l) / max(1e-6, 1 - l)
            let srgb = out <= 0.0031308 ? out * 12.92 : 1.055 * pow(out, 1 / 2.4) - 0.055
            return floor(255 * min(1, max(0, srgb)) + 0.5)
        }
    }
}
