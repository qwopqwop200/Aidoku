import Foundation

/// Independent original endpoints enter here; reconstructed surface and display
/// stroke colors must never vote as source ink. Extracted from actual DEV pilot.
enum NativeSourceInkSelection {
    struct Evidence {
        let fillPixels: Double
        let strokePixels: Double
        let fillShapePixels: Double
        let strokeShapePixels: Double
        let fillRepeatedTiles: Double
        let strokeRepeatedTiles: Double
        let fillEnclosedPixels: Double
        let strokeEnclosedPixels: Double
    }
    struct Selection {
        let color: [Double]?
        let role: String
        let neutralExteriorSuppressed: Bool
        let evidenceAuthority = "original owned endpoint topology/chroma proxy; not color gold"
    }
    static func select(fill: [Double]?, stroke: [Double]?, evidence e: Evidence) -> Selection {
        func valid(_ rgb: [Double]?) -> [Double]? {
            guard let rgb, rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
            return rgb
        }
        let fill = valid(fill), stroke = valid(stroke)
        guard let fill else {
            return Selection(color: stroke, role: stroke == nil ? "unknown" : "sourceStrokeOnly",
                neutralExteriorSuppressed: false)
        }
        guard let stroke else {
            return Selection(color: fill, role: "sourceFill", neutralExteriorSuppressed: false)
        }
        func chroma(_ rgb: [Double]) -> Double { rgb.max()! - rgb.min()! }
        func luminance(_ rgb: [Double]) -> Double {
            zip(rgb, [0.2126, 0.7152, 0.0722]).reduce(0) { total, pair in
                let s = pair.0 / 255
                return total + (s <= 0.04045 ? s/12.92 : pow((s+0.055)/1.055, 2.4)) * pair.1
            }
        }
        let neutralDarkBody = chroma(stroke) < 24 && chroma(fill) < 24
            && luminance(stroke) > 0.7 && luminance(fill) < 0.2
        let fillCore = e.fillEnclosedPixels / max(1, e.fillPixels)
        let strokeCore = e.strokeEnclosedPixels / max(1, e.strokePixels)
        let exterior = chroma(stroke) < 28 && chroma(fill) >= 28 && luminance(stroke) > 0.7
            && max(e.fillEnclosedPixels, e.strokeEnclosedPixels) >= 12
            && fillCore > strokeCore * 1.5 && fillCore > 0.08
        let fs = e.fillShapePixels * min(1, e.fillRepeatedTiles / 4)
        let ss = e.strokeShapePixels * min(1, e.strokeRepeatedTiles / 4)
        let useStroke = !neutralDarkBody && !exterior && ss > fs * 1.2 && ss >= 12
        return Selection(color: useStroke ? stroke : fill, role: useStroke ? "sourceStroke" : "sourceFill",
            neutralExteriorSuppressed: exterior)
    }

    /// Display-only correction. Do not use for source palette/group compatibility:
    /// that would change grouping and layout while repairing the display ink.
    static func displaySelection(fill: [Double]?, stroke: [Double]?, evidence e: Evidence) -> Selection {
        let prior = select(fill: fill, stroke: stroke, evidence: e)
        guard prior.role == "sourceStroke", let fill, let stroke,
              fill.count == 3, stroke.count == 3,
              e.fillShapePixels >= 12, e.fillRepeatedTiles >= 4 else { return prior }
        let fillChroma = fill.max()! - fill.min()!, strokeChroma = stroke.max()! - stroke.min()!
        let whiteCore = fill.min()! >= 230 && fillChroma <= 20
        // Preserve saturated emphasis outlines (orange/cyan/magenta). The
        // low-chroma surface/halo population cannot win on area alone.
        let areaOnlyHalo = e.strokeEnclosedPixels < 12 && strokeChroma < 90
        let washedHaloOverChromaticCore = stroke.min()! >= 180 && strokeChroma <= 64 && fillChroma >= 90
        if washedHaloOverChromaticCore || (strokeChroma < 90 && (whiteCore || areaOnlyHalo)) {
            return Selection(color: fill, role: "display-source-core-over-area-only-halo", neutralExteriorSuppressed: true)
        }
        return prior
    }
}
