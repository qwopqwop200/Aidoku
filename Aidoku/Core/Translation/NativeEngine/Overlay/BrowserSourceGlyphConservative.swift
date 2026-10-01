import Foundation

/// Keeps the source glyph segmenter aligned with the renderer's bounded crop
/// budget while limiting long dark artwork components. This adapter can be
/// removed after the upstream segmenter accepts these two parameters directly.
enum BrowserSourceGlyphConservative {
    static let script: String = {
        BrowserSourceGlyphSegmentation.script
            .replacingOccurrences(of: "n>262144", with: "n>750000")
            .replacingOccurrences(
                of: "const maxDimension=Math.min(78,Math.max(48,Math.min(b[2],b[3])*.48));",
                with: "const maxDimension=Number(options.glyphSize)>0?Math.min(180,Math.max(48,Number(options.glyphSize)*1.6)):dark&&!(background&&background.length>=3&&Math.min(...background)>=230)?56:Math.min(78,Math.max(48,Math.min(b[2],b[3])*.48));"
            )
            .replacingOccurrences(
                of: "area>Math.max(1800,b[2]*b[3]*.08)",
                with: "area>(Number(options.glyphSize)>0?Math.max(3200,Number(options.glyphSize)**2*1.3):(dark?Math.max(3200,b[2]*b[3]*.14):Math.max(1800,b[2]*b[3]*.08)))"
            )
    }()
}
