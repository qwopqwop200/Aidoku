"""Real CoreText shaping/ink geometry only; no bitmap or page rendering."""
from pathlib import Path
import subprocess
import time
ROOT=Path(__file__).resolve().parents[2]
BASE=ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble'
OUT=ROOT/'build/line-break-policy-smoke'
OUT.mkdir(parents=True,exist_ok=True)
files=['NativeTextSpacing.swift','NativeLineBreakPolicy.swift','NativeRenderWrapQuality.swift','NativeWholeWordWrap.swift','NativeWholeWordWrap+Proposals.swift','NativeNecessaryCJKBreaks.swift','NativeWholeWordGlyphPainter.swift','NativeFinalTextFlow.swift','NativeTextAlignmentPolicy.swift']
files+=['NativeTextExpansionPolicy.swift','NativeTextPlacementGuide.swift','NativeSourceClusterAlignment.swift','NativeContourWordWrap.swift']
start=time.monotonic()
subprocess.run(['xcrun','swiftc','-O',*[str(BASE/n) for n in files],str(Path(__file__).with_name('NativeLineBreakPolicySmoke.swift')),'-o',str(OUT/'checks')],check=True)
print('compileSeconds',round(time.monotonic()-start,3),flush=True)
subprocess.run([str(OUT/'checks'),str(OUT/'RESULT.json')],check=True)
