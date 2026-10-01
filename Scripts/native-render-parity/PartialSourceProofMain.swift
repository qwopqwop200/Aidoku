import CoreGraphics
import Foundation

@main enum PartialSourceProofMain {
    static func main() throws {
        let jobs = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String: Any]]
        let output = jobs.map { j -> Any in
            if j["operation"] as? String == "position" {
                func rect(_ a: Any) -> CGRect { let v=a as! [Double]; return CGRect(x:v[0],y:v[1],width:v[2],height:v[3]) }
                let owners=(j["owners"] as! [[String:Any]]).map { q in NativePartialSourceProof.SourceOwner(sources:(q["sources"] as! [[Double]]).map(rect), erasureVerified:q["verified"] as! Bool, provisional:q["provisional"] as! Bool, partialCertified:q["partial"] as! Bool, connected:q["connected"] as! Bool) }
                if let v = NativePartialSourceProof.outlinedSourcePosition(source:rect(j["source"]!),ink:rect(j["ink"]!),font:j["font"] as! Double,foreground:j["foreground"] as! [Double],sampledStroke:j["stroke"] as? [Double],neighbors:(j["neighbors"] as! [[Double]]).map(rect),oldPlate:rect(j["plate"]!),otherSources:owners,sourceVertical:j["vertical"] as! Bool,sourceSingleColumn:j["single"] as! Bool,contentFits:j["fits"] as! Bool,erasureComplete:j["erasure"] as! Bool,outlineResolved:j["resolved"] as! Bool,attachedLeadingInk:j["attached"] as! Bool,largePartialResidual:j["residual"] as! Bool) {
                    return ["foreground":v.foreground,"stroke":v.stroke,"width":v.width,"minimumContrast":v.minimumContrast] as [String:Any]
                }
                return NSNull()
            }
            let w = j["width"] as! Int, h = j["height"] as! Int, glyph = j["glyph"] as! Double
            let safe = j["safe"] as! [UInt8], core = (j["core"] as! [[Double]]).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
            return ["resolved":NativePartialSourceProof.outlineSourceResolved(safe: safe, width: w, height: h, core: core,
                        erasureVerified: j["erasure"] as! Bool, glyphsVerified: j["glyphs"] as! Bool, pixelRatio: j["ratio"] as! Double),
                    "attached":NativePartialSourceProof.hasAttachedLeadingInk(safe: safe, width: w, height: h, core: core, glyph: glyph),
                    "residual":NativePartialSourceProof.hasLargePartialResidual(safe: safe, width: w, height: h, core: core,
                        glyph: glyph, vertical: j["vertical"] as! Bool)]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
    }
}
