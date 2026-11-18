#!/usr/bin/env python3
"""Exact production geometry proposal; does not certify final pixels or contours."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTextBoxEarlySurfaceTrial.swift').read_text()
start = source.index('    static func sourceCoveredProposal(')
end = source.index('\n    }', start) + len('\n    }')
containment = (ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTextBoxContainment.swift').read_text()
separate = containment[containment.index('    static func separated('):containment.rfind('\n}')]
harness = '''import Foundation
import CoreGraphics
enum NativeTextBoxEarlySurfaceTrial {
''' + source[start:end] + '''
}
enum NativeTextBoxContainment {
''' + separate + '''
}
// A search domain overlaps its peer; the observed usable face does not.
let panels = [CGRect(x: 5, y: 10, width: 50, height: 85), CGRect(x: 51, y: 89, width: 40, height: 85)]
let owners = [CGRect(x: 17, y: 12, width: 27, height: 80), CGRect(x: 61, y: 90, width: 12, height: 80)]
let face = CGRect(x: 60, y: 91, width: 15, height: 81)
let proposal = NativeTextBoxEarlySurfaceTrial.sourceCoveredProposal(panel: panels[1], surfaceBounds: face, owner: owners[1])!
precondition(proposal.contains(owners[1]) && panels[1].contains(proposal))
precondition(!face.contains(proposal)) // owner conflict remains explicit, not certified.
let coarse = NativeTextBoxContainment.separated(panels: panels, owners: owners, kept: [false, false])
let refined = NativeTextBoxContainment.separated(panels: [panels[0], proposal], owners: owners, kept: [false, false])
precondition(coarse[0] != panels[0] && refined[0] == panels[0])
precondition(refined[1].contains(owners[1]) && !refined[0].intersects(refined[1]))
for invalid: CGRect in [.null, .zero, CGRect(x: 500, y: 500, width: 10, height: 10)] {
    precondition(NativeTextBoxEarlySurfaceTrial.sourceCoveredProposal(panel: panels[1], surfaceBounds: invalid, owner: owners[1]) == nil)
}
precondition(NativeTextBoxEarlySurfaceTrial.sourceCoveredProposal(panel: panels[1], surfaceBounds: face, owner: owners[0]) == nil)
// Full observed face preserves the incumbent rather than inventing extra paint.
precondition(NativeTextBoxEarlySurfaceTrial.sourceCoveredProposal(panel: panels[1], surfaceBounds: panels[1].insetBy(dx: -10, dy: -10), owner: owners[1]) == panels[1])
print("PASS: exact source-preserving proposal before separation, peer capacity, no growth, invalid/foreign domains and explicit unknown containment")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-early-surface-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', '-O', str(work / 'main.swift'), '-o', str(work / 'probe')], check=True)
    subprocess.run([str(work / 'probe')], check=True)
