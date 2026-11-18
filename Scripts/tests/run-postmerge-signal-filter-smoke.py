#!/usr/bin/env python3
"""Focused actual-Core tests for merged REC/RF/DET admission."""
from pathlib import Path
import re,json,tempfile,subprocess
repo=Path(__file__).resolve().parents[2];ocr=repo/'Aidoku/Core/Translation/NativeEngine/OCR'
def names(file):
 text=(ocr/file).read_text();return re.findall(r'"([^"]+)"',re.search(r'static let featureNames\s*=\s*\[(.*?)\]',text,re.S).group(1))
semantic=names('NativeOCRPremergeSpatialEvidence.swift')+names('NativeOCRPremergeQueryRelations.swift')
features=['ocrOutputConfidence','ocrBodyMin','ocrBodyMean','ocrBodyMax']+[f'{prefix}.{name}'for prefix in ['out','bodyMin','bodyMean','bodyMax']for name in semantic]+[f'detector.{scope}.{name}'for scope in ['bodyMin','bodyMean','bodyMax']for name in ['available','confidence','referenceIoU','currentIoU','currentCoverage']]
assert len(features)==107
support='''import Foundation
enum NativeFinalOutputContentFilter { static let usesLegacyAdmissionRules=false; struct Condition: Codable, Sendable { let feature:Int; let lower:Double?; let upper:Double? } }
enum NativePostLLMContentReclassifier { static let featureNames: [String] = '''+json.dumps(features)+''' }
'''
source=(repo/'Aidoku/Core/Translation/NativePostMergeSignalFilter.swift').read_text()
checks=r'''
typealias F = NativePostMergeSignalFilter
func index(_ name:String)->Int { F.featureNames.firstIndex(of:name)! }
let rule=[F.Condition(feature:index("bodyMin.rawTextShare"),lower:nil,upper:0.2),F.Condition(feature:index("detector.bodyMean.confidence"),lower:nil,upper:0.8)]
let policy=F.Policy(version:1,featureNames:F.featureNames,rules:[rule])
precondition(policy.isValid)
precondition(F.defaultPolicy?.isValid == true)
var weak=[Double](repeating:0.1,count:107)
weak[index("detector.bodyMin.available")]=1
weak[index("detector.bodyMax.available")]=1
precondition(!F.decide(weak,policy:policy).keep)
var strong=weak
for (name,value)in [("ocrBodyMax",0.95),("bodyMax.rawTextSupport",0.2),("bodyMax.jointTextSupport",0.1),("bodyMax.jointTextMaskCoverage",0.5),("detector.bodyMax.confidence",0.9),("detector.bodyMax.currentIoU",0.95),("detector.bodyMax.currentCoverage",0.99)] {strong[index(name)]=value}
let protected=F.decide(strong,policy:policy)
precondition(protected.keep && protected.sourceEvidenceProtected && protected.matchedRule==0)
for i in weak.indices {var missing=weak;missing[i] = .nan;precondition(F.decide(missing,policy:policy).keep && F.decide(missing,policy:policy).unavailable)}
var unavailable=weak;unavailable[index("detector.bodyMin.available")]=0
precondition(F.decide(unavailable,policy:policy).keep)
precondition(F.decide(nil,policy:policy).keep)
precondition(F.decide(Array(weak.dropLast()),policy:policy).keep)
var boundary=weak;boundary[index("bodyMin.rawTextShare")]=0.2
precondition(!F.decide(boundary,policy:policy).keep)
boundary[index("bodyMin.rawTextShare")]=0.200001
precondition(F.decide(boundary,policy:policy).keep)
let invalid=F.Policy(version:1,featureNames:F.featureNames,rules:[])
precondition(F.decide(weak,policy:invalid).keep)
precondition(F.extract(features:Array(weak.prefix(92)),detectorFeatures:nil)==nil)
print("PASS merged signal admission: 107 missing-value cases, source-conservation guard, unavailable detectors, boundaries and invalid policy")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-postmerge-signals-')as folder:
 p=Path(folder);(p/'main.swift').write_text(support+source+checks)
 subprocess.run(['xcrun','swiftc','-O',str(p/'main.swift'),'-o',str(p/'smoke')],check=True)
 subprocess.run([str(p/'smoke')],check=True)
