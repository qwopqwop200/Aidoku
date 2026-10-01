from pathlib import Path
import json,re,subprocess,zlib,struct
ROOT=Path(__file__).resolve().parents[4];HERE=Path(__file__).resolve().parent;O=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';OUT=ROOT/'build/native-render-parity/vertical-ideograph-paint';OUT.mkdir(parents=True,exist_ok=True)
BASE=ROOT/'build/native-render-parity/vertical-content-fit';OPT=ROOT/'build/native-render-parity/vertical-optical-tracking'
sources=[OPT/'TypographyCandidate.swift',O/'NativeTextPaintGeometry.swift',*[O/(n+'.swift') for n in ('NativePreformattedTabs','NativeKeepAllAutoLines','NativeKeepAllTextBalance','NativeKeepAllBreakOpportunities','NativeRawTextBalance','NativeVerticalLetterSpacing','NativeNormalTextFlow','NativeNormalBreakOpportunities','NativeCTFontStrokePainter')],HERE/'NativeVerticalIdeographOpticalTracking.swift',OUT/'ShiftPaintProbe.swift']
subprocess.run(['xcrun','swiftc','-O','-swift-version','6',*map(str,sources),'-o',str(OUT/'shift-probe')],check=True)
