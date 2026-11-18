"""Compile real expansion admission and exercise exterior balloon exclusions."""
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[2]
ENGINE=ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble'
SWIFT=r'''
import CoreGraphics
import Foundation
enum NativeSourceClusterAlignment {enum Failure:Error {case invalidPacket}}
@main struct Check {
 static func main() throws {
  let page=CGRect(x:0,y:0,width:1000,height:500)
  var p=NativeTextExpansionPolicy(allowedRectNormalized:[0,0,1,1],candidates:[[0,0,1,1]],
   maskCoverage:[1],backgroundRisk:[0],sourceFontPixels:24,kind:"source-near-limited-expansion",
   maskRectNormalized:nil,maskSpansNormalized:nil)
  let crossing=CGRect(x:400,y:120,width:150,height:60)
  precondition(p.valid && p.allows(crossing,page:page))
  p.forbiddenBalloonRectNormalized=[0.5,0.2,0.2,0.6]
  p.forbiddenBalloonRowsNormalized=[[0.5,0.7],[0.5,0.7]]
  precondition(p.valid && !p.allows(crossing,page:page))
  precondition(p.allows(CGRect(x:400,y:120,width:100,height:60),page:page))
  precondition(p.allows(CGRect(x:720,y:120,width:100,height:60),page:page))
  precondition(p.allows(CGRect(x:500,y:410,width:100,height:60),page:page))
  let horizontal=p.exteriorPackingIntervals(crossStart:120,crossExtent:60,horizontal:true,page:page)
  precondition(horizontal.count==2 && horizontal[0].1==500 && horizontal[1].0==700)
  let vertical=p.exteriorPackingIntervals(crossStart:600,crossExtent:60,horizontal:false,page:page)
  precondition(vertical.count==2 && vertical[0].1==100 && vertical[1].0==400)
  p.balloonExclusionSourceRectNormalized=[0.48,0.24,0.08,0.12]
  precondition(p.allows(CGRect(x:480,y:120,width:80,height:60),page:page))
  precondition(!p.allows(CGRect(x:480,y:120,width:81,height:60),page:page))
  precondition(!p.allows(CGRect(x:480,y:119,width:80,height:61),page:page))
  let shifts=p.projectedShifts(bounds:crossing,page:page,preferred:.zero,font:24)
  precondition(!shifts.isEmpty && shifts.allSatisfy {p.allows(crossing.offsetBy(dx:$0.x,dy:$0.y),page:page)})
  let encoded=try JSONEncoder().encode(p),decoded=try JSONDecoder().decode(NativeTextExpansionPolicy.self,from:encoded)
  precondition(decoded==p)
  let scaledPage=CGRect(x:0,y:0,width:2000,height:1000)
  precondition(!p.allows(CGRect(x:800,y:240,width:330,height:120),page:scaledPage))
  p.forbiddenBalloonRowsNormalized=[[0.5,0.55,0.65,0.7],[]]
  precondition(p.valid && p.allows(CGRect(x:560,y:130,width:80,height:30),page:page))
  p.forbiddenBalloonRowsNormalized=[[0.7,0.5]];precondition(!p.valid)
  p.forbiddenBalloonRowsNormalized=[[0.5]];precondition(!p.valid)
  p.forbiddenBalloonRowsNormalized=[[0.4,0.6,0.5,0.7]];precondition(!p.valid)
  print("PASS exterior balloon admission, source-only exception, projection, scale, holes, codec, invalid boundaries")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aidoku-balloon-exclusion-') as tmp:
    path=Path(tmp);(path/'Check.swift').write_text(SWIFT)
    subprocess.run(['xcrun','swiftc','-Onone','-parse-as-library',str(ENGINE/'NativeTextExpansionPolicy.swift'),str(ENGINE/'NativeTextPlacementGuide.swift'),str(path/'Check.swift'),'-o',str(path/'check')],check=True)
    subprocess.run([str(path/'check')],check=True)
