#!/usr/bin/env python3
"""Test the exact production helper, including the saved owner/face contradiction."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTextBoxContainment.swift').read_text()
start = source.index('    static func sourcePreservingIntersection(')
end = source.index('\n    }', start) + len('\n    }')
method = source[start:end]
integration = (ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationRenderer+TextBoxes.swift').read_text()
assert 'AIDOKU_EXPERIMENT_PRESERVE_SOURCE_INTERSECTION' in integration
assert 'box = NativeTextBoxContainment.sourcePreservingIntersection(panel: box,' in integration
harness = '''import Foundation
import CoreGraphics
enum NativeTextBoxContainment {
''' + method + '''
}
let panel = CGRect(x: 5, y: 5, width: 100, height: 40)
let owner = CGRect(x: 10, y: 10, width: 90, height: 20)
let partial = CGRect(x: 8, y: 8, width: 80, height: 30)
precondition(NativeTextBoxContainment.sourcePreservingIntersection(panel: panel, surfaceBounds: partial, owner: owner) == panel)
let complete = CGRect(x: 8, y: 8, width: 94, height: 25)
precondition(NativeTextBoxContainment.sourcePreservingIntersection(panel: panel, surfaceBounds: complete, owner: owner) == panel.intersection(complete))
for surface: CGRect in [.null, .zero, CGRect(x: 200, y: 200, width: 20, height: 20)] {
    precondition(NativeTextBoxContainment.sourcePreservingIntersection(panel: panel, surfaceBounds: surface, owner: owner) == panel)
}
// Saved contradiction: the estimated face maxX is left of the accepted owner.
let observedOwner = CGRect(x: 12.541666666666666, y: 176.3, width: 286.30833333333334, height: 12.541666666666657)
let incumbent = observedOwner.insetBy(dx: -2, dy: -2)
let face = CGRect(x: 12.09375, y: 171.42890625, width: 280.84375, height: 21.1640625)
precondition(!incumbent.intersection(face).contains(observedOwner))
let preserved = NativeTextBoxContainment.sourcePreservingIntersection(panel: incumbent, surfaceBounds: face, owner: observedOwner)
precondition(preserved == incumbent && preserved.contains(observedOwner))
// Retention is NOT evidence that the incumbent lies in the face.
precondition(!face.contains(preserved))
print("PASS: source-preserving intersection, incomplete/disjoint surfaces, unchanged incumbent, explicit containment contradiction")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-source-intersection-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', '-O', str(work / 'main.swift'), '-o', str(work / 'probe')], check=True)
    subprocess.run([str(work / 'probe')], check=True)
