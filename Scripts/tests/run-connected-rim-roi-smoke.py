#!/usr/bin/env python3
"""Neutral connected-lobe outlines extend observation without joining source owners."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
import Foundation
import CoreGraphics
struct ReaderTranslationRegion {let id:String;let rect:CGRect;let source:String}
struct ReaderTranslationBalloonInterior {let rect:CGRect;let center:CGPoint;let spans:[Double];let contourVerified:Bool}
func fixture(_ open: Bool) -> CGImage {
 let c=CGContext(data:nil,width:600,height:600,bitsPerComponent:8,bytesPerRow:2400,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 c.translateBy(x:0,y:600);c.scaleBy(x:1,y:-1)
 c.setFillColor(gray:0.3,alpha:1);c.fill(CGRect(x:0,y:0,width:600,height:600))
 // A continuous two-lobe outline, independently drawn without OCR geometry.
 let p=CGMutablePath();p.move(to:CGPoint(x:355,y:35))
 p.addCurve(to:CGPoint(x:430,y:260),control1:CGPoint(x:495,y:5),control2:CGPoint(x:505,y:220))
 p.addCurve(to:CGPoint(x:375,y:445),control1:CGPoint(x:425,y:370),control2:CGPoint(x:430,y:445))
 p.addCurve(to:CGPoint(x:230,y:300),control1:CGPoint(x:190,y:490),control2:CGPoint(x:180,y:355))
 p.addCurve(to:CGPoint(x:335,y:210),control1:CGPoint(x:260,y:245),control2:CGPoint(x:320,y:275))
 p.addCurve(to:CGPoint(x:355,y:35),control1:CGPoint(x:280,y:140),control2:CGPoint(x:290,y:65));p.closeSubpath()
 c.addPath(p);c.setStrokeColor(gray:1,alpha:1);c.setLineWidth(5);c.strokePath()
 if open {c.setFillColor(gray:0.3,alpha:1);c.fill(CGRect(x:340,y:25,width:30,height:25))}
 return c.makeImage()!
}
let own=CGRect(x:370,y:85,width:35,height:120), peer=CGRect(x:280,y:295,width:35,height:105)
var budget=4_000_000
let clipped=ReaderTranslationWhiteRimBalloon.inspect(image:fixture(false),owned:[own],padding:90,pixelBudget:&budget)
let recovered=ReaderTranslationWhiteRimBalloon.inspect(image:fixture(false),owned:[own],padding:90,searchBounds:peer,pixelBudget:&budget)
print("single",clipped != nil,"peer",recovered != nil,"remaining",budget)
precondition(clipped == nil && recovered != nil)
let broken=ReaderTranslationWhiteRimBalloon.inspect(image:fixture(true),owned:[own],padding:90,searchBounds:peer,pixelBudget:&budget)
precondition(broken == nil)
print("CONNECTED_RIM_ROI closed recovery/open rejection passed")
var exhausted=1
precondition(ReaderTranslationWhiteRimBalloon.inspect(image:fixture(false),owned:[own],padding:90,searchBounds:peer,pixelBudget:&exhausted)==nil && exhausted==1)
var limitBudget=4_000_000
let unrelated=CGRect(x:520,y:520,width:20,height:20)
precondition(ReaderTranslationWhiteRimBalloon.inspect(image:fixture(false),owned:[unrelated],padding:90,searchBounds:own,pixelBudget:&limitBudget)==nil)
// Crop extension never grants ownership: both sources must independently fit the actual hole.
let both=ReaderTranslationWhiteRimBalloon.inspect(image:fixture(false),owned:[own,peer],padding:90,pixelBudget:&limitBudget)
precondition(both != nil)
let foreignOwned=ReaderTranslationWhiteRimBalloon.inspect(image:fixture(false),owned:[own,unrelated],padding:90,pixelBudget:&limitBudget)
precondition(foreignOwned == nil)
print("CONNECTED_RIM_ROI budget/unrelated owner/both owners/foreign owner passed")

let normalized = [own, peer].map { CGRect(x:$0.minX/600,y:$0.minY/600,width:$0.width/600,height:$0.height/600) }
let regions = normalized.enumerated().map { ReaderTranslationRegion(id:"owner-\($0.offset)",rect:$0.element,source:"neutral dialogue") }
let filled = ReaderTranslationWhiteRimBalloon.fillMissing([nil,nil],regions:regions,image:fixture(false),preservingSourceSlots:[])
precondition(filled.allSatisfy { $0 != nil })
precondition(regions.map(\.rect) == normalized && regions.count == filled.count)
let preserved = ReaderTranslationWhiteRimBalloon.fillMissing([nil,nil],regions:regions,image:fixture(false),preservingSourceSlots:[regions[0].id])
precondition(preserved[0] == nil && preserved[1] != nil)
let openFilled = ReaderTranslationWhiteRimBalloon.fillMissing([nil,nil],regions:regions,image:fixture(true),preservingSourceSlots:[])
precondition(openFilled.allSatisfy { $0 == nil })
var invalidBudget=4_000_000
precondition(ReaderTranslationWhiteRimBalloon.inspect(image:fixture(false),owned:[own],padding:90,searchBounds:CGRect(x:CGFloat.infinity,y:0,width:10,height:10),pixelBudget:&invalidBudget)==nil)
precondition(invalidBudget==4_000_000)
print("CONNECTED_RIM_ROI integrated separate ownership / preserved slots / open boundary / invalid context passed")

var individualBudget = 4_000_000
let tinyExteriorOwner = CGRect(x:210,y:40,width:8,height:8)
precondition(ReaderTranslationWhiteRimBalloon.inspect(image:fixture(false),owned:[own,tinyExteriorOwner],padding:90,searchBounds:peer,pixelBudget:&individualBudget)==nil)
for i in 0..<2 {
 let other = normalized[1-i], balloon = filled[i]!
 let row = min(balloon.spans.count/2-1,max(0,Int((other.midY-balloon.rect.minY)/balloon.rect.height*CGFloat(balloon.spans.count/2))))
 let l = balloon.spans[row*2], r = balloon.spans[row*2+1]
 precondition(l<0 || Double(other.midX)<l || Double(other.midX)>r)
}
print("CONNECTED_RIM_ROI every individual owner enclosed / peer source center excluded passed")
'''
with tempfile.TemporaryDirectory(prefix="aidoku-connected-rim-roi-") as directory:
    path = Path(directory)
    (path / "main.swift").write_text(HARNESS)
    subprocess.run(["swiftc", "-O", str(ROOT / "Aidoku/Core/Translation/ReaderTranslationWhiteRimBalloon.swift"),
                    str(path / "main.swift"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
