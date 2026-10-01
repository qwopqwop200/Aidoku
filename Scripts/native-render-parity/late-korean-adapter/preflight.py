#!/usr/bin/env python3
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent;OUT=ROOT/'build/native-render-parity/late-korean-adapter';OUT.mkdir(parents=True,exist_ok=True);O=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
subprocess.run(['swiftc','-O',str(O/'NativeTranslationTypography.swift'),str(O/'NativeBalloonUnitParts.swift'),str(HERE/'Preflight.swift'),'-o',str(OUT/'preflight')],check=True)
subprocess.run([str(OUT/'preflight'),str(OUT/'preflight-report.json')],check=True)
print((OUT/'preflight-report.json').read_text())
