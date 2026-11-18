"""Compile the production first-pass RF/DB planner with synthetic model carriers."""

from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRRFGapRecovery.swift").read_text()
primary = source.split("/// RF + ORIGINAL pixels nominate missing lines", 1)[0]
stubs = r'''
import CoreGraphics
import Foundation

// Metadata carrier only; geometry/planning algorithms are production code.
struct NativeOCRDetectorSeedEvidence: Sendable { var components: [Int] = [] }
struct NativeCoreMLDetectionBox {
    let polygon: [CGPoint]
    let score: Double
    var erasurePolygons: [[CGPoint]] = []
    var recognitionPolygon: [CGPoint]? = nil
    var isThinFinePrintRecovery: Bool = false
    var finePrintRetryPolygons: [[CGPoint]] = []
    var recognitionColumnEvidence: Int? = nil
    var detectorSeedEvidence: NativeOCRDetectorSeedEvidence? = nil
}
struct NativeOCRRGBAFrame {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]
    init?(width: Int, height: Int, bytesPerRow: Int? = nil, bytes: [UInt8]) {
        self.width = width; self.height = height; self.bytesPerRow = bytesPerRow ?? width*4; self.bytes = bytes
    }
}
struct NativeCoreMLRecognizedRegion {
    let sourceIndex: Int
    let polygon: [CGPoint]
    let text: String
    let confidence: Double
}
enum NativeRFDETRLayoutClass { case text, soundEffect }
struct NativeRFDETRLayoutPrimitive {
    let queryID: Int
    let semanticClass: NativeRFDETRLayoutClass
    let confidence: Double
    var normalizedBounds: CGRect = .zero
    let sourceBounds: CGRect
    var mask: Int? = nil
    var supportPolygon: [CGPoint]? = nil
}
struct NativeRFDETRLayoutResult {
    var imageIdentity: String = "synthetic"
    let sourceWidth: Int
    let sourceHeight: Int
    let primitives: [NativeRFDETRLayoutPrimitive]
    var maskQueriesOmittedByBudget: Int = 0
    var preprocessingMilliseconds: Double = 0
    var modelMilliseconds: Double = 0
    var decodeMilliseconds: Double = 0
    var computeUnits: String = "synthetic"
    var fromCache: Bool = false
}
enum NativeMainEnsembleOCRProbability {
    struct Sample {
        let sourceWidth: Int
        let sourceHeight: Int
        let resizedWidth: Int
        let resizedHeight: Int
        let region: CGRect
        let width: Int
        let height: Int
        let values: [Float]
    }
    struct Report {
        let status: Status
        let width: Int
        let height: Int
    }
    enum Status { case registered }
    typealias Observer = (Sample) -> Report
}
'''
stubs = stubs.replace('struct NativeOCRDetectorSeedEvidence: Sendable { var components: [Int] = [] }', '')
stubs += ''.join((root / 'Aidoku/Core/Translation/NativeEngine/OCR' / name).read_text() for name in [
    'NativeOCRSourceROIProbabilityEvidence.swift', 'NativeOCRDetectorSeedEvidence.swift'])

checks = r'''
let side = 160
let peer = NativeCoreMLDetectionBox(polygon: [CGPoint(x: 25, y: 10), CGPoint(x: 39, y: 10),
    CGPoint(x: 39, y: 140), CGPoint(x: 25, y: 140)], score: 0.8)
let text = NativeRFDETRLayoutPrimitive(queryID: 1, semanticClass: .text, confidence: 0.9,
    sourceBounds: CGRect(x: 20, y: 10, width: 60, height: 130))
let layout = NativeRFDETRLayoutResult(sourceWidth: side, sourceHeight: side, primitives: [text])
var values = [Float](repeating: 0, count: side * side)
for y in 15..<135 {
    for x in 27..<37 { values[y * side + x] = 0.9 }
    for x in 65..<75 { values[y * side + x] = 0.9 }
}
let full = NativeMainEnsembleOCRProbability.Sample(sourceWidth: side, sourceHeight: side,
    resizedWidth: side, resizedHeight: side, region: CGRect(x: 0, y: 0, width: side, height: side),
    width: side, height: side, values: values)
let plan = NativeOCRRFPrimaryEnsemble.plan(boxes: [peer], layout: layout,
    width: side, height: side, probability: full)
precondition(plan.boxes.count == 2 && plan.supported.contains(1), "independent column must be added")
let mark = NativeCoreMLRecognizedRegion(sourceIndex: 0, polygon: peer.polygon,
    text: "?", confidence: 0.7)
precondition(NativeOCRRFPrimaryEnsemble.admits(mark, threshold: 0.75,
    supported: [0], stronglySupported: [], merged: [], dbScore: 0.8),
    "one punctuation mark with independent RF and DB evidence is admitted")
precondition(!NativeOCRRFPrimaryEnsemble.admits(mark, threshold: 0.75,
    supported: [], stronglySupported: [], merged: [], dbScore: 0.8),
    "DB evidence alone cannot admit punctuation")
let weakMark = NativeCoreMLRecognizedRegion(sourceIndex: 0, polygon: peer.polygon,
    text: ".", confidence: 0.46)
precondition(!NativeOCRRFPrimaryEnsemble.admits(weakMark, threshold: 0.75,
    supported: [0], stronglySupported: [], merged: [], dbScore: 0.8),
    "a weak single-mark decode cannot become an isolated source")
let empty = NativeCoreMLRecognizedRegion(sourceIndex: 0, polygon: peer.polygon,
    text: "", confidence: 0.7)
precondition(!NativeOCRRFPrimaryEnsemble.admits(empty, threshold: 0.75,
    supported: [0], stronglySupported: [], merged: [], dbScore: 0.8),
    "an empty recognition remains rejected")
let recovered = plan.boxes[1].polygon.reduce(CGRect.null) {
    $0.union(CGRect(origin: $1, size: .zero))
}
precondition(recovered.contains(CGPoint(x: 70, y: 80)), "column is centered on missing DB ink")
precondition(!recovered.intersects(CGRect(x: 25, y: 10, width: 14, height: 130)),
    "existing DB ownership remains a keepout")
let partial = NativeMainEnsembleOCRProbability.Sample(sourceWidth: side, sourceHeight: side,
    resizedWidth: side, resizedHeight: side, region: CGRect(x: 0, y: 10, width: side, height: side - 10),
    width: side, height: side, values: values)
precondition(NativeOCRRFPrimaryEnsemble.plan(boxes: [peer], layout: layout,
    width: side, height: side, probability: partial).boxes.count == 1,
    "partial probability maps cannot nominate new boxes")
let diamondBox = NativeCoreMLDetectionBox(polygon: [CGPoint(x:80,y:20),CGPoint(x:140,y:80),
    CGPoint(x:80,y:140),CGPoint(x:20,y:80)],score:0.7)
let diamondText = NativeRFDETRLayoutPrimitive(queryID:11,semanticClass:.text,confidence:0.95,
    sourceBounds:CGRect(x:15,y:15,width:130,height:130))
let emptyCornerSFX = NativeRFDETRLayoutPrimitive(queryID:12,semanticClass:.soundEffect,confidence:0.8,
    sourceBounds:CGRect(x:20,y:20,width:10,height:10))
let diamondLayout = NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[diamondText,emptyCornerSFX])
setenv("AIDOKU_OCR_ORIENTED_PATHS","",1)
let legacySupport = NativeOCRRFPrimaryEnsemble.plan(boxes:[diamondBox],layout:diamondLayout,width:side,height:side)
precondition(!legacySupport.supported.contains(0),"legacy SFX overlap uses empty AABB corner")
setenv("AIDOKU_OCR_ORIENTED_PATHS","rfOverlap",1)
let polygonSupport = NativeOCRRFPrimaryEnsemble.plan(boxes:[diamondBox],layout:diamondLayout,width:side,height:side)
precondition(polygonSupport.supported.contains(0) && polygonSupport.stronglySupported.contains(0),
    "actual quad does not overlap the corner SFX query")
unsetenv("AIDOKU_OCR_ORIENTED_PATHS")
print("RF/DB first-pass synthetic checks passed, including actual-quad SFX support")
let supportBox = NativeCoreMLDetectionBox(polygon: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10),
    CGPoint(x: 50, y: 150), CGPoint(x: 10, y: 150)], score: 0.8)
let narrow = NativeRFDETRLayoutPrimitive(queryID: 2, semanticClass: .text, confidence: 0.4,
    sourceBounds: CGRect(x: 20, y: 12, width: 22, height: 136))
let supportLayout = NativeRFDETRLayoutResult(sourceWidth: side, sourceHeight: side, primitives: [narrow])
var pixels = [UInt8](repeating: 255, count: side * side * 4)
for y in 20..<140 { for x in 15..<45 { for c in 0..<3 { pixels[(y * side + x) * 4 + c] = 0 } } }
let supportFrame = NativeOCRRGBAFrame(width: side, height: side, bytesPerRow: side * 4, bytes: pixels)!
let complete = NativeOCRRFPrimaryEnsemble.completeSupportSampling(box: supportBox, boxes: [supportBox],
    layout: supportLayout, frame: supportFrame)!
let completeBounds = complete.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
precondition(completeBounds.minX < 15 && completeBounds.maxX > 45, "retain ink beyond both RF edges")
precondition(completeBounds.minY == 10 && completeBounds.maxY == 150, "retain complete DB axis extent")
let slantedBox = NativeCoreMLDetectionBox(polygon: [CGPoint(x: 10, y: 12), CGPoint(x: 40, y: 10),
    CGPoint(x: 50, y: 148), CGPoint(x: 20, y: 150)], score: 0.8)
precondition(NativeOCRRFPrimaryEnsemble.completeSupportSampling(box: slantedBox, boxes: [slantedBox],
    layout: supportLayout, frame: supportFrame) == nil, "source-axis estimator must not flatten a slanted quad")
for c in 0..<3 { pixels[(80 * side + 10) * 4 + c] = 0 }
let clippedFrame = NativeOCRRGBAFrame(width: side, height: side, bytesPerRow: side * 4, bytes: pixels)!
precondition(NativeOCRRFPrimaryEnsemble.completeSupportSampling(box: supportBox, boxes: [supportBox],
    layout: supportLayout, frame: clippedFrame) == nil, "border ink vetoes uncertain support")
precondition(NativeOCRRFPrimaryEnsemble.completeSupportSampling(box: supportBox, boxes: [supportBox],
    layout: supportLayout, frame: supportFrame) == complete, "sampling is deterministic without runtime flags")
print("Complete original-pixel support checks passed")
let shortColumn = NativeCoreMLDetectionBox(polygon: [CGPoint(x: 25, y: 20), CGPoint(x: 39, y: 20),
    CGPoint(x: 39, y: 100), CGPoint(x: 25, y: 100)], score: 0.8)
let endpointRF = NativeRFDETRLayoutPrimitive(queryID: 19, semanticClass: .text, confidence: 0.8,
    sourceBounds: CGRect(x: 20, y: 10, width: 24, height: 135))
let endpointLayout = NativeRFDETRLayoutResult(sourceWidth: side, sourceHeight: side, primitives: [endpointRF])
let completedColumn = NativeOCRRFPrimaryEnsemble.endpointCompletion(index: 0, boxes: [shortColumn],
    layout: endpointLayout, width: side, height: side)!
let endpointBounds = completedColumn.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
precondition(endpointBounds.minX == 25 && endpointBounds.maxX == 39 &&
    endpointBounds.minY == 10 && endpointBounds.maxY == 120, "RF extends ends within the original column lane and scale")
let following = NativeCoreMLDetectionBox(polygon: [CGPoint(x: 25, y: 110), CGPoint(x: 39, y: 110),
    CGPoint(x: 39, y: 140), CGPoint(x: 25, y: 140)], score: 0.8)
let stopped = NativeOCRRFPrimaryEnsemble.endpointCompletion(index: 0, boxes: [shortColumn, following],
    layout: endpointLayout, width: side, height: side)!
precondition(stopped.map(\.y).max()! < 110, "endpoint completion stops before another DB owner")
precondition(NativeOCRRFPrimaryEnsemble.endpointCompletion(index: 0, boxes: [shortColumn],
    layout: nil, width: side, height: side) == nil, "no RF prediction means no change")
let ambiguousRF = NativeRFDETRLayoutResult(sourceWidth: side, sourceHeight: side, primitives: [endpointRF, endpointRF])
precondition(NativeOCRRFPrimaryEnsemble.endpointCompletion(index: 0, boxes: [shortColumn],
    layout: ambiguousRF, width: side, height: side) == nil, "ambiguous paragraph ownership is not completion evidence")
precondition(NativeOCRRFPrimaryEnsemble.endpointCompletion(index: 0, boxes: [slantedBox],
    layout: endpointLayout, width: side, height: side) == nil, "RF endpoint experiment preserves slanted DB axes")
print("RF endpoint completion checks passed")
var tailValues = [Float](repeating: 0, count: side * side)
func tailMap(_ values: [Float]) -> NativeMainEnsembleOCRProbability.Sample {
    .init(sourceWidth: side, sourceHeight: side, resizedWidth: side, resizedHeight: side,
        region: CGRect(x: 0, y: 0, width: side, height: side), width: side, height: side, values: values)
}
precondition(NativeOCRRFPrimaryEnsemble.supportedEndpointCompletion(index: 0, boxes: [shortColumn],
    layout: endpointLayout, width: side, height: side, probability: tailMap(tailValues),
    pixelThreshold: 0.15) == nil, "empty RF margins cannot move a column endpoint")
for y in 103..<108 { for x in 28..<36 { tailValues[y * side + x] = 0.8 } }
let supportedTail = NativeOCRRFPrimaryEnsemble.supportedEndpointCompletion(index: 0, boxes: [shortColumn],
    layout: endpointLayout, width: side, height: side, probability: tailMap(tailValues), pixelThreshold: 0.15)!
precondition(supportedTail.map(\.y).min()! == 20 && supportedTail.map(\.y).max()! == 110,
    "only the measured tail receives bounded recognition context")
precondition(NativeOCRRFPrimaryEnsemble.supportedEndpointCompletion(index: 0, boxes: [shortColumn],
    layout: endpointLayout, width: side, height: side, probability: nil, pixelThreshold: 0.15) == nil,
    "missing DB evidence never falls back to paragraph-wide extension")
print("DB-supported endpoint checks passed")
let horizontalColumn = NativeCoreMLDetectionBox(polygon: shortColumn.polygon.map {
    CGPoint(x: CGFloat(side) - $0.y, y: $0.x)
}, score: 0.8)
let horizontalRF = NativeRFDETRLayoutPrimitive(queryID: 19, semanticClass: .text, confidence: 0.8,
    sourceBounds: CGRect(x: 15, y: 20, width: 135, height: 24))
let horizontalLayout = NativeRFDETRLayoutResult(sourceWidth: side, sourceHeight: side, primitives: [horizontalRF])
var rotatedValues = [Float](repeating: 0, count: side * side)
for y in 0..<side { for x in 0..<side {
    rotatedValues[x * side + (side - 1 - y)] = tailValues[y * side + x]
} }
let horizontalTail = NativeOCRRFPrimaryEnsemble.supportedEndpointCompletion(index: 0, boxes: [horizontalColumn],
    layout: horizontalLayout, width: side, height: side, probability: tailMap(rotatedValues), pixelThreshold: 0.15)!
precondition(abs(horizontalTail.map(\.x).min()! - 50) < 0.001 && abs(horizontalTail.map(\.x).max()! - 140) < 0.001,
    "a 90 degree rotation preserves the same endpoint expansion")
precondition(NativeOCRRFPrimaryEnsemble.supportedEndpointCompletion(index: 0, boxes: [horizontalColumn],
    layout: horizontalLayout, width: side, height: side, probability: tailMap([Float](repeating: 0, count: side * side)),
    pixelThreshold: 0.15) == nil, "rotation does not bypass DB support")
for angle in [0.3, 0.8, 1.8, 2.5, 3.5, 4.5, 5.5] {
    func rotate(_ point: CGPoint) -> CGPoint {
        let x = point.x - 80, y = point.y - 80
        return CGPoint(x: 80 + x * cos(angle) - y * sin(angle), y: 80 + x * sin(angle) + y * cos(angle))
    }
    let original = [CGPoint(x: 72, y: 50), CGPoint(x: 88, y: 50), CGPoint(x: 88, y: 110), CGPoint(x: 72, y: 110)]
    let quad = original.map(rotate)
    let rfQuad = [CGPoint(x: 68, y: 40), CGPoint(x: 92, y: 40), CGPoint(x: 92, y: 120), CGPoint(x: 68, y: 120)].map(rotate)
    let rfBounds = rfQuad.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    let rotatedLayout = NativeRFDETRLayoutResult(sourceWidth: side, sourceHeight: side,
        primitives: [.init(queryID: 20, semanticClass: .text, confidence: 0.8, sourceBounds: rfBounds)])
    let extended = NativeOCRRFPrimaryEnsemble.supportedEndpointCompletion(index: 0,
        boxes: [.init(polygon: quad, score: 0.8)], layout: rotatedLayout, width: side, height: side,
        probability: tailMap([Float](repeating: 0.9, count: side * side)), pixelThreshold: 0.15)!
    let a = CGPoint(x: quad[2].x - quad[1].x, y: quad[2].y - quad[1].y)
    let b = CGPoint(x: extended[2].x - extended[1].x, y: extended[2].y - extended[1].y)
    precondition(abs(a.x * b.y - a.y * b.x) < 0.00001, "all-angle extension preserves the box vector")
}
print("All-angle RF+DB endpoint checks passed")
var glyphPixels = [UInt8](repeating: 255, count: side * side * 4)
func paintGlyph(_ image: inout [UInt8], _ y0: Int, _ y1: Int) {
    for y in y0..<y1 { for x in 28..<36 { for c in 0..<3 { image[(y * side + x) * 4 + c] = 0 } } }
}
for y in [28, 47, 67, 87] { paintGlyph(&glyphPixels, y, y + 12) }
func glyphFrame(_ image: [UInt8]) -> NativeOCRRGBAFrame {
    .init(width: side, height: side, bytesPerRow: side * 4, bytes: image)!
}
precondition(NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index: 0, boxes: [shortColumn],
    layout: endpointLayout, frame: glyphFrame(glyphPixels)) == nil,
    "RF paragraph whitespace cannot extend the measured glyph column")
var farPixels = glyphPixels
paintGlyph(&farPixels, 135, 141)
precondition(NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index: 0, boxes: [shortColumn],
    layout: endpointLayout, frame: glyphFrame(farPixels)) == nil,
    "a distant disconnected object cannot become the column tail")
paintGlyph(&glyphPixels, 105, 117)
let pixelTail = NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index: 0, boxes: [shortColumn],
    layout: endpointLayout, frame: glyphFrame(glyphPixels))!
precondition(pixelTail.map(\.y).max()! > 117 && pixelTail.map(\.y).max()! < 122 &&
    pixelTail.map(\.x).min()! == 25 && pixelTail.map(\.x).max()! == 39,
    "original pixel components restore the missing tail without DB probability evidence")
precondition(NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index: 0, boxes: [shortColumn, following],
    layout: endpointLayout, frame: glyphFrame(glyphPixels)) == nil,
    "pixels already belonging to a following DB owner cannot extend this column")
var inversePixels = glyphPixels
for pixel in stride(from: 0, to: inversePixels.count, by: 4) {
    for channel in 0..<3 { inversePixels[pixel + channel] = 255 - inversePixels[pixel + channel] }
}
precondition(NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index: 0, boxes: [shortColumn],
    layout: endpointLayout, frame: glyphFrame(inversePixels)) == pixelTail,
    "local contrast supports both dark and light lettering")
print("RF + original-pixel column endpoint checks passed")
// Enabling all-angle completion must leave the calibrated vertical path exact,
// including peer exclusion and RF/SFX policy, not merely its final angle.
do {
let savedPaths = ProcessInfo.processInfo.environment["AIDOKU_OCR_ORIENTED_PATHS"] ?? ""
let sfx = NativeRFDETRLayoutPrimitive(queryID: 20, semanticClass: .soundEffect, confidence: 0.9,
    sourceBounds: CGRect(x: 26,y: 103,width: 12,height: 16))
let overlappingSFX = NativeRFDETRLayoutResult(sourceWidth: side,sourceHeight: side,
    primitives: [endpointRF,sfx])
for degrees in [0.0] {
    let a=degrees*Double.pi/180
    func turn(_ p:CGPoint)->CGPoint {
        CGPoint(x:32+(p.x-32)*cos(a)-(p.y-70)*sin(a),
                y:70+(p.x-32)*sin(a)+(p.y-70)*cos(a))
    }
    let b=NativeCoreMLDetectionBox(polygon:shortColumn.polygon.map(turn),score:0.8)
    for boxes in [[b],[b,following]] {
        for layout in [endpointLayout,overlappingSFX] {
            for image in [glyphPixels,inversePixels,farPixels] {
                setenv("AIDOKU_OCR_ORIENTED_PATHS","",1)
                let before=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:boxes,
                    layout:layout,frame:glyphFrame(image))
                setenv("AIDOKU_OCR_ORIENTED_PATHS","pixelLocal",1)
                let after=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:boxes,
                    layout:layout,frame:glyphFrame(image))
                precondition(before==after,"near-vertical pixel endpoint must remain exactly unchanged")
            }
        }
    }
}
setenv("AIDOKU_OCR_ORIENTED_PATHS",savedPaths,1)
print("Near-vertical pixelLocal parity checks passed")
}
// Rotate the complete scene, not just the DB quad: actual RF support, peer
// ownership and original pixels must use the same owner-local policy.
do {
let savedPaths=ProcessInfo.processInfo.environment["AIDOKU_OCR_ORIENTED_PATHS"] ?? ""
setenv("AIDOKU_OCR_ORIENTED_PATHS","pixelLocal",1)
for degrees in stride(from:0.0,to:360.0,by:15) {
    let a=degrees*Double.pi/180
    func turn(_ p:CGPoint)->CGPoint {
        CGPoint(x:80+(p.x-32)*cos(a)-(p.y-70)*sin(a),
                y:80+(p.x-32)*sin(a)+(p.y-70)*cos(a))
    }
    var image=[UInt8](repeating:255,count:side*side*4)
    for y in 0..<side { for x in 0..<side {
        let dx=CGFloat(x)+0.5-80, dy=CGFloat(y)+0.5-80
        let xx=Int(floor(32+dx*cos(a)+dy*sin(a)))
        let yy=Int(floor(70-dx*sin(a)+dy*cos(a)))
        if xx >= 0 && xx < side && yy >= 0 && yy < side {
            for c in 0..<4 { image[(y*side+x)*4+c]=glyphPixels[(yy*side+xx)*4+c] }
        }
    } }
    let b=NativeCoreMLDetectionBox(polygon:shortColumn.polygon.map(turn),score:0.8)
    let peer=NativeCoreMLDetectionBox(polygon:following.polygon.map(turn),score:0.8)
    let support=NativeOCRDirectionGeometry.corners(endpointRF.sourceBounds).map(turn)
    var rf=NativeRFDETRLayoutPrimitive(queryID:19,semanticClass:.text,confidence:0.8,
        sourceBounds:NativeOCRDirectionGeometry.bounds(support))
    rf.supportPolygon=support
    let layout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[rf])
    let actual=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[b],
        layout:layout,frame:glyphFrame(image))!
    let noRF=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[])
    let independent=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[b],
        layout:noRF,frame:glyphFrame(image))!
    for (p,q) in zip(actual,pixelTail.map(turn)) {
        precondition(hypot(p.x-q.x,p.y-q.y)<2,"all-angle endpoint covariance within raster error")
    }
    for (p,q) in zip(independent,pixelTail.map(turn)) {
        precondition(hypot(p.x-q.x,p.y-q.y)<2,"bounded multi-glyph pixel evidence does not require an RF query")
    }
    let weak=NativeCoreMLDetectionBox(polygon:b.polygon,score:0.7)
    precondition(NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[weak],
        layout:noRF,frame:glyphFrame(image))==nil,"weak DB cannot bootstrap RF-free endpoint growth")
    precondition(NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[b],
        layout:noRF,frame:glyphFrame([UInt8](repeating:255,count:side*side*4)))==nil,
        "no original ink means no RF-free growth")
    if let stopped=NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[b,peer],
        layout:layout,frame:glyphFrame(image)) {
        let along=CGPoint(x:-sin(a),y:cos(a))
        let maxTail=zip(stopped,b.polygon).map { ($0.x-$1.x)*along.x+($0.y-$1.y)*along.y }.max()!
        precondition(maxTail<2,"all-angle peer ownership must stop tail growth, allowing raster padding")
    }
}
setenv("AIDOKU_OCR_ORIENTED_PATHS",savedPaths,1)
print("Pixel-local whole-scene rotation checks passed: 24 angles, RF support and peer ownership")
}
do {
func rotate(_ p: CGPoint) -> CGPoint { CGPoint(x: CGFloat(side) - p.y, y: p.x) }
func rotatedPixels(_ pixels: [UInt8]) -> [UInt8] {
    var result = pixels
    for y in 0..<side { for x in 0..<side { for c in 0..<4 {
        result[(x * side + side - 1 - y) * 4 + c] = pixels[(y * side + x) * 4 + c]
    } } }
    return result
}
let horizontal = NativeCoreMLDetectionBox(polygon: shortColumn.polygon.map(rotate), score: 0.8)
let horizontalRF = endpointRF.sourceBounds
let horizontalLayout = NativeRFDETRLayoutResult(sourceWidth: side, sourceHeight: side, primitives: [
    .init(queryID: 19, semanticClass: .text, confidence: 0.8,
          sourceBounds: CGRect(x: CGFloat(side) - horizontalRF.maxY, y: horizontalRF.minX,
                               width: horizontalRF.height, height: horizontalRF.width))])
let horizontalTail = NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index: 0, boxes: [horizontal],
    layout: horizontalLayout, frame: glyphFrame(rotatedPixels(inversePixels)))!
for (actual, expected) in zip(horizontalTail, pixelTail.map(rotate)) {
    precondition(hypot(actual.x - expected.x, actual.y - expected.y) < 0.001, "pixel endpoint rotation covariance")
}
let horizontalSupport = NativeCoreMLDetectionBox(polygon: supportBox.polygon.map(rotate), score: 0.8)
let r = narrow.sourceBounds
let horizontalSupportLayout = NativeRFDETRLayoutResult(sourceWidth: side, sourceHeight: side, primitives: [
    .init(queryID: 2, semanticClass: .text, confidence: 0.4,
          sourceBounds: CGRect(x: CGFloat(side) - r.maxY, y: r.minX, width: r.height, height: r.width))])
let horizontalCrop = NativeOCRRFPrimaryEnsemble.completeSupportSampling(box: horizontalSupport,
    boxes: [horizontalSupport], layout: horizontalSupportLayout, frame: glyphFrame(rotatedPixels(supportFrame.bytes)))!
for (actual, expected) in zip(horizontalCrop, complete.map(rotate)) {
    precondition(hypot(actual.x - expected.x, actual.y - expected.y) < 0.001, "width correction rotation covariance")
}
let rereadQuad = [CGPoint(x: 40, y: 20), CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 240), CGPoint(x: 40, y: 240)]
let expanded = NativeOCRRFPrimaryEnsemble.expandedRecognitionPolygon(rereadQuad)!
for angle in [0.0, 0.31, 1.57, 2.4, 3.14, 4.1, 5.2] {
    func turn(_ p: CGPoint) -> CGPoint {
        CGPoint(x: 400 + p.x * cos(angle) - p.y * sin(angle),
                y: 400 + p.x * sin(angle) + p.y * cos(angle))
    }
    let result = NativeOCRRFPrimaryEnsemble.expandedRecognitionPolygon(rereadQuad.map(turn))!
    for (actual, expected) in zip(result, expanded.map(turn)) {
        precondition(hypot(actual.x - expected.x, actual.y - expected.y) < 0.001, "reread rotation covariance")
    }
}
print("Three local-axis recovery rotation checks passed")
}
// End punctuation fragments keep their real DB owner and are sampled with
// the word only under one common RF text scope, at every rigid orientation.
do {
setenv("AIDOKU_OCR_ENDPOINT_INK_REFINEMENT","1",1)
func qrect(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat)->[CGPoint] {
    [.init(x:x,y:y),.init(x:x+w,y:y),.init(x:x+w,y:y+h),.init(x:x,y:y+h)]
}
for degrees in stride(from:0.0,to:360,by:15) {
    let a=degrees*Double.pi/180
    func turn(_ p:CGPoint)->CGPoint { .init(x:80+(p.x-80)*cos(a)-(p.y-80)*sin(a),y:80+(p.x-80)*sin(a)+(p.y-80)*cos(a)) }
    func evidence(_ id:Int,_ p:CGPoint)->NativeOCRDetectorSeedEvidence {
        let x=Int(p.x),y=Int(p.y)
        return .init(ownerID:"point-owner-\(id)",parentBoxIndex:id,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
            mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
            components:[.init(seed:y*side+x,pixelCount:1,meanProbability:0.99,runs:[.init(y:y,x:x,count:1)])],
            ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    }
    let word=NativeCoreMLDetectionBox(polygon:qrect(40,20,12,75).map(turn),score:0.9,detectorSeedEvidence:evidence(0,turn(.init(x:46,y:55))))
    let point=NativeCoreMLDetectionBox(polygon:qrect(44,90,4,25).map(turn),score:0.85,detectorSeedEvidence:evidence(1,turn(.init(x:46,y:102))))
    let scope=qrect(35,15,25,110).map(turn)
    var rf=NativeRFDETRLayoutPrimitive(queryID:31,semanticClass:.text,confidence:0.95,sourceBounds:NativeOCRDirectionGeometry.bounds(scope))
    rf.supportPolygon=scope
    let layout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[rf])
    let raw=NativeOCRRFPrimaryEnsemble.Plan(boxes:[word,point],supported:[0,1],stronglySupported:[0,1],groups:[],refinedCrops:[])
    let measured=NativeOCRRFPrimaryEnsemble.includingAlignedPointFragments(raw,layout:layout,width:side,height:side)
    precondition(measured.groups.count==1 && measured.groups[0].members==[0,1] && measured.groups[0].pointFragments==[1],
        "an aligned same-scope point fragment retains both real DB owners")
    let heart=NativeCoreMLDetectionBox(polygon:qrect(42,94,8,10).map(turn),score:0.85,detectorSeedEvidence:evidence(1,turn(.init(x:46,y:99))))
    let heartRaw=NativeOCRRFPrimaryEnsemble.Plan(boxes:[word,heart],supported:[0,1],stronglySupported:[0,1],groups:[],refinedCrops:[])
    precondition(NativeOCRRFPrimaryEnsemble.includingAlignedPointFragments(heartRaw,layout:layout,width:side,height:side).groups.count==1,
        "a compact end symbol can be sampled with its same-column word")
    let ruby=NativeCoreMLDetectionBox(polygon:qrect(56,90,4,25).map(turn),score:0.85,detectorSeedEvidence:evidence(1,turn(.init(x:58,y:102))))
    let sideRaw=NativeOCRRFPrimaryEnsemble.Plan(boxes:[word,ruby],supported:[0,1],stronglySupported:[0,1],groups:[],refinedCrops:[])
    precondition(NativeOCRRFPrimaryEnsemble.includingAlignedPointFragments(sideRaw,layout:layout,width:side,height:side).groups.isEmpty,
        "a side reading cannot become an end punctuation fragment")
    precondition(NativeOCRRFPrimaryEnsemble.includingAlignedPointFragments(raw,layout:nil,width:side,height:side).groups.isEmpty,
        "pixel alignment alone cannot invent a shared RF text scope")
}
unsetenv("AIDOKU_OCR_ENDPOINT_INK_REFINEMENT")
print("Same-scope point fragment ownership checks passed at 24 angles")
}

'''

with tempfile.TemporaryDirectory(prefix="rf-primary-") as temporary:
    path = Path(temporary)
    swift = path / "main.swift"
    helpers = (root/'Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRLocalCoordinates.swift').read_text()
    helpers += (root/'Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRDirectionAdapters.swift').read_text()
    swift.write_text(stubs + helpers + primary + checks)
    executable = path / "smoke"
    cache = root / "build/image-translation-host/rf-primary-module-cache"
    cache.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-module-cache-path", str(cache),
                    str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
