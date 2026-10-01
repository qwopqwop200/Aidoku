"""Read-only current-source replay of the existing vertical CSSOM corpus."""
from pathlib import Path
import os
original=Path(__file__).resolve().parent.parent/'run-current-shaping.py'
root=original.parents[3]
os.environ.setdefault('AIDOKU_VERTICAL_PROBE_OUT',str(root/'build/native-render-parity/vertical-content-fit/current47-audit'))
code=original.read_text().replace("'NativeCTFontStrokePainter','NativeVerticalLetterSpacing'", "'NativeCTFontStrokePainter','NativeVerticalLetterSpacing','NativeCTFontVerticalPainter','NativeVerticalGlyphOrigins'")
exec(compile(code,str(original),'exec'),dict(__file__=str(original),__name__='__main__'))
