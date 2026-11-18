#!/usr/bin/env python3
"""Run the same focused CoreText spacing assertions without the shared app cache."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble'
source = (ROOT / 'AidokuTests/NativeTextSpacingTests.swift').read_text()
names = re.findall(r'@Test func (\w+)\(', source)
assert len(names) == 10
source = source.replace('import Testing\n', '').replace('@testable import Aidoku\n', '')
source = source.replace('@Test func ', 'func ').replace('#expect(', 'precondition(')
shell = '''import CoreGraphics
struct NativeAOTTranslationPageComposer {
 struct TranslatedFillPrimitive {let image: CGImage; let frame: CGRect; let fontOutputPixels: CGFloat}
}
'''
with tempfile.TemporaryDirectory(prefix='aidoku-text-spacing-') as directory:
    directory = Path(directory)
    fixture = directory / 'Check.swift'
    fixture.write_text(shell + source + '\n@main struct Check { static func main() throws {\nlet suite = NativeTextSpacingTests()\n' +
                       '\n'.join('try suite.' + name + '()' for name in names) + '\nprint("PASS: 10 CoreText spacing checks")\n}}\n')
    painter = directory / 'Painter.swift'
    painter.write_text((ENGINE / 'NativeWholeWordGlyphPainter.swift').read_text().split('extension NativeAOTRawTextPainter {')[0])
    sources = [ENGINE / (name + '.swift') for name in ['NativeTextSpacing', 'NativeLineBreakPolicy',
               'NativeNecessaryCJKBreaks', 'NativeWholeWordWrap']]
    binary = directory / 'check'
    subprocess.run(['xcrun', 'swiftc', '-O', *map(str, sources), str(painter), str(fixture), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
