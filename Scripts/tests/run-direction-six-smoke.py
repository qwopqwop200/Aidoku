"""Exercise production six-path geometry with synthetic evidence, without models."""
import ast
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
tree = ast.parse((root/'Scripts/tests/run-ocr-rf-primary-smoke.py').read_text())
stubs = next(ast.literal_eval(n.value) for n in tree.body
             if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'stubs' for t in n.targets))
ocr = root/'Aidoku/Core/Translation/NativeEngine/OCR'
stubs = stubs.replace('struct NativeOCRDetectorSeedEvidence: Sendable { var components: [Int] = [] }', '')
stubs += ''.join((ocr/name).read_text() for name in [
    'NativeOCRSourceROIProbabilityEvidence.swift','NativeOCRDetectorSeedEvidence.swift'])
production = ''.join((ocr/name).read_text() for name in ['NativeOCRLocalCoordinates.swift', 'NativeOCRDirectionAdapters.swift', 'NativeOCRIndependentLanes.swift'])
production += (ocr/'NativeOCRRFGapRecovery.swift').read_text().split('/// RF + ORIGINAL pixels nominate missing lines',1)[0]
checks = r'''
setenv("AIDOKU_OCR_ORIENTED_PATHS","groups,rfShape,mixedDirections,unanchored,pixelLocal,lanes,missing,narrow",1)
func rect(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat)->[CGPoint] {
    NativeOCRDirectionGeometry.corners(CGRect(x:x,y:y,width:w,height:h))
}
// A rectified ROI must not silently rescale or shift an existing DB lattice.
let latticeValues=(0..<(112*86)).map { Float($0 % 251)/251 }
let latticeMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:260,sourceHeight:195,
    resizedWidth:112,resizedHeight:86,region:CGRect(x:0,y:0,width:112,height:86),
    width:112,height:86,values:latticeValues)
let latticeBasis=NativeOCRDirectionGeometry.Frame(rect(83,21,24,109))!
let latticeWindow=NativeOCRDirectionGeometry.Window(frame:latticeBasis,
    world:CGRect(x:70,y:15,width:54,height:120),lattice:CGSize(width:65,height:195))!
let transported=NativeOCRDirectionAdapters.probability(latticeMap,window:latticeWindow,
    spacing:CGSize(width:260.0/112,height:195.0/86))!
for y in 0..<transported.height { for x in 0..<transported.width {
    let p=latticeWindow.restore(CGPoint(x:(CGFloat(x)+0.5)*CGFloat(latticeWindow.width)/CGFloat(transported.width),
        y:(CGFloat(y)+0.5)*CGFloat(latticeWindow.height)/CGFloat(transported.height)))
    let xx=Int(floor(p.x*112/260)), yy=Int(floor(p.y*86/195))
    let expected:Float = xx>=0 && yy>=0 && xx<112 && yy<86 ? latticeValues[yy*112+xx] : 0
    precondition(transported.values[y*transported.width+x]==expected,"original DB cell phase must survive local transport")
} }
// Preparing support winding once must retain the exact probability values,
// including invalid support, preserved owner islands and boundary cells.
let mask=NativeOCRDirectionGeometry.corners(CGRect(x:80,y:20,width:20,height:90))
let preserved=[NativeOCRDirectionGeometry.corners(CGRect(x:105,y:40,width:14,height:20))]
for support in [mask,Array(mask.reversed()),[]] {
    let masked=NativeOCRDirectionAdapters.probability(latticeMap,window:latticeWindow,
        support:support,preserving:preserved,spacing:CGSize(width:260.0/112,height:195.0/86))!
    precondition(masked.width==transported.width && masked.height==transported.height)
    for y in 0..<masked.height { for x in 0..<masked.width {
        let p=latticeWindow.restore(CGPoint(x:(CGFloat(x)+0.5)*CGFloat(latticeWindow.width)/CGFloat(masked.width),
            y:(CGFloat(y)+0.5)*CGFloat(latticeWindow.height)/CGFloat(masked.height)))
        let retained=NativeOCRDirectionGeometry.contains(support,p) || preserved.contains {
            NativeOCRDirectionGeometry.contains($0,p)
        }
        precondition(masked.values[y*masked.width+x]==(retained ? transported.values[y*masked.width+x]:0),
            "prepared support must preserve original probability lattice exactly")
    } }
}
for degrees in stride(from:0.0,to:360.0,by:15) {
    let a=degrees*Double.pi/180
    func rotate(_ p:CGPoint)->CGPoint { CGPoint(x:200+(p.x-200)*cos(a)-(p.y-200)*sin(a),y:200+(p.x-200)*sin(a)+(p.y-200)*cos(a)) }
    let boxes=[NativeCoreMLDetectionBox(polygon:rect(192,150,16,35).map(rotate),score:0.9),
               NativeCoreMLDetectionBox(polygon:rect(192,195,16,35).map(rotate),score:0.9)]
    let support=rect(185,140,30,100).map(rotate)
    var primitive=NativeRFDETRLayoutPrimitive(queryID:1,semanticClass:.text,confidence:0.9,
        sourceBounds:NativeOCRDirectionGeometry.bounds(support))
    primitive.supportPolygon=support
    let layout=NativeRFDETRLayoutResult(sourceWidth:400,sourceHeight:400,primitives:[primitive])
    let plan=NativeOCRRFPrimaryEnsemble.plan(boxes:boxes,layout:layout,width:400,height:400)
    precondition(plan.groups.count==1,"rotated DB fragments must join: \(degrees)")
    precondition(Set(plan.groups[0].members)==Set([0,1]),"original owner indices must survive")
    let polygon=plan.boxes[plan.groups[0].index].polygon
    precondition(abs(NativeOCRDirectionGeometry.area(polygon)-1280)<0.01,"group must not become world AABB")
    let f=NativeOCRDirectionGeometry.Frame(boxes[0].polygon)!
    let w=NativeOCRDirectionAdapters.window(f,scope:primitive.sourceBounds,boxes:boxes)!
    let local=NativeOCRDirectionAdapters.layout(layout,primitives:[primitive],window:w).primitives[0]
    precondition(abs(NativeOCRDirectionGeometry.area(local.supportPolygon!)-3000)<0.01,"RF support area cannot inflate")
    let touching=[NativeCoreMLDetectionBox(polygon:rect(190,150,14,55.5).map(rotate),score:0.9),
        NativeCoreMLDetectionBox(polygon:[CGPoint(x:185.5,y:206),CGPoint(x:205,y:205.5),
            CGPoint(x:207,y:299),CGPoint(x:187.5,y:299.5)].map(rotate),score:0.9)]
    let contactSupport=rect(180,140,50,170).map(rotate)
    var contactRF=NativeRFDETRLayoutPrimitive(queryID:2,semanticClass:.text,confidence:0.9,
        sourceBounds:NativeOCRDirectionGeometry.bounds(contactSupport))
    contactRF.supportPolygon=contactSupport
    let contactLayout=NativeRFDETRLayoutResult(sourceWidth:400,sourceHeight:400,primitives:[contactRF])
    let contactPlan=NativeOCRRFPrimaryEnsemble.plan(boxes:touching,layout:contactLayout,width:400,height:400)
    precondition(contactPlan.groups.count==1,"projected contact must not split real DB fragments: \(degrees)")
}
let partialRF=NativeRFDETRLayoutPrimitive(queryID:8,semanticClass:.text,confidence:0.9,
    sourceBounds:CGRect(x:104,y:90,width:30,height:150))
precondition(NativeOCRDirectionAdapters.supportsExpansion(rect(100,100,20,120),
    preserving:rect(100,100,20,100),by:partialRF),"known DB outside RF cannot veto supported tail growth")
precondition(!NativeOCRDirectionAdapters.supportsExpansion(rect(100,100,20,220),
    preserving:rect(100,100,20,100),by:partialRF),"unsupported new tail must still be rejected")
let upright=NativeCoreMLDetectionBox(polygon:rect(100,100,10,80),score:0.9)
let horizontal=NativeCoreMLDetectionBox(polygon:rect(160,200,80,10),score:0.9)
let frames=NativeOCRDirectionAdapters.scopeFrames(CGRect(x:0,y:0,width:400,height:400),boxes:[upright,horizontal],probability:nil)
precondition(frames.count==2,"mixed RF directions need separate frames")
precondition(frames.filter { NativeOCRDirectionGeometry.compatible(upright.polygon,with:$0) }.count==1)
precondition(frames.filter { NativeOCRDirectionGeometry.compatible(horizontal.polygon,with:$0) }.count==1)
// An unanchored switch must not reroute scopes which already have a DB basis.
setenv("AIDOKU_OCR_ORIENTED_PATHS","lanes,missing,narrow,unanchored",1)
let anchoredScope=CGRect(x:80,y:80,width:50,height:120)
let anchoredFrame=NativeOCRDirectionAdapters.scopeFrame(anchoredScope,boxes:[upright])!
let anchoredFrames=NativeOCRDirectionAdapters.scopeFrames(anchoredScope,boxes:[upright],probability:nil)
precondition(anchoredFrames.count==1 && anchoredFrames[0].quad==anchoredFrame.quad,
    "unanchored fallback cannot replace an existing DB basis; both use local kernels")
setenv("AIDOKU_OCR_ORIENTED_PATHS","groups,rfShape,mixedDirections,unanchored,pixelLocal,lanes,missing,narrow",1)
// Small detector tilt must not create another direction cluster. Verify the
// same tolerance at arbitrary orientations, without changing owner geometry.
for degrees in stride(from:0.0,to:360.0,by:30) {
    func tilted(_ angle:Double)->NativeCoreMLDetectionBox {
        let a=angle*Double.pi/180
        return .init(polygon:rect(195,160,10,80).map { p in
            let x=p.x-200, y=p.y-200
            return CGPoint(x:200+x*cos(a)-y*sin(a),y:200+x*sin(a)+y*cos(a))
        },score:0.9)
    }
    let anchor=tilted(degrees)
    let frame=NativeOCRDirectionGeometry.Frame(NativeOCRDirectionGeometry.readingQuad(anchor.polygon,vertical:true)!)!
    for delta in [-15.0,-10,0,10,15] {
        let neighbor=tilted(degrees+delta), original=neighbor.polygon
        precondition(NativeOCRDirectionGeometry.compatible(neighbor.polygon,with:frame),"nearby tilt stays in cluster")
        precondition(NativeOCRDirectionAdapters.scopeFrames(CGRect(x:0,y:0,width:400,height:400),
            boxes:[anchor,neighbor],probability:nil).count==1,"nearby tilt must not split scope")
        precondition(neighbor.polygon==original,"clustering must not rotate owners")
    }
    for delta in [-90.0,-25,-16,16,25,90] {
        let neighbor=tilted(degrees+delta)
        precondition(!NativeOCRDirectionGeometry.compatible(neighbor.polygon,with:frame),"distinct directions stay separate")
        precondition(NativeOCRDirectionAdapters.scopeFrames(CGRect(x:0,y:0,width:400,height:400),
            boxes:[anchor,neighbor],probability:nil).count==2,"distinct directions need separate frames")
    }
}
func sample(_ v:[Float])->NativeMainEnsembleOCRProbability.Sample {
    .init(sourceWidth:128,sourceHeight:128,resizedWidth:128,resizedHeight:128,
          region:CGRect(x:0,y:0,width:128,height:128),width:128,height:128,values:v)
}
let scope=CGRect(x:0,y:0,width:128,height:128)
precondition(NativeOCRDirectionAdapters.evidenceFrame(scope,probability:sample([Float](repeating:0,count:128*128)))==nil)
var isotropic=[Float](repeating:0,count:128*128)
for y in 40..<80 { for x in 40..<80 { isotropic[y*128+x]=0.9 } }
precondition(NativeOCRDirectionAdapters.evidenceFrame(scope,probability:sample(isotropic))==nil)
for angle in [0.0,0.4,0.8,1.2,1.57,2.1,2.8] {
    var v=[Float](repeating:0,count:128*128)
    for y in 0..<128 { for x in 0..<128 {
        let dx=Double(x)-64,dy=Double(y)-64
        if abs(dx*cos(angle)+dy*sin(angle))<40 && abs(-dx*sin(angle)+dy*cos(angle))<3 { v[y*128+x]=0.9 }
    } }
    let f=NativeOCRDirectionAdapters.evidenceFrame(scope,probability:sample(v))!
    precondition(abs(f.along.x*cos(angle)+f.along.y*sin(angle))>0.999,"probability evidence axis")
    let recovered=NativeOCRDirectionAdapters.scopeFrames(scope,boxes:[],probability:sample(v))
    precondition(recovered.count==1,
        "no-anchor direction recovery must remain available at every tested angle")
}
print("Six-path geometry passed: 24 rotations, RF support area, owner mappings, mixed directions, no-anchor evidence/abstention")
'''
with tempfile.TemporaryDirectory(prefix='direction-six-') as tmp:
    main=Path(tmp)/'main.swift'; binary=Path(tmp)/'checks'
    main.write_text(stubs+production+checks)
    subprocess.run(['swiftc','-module-cache-path',str(root/'build/image-translation-host/rf-primary-module-cache'),str(main),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
