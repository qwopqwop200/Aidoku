"""Actual polygon coverage/SFX regression, using production Swift geometry."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
geometry = root / 'Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRLocalCoordinates.swift'
checks = r'''
import CoreGraphics
import Foundation
let diamond = [CGPoint(x:50,y:0),CGPoint(x:100,y:50),CGPoint(x:50,y:100),CGPoint(x:0,y:50)]
func referenceContains(_ polygon:[CGPoint],_ point:CGPoint)->Bool {
    guard let q=NativeOCRDirectionGeometry.cycle(polygon) else { return false }
    return q.indices.allSatisfy { i in
        let a=q[i],b=q[(i+1)%4]
        return (b.x-a.x)*(point.y-a.y)-(b.y-a.y)*(point.x-a.x) >= -0.000001
    }
}
for angle in stride(from:0.0,to:360.0,by:5) {
    let a=angle*Double.pi/180
    let p=diamond.map { q in CGPoint(x:150+q.x*cos(a)-q.y*sin(a),y:150+q.x*sin(a)+q.y*cos(a)) }
    for q in [p,[p[0],p[3],p[2],p[1]],[p[0],p[2],p[1],p[3]]] {
        let prepared=NativeOCRDirectionGeometry.Containment(q)!
        let samples = q + q.map { CGPoint(x:$0.x+0.0000001,y:$0.y-0.0000001) } +
            stride(from:40.0,through:280.0,by:8).flatMap { x in
                stride(from:40.0,through:280.0,by:8).map { CGPoint(x:x,y:$0) }
            }
        for point in samples {
            precondition(prepared.contains(point)==referenceContains(q,point),"prepared support must preserve every cell")
        }
    }
}
precondition(NativeOCRDirectionGeometry.Containment([])==nil)
print("Prepared containment parity passed: 72 rotations, winding/order variants, grid and boundary samples")
precondition(abs(NativeOCRDirectionGeometry.area(diamond)-5000)<0.000001)
let corner = CGRect(x:0,y:0,width:10,height:10)
precondition(NativeOCRDirectionGeometry.bounds(diamond).intersects(corner))
precondition(NativeOCRDirectionGeometry.intersectionArea(diamond,corner)==0,"AABB-only SFX conflict must disappear")
precondition(abs(NativeOCRDirectionGeometry.coverage(diamond,by:CGRect(x:0,y:0,width:50,height:100))-0.5)<0.000001)
precondition(NativeOCRDirectionGeometry.coverage(diamond,by:CGRect(x:0,y:0,width:100,height:100))==1)
for angle in stride(from:0.0,to:360.0,by:5) {
    let a=angle*Double.pi/180
    let p=diamond.map { q in CGPoint(x:150+(q.x-50)*cos(a)-(q.y-50)*sin(a),y:150+(q.x-50)*sin(a)+(q.y-50)*cos(a)) }
    precondition(abs(NativeOCRDirectionGeometry.area(p)-5000)<0.000001)
    precondition(abs(NativeOCRDirectionGeometry.coverage(p,by:CGRect(x:50,y:50,width:100,height:200))-0.5)<0.000001)
    let reverse=[p[0],p[3],p[2],p[1]]
    precondition(abs(NativeOCRDirectionGeometry.intersectionArea(reverse,CGRect(x:50,y:50,width:100,height:200))-2500)<0.000001)
}
let axis=[CGPoint(x:10,y:20),CGPoint(x:30,y:20),CGPoint(x:30,y:100),CGPoint(x:10,y:100)]
precondition(NativeOCRDirectionGeometry.intersectionArea(axis,CGRect(x:20,y:10,width:40,height:100))==800)
print("Polygon RF support/SFX checks passed: axis parity, corner rejection, 72 rotations and reverse winding")
let regressionQuad = [CGPoint(x:1494.918310897331,y:2315.9005470007137),
    CGPoint(x:1554.918310897331,y:2314.9005470007137),
    CGPoint(x:1558.0278534612237,y:2547.0797251047015),
    CGPoint(x:1498.0278534612237,y:2548.0797251047015)]
precondition(NativeOCRDirectionGeometry.readingQuad(regressionQuad)==regressionQuad)
for angle in stride(from:0.0,to:360.0,by:5) {
    let a=angle*Double.pi/180
    let p=regressionQuad.map { q in CGPoint(x:q.x*cos(a)-q.y*sin(a),y:q.x*sin(a)+q.y*cos(a)) }
    let expected=NativeOCRDirectionGeometry.readingQuad(p)!
    for offset in 0..<4 {
        let shifted=(0..<4).map { p[($0+offset)%4] }
        precondition(NativeOCRDirectionGeometry.readingQuad(shifted)==expected,"untyped vertex zero cannot rotate OCR")
        let reverse=[shifted[0],shifted[3],shifted[2],shifted[1]]
        precondition(NativeOCRDirectionGeometry.readingQuad(reverse)==expected,"winding cannot rotate OCR")
    }
    precondition(Set(expected.map { "\($0.x),\($0.y)" })==Set(p.map { "\($0.x),\($0.y)" }),"no AABB flattening")
    precondition(NativeOCRDirectionGeometry.directedQuad(p)==p,"trusted local-axis direction must remain explicit")
}
for offset in 0..<4 {
    let shifted=(0..<4).map { diamond[($0+offset)%4] }
    precondition(NativeOCRDirectionGeometry.readingQuad(shifted)==NativeOCRDirectionGeometry.readingQuad(diamond),
        "equal-slope diamond tie is independent of initial index")
}
print("Reading-basis regression passed: 72 rotations, all cyclic starts, reverse winding, ties, trusted-direction preservation")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-direction-polygon-') as tmp:
    folder=Path(tmp)
    main=folder/'main.swift'
    main.write_text(checks)
    binary=folder/'checks'
    subprocess.run(['swiftc','-O','-module-cache-path',str(root/'build/image-translation-host/rf-primary-module-cache'),
                    str(geometry),str(main),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
