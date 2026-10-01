import CoreGraphics
import Foundation

@main enum OversizedTitleMain {
    static func main() throws {
        let jobs = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String: Any]]
        func rect(_ a: Any) -> CGRect { let v = a as! [Double]; return CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
        func array(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
        var output: [Any] = []
        for job in jobs {
            let frame = rect(job["frame"]!)
            let inputs = job["records"] as! [[String: Any]]
            func measure(_ id: String, _ text: String, _ size: Double, _ width: Double, _ lineHeight: Double, _ origin: CGPoint) -> CGRect {
                let natural = Double(text.utf16.count) * size * 0.53, lines = max(1, ceil(natural / width)), tw = min(width, natural)
                return CGRect(x: origin.x + (width - tw) / 2, y: origin.y + size * 0.08, width: tw, height: lines * lineHeight * 0.82)
            }
            let records = inputs.map { r -> NativeTranslationOversizedTitleGloss.Record in
                let origin = r["origin"] as! [Double]
                let font = r["font"] as! Double, width = r["width"] as! Double
                return .init(id: r["id"] as! String, text: r["text"] as! String, normalizedSourceBounds: rect(r["source"]!),
                    sourceFontSize: r["sourceFont"] as? Double, rotation: r["rotation"] as? Double ?? 0,
                    hasRestorationProposal: r["restored"] as? Bool ?? false, origin: CGPoint(x: origin[0], y: origin[1]),
                    ink: measure(r["id"] as! String, r["text"] as! String, font, width, font * 1.2, CGPoint(x: origin[0], y: origin[1])),
                    fontSize: font, panels: (r["panels"] as! [[Double]]).map {
                        let box = rect($0)
                        return .init(rect: box, background: [240,240,235], coverage: [box])
                    }, sampledForeground: [30,30,30], sampledStroke: nil, sampledBackground: [240,240,235])
            }
            let result = NativeTranslationOversizedTitleGloss.refining(records: records, frame: frame, image: nil,
                keptSources: [], erased: [], measure: measure, placerFactory: { f,s,fill,ground,_ in
                    NativeTranslationGlossPlacement(frame: f, band: s, fill: fill, ground: ground) { _,_,w,h in
                        Array(repeating: [UInt8(240),240,235,255], count: w*h).flatMap { $0 }
                    }
                })
            output.append(result.records.map { r -> [String: Any] in
                let note = result.gloss.notes.first { $0.id == r.id }
                let ink: CGRect
                if let note {
                    let p = note.placement, move = p.moves[0]
                    ink = measure(r.id, r.text, p.size, p.width, p.lineHeight, note.origin).offsetBy(dx: move.x, dy: move.y)
                } else { ink = r.ink }
                return ["id":r.id,"ink":array(ink),"font":note?.placement.size ?? r.fontSize,"panels":r.panels.map { array($0.rect) },
                    "preserved":r.preservedErasure,"gloss":note != nil]
            })
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
    }
}
