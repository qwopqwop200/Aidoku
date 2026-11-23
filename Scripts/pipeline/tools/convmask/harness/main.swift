import CoreGraphics
import Foundation
import ImageIO
import CoreML

// harness RUN_PREFIX OUT [PAGE...]: rebuild S6 masks from saved page JSON blocks (RUN_PREFIX_{dev,train,test}/pages);
// targets = blocks with role != background. BLOCKS=1 instead dumps per-block geometry (frame, T, background, poly/roi).
let a = CommandLine.arguments
let prefix = a[1], out = URL(fileURLWithPath: a[2])
let dumpBlocks = ProcessInfo.processInfo.environment["BLOCKS"] == "1"
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func pt(_ v: Any) -> CGPoint { let p = v as! [Double]; return CGPoint(x: p[0], y: p[1]) }
func rect(_ v: Any) -> CGRect { let r = v as! [[Double]]; return CGRect(x: r[0][0], y: r[0][1], width: r[1][0], height: r[1][1]) }
func find(_ pid: String) -> [String: Any]? {
    for sp in ["dev", "train", "test"] {
        if let d = try? Data(contentsOf: URL(fileURLWithPath: "\(prefix)_\(sp)/pages/\(pid).json")) {
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
    }
    return nil
}
var total = 0.0
// MASKNET=path.mlpackage: run the conv classifier instead of the MLP.
let net: PipelineMaskNet? = ProcessInfo.processInfo.environment["MASKNET"].map { path in
    try! PipelineMaskNet(compiledURL: try! MLModel.compileModel(at: URL(fileURLWithPath: path)))
}
for pid in a.dropFirst(3) {
    guard let rec = find(pid) else { continue }
    let url = URL(fileURLWithPath: rec["image"] as! String)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
    var blocks: [PipelineBlock] = []
    for b in rec["blocks"] as! [[String: Any]] {
        guard (b["role"] as? String) != "background" else { continue }
        let id = (b["id"] as? Int) ?? Int(b["id"] as! String)!
        let lines = (b["lines"] as! [[String: Any]]).map { l in
            PipelineLine(polygon: (l["polygon"] as! [Any]).map(pt), bounds: rect(l["bounds"]!), vertical: (l["vertical"] as? Bool) ?? false,
                   detectionScore: 1)
        }
        blocks.append(PipelineBlock(id: id, lines: lines, bounds: rect(b["bounds"]!), polygon: (b["polygon"] as? [Any] ?? []).map(pt),
                              vertical: (b["vertical"] as? Bool) ?? false, readingOrder: 0, sourceText: (b["sourceText"] as? String) ?? ""))
    }
    let page = PipelinePage(id: pid, image: image)
    var layout: [PipelineLayoutRegion] = []
    if let ld = ProcessInfo.processInfo.environment["LAYOUT_DUMP"],
       let x = try? Data(contentsOf: URL(fileURLWithPath: "\(ld)/\(pid).json")),
       let d = try? JSONSerialization.jsonObject(with: x) as? [String: Any] {
        for q in d["layout"] as! [[String: Any]] {
            layout.append(PipelineLayoutRegion(kind: PipelineLayoutKind(rawValue: q["kind"] as! String) ?? .other, bounds: rect(q["bounds"]!),
                                         score: Float(q["score"] as! Double)))
        }
    }
    if dumpBlocks {
        guard let rgba = PipelineRemovalMask.rgbaBytes(image) else { continue }
        var infos: [[String: Any]] = []
        var blob = Data()
        for block in blocks {
            guard let g = PipelineRemovalMask.geometry(block, width: page.width, height: page.height) else { continue }
            let r = PipelineRemovalMask.regions(g)
            let bg = rgba.withUnsafeBufferPointer { PipelineRemovalMask.background(r, frame: g.frame, pixels: $0, width: page.width) }
            infos.append(["id": block.id, "frame": [g.frame.x, g.frame.y, g.frame.width, g.frame.height], "T": g.thickness,
                          "bg": [bg.0, bg.1, bg.2], "offset": blob.count])
            blob.append(contentsOf: r.poly); blob.append(contentsOf: r.roi)
        }
        try JSONSerialization.data(withJSONObject: ["w": page.width, "h": page.height, "blocks": infos])
            .write(to: out.appendingPathComponent("\(pid).json"))
        try (blob as NSData).compressed(using: .zlib).write(to: out.appendingPathComponent("\(pid).b"))
        continue
    }
    let t0 = DispatchTime.now().uptimeNanoseconds
    let m = PipelineRemovalMask.build(page, blocks: blocks, layout: layout, net: net)
    total += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    try (Data(m) as NSData).compressed(using: .zlib).write(to: out.appendingPathComponent("\(pid).z"))
    try JSONSerialization.data(withJSONObject: ["w": page.width, "h": page.height, "ids": blocks.map(\.id)])
        .write(to: out.appendingPathComponent("\(pid).json"))
}
FileHandle.standardError.write(Data("S6 total ms \(total)\n".utf8))
