"""Execute original-gutter production code against gradients and thin border controls."""
from pathlib import Path
import re
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
source = (repo/'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeEnsembleOwnership.swift').read_text()
def block(pattern):
    match = re.search(pattern, source)
    assert match, pattern
    start = source.index('{', match.start())
    depth, end = 1, start+1
    while depth:
        depth += (source[end]=='{')-(source[end]=='}')
        end += 1
    return source[match.start():end]
swift = 'import Foundation\nimport CoreGraphics\nenum Witness {\n'+ '\n'.join([
    block(r'    private struct Pixels \{'),
    *[block(r'    (?:private )?static func '+name+r'\(')
      for name in ('number','rect','scale','distance','originalLocalGutterEvidence')]]) + '\n}\n'+r'''
func image(border:Bool=false,alpha:Bool=false)->CGImage {
    let w=200,h=200
    var data=[UInt8](repeating:255,count:w*h*4)
    for y in 0..<h {for x in 0..<w {
        let i=(y*w+x)*4
        let value=border && (99...100).contains(x) ? 0 : 90+y/3+x/10
        for c in 0..<3 {data[i+c]=UInt8(value)}
        if alpha {data[i+3]=128}
    }}
    let provider=CGDataProvider(data:Data(data) as CFData)!
    return CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
        provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}
let a:[String:Any]=["sourceBounds":[0.3,0.1,0.12,0.7]]
let b:[String:Any]=["sourceBounds":[0.58,0.1,0.12,0.7]]
precondition(Witness.originalLocalGutterEvidence(a,b,original:image()) != nil)
precondition(Witness.originalLocalGutterEvidence(a,b,original:image(border:true)) == nil)
precondition(Witness.originalLocalGutterEvidence(a,b,original:image(alpha:true)) == nil)
precondition(Witness.originalLocalGutterEvidence(a,b,original:image(),budget:4) == nil)
precondition(Witness.originalLocalGutterEvidence(a,a,original:image()) == nil)
print("local original gutter: gradient, thin border, alpha, memory budget, overlap controls passed")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-local-gutter-') as folder:
    path=Path(folder)/'main.swift'
    path.write_text(swift)
    binary=Path(folder)/'check'
    subprocess.run(['swiftc','-module-cache-path',str(repo/'build/image-translation-host/module-cache'),
                    str(path),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
