"""Production Latin quad normalization: full rotations and cyclic starts."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
ocr = root / 'Aidoku/Core/Translation/NativeEngine/OCR'
pipeline = (ocr / 'NativeCoreMLOCRPipeline.swift').read_text()
scope = 'enum NativeOCRScopeGeometry {' + pipeline.split('enum NativeOCRScopeGeometry {', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
checks = r'''
setenv("AIDOKU_OCR_ORIENTED_PATHS","latin",1)
for degrees in stride(from:0.0,to:360.0,by:5) {
    let a=degrees*Double.pi/180
    let original=[CGPoint(x:-60,y:-12),CGPoint(x:60,y:-12),CGPoint(x:60,y:12),CGPoint(x:-60,y:12)]
    let points=original.map { p in CGPoint(x:200+p.x*cos(a)-p.y*sin(a),y:200+p.x*sin(a)+p.y*cos(a)) }
    var reference:[CGPoint]?
    for offset in 0..<4 {
        let shifted=(0..<4).map { points[($0+offset)%4] }
        for p in [shifted,[shifted[0],shifted[3],shifted[2],shifted[1]]] {
            let q=NativeOCRScopeGeometry.alternateHorizontalQuad(p) ?? NativeOCRScopeGeometry.canonicalQuad(p)!
            let size=NativeOCRDirectionGeometry.edgeSize(q)!
            precondition(abs(size.width-120)<0.000001 && abs(size.height-24)<0.000001)
            precondition(Set(q.map { "\($0.x),\($0.y)" })==Set(points.map { "\($0.x),\($0.y)" }))
            if let reference { precondition(q==reference,"vertex zero/winding cannot reverse a Latin baseline") }
            else { reference=q }
        }
    }
}
print("Latin baseline checks passed: 72 rotations, cyclic starts, reverse winding, original angles")
'''
with tempfile.TemporaryDirectory(prefix='latin-baseline-') as tmp:
    folder = Path(tmp)
    main = folder / 'main.swift'
    main.write_text('import Foundation\nimport CoreGraphics\n' + scope + checks)
    binary = folder / 'checks'
    subprocess.run(['swiftc', '-O', '-module-cache-path', str(root / 'build/image-translation-host/rf-primary-module-cache'),
                    str(ocr / 'NativeOCRLocalCoordinates.swift'), str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
