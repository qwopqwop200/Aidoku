"""Compile and exercise the production display-owner partition, no OCR or images."""
from pathlib import Path
import subprocess,json,time
ROOT=Path(__file__).resolve().parents[2];cache=ROOT/'build/display-fragment-dedup';cache.mkdir(parents=True,exist_ok=True)
SWIFT=r'''
import CoreGraphics
import Foundation
func item(_ id: String, _ source: String, _ b: [Double], _ confidence: Double = 0.99) -> [String: Any] {
    ["id": id, "sourceOriginalText": source, "text": source, "sourceConfidence": confidence,
     "sourceFontSize": 0.05, "sourceVertical": true,
     "sourcePolygon": [[b[0], b[1]], [b[0]+b[2], b[1]], [b[0]+b[2], b[1]+b[3]], [b[0], b[1]+b[3]]]]
}
func ids(_ rows: [[String: Any]]) -> [String] { rows.map { $0["id"] as! String } }
func check(_ condition: @autoclosure () -> Bool, _ name: String) { precondition(condition(), name) }
let body = item("body", "先頭文章これは重複した長い文章末尾です", [0.3,0.2,0.1,0.5])
let fragment = item("fragment", "これは重複した長い文章末尾です", [0.29,0.15,0.05,0.65])
let result = NativeSourceOwnerRecovery.partitionDisplayTargets([fragment,body])
check(ids(result.displayItems) == ["body"], "overextended fragment suppressed")
check(ids(result.sourceItems) == ["fragment","body"], "source owners retained")
check(result.sourceItems[0]["sourcePolygon"] as! [[Double]] == fragment["sourcePolygon"] as! [[Double]], "source geometry immutable")
check(NativeSourceOwnerRecovery.partitionDisplayTargets(result.displayItems).audit.isEmpty, "idempotent")
var wrongFont = fragment; wrongFont["sourceFontSize"] = 0.1
check(ids(NativeSourceOwnerRecovery.partitionDisplayTargets([wrongFont,body]).displayItems) == ["body"], "wrong fragment font does not defeat physical duplicate witness")
let distinct = item("distinct", "独立した異なる内容の文章です", [0.29,0.15,0.05,0.65])
check(ids(NativeSourceOwnerRecovery.partitionDisplayTargets([distinct,body]).displayItems).count == 2, "distinct overlapping content retained")
let separate = item("separate", "これは重複した長い文章末尾です", [0.7,0.15,0.05,0.65])
check(ids(NativeSourceOwnerRecovery.partitionDisplayTargets([separate,body]).displayItems).count == 2, "same text elsewhere retained")
var protected = fragment; protected["keptLettering"] = true
check(ids(NativeSourceOwnerRecovery.partitionDisplayTargets([protected,body]).displayItems).count == 2, "protected lettering retained")
var conflict = fragment; conflict["paragraphID"] = "second"
var first = body; first["paragraphID"] = "first"
check(ids(NativeSourceOwnerRecovery.partitionDisplayTargets([conflict,first]).displayItems).count == 2, "paragraph conflict retained")
let short = item("short", "文章", [0.31,0.21,0.05,0.1])
check(ids(NativeSourceOwnerRecovery.partitionDisplayTargets([short,body]).displayItems).count == 2, "short repeated token retained")
var peer = body; peer["id"] = "peer"
check(ids(NativeSourceOwnerRecovery.partitionDisplayTargets([fragment,body,peer]).displayItems) == ["body"], "exact duplicate plus fragment")
var ambiguous = body; ambiguous["id"] = "ambiguous"; ambiguous["sourceOriginalText"] = "別の冒頭これは重複した長い文章末尾です"
check(ids(NativeSourceOwnerRecovery.partitionDisplayTargets([fragment,body,ambiguous]).displayItems).count == 3, "ambiguous physical parents retained")
let symbolBody = item("symbol-body", "「んやっ♡なんでっ♡変な声出ちゃっ♡あぁっ♡」", [0.4,0.1,0.1,0.5])
let symbolPrefix = item("symbol-prefix", "「んやっ♡なんでっ♡", [0.45,0.0,0.05,0.5])
check(ids(NativeSourceOwnerRecovery.partitionDisplayTargets([symbolPrefix,symbolBody]).displayItems) == ["symbol-body"],
    "normalization must not shorten physical symbol-bearing fragments")
let distantPrefix = item("distant-prefix", "「んやっ♡なんでっ♡", [0.7,0.0,0.05,0.5])
check(ids(NativeSourceOwnerRecovery.partitionDisplayTargets([distantPrefix,symbolBody]).displayItems).count == 2,
    "same symbol-bearing phrase elsewhere retained")
let quoteRead = item("quote-low", "『んっ……んうっ?」", [0.2,0.2,0.05,0.5], 0.85)
var quotePeer = item("quote-high", "「んっ……んうっ?」", [0.2,0.22,0.05,0.45], 0.86)
var quoteDuplicate = quoteRead; quoteDuplicate["text"] = "same target"
quotePeer["text"] = "same target"
check(ids(NativeSourceOwnerRecovery.partitionDisplayTargets([quoteDuplicate,quotePeer]).displayItems) == ["quote-high"],
    "quote variant duplicate prefers actual confidence")
var conflictingQuote = quoteDuplicate; conflictingQuote["text"] = "different target"
check(NativeSourceOwnerRecovery.partitionDisplayTargets([conflictingQuote,quotePeer]).displayItems.count == 2,
    "quote normalization must not hide target conflicts")
if CommandLine.arguments.contains("--self-test") { print("PASS display fragment dedup: 15 regression controls"); exit(0) }
while let line = readLine() {
 let input = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
 let rows = input["items"] as! [[String: Any]]
 let old = NativeSourceOwnerRecovery.partitionExactDuplicateTargets(rows)
 let result = NativeSourceOwnerRecovery.partitionDisplayTargets(rows)
 let document: [String: Any] = ["page": input["page"]!, "items": result.displayItems, "sourceCount": result.sourceItems.count,
    "oldDisplayIDs": ids(old.displayItems), "audit": result.audit]
 print(String(data: try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), encoding: .utf8)!)
}
'''
source=cache/'main.swift';source.write_text(SWIFT);binary=cache/'display-dedup';native=ROOT/'Aidoku/Core/Translation/NativeEngine';files=[native/'OCR/NativeOCRLocalCoordinates.swift',native/'Ensemble/NativeSourceOwnerRecovery.swift',source]
start=time.perf_counter();subprocess.run(['xcrun','swiftc','-Onone','-module-cache-path',str(ROOT/'build/source-owner-recovery-smoke/module-cache'),*[str(p)for p in files],'-o',str(binary)],check=True);print('Compile seconds',round(time.perf_counter()-start,2),flush=True);subprocess.run([str(binary),'--self-test'],check=True)
