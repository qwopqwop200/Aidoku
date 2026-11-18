"""Incremental shared native domain checks; no images or GT read."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT=Path(__file__).resolve().parents[2]
engine=ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble'
sources=[engine/(n+'.swift')for n in ('NativeTextPlacementGuide','NativeTextExpansionPolicy','NativeSourceClusterAlignment')]
sources.append(Path(__file__).with_name('NativeMaskIntervalDomainSmoke.swift'))
out=ROOT/'build/mask-interval-domain-smoke';out.mkdir(parents=True,exist_ok=True)
identity=hashlib.sha256(b''.join(p.read_bytes()for p in sources)).hexdigest();stamp=out/'SOURCE-SHA256';binary=out/'checks'
if not binary.exists()or not stamp.exists()or stamp.read_text()!=identity:
    mapping={str(p):dict(object=str(out/(p.stem+'.o')),**{'swift-dependencies':str(out/(p.stem+'.swiftdeps'))})for p in sources}
    mapping['']={'swift-dependencies':str(out/'master.swiftdeps')}
    path=out/'output-file-map.json';path.write_text(json.dumps(mapping))
    subprocess.run(['xcrun','swiftc','-O','-incremental','-enable-batch-mode','-j2','-parse-as-library',
        '-module-name','MaskIntervalDomainSmoke','-output-file-map',str(path),*map(str,sources),'-o',str(binary)],check=True)
    stamp.write_text(identity)
subprocess.run([str(binary)],check=True)
