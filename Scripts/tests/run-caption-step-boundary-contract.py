#!/usr/bin/env python3
"""Independent raster controls for same-component stepped caption boundaries.

Set AIDOKU_TEST_ENCLOSED_SOURCE to an isolated candidate. Production is read only.
The masks are synthetic and contain no image-derived pixels or text.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source_path = Path(os.environ.get('AIDOKU_TEST_ENCLOSED_SOURCE', str(
    ROOT / 'Aidoku/Core/Translation/ReaderTranslationEnclosedBackground.swift')))
source = source_path.read_text()
start = source.index('    static func attachingBalloonInteriors(')
end = source.index('    private struct Component {', start)
source = source[:start] + source[end:]
harness = r'''
func makeImage(_ kind: String, _ scale: Int) -> CGImage {
    let size = 512 * scale
    var pixels = [UInt8](repeating: kind == "lightBoundary" ? 210 : 70, count: size * size)
    for py in 0..<size { for px in 0..<size {
        let x = Double(px) / Double(scale), y = Double(py) / Double(scale)
        let step = (275...355).contains(x) && (55...300).contains(y) ||
                   (175...275).contains(x) && (130...300).contains(y)
        var paper = step
        if kind == "rectangle" || kind == "glyphHoles" {
            paper = (175...355).contains(x) && (55...300).contains(y)
        }
        if kind == "ellipse" {
            paper = pow((x - 265) / 115, 2) + pow((y - 180) / 155, 2) <= 1
        }
        if kind == "slopedTop" {
            let top = 55 + max(0, 275 - x) * 0.75
            paper = (175...355).contains(x) && y >= top && y <= 300
        }
        if kind == "returningPaper" {
            paper = paper || (175...290).contains(x) && (55...65).contains(y) ||
                (175...180).contains(x) && (55...145).contains(y)
        }
        if kind == "glyphHoles" && (190...255).contains(x) && (100...110).contains(y) {
            paper = false
        }
        if kind == "jaggedTop" && step {
            let top = x >= 275 ? 55.0 : 130.0
            if y < top + Double(Int(x / 5) % 2) * 5 { paper = false }
        }
        if kind == "twoComponents", (20...135).contains(x), (50...350).contains(y) { paper = true }
        if paper { pixels[py * size + px] = 255 }
    } }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width:size,height:size,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:size,
        space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,
        decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}
var checked = 0, failures = 0
for scale in [1, 2, 4] {
    for kind in ["step", "rectangle", "ellipse", "slopedTop", "returningPaper", "glyphHoles", "jaggedTop", "lightBoundary"] {
        let s = CGFloat(scale)
        let a = CGRect(x:285*s,y:70*s,width:24*s,height:200*s)
        let b = CGRect(x:245*s,y:145*s,width:24*s,height:125*s)
        for reverse in [false, true] {
            let map = ReaderTranslationEnclosedBackground.ComponentMap(image:makeImage(kind,scale))
            let first = reverse ? b : a, second = reverse ? a : b
            let ca = map.component(of:first), cb = map.component(of:second)
            guard let id = ca, cb == id else {
                print("FIXTURE_FAIL",kind,scale,reverse,String(describing:ca),String(describing:cb))
                failures += 1; continue
            }
            let actual = map.separates(first,second)
            let expected = kind == "step"
            if actual != expected {
                print("FAIL",kind,scale,reverse,"expected",expected,"actual",actual)
                failures += 1
            }
            checked += 1
        }
    }
}
for scale in [1, 2, 4] { for kind in ["step", "rectangle"] { for prime in [false, true] { for reverse in [false, true] {
    let s = CGFloat(scale), map = ReaderTranslationEnclosedBackground.ComponentMap(image:makeImage(kind,scale))
    let a = CGRect(x:285*s,y:70*s,width:24*s,height:200*s)
    let b = CGRect(x:245*s,y:145*s,width:24*s,height:125*s)
    if prime { _ = map.separates(reverse ? b : a,reverse ? a : b) }
    let expanded = [CGRect(x:280*s,y:70*s,width:55*s,height:200*s), CGRect(x:205*s,y:145*s,width:65*s,height:125*s)]
    let boxes = reverse ? Array(expanded.reversed()) : expanded
    let interiors = map.balloonInteriors(of:boxes,candidates:[true,true])
    let expected: [Int] = kind == "step" && prime ? [-1,-1] : [2,2]
    if interiors.map({$0?.members ?? -1}) != expected {
        print("SHARED_FAIL",kind,scale,prime,reverse,interiors.map{$0?.members ?? -1})
        failures += 1
    }
    checked += 1
} } } }
for scale in [1, 2, 4] { for variant in ["bothInOneGroup", "missingSecond", "otherComponent"] { for reverse in [false,true] {
    let s = CGFloat(scale), kind = variant == "otherComponent" ? "twoComponents" : "step"
    let image = makeImage(kind,scale)
    let certified = ReaderTranslationEnclosedBackground.ComponentMap(image:image)
    let fresh = ReaderTranslationEnclosedBackground.ComponentMap(image:image)
    let a = CGRect(x:285*s,y:70*s,width:24*s,height:200*s)
    let b = CGRect(x:245*s,y:145*s,width:24*s,height:125*s)
    precondition(certified.separates(reverse ? b : a,reverse ? a : b))
    let raw: [CGRect]
    switch variant {
    case "bothInOneGroup": raw = [CGRect(x:205,y:70,width:130,height:200),CGRect(x:210,y:278,width:30,height:12)]
    case "missingSecond": raw = [CGRect(x:280,y:70,width:55,height:200),CGRect(x:185,y:150,width:30,height:110)]
    default: raw = [CGRect(x:35,y:70,width:30,height:180),CGRect(x:85,y:100,width:30,height:150)]
    }
    let scaled = raw.map{CGRect(x:$0.minX*s,y:$0.minY*s,width:$0.width*s,height:$0.height*s)}
    let boxes = reverse ? Array(scaled.reversed()) : scaled
    let actual = certified.balloonInteriors(of:boxes,candidates:[true,true])
    let expected = fresh.balloonInteriors(of:boxes,candidates:[true,true])
    if actual != expected {
        print("UNRELATED_CACHE_FAIL",variant,scale,reverse); failures += 1
    }
    checked += 1
} } }
print("CAPTION_STEP_CONTRACT cases=\(checked) failures=\(failures)")
if failures != 0 { exit(1) }
'''
if 'func separateCaptionOwnerIndices(' in source:
    harness = harness.replace('    let interiors = map.balloonInteriors(of:boxes,candidates:[true,true])', r'''    let actualOwners = map.separateCaptionOwnerIndices(of:boxes)
    let expectedOwners: Set<Int> = kind == "step" && prime ? [0,1] : []
    if actualOwners != expectedOwners { failures += 1; print("SOURCE_SLOT_OWNER_FAIL",kind,scale,prime,reverse,actualOwners) }
    checked += 1
    let interiors = map.balloonInteriors(of:boxes,candidates:[true,true])''')
    harness = harness.replace('    let actual = certified.balloonInteriors(of:boxes,candidates:[true,true])', r'''    if !certified.separateCaptionOwnerIndices(of:boxes).isEmpty || !fresh.separateCaptionOwnerIndices(of:boxes).isEmpty {
        failures += 1; print("UNRELATED_SOURCE_SLOT_OWNER_FAIL",variant,scale,reverse)
    }
    checked += 1
    let actual = certified.balloonInteriors(of:boxes,candidates:[true,true])''')
with tempfile.TemporaryDirectory(prefix='aidoku-caption-step-audit-') as temporary:
    p = Path(temporary)
    (p / 'main.swift').write_text(source + harness)
    subprocess.run(['swiftc', '-O', str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
