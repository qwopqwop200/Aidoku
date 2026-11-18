"""Compact original detector transport controls; no models or page rendering."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TEST = r'''
import Foundation
let runs:[[String:Any]]=[["x":10,"y":20,"count":3],["x":10,"y":21,"count":3]]
let component:[String:Any]=["seed":2010,"pixelCount":6,"meanProbability":0.99,"runs":runs]
var seed:[String:Any]=["provenance":"db-complete-cc-candidates-v2","ownershipVersion":2,"completeCCScan":true,
    "sourceWidth":1000,"sourceHeight":2000,"threshold":0.9,"mapFullWidth":100,"mapFullHeight":100,
    "mapOriginX":0,"mapOriginY":0,"parentBoxIndex":4,"ownerID":"own-4","components":[component],
    "ambiguousComponents":[],"candidateComponents":[],"sourceProbabilityROI":["forbiddenHugeData":"not-retained"]]
func project(_ s:[[String:Any]])->[String:Any]? {NativeSourceOwnedComponentProjection.project(s,width:1000,height:2000)}
let valid=project([seed])!
precondition(valid["status"] as? String=="complete-exclusive-components")
let components=valid["components"] as! [[String:Any]]
precondition(components[0]["bounds"] as? [Double]==[0.1,0.2,0.03,0.02])
let encoded=try JSONSerialization.data(withJSONObject:valid)
precondition(!String(data:encoded,encoding:.utf8)!.contains("forbiddenHugeData"))
var bad=seed;bad["sourceWidth"]=999;precondition(project([bad])==nil)
bad=seed;bad["ambiguousComponents"]=[component];precondition(project([bad])==nil)
bad=seed;bad["completeCCScan"]=false;precondition(project([bad])==nil)
bad=seed;bad["ownershipVersion"]=1;precondition(project([bad])==nil)
var wrong=component;wrong["pixelCount"]=7;bad=seed;bad["components"]=[wrong];precondition(project([bad])==nil)
wrong=component;wrong["meanProbability"]=Double.nan;bad=seed;bad["components"]=[wrong];precondition(project([bad])==nil)
wrong=component;wrong["seed"]=true;bad=seed;bad["components"]=[wrong];precondition(project([bad])==nil)
bad=seed;bad["parentBoxIndex"]=true;precondition(project([bad])==nil)
bad=seed;bad["components"]=Array(repeating:component,count:17);precondition(project([bad])==nil)
bad=seed;bad["sourceWidth"]=999
precondition(project([seed,bad])?["status"] as? String=="partial-exclusive-components")
precondition(project([seed,seed])?["status"] as? String=="partial-exclusive-components")
precondition(NativeSourceOwnedComponentProjection.project(nil,width:1000,height:2000)==nil)
print("PASS15 compact detector transport controls; no quality acceptance claim")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-causal8-projection-') as directory:
    folder = Path(directory)
    main = folder/'main.swift'
    main.write_text(TEST)
    subprocess.run(['swiftc', str(ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeSourceOwnedComponentProjection.swift'),
                    str(main), '-o', str(folder/'check')], check=True)
    subprocess.run([str(folder/'check')], check=True)
