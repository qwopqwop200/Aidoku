#!/usr/bin/env python3
"""Focused native invariants for conditional learned proposal materialization."""
import hashlib,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];OCR=ROOT/'Aidoku/Core/Translation/NativeEngine/OCR'
CACHE=ROOT/'build/conditional-learned-emission-tests';CACHE.mkdir(parents=True,exist_ok=True)
files=[OCR/'NativeOCRIndividualGeometryHypotheses.swift',OCR/'NativeOCRGeometryDeduplication.swift',OCR/'NativeOCRConditionalLearnedEmission.swift',Path(__file__).parent/'conditional-learned-emission/ConditionalLearnedEmissionSmoke.swift']
digest=hashlib.sha256(b''.join(p.read_bytes()for p in files)).hexdigest();stamp=CACHE/'fingerprint';binary=CACHE/'smoke'
if not binary.exists()or not stamp.exists()or stamp.read_text()!=digest:
 output={'':{'swift-dependencies':str(CACHE/'master.swiftdeps')}}
 for p in files:output[str(p)]={'object':str(CACHE/(p.stem+'.o')),'swift-dependencies':str(CACHE/(p.stem+'.swiftdeps'))}
 path=CACHE/'output-map.json';path.write_text(json.dumps(output));subprocess.run(['xcrun','swiftc','-O','-incremental','-enable-batch-mode','-j2','-parse-as-library','-module-name','ConditionalLearnedEmissionSmoke','-output-file-map',str(path),*[str(p)for p in files],'-o',str(binary)],check=True);stamp.write_text(digest)
subprocess.run([str(binary)],check=True)
