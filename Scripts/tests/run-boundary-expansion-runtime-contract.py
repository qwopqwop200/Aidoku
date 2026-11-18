#!/usr/bin/env python3
"""Actual default-off compatibility/TaskLocal helper, no models/shared build."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
helper = (ROOT / "Aidoku/Core/Translation/NativeEngine/OCR/NativeSimpleOCRBoundaryExpansionRuntime.swift").read_text()
helper = helper[:helper.index("    /// Shared actual packet seam")] + "}\n"
program = '''import Foundation
enum NativeSimpleOCRBoundaryExpansion {
    struct Configuration: Equatable, Sendable { var threshold: Double = 0.3940652310848236; var margin: Double = 0.025 }
}
enum NativeOCRRawCanonicalPolicy {
    enum SourceAnchorMode: CaseIterable { case disabled, fixedPreRecognition, noPreRecognition, noPreRecognitionTerminalRecovery }
}
''' + helper + '''
typealias R = NativeSimpleOCRBoundaryExpansionRuntime
precondition(R.configuration == nil)
try R.validateCompatibility(mode:.noPreRecognition,usesSimpleDeduplication:true,observingModules:false,compactAgreementEnabled:true)
var rejected = 0
for mode in NativeOCRRawCanonicalPolicy.SourceAnchorMode.allCases {
    for simple in [false,true] { for observer in [false,true] { for compact in [false,true] {
        let allowed = mode == .noPreRecognition && simple && !observer && compact
        do {
            try R.validateCompatibility(mode:mode,usesSimpleDeduplication:simple,observingModules:observer,compactAgreementEnabled:compact)
            precondition(allowed)
        } catch R.Failure.incompatiblePolicy { precondition(!allowed); rejected += 1 }
    } } }
}
precondition(rejected == 31)
R.$configuration.withValue(.init()) {
    precondition(R.configuration?.margin == 0.025)
    R.$configuration.withValue(nil) { precondition(R.configuration == nil) }
    precondition(R.configuration != nil)
}
precondition(R.configuration == nil)
print("PASS actual runtime helper:defaultOFF,31 explicit incompatible cases,sole supported routing,TaskLocal restoration; models0")
'''
with tempfile.TemporaryDirectory(prefix="boundary-runtime-contract-") as folder:
    path = Path(folder)
    (path / "main.swift").write_text(program)
    subprocess.run(["xcrun", "swiftc", str(path / "main.swift"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
