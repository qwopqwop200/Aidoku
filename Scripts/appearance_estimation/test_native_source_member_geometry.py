"""Compile the shared production geometry resolver without a shared app build."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class NativeSourceMemberGeometryTests(unittest.TestCase):
    def test_authoritative_source_polygons(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / 'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeSourceInputFactory.swift').read_text()
        resolver = source[source.index('    static func memberPolygons('):source.index('    static func contexts(')]
        smoke = r'''
let polygon: [[[Double]]] = [[[20,22],[38,20],[42,78],[22,80]]]
let polygon2: [[[Double]]] = [[[50,22],[68,20],[72,78],[52,80]]]
let first: [Double] = [0.2,0.2,0.22,0.6]
let second: [Double] = [0.5,0.2,0.22,0.6]
let size=CGSize(width:100,height:100)
let fallback=[CGPoint(x:0,y:0),CGPoint(x:100,y:0),CGPoint(x:100,y:100)]
func resolve(_ item:[String:Any],_ rows:[[String:Any]] = []) throws -> [[CGPoint]] {
    try NativeSourceInputFactory.memberPolygons(item:item,originalRows:rows,recognizedRows:[],pageSize:size,fallback:fallback)
}
let expected=polygon[0].map {CGPoint(x:$0[0],y:$0[1])}
precondition(try resolve(["sourceMemberPolygons":polygon]) == [expected])
precondition(try resolve(["sourceBounds":first,"sourceMemberPolygons":[]],
    [["sourceBounds":first,"sourceMemberPolygons":polygon]]) == [expected])
let grouped=try resolve(["sourceBounds":[0.2,0.2,0.52,0.6],"unitMemberRects":[first,second]],
    [["sourceBounds":first,"sourceMemberPolygons":polygon],["sourceBounds":second,"sourceMemberPolygons":polygon2]])
precondition(grouped.count==2 && grouped[0]==expected && grouped[1][0]==CGPoint(x:50,y:22))
precondition(try resolve(["sourceMemberPolygons":[]]) == [fallback])
let unclipped: [Double] = [0.2,-0.02,0.22,0.62]
let visible: [Double] = [0.2,0,0.22,0.6]
let crossing: [String:Any] = ["sourceBounds":visible,"sourceMemberPolygons":polygon,
    "sourceGeometryObservation":["rectClipped":true,"inputCoordinateSpace":"normalized-top-left","rawRect":unclipped] as [String:Any]]
let other: [String:Any] = ["sourceBounds":visible,"sourceMemberPolygons":polygon2]
precondition(try resolve(["sourceBounds":unclipped], [other,crossing]) == [expected])
precondition(try resolve(["sourceBounds":visible], [crossing,other]) == [polygon2[0].map {CGPoint(x:$0[0],y:$0[1])}])
for rect: [Double] in [[0.2,-0.02,0.2,0.6],[-0.02,0.2,0.6,0.2],[0.2,0.8,0.2,0.22],[0.8,0.2,0.22,0.2]] {
    let result = try resolve(["unitMemberRects":[rect]])[0]
    precondition(result.count == 4 && result.allSatisfy { (0...100).contains($0.x) && (0...100).contains($0.y) })
}
for rect: [Double] in [[-0.4,0.2,0.1,0.1],[0.2,1.0,0.2,0.1],[0.2,0.2,0.0,0.3]] {
    do {_ = try resolve(["unitMemberRects":[rect]]); preconditionFailure("Invisible source member was accepted")} catch {}
}
let malformed:[Any] = [[[[Double.nan,0],[1,0],[1,1]]],[[[0,0],[1,0],[101,1]]],[[[0,0],[1,1],[2,2]]],"bad"]
for value in malformed {
    var failed=false
    do {_ = try resolve(["sourceMemberPolygons":value,"unitMemberRects":[first]])} catch {failed=true}
    precondition(failed,"Known malformed geometry was silently rectangularized")
}
let original=[CGPoint(x:10,y:20),CGPoint(x:50,y:10),CGPoint(x:70,y:70),CGPoint(x:20,y:80)]
let crop=CGRect(x:20,y:20,width:40,height:40)
let feature=try NativeSourceInputFactory.featureGeometry(members:[original],merged:original,crop:crop)
precondition(original[0]==CGPoint(x:10,y:20))
precondition(feature.polygons[0].count>=4 && feature.polygons[0] != [CGPoint(x:20,y:20),CGPoint(x:60,y:20),CGPoint(x:60,y:60),CGPoint(x:20,y:60)])
precondition(feature.polygons[0].allSatisfy {$0.x>=20 && $0.x<=60 && $0.y>=20 && $0.y<=60})
precondition(feature.audit["cropExpanded"] as? Bool == false)
precondition(feature.audit["predictedMaskBBoxClipped"] as? Bool == false)
let edge=[CGPoint(x:20,y:20),CGPoint(x:60,y:20),CGPoint(x:60,y:60),CGPoint(x:20,y:60)]
let unchanged=try NativeSourceInputFactory.featureGeometry(members:[edge],merged:edge,crop:crop)
precondition(unchanged.polygons==[edge])
print("PASS direct, matched, grouped, legacy-empty, malformed global source geometry")
'''
        # Swift's precondition autoclosure is nonthrowing.
        smoke = smoke.replace('precondition(try resolve(', 'try check(resolve(')
        header = '''import Foundation\nimport CoreGraphics\nenum NativeSourceInputFactory {enum Failure:Error {case sourceMismatch,geometryOutsideCrop(String)}\n'''
        check = '\nfunc check(_ condition: Bool) { precondition(condition) }\n'
        with tempfile.TemporaryDirectory(prefix='aidoku-source-member-') as folder:
            main=Path(folder)/'main.swift'; binary=Path(folder)/'geometry'
            main.write_text(header+resolver+'}\n'+check+smoke)
            subprocess.run(['swiftc',str(main),'-o',str(binary)],check=True,capture_output=True,text=True)
            result=subprocess.run([str(binary)],check=True,capture_output=True,text=True)
            self.assertIn('PASS',result.stdout)


if __name__ == '__main__': unittest.main()
