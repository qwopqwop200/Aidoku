#!/usr/bin/env python3
"""Actual immutable-packet/member geometry checks, isolated from app builds."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT / 'Aidoku/Core/Translation/NativeEngine/OCR'
pipeline = (OCR / 'NativeCoreMLOCRPipeline.swift').read_text()
line = pipeline[pipeline.index('struct NativeCoreMLOCRLine:'):pipeline.index('@available(iOS 18.0, *)\nstruct NativeCoreMLOCRPipelineDiagnostics:')]
seed = (OCR / 'NativeOCRDetectorSeedEvidence.swift').read_text().split('extension NativeOCRDetectorSeedEvidence {')[0]
support = 'import Foundation\nimport CoreGraphics\nstruct NativeOCRSourceROIProbabilityEvidence: Codable, Equatable, Sendable {}\n' + seed + line
checks = r'''
import Foundation
let a = [CGPoint(x:120,y:300),CGPoint(x:140,y:302),CGPoint(x:133,y:400),CGPoint(x:113,y:398)]
let b = a.map { CGPoint(x:$0.x+25,y:$0.y) }
let original = [NativeCoreMLOCRLine(polygon:a,text:"first",score:0.95,orientation:.vertical),
    NativeCoreMLOCRLine(polygon:b,text:"second",score:0.9,orientation:.vertical)]
let bound = NativeOCRAcceptedSource.bindingPrimary(original,width:1000,height:1500)
let table = bound[0].acceptedSource.membership!.table
let union = NativeOCRSourceMetadata.union(bound.map { $0.acceptedSource })
precondition(union.bodySourcePolygons! == [a,b])
let m = bound[0].acceptedSource.membership!
var survivor = bound[0]
survivor.acceptedSource = .init(.init(table:table,body:m.body,readings:[],unknownDedup:[1],hasUntrackedInputs:false))
let rebound = NativeOCRAcceptedSource.bindingPrimary([survivor],width:1000,height:1500)
precondition(rebound[0].acceptedSource.membership!.table === table)
precondition(table.packets.count == 2)
precondition(rebound[0].acceptedSource.bodySourcePolygons! == [a])
precondition(rebound[0].acceptedSource.membership!.unknownDedup == [1])
let unknown = NativeOCRSourceMetadata(.init(table:table,body:[0],readings:[],unknownDedup:[],hasUntrackedInputs:true))
precondition(unknown.bodySourcePolygons! == [])
precondition(NativeOCRSourceMetadata().bodySourcePolygons == nil)
let differentPage = NativeOCRAcceptedSource.bindingPrimary(original,width:1000,height:1500)
precondition(NativeOCRSourceMetadata.union([bound[0].acceptedSource,differentPage[0].acceptedSource]).bodySourcePolygons == nil)
let encoded = try JSONEncoder().encode(union.bodySourcePolygons!)
let decoded = try JSONDecoder().decode([[CGPoint]].self,from:encoded)
precondition(decoded == [a,b])
print("PASS live source-member packets: pixel geometry through merge, full-table identity after dedup/rebind, aliases excluded, cross-page rejection and geometry codec")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-source-members-focused-') as directory:
    temp = Path(directory)
    (temp / 'Support.swift').write_text(support)
    (temp / 'main.swift').write_text(checks)
    binary = temp / 'smoke'
    subprocess.run(['xcrun','swiftc','-O',str(temp / 'Support.swift'),
        str(OCR / 'BrowserOCRSourceOrientation.swift'),str(OCR / 'NativeOCRAcceptedSource.swift'),
        str(temp / 'main.swift'),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
