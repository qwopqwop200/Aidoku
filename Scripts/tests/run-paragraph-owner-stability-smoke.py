#!/usr/bin/env python3
"""Exercise actual RF-owner code against nested-query score inversions."""
from pathlib import Path
import subprocess,tempfile
repo=Path(__file__).resolve().parents[2]
source=(repo/'Aidoku/Core/Translation/NativeParagraphFragmentGrouping.swift').read_text()
start=source.index('    static func owningScope(')
end=source.index('    /// Physical adjacency',start)
methods=source[start:end]
harness='''import Foundation
import CoreGraphics
enum Harness {
struct TextScope { let owner: Int; let box: CGRect; let confidence: Double }
'''+methods+'''}
let input=CGRect(x:0.1,y:0.1,width:0.1,height:0.15)
func scope(_ owner:Int,_ box:CGRect,_ confidence:Double)->Harness.TextScope {
    .init(owner:owner,box:box,confidence:confidence)
}
let full=CGRect(x:0,y:0,width:1,height:2.5)
let part=CGRect(x:0,y:0,width:0.65,height:0.95)
for values in [(0.3582,0.4010),(0.4015,0.3942)] {
    precondition(Harness.owningScope(input,scopes:[scope(1,full,values.0),scope(2,part,values.1)],minimumConfidence:0.25)?.owner==1)
}
precondition(Harness.owningScope(input,scopes:[scope(1,full,0.3),scope(2,part,0.5)],minimumConfidence:0.25)?.owner==2)
let small=CGRect(x:0,y:0,width:0.3,height:0.3)
let crossing=CGRect(x:-0.1,y:0.05,width:0.6,height:0.25)
precondition(Harness.owningScope(input,scopes:[scope(2,small,0.401),scope(3,crossing,0.39)],minimumConfidence:0.25)?.owner==2)
precondition(Harness.owningScope(input,scopes:[scope(1,full,0.4),scope(2,part,0.4)],minimumConfidence:0.25)==nil)
precondition(Harness.owningScope(input,scopes:[scope(1,full,Double.nan)],minimumConfidence:0.25)==nil)
print("PASS RF owner stability: 2 score inversions, weaker/nonnested negatives, ties, missing confidence")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-rf-owner-')as folder:
 root=Path(folder);swift=root/'main.swift';binary=root/'smoke';swift.write_text(harness)
 subprocess.run(['xcrun','swiftc','-O',str(swift),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
