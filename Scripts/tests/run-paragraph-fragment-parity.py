#!/usr/bin/env python3
"""Replay the production Swift v6 delta on a frozen development corpus.

Usage: python3 Scripts/tests/run-paragraph-fragment-parity.py RUN_DIRECTORY
This is core-rule parity, not live OCR/translation/render quality certification.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[2]
run = Path(sys.argv[1]).resolve()
sources = root / 'Aidoku/Core/Translation'
harness = r'''
import Foundation
import CoreGraphics
func read(_ p:String)->Any { try! JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:p))) }
let run=CommandLine.arguments[1]
let corpus=read(run+"/merge_optimization_v1/features/pairs-native-color.json") as! [String:Any]
let seeds=read(run+"/merge_optimization_v5/partitions.json") as! [[String:Any]]
let frozen=read(run+"/merge_optimization_v6/partitions.json") as! [[String:Any]]
let seed=Dictionary(uniqueKeysWithValues:seeds.map{($0["page"] as! String,$0["groups"] as! [[Int]])})
let expected=Dictionary(uniqueKeysWithValues:frozen.map{($0["page"] as! String,$0["groups"] as! [[Int]])})
func canonical(_ groups:[[Int]])->[[Int]] { groups.map{$0.sorted()}.sorted{$0[0]<$1[0]} }
func partitions(_ input:[[Int]],_ edges:[NativeParagraphFragmentGrouping.Edge])->[[Int]] {
 var groups=input
 for edge in edges {
  guard let a=groups.firstIndex(where:{$0.contains(edge.first)}),let b=groups.firstIndex(where:{$0.contains(edge.second)}) else {preconditionFailure("Unknown original edge member")}
  if a != b {groups[a] += groups[b];groups.remove(at:b)}
 }
 precondition(groups.flatMap{$0}.sorted()==input.flatMap{$0}.sorted(),"Edge reconstruction lost or duplicated an original")
 return canonical(groups)
}
var pairFeatures:[String:[String:[String:Any]]]=[:]
func key(_ a:Int,_ b:Int)->String { "\(min(a,b))|\(max(a,b))" }
for p in corpus["pairs"] as! [[String:Any]] where p["stage"] as? String == "native-ocr" {
 pairFeatures[p["page"] as! String,default:[:]][key(p["a"] as! Int,p["b"] as! Int)]=p["features"] as? [String:Any]
}
var pages=0,occurrences=0,edgeCount=0,changedPages:[String]=[]
for p in corpus["pages"] as! [[String:Any]] {
 let id=p["page"] as! String,w=p["width"] as! Double,h=p["height"] as! Double
 let stages=p["stages"] as! [[String:Any]],rows=stages.first{$0["stage"] as? String == "native-ocr"}!["regions"] as! [[String:Any]]
 var inks:[Int:NativeParagraphFragmentGrouping.Ink]=[:]
 let atoms=rows.map { r->NativeParagraphFragmentGrouping.Atom in
  let i=r["index"] as! Int,box=r["rect"] as! [String:Double]
  if let rgb=r["foregroundRGB"] as? [Double],let evidence=r["colorEvidence"] as? [String:Any],let n=evidence["inkSamples"] as? Int {
   inks[i] = .init(rgb:rgb,samples:n)
  }
  return .init(index:i,source:r["source"] as! String,
   box:.init(x:box["x"]!*w,y:box["y"]!*h,width:box["width"]!*w,height:box["height"]!*h),
   orientation:.init(tolerantRawValue:r["sourceOrientation"] as? String),owner:(r["membership017"] as? [String:Any])?["index"] as? Int)
 }
 let features=pairFeatures[id] ?? [:]
 let result=NativeParagraphFragmentGrouping.infer(atoms:atoms,groups:seed[id]!,
  separates:{features[key($0.index,$1.index)]?["sameBalloon"] as? Bool == false},ink:{inks[$0.index]})
 let groups=partitions(seed[id]!,result.edges)
 precondition(groups==canonical(expected[id]!),"Swift/v6 mismatch on \(id): \(groups)")
 precondition(groups.flatMap{$0}.sorted()==atoms.map{$0.index}.sorted(),"Source conservation \(id)")
 let reversed=NativeParagraphFragmentGrouping.infer(atoms:Array(atoms.reversed()),groups:seed[id]!.reversed().map{Array($0.reversed())},
  separates:{features[key($0.index,$1.index)]?["sameBalloon"] as? Bool == false},ink:{inks[$0.index]})
 precondition(groups==partitions(seed[id]!,reversed.edges),"Input order regression \(id)")
 let again=NativeParagraphFragmentGrouping.infer(atoms:atoms,groups:groups,
  separates:{features[key($0.index,$1.index)]?["sameBalloon"] as? Bool == false},ink:{inks[$0.index]})
 precondition(again.edges.isEmpty && groups==partitions(groups,again.edges),"Repeated application regression \(id)")
 if canonical(seed[id]!) != groups { changedPages.append(id) }
 pages+=1;occurrences+=atoms.count;edgeCount+=result.edges.count
}
precondition(pages==836 && occurrences==13343 && edgeCount==3)
print("PASS production Swift core parity: \(pages) pages, \(occurrences) atoms, \(edgeCount) edges; changed \(changedPages); reverse-order + idempotence")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-paragraph-parity-') as directory:
    workspace = Path(directory)
    main = workspace / 'main.swift'
    main.write_text(harness)
    binary = workspace / 'parity'
    started = time.monotonic()
    subprocess.run(['xcrun', 'swiftc', '-O',
                    str(sources / 'NativeEngine/OCR/BrowserOCRSourceOrientation.swift'),
                    str(sources / 'NativeParagraphFragmentGrouping.swift'),
                    str(main), '-o', str(binary)], check=True)
    print(f'Host compile seconds: {time.monotonic() - started:.2f}', flush=True)
    started = time.monotonic()
    subprocess.run([str(binary), str(run)], check=True)
    print(f'Host replay seconds: {time.monotonic() - started:.2f}', flush=True)
