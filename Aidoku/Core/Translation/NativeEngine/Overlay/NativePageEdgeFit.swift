import CoreGraphics
import Foundation

/// Late page-edge fitting (the frozen implementation permits a 1.2-font shift,
/// despite its older half-line comment). Owned plates remain where they are.
enum NativePageEdgeFit {
    struct Result { var font: Double; var pitch: Double; var shift: CGPoint; var outcome: String }
    static func fit(ink: CGRect, frame: CGRect, font: Double, pitch: Double, plated: Bool, allowsResize: Bool,
        measure: (Double, Double) -> CGRect) -> Result? {
        guard valid(ink), valid(frame), font.isFinite, font > 0, pitch.isFinite else { return nil }
        func overflow(_ r: CGRect) -> CGPoint {
            .init(x: r.minX < frame.minX ? frame.minX - r.minX : r.maxX > frame.maxX ? frame.maxX - r.maxX : 0,
                y: r.minY < frame.minY ? frame.minY - r.minY : r.maxY > frame.maxY ? frame.maxY - r.maxY : 0)
        }
        func minor(_ delta: CGPoint) -> Bool { abs(delta.x) < 0.75 && abs(delta.y) < 0.75 }
        func canShift(_ r: CGRect, _ delta: CGPoint, limit: Double) -> Bool {
            !plated && abs(delta.x) <= limit && abs(delta.y) <= limit && r.width <= frame.width && r.height <= frame.height
        }
        let delta = overflow(ink)
        if minor(delta) { return nil }
        if canShift(ink, delta, limit: font * 1.2) { return .init(font: font, pitch: pitch, shift: delta, outcome: "shift") }
        guard allowsResize else { return nil }
        let ratio = (pitch == 0 ? font * 1.2 : pitch) / font, floor = min(font, 7)
        var size = font
        while size > floor {
            size = max(floor, size - 0.5)
            let newPitch = size * ratio, r = measure(size, newPitch), delta = overflow(r)
            if minor(delta) { return .init(font: size, pitch: newPitch, shift: .zero, outcome: "shrink") }
            if canShift(r, delta, limit: size * 1.2) { return .init(font: size, pitch: newPitch, shift: delta, outcome: "shrink") }
        }
        return .init(font: font, pitch: pitch, shift: .zero, outcome: "unresolved")
    }
    private static func valid(_ r: CGRect) -> Bool {
        [r.origin.x,r.origin.y,r.size.width,r.size.height].allSatisfy(\.isFinite) && r.size.width > 0 && r.size.height > 0
    }
}
