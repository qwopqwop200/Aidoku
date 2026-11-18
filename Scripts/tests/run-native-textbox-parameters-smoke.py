#!/usr/bin/env python3
"""Bounded saved-manifest compatibility check; no shared cache/render/OCR/API."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTextBoxGeometryParameters.swift'
PROGRAM = r'''
import Foundation
let original: [String: Any] = ["sourceMarginMinimum": 1.5, "sourceMarginMaximum": 2.25,
    "sourceWidthRatio": 0.12, "sourceFontRatio": 0, "openPanelExpansion": 0.75]
func decode(_ raw: [String: Any]) throws -> NativeTextBoxGeometryParameters {
    try JSONDecoder().decode(NativeTextBoxGeometryParameters.self,
        from: JSONSerialization.data(withJSONObject: raw))
}
let old = try decode(original)
precondition(old.isValid && old.observedFamilyRatiosEnabled == nil)
precondition(old.diagnosticValues["observedFamilyRatiosEnabled"] == 0)
var checks = 2
for value: Double in [0, 1, -1, 0.5, 2] {
    var raw = original; raw["observedFamilyRatiosEnabled"] = value
    let p = try decode(raw)
    precondition(p.isValid == (value == 0 || value == 1)); checks += 1
    precondition(p.sourceMarginMinimum == old.sourceMarginMinimum &&
        p.sourceMarginMaximum == old.sourceMarginMaximum && p.sourceWidthRatio == old.sourceWidthRatio &&
        p.sourceFontRatio == old.sourceFontRatio && p.openPanelExpansion == old.openPanelExpansion)
    checks += 1
}
var null = original; null["observedFamilyRatiosEnabled"] = NSNull()
let decodedNull = try decode(null)
precondition(decodedNull.observedFamilyRatiosEnabled == nil); checks += 1
for invalid: Any in [true, "1"] {
    var raw = original; raw["observedFamilyRatiosEnabled"] = invalid
    do { _ = try decode(raw); fatalError("Non-numeric trial switch accepted") }
    catch { checks += 1 }
}
print("PASS \(checks) saved-parameter compatibility and explicit trial validation checks")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-textbox-parameters-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(PROGRAM)
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(work / 'modules'),
                    str(SOURCE), str(work / 'main.swift'), '-o', str(work / 'probe')], check=True)
    subprocess.run([str(work / 'probe')], check=True)
