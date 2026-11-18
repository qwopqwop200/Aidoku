#!/usr/bin/env python3
"""Exercise native balloon paper ownership on asymmetric and returning necks."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'Aidoku/Core/Translation/ReaderTranslationEnclosedBackground.swift').read_text()
start = source.index('    static func attachingBalloonInteriors(')
end = source.index('    private struct Component {', start)
source = source[:start] + source[end:]
harness = r'''
func image(_ narrow: Bool, _ returning: Bool, _ transpose: Bool, _ scale: Int) -> CGImage {
    let size = 320 * scale
    var pixels = [UInt8](repeating: 70, count: size * size)
    for py in 0..<size { for px in 0..<size {
        let x = (transpose ? py : px) / scale, y = (transpose ? px : py) / scale
        let neck = narrow && (86...94).contains(x)
        let paper = (25...210).contains(x) && (neck ? (85...115).contains(y) : (35...165).contains(y))
        // A returning portion of the same balloon surrounds another dark/art island.
        // Full min/max component extent at the neck falsely measures this as 131 px.
        let returnPaper = returning && (30...165).contains(y) && ((80...100).contains(x) && (35...60).contains(y) ||
            (80...100).contains(x) && (140...165).contains(y) || (80...84).contains(x))
        if paper || returnPaper { pixels[py * size + px] = 255 }
    } }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width:size,height:size,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:size,
        space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,
        decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}
var checked = 0
for scale in [1, 2, 4] { for transpose in [false, true] { for returning in [false, true] { for narrow in [false, true] {
    let s = CGFloat(scale)
    func box(_ x: CGFloat) -> CGRect {
        transpose ? CGRect(x:90*s,y:x*s,width:20*s,height:20*s) : CGRect(x:x*s,y:90*s,width:20*s,height:20*s)
    }
    let a = box(55), b = box(160), map = ReaderTranslationEnclosedBackground.ComponentMap(image:image(narrow,returning,transpose,scale))
    let component = map.balloon(of:a)!
    precondition(component == map.balloon(of:b), "fixture must have one connected bounded paper")
    for reversed in [false, true] { for lobe in [false, true] {
        let actual = map.sharesBalloonInterior(reversed ? b : a,reversed ? a : b,component:component,lobe:lobe)
        precondition(actual == !narrow, "neck=\(narrow) returning=\(returning) transpose=\(transpose) scale=\(scale) reverse=\(reversed) lobe=\(lobe) actual=\(actual)")
        checked += 1
    } }
} } } }
print("BALLOON_NECK_PASS cases=\(checked) axes=horizontal,vertical scales=1,2,4 orders=forward,reverse")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-balloon-neck-') as temporary:
    path = Path(temporary)
    (path / 'main.swift').write_text(source + harness)
    subprocess.run(['swiftc', '-O', str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
