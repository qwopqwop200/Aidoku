#!/usr/bin/env python3
"""New color roles cannot borrow an older pair's confidence probabilities."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeOriginalColorFidelity.swift'
harness = '''import Foundation
@main struct Smoke {
 static func main() throws {
  let raw: [String: Any] = ["foreground": 0.99, "stroke": 0.8, "background": 0.7]
  let original: [String: Any] = ["foreground": [255,255,255], "stroke": [220,90,5], "confidence": raw]
  let before = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
  let unchanged = NativeOriginalColorFidelity.sourceRoleConfidenceAudit(original)!
  precondition((unchanged["foreground"] as? Double) == 0.99)
  var replacement = original
  replacement["nativeTopologyRoleEvidence"] = ["conditionalSupport": true]
  let audited = NativeOriginalColorFidelity.sourceRoleConfidenceAudit(replacement)!
  precondition(audited["foreground"] is NSNull && audited["stroke"] is NSNull)
  precondition((audited["background"] as? Double) == 0.7)
  precondition(((audited["rawLegacyRoleConfidence"] as? [String: Any])?["foreground"] as? Double) == 0.99)
  let after = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
  precondition(after == before)
  precondition(NativeOriginalColorFidelity.sourceRoleConfidenceAudit(nil) == nil)
  precondition(NativeOriginalColorFidelity.sourceRoleConfidenceAudit([:]) == nil)
  let absent = NativeOriginalColorFidelity.sourceRoleConfidenceAudit(["nativeTopologyRoleEvidence": ["conditionalSupport": true]])!
  precondition(absent["foreground"] is NSNull && absent["background"] is NSNull)
  var missing = original; missing["nativeTopologyRoleEvidence"] = NSNull()
  precondition((NativeOriginalColorFidelity.sourceRoleConfidenceAudit(missing)?["foreground"] as? Double) == 0.99)
  print("PASS: unchanged baseline, preserved raw scores, unknown new-role confidence, independent background and missing evidence")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aidoku-role-confidence-') as directory:
    work = Path(directory)
    (work / 'Smoke.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', '-O', str(source), str(work / 'Smoke.swift'), '-o', str(work / 'smoke')], check=True)
    subprocess.run([str(work / 'smoke')], check=True)
