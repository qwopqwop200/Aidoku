#!/usr/bin/env python3
"""Focused tests of the actual native geometry selector, without models or GT."""
import hashlib,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
CACHE=ROOT/'build/geometry-dedup-tests';CACHE.mkdir(parents=True,exist_ok=True)
OCR=ROOT/'Aidoku/Core/Translation/NativeEngine/OCR'
files=[OCR/'NativeOCRIndividualGeometryHypotheses.swift',OCR/'NativeOCRGeometryDeduplication.swift',Path(__file__).parent/'geometry-dedup/GeometryDedupSmoke.swift']
fingerprint=hashlib.sha256(b''.join(p.read_bytes()for p in files)).hexdigest();stamp=CACHE/'fingerprint';binary=CACHE/'smoke'
if not binary.exists()or not stamp.exists()or stamp.read_text()!=fingerprint:
 output_map={'':{'swift-dependencies':str(CACHE/'master.swiftdeps')}}
 for p in files:output_map[str(p)]={'object':str(CACHE/(p.stem+'.o')),'swift-dependencies':str(CACHE/(p.stem+'.swiftdeps'))}
 mapfile=CACHE/'output-map.json';mapfile.write_text(json.dumps(output_map))
 subprocess.run(['xcrun','swiftc','-O','-incremental','-enable-batch-mode','-j2','-parse-as-library','-module-name','GeometryDedupSmoke','-output-file-map',str(mapfile),*[str(p)for p in files],'-o',str(binary)],check=True)
 stamp.write_text(fingerprint)
subprocess.run([str(binary)],check=True)
