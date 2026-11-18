#!/usr/bin/env python3
"""Actual paint controller with instrumented measurement stubs; no model/GT claim."""
from pathlib import Path
import hashlib,json,os,subprocess
R=Path(__file__).resolve().parents[2];C=R/'build/source-paint-single-pass-tests';C.mkdir(parents=True,exist_ok=True)
O=R/'Aidoku/Core/Translation/NativeEngine/OCR';files=[O/'NativeOCRIndividualGeometryHypotheses.swift',O/'NativeOCRGeometryDeduplication.swift',O/'NativeOCRSourcePaintGeometry.swift',Path(__file__).parent/'source-paint-single-pass/SourcePaintSinglePassSmoke.swift']
digest=hashlib.sha256(b''.join(p.read_bytes()for p in files)).hexdigest();stamp=C/'fingerprint';binary=C/'smoke'
if not binary.exists()or not stamp.exists()or stamp.read_text()!=digest:
 output={'':{'swift-dependencies':str(C/'master.swiftdeps')}}
 for p in files:output[str(p)]={'object':str(C/(p.stem+'.o')),'swift-dependencies':str(C/(p.stem+'.swiftdeps'))}
 path=C/'output-map.json';path.write_text(json.dumps(output));subprocess.run(['xcrun','swiftc','-O','-incremental','-enable-batch-mode','-j2','-parse-as-library','-module-name','SourcePaintSinglePassSmoke','-output-file-map',str(path),*[str(p)for p in files],'-o',str(binary)],check=True);stamp.write_text(digest)
subprocess.run([str(binary)],check=True,env=dict(os.environ,AIDOKU_OCR_SOURCE_PAINT_GEOMETRY='1'))
# Both native entrypoints must pass the actual current correction records.
for name,expected in [('NativeCoreMLOCRPipeline.swift','currentCorrections: paintCorrections'),('HostIndividualGeometry.swift','currentCorrections: paintCorrections')]:
 path=O/name if name.startswith('Native')else R/'Scripts/image-translation'/name
 source=path.read_text();assert expected in source
 assert 'queries: incumbent'not in source
 assert 'canonicalSeeds' in source
print('PASS: live and saved geometry entrypoints use direct corrections')
