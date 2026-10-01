#!/usr/bin/env python3
"""Reuse the actual Card/CoreText host harness for the measured leading adapter."""
from pathlib import Path

template = Path(__file__).with_name('run-source-column-anchor-tests.py')
code = template.read_text()
replacements = {
    "expected_tests = 1": "expected_tests = 3",
    "card = renderer[renderer.index('    struct TextPart {'):renderer.index('    struct GlossCard {')]":
        "owner_transport += '\\n' + re.search(r'    struct InitialCaptionCSS[\\s\\S]*?\\n    }', (OVERLAY / 'NativeTranslationRenderer+CaptionReflow.swift').read_text()).group()\n"
        "card = renderer[renderer.index('    struct TextPart {'):renderer.index('    struct GlossCard {')]",
    "'build/native-render-parity/source-column-anchor-tests'": "'build/native-render-parity/caption-line-spacing-tests-50'",
    'NativeSourceColumnAnchorTests.swift': 'NativeCaptionLineSpacingTests.swift',
    "'cardPageLineRects', 'polishFinalGeometry'": "'cardPageLineRects', 'cardWholeRangeRect', 'polishFinalGeometry'",
    "sources = {OVERLAY / (name + '.swift') for name in names}":
        "names.extend(['NativeTranslationRenderer+CaptionLineSpacing','NativeCTFontStrokePainter','NativeCTFontVerticalPainter','NativeVerticalGlyphOrigins','NativeVerticalLetterSpacing','NativeVisibleControlGlyphs','NativeCTFontHorizontalFillPainter','NativePreLineTextFlow','NativeNormalTextFlow','NativeKeepAllBreakOpportunities','NativeKeepAllAutoLines','NativeKeepAllTextBalance','NativePreformattedTabs','NativeRawTextBalance','NativeNormalBreakOpportunities'])\n"
        "sources = {OVERLAY / (name + '.swift') for name in names}",
    'Unchanged app numeric cleanup-frame regression using production Card, polishPanelGeometry, CoreText and geometry.':
        'Actual measured leading adapter with production Card, CSS overflow and CoreText Range geometry.',
}
for old, new in replacements.items():
    assert code.count(old) == 1, old
    code = code.replace(old, new)
exec(compile(code, str(template), 'exec'), {'__file__': str(template), '__name__': '__main__'})
