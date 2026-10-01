#!/usr/bin/env python3
"""Read-only comparisons of actual iOS51 backing routes and preserved host controls."""
from pathlib import Path
import hashlib,json
import numpy as np
ROOT=Path(__file__).resolve().parents[3]
BASE=ROOT/'build/native-render-parity'; SNAP=BASE/'verify-source-canvas-backing-build51-snapshot'
OUT=BASE/'source-canvas-clip/backing51-analysis'; OUT.mkdir(parents=True,exist_ok=True)
inputs={}
def read(path,width=960,height=480):
    raw=path.read_bytes(); inputs[str(path.relative_to(ROOT))]=hashlib.sha256(raw).hexdigest()
    return np.frombuffer(raw,dtype=np.uint8).reshape(height,width,4)
def metric(a,b):
    d=np.abs(a.astype(np.int16)-b.astype(np.int16)); ys,xs=np.nonzero(np.any(d,axis=2))
    return dict(changedPixels=int(len(xs)),maxChannelDelta=int(d.max()),exactRGBA=len(xs)==0,
                bounds=None if len(xs)==0 else [int(xs.min()),int(ys.min()),int(xs.max()+1),int(ys.max()+1)])
roi=np.s_[21:384,405:678]
rows=[]
for bg in ['transparent','opaque']:
    values={k:read(SNAP/bg/(k+'.rgba')) for k in ['web-default','web-read-frequently','native-view-hierarchy']}
    rows.append(dict(background=bg,comparison='default vs readFrequently',scope='entire captured960x480',**metric(values['web-default'],values['web-read-frequently'])))
    for quality in ['CG-default','CG-low','zero']:
        v=read(BASE/'source-canvas-clip/alpha48-gpu'/bg/(quality+'.rgba'))
        for key,w in values.items():
            rows.append(dict(background=bg,comparison=quality+' vs '+key,scope='actual mask273x363 ROI; local bounds',**metric(v[roi],w[roi])))
    old=read(BASE/'verify-source-canvas-alpha-build48-snapshot'/bg/'web-live-320.rgba')
    for key,w in values.items():
        rows.append(dict(background=bg,comparison='actual48 vs '+key,scope='actual mask273x363 ROI; local bounds',**metric(old[roi],w[roi])))
source_controls=[]
for p in sorted((BASE/'source-canvas-clip/cg-source-format51').glob('*.rgba')):
    v=read(p,273,363); row=dict(source=p.stem)
    for key in ['web-default','web-read-frequently','native-view-hierarchy']:
        row[key]=metric(v,read(SNAP/'transparent'/(key+'.rgba'))[roi])
    source_controls.append(row)
report=dict(scope='Descriptive immutable actual iOS51/48 route comparisons and five host source-format controls. No exact full-alpha acceptance claim.',
    capturedGeometry=dict(frameCSS=[135,7,91,121],DPR=3,ROI=[405,21,273,363]),
    comparisons=rows,sourceFormatControls=source_controls,
    conclusions=[
        'Public iOS UIView drawHierarchy ROI equals prior direct CPU CGContext default control on both backgrounds.',
        'Five CGImage PNG/PMA RGBA/PMA BGRA representations all yield the same CPU minification result and equal the iOS UIView ROI.',
        'Web default and willReadFrequently routes differ despite identical serialized canonical source buffers.',
        'Transparent actual48 mask ROI equals iOS51 readFrequently route exactly.',
        'Scripts differ in canvas.toDataURL timing:48 before the two RAFs,51 after. These data do not isolate readback timing from readFrequently flag or resident backing state.'
    ],
    unresolved='WebKit resident image-buffer minification/backend semantics remain unknown; no arbitrary sampler parameters accepted.',
    inputSHA256=inputs,analysisSourceSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
(OUT/'report.json').write_text(json.dumps(report,indent=2))
print(json.dumps({'actualDefaultReadFrequently':[x for x in rows if x['comparison']=='default vs readFrequently'],'sourceRepresentations':len(source_controls),'report':str(OUT/'report.json')},indent=2))
