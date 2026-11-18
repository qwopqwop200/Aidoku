#!/usr/bin/env python3
"""Focused production admission: source detector tilt is not painted text tilt."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationRenderer+CohortTextCommit.swift').read_text()
start = source.index('    static func cohortBackingIsUpright(')
end = source.index('\n    /// One shared', start)
method = source[start:end]
program = '''import Foundation
import CoreGraphics
enum NativeTranslationRenderer {
''' + method + '''
}
func check(_ value: Bool) { precondition(value) }
let angles: [CGFloat] = [-0.127, 0, 0.1]
for original in angles {
    for painted in angles {
        for straightened in [false, true] {
            let expected = painted == 0 && (original == 0 || straightened)
            check(NativeTranslationRenderer.cohortBackingIsUpright(sourceRotation: original,
                textRotation: painted, hasStraightenedBacking: straightened) == expected)
        }
    }
}
check(!NativeTranslationRenderer.cohortBackingIsUpright(sourceRotation: .nan,
    textRotation: 0, hasStraightenedBacking: true))
check(!NativeTranslationRenderer.cohortBackingIsUpright(sourceRotation: 0,
    textRotation: .infinity, hasStraightenedBacking: true))
print("PASS: upright text plus straightened backing accepted; actual painted rotations and invalid evidence rejected")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-cohort-upright-') as directory:
    temporary = Path(directory)
    (temporary / 'main.swift').write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(temporary / 'modules'),
                    str(temporary / 'main.swift'), '-o', str(temporary / 'probe')], check=True)
    subprocess.run([str(temporary / 'probe')], check=True)
