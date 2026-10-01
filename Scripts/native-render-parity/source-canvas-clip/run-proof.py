#!/usr/bin/env python3
"""Capture twelve real WK clip shapes and compare the actual native helper."""
from pathlib import Path
import hashlib,json,subprocess,sys
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/source-canvas-clip';OUT.mkdir(parents=True,exist_ok=True)
frozen=ROOT/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'
digest=hashlib.sha256(frozen.read_bytes()).hexdigest()
assert digest=='439bb538820eb9d270be480e68141ddfc0dc2bfdb1bed53d697a4815f072e7d2','Frozen oracle changed'
text=frozen.read_text();start=text.index('    function aidokuCleanupClip(');end=text.index('\n    }',start)+len('\n    }')
(OUT/'frozen-helper.js').write_text(text[start:end]);(OUT/'inputs.json').write_bytes((HERE/'inputs.json').read_bytes())
(OUT/'provenance.json').write_text(json.dumps(dict(frozenPath=str(frozen.relative_to(ROOT)),frozenSHA256=digest,lines=[1115,1119]),indent=2))
subprocess.run(['xcrun','swiftc','-O',str(HERE/'capture.swift'),'-o',str(OUT/'capture')],check=True)
subprocess.run([str(OUT/'capture'),str(OUT/'inputs.json'),str(OUT/'frozen-helper.js'),str(OUT)],check=True)
helper=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeSourceCanvasClip.swift'
subprocess.run(['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete','-O',str(helper),str(HERE/'probe.swift'),'-o',str(OUT/'probe')],check=True)
paths=[helper,HERE/'probe.swift',OUT/'probe']
(OUT/'native-compile-manifest.json').write_text(json.dumps(dict(compiler='xcrun swiftc -swift-version 6 -strict-concurrency=complete -O',hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}),indent=2))
subprocess.run([str(OUT/'probe'),str(OUT/'web.json'),str(OUT/'native.json')],check=True)
subprocess.run([sys.executable,str(HERE/'verify.py')],check=True)
