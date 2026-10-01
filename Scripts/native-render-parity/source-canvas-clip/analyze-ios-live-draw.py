from pathlib import Path
import json,subprocess,numpy as np,hashlib
ROOT=Path(__file__).resolve().parents[3];BASE=ROOT/'build/native-render-parity/verify-source-canvas-build42-snapshot'
OUT=ROOT/'build/native-render-parity/source-canvas-clip/ios-live-factor';OUT.mkdir(exist_ok=True)
records=[]
for scene in ['original-six','negative-global']:
 d=BASE/scene
 for requested in [320,640]:
  metadata=json.loads((d/f'web-live-{requested}-capture.json').read_text());w,h=metadata['width'],metadata['height'];scale=w/640
  web=np.fromfile(d/f'web-live-{requested}.rgba',np.uint8).reshape(h,w,4)
  native=np.fromfile(d/f'native-live-{requested}.rgba',np.uint8).reshape(h,w,4)
  # Read-only fixture baseline model: all observed liveWeb content has62CSS
  # automatic safe-area offset. .never production-compatible capture is pending.
  offset=round(62*scale);shifted=np.full_like(web,255);shifted[:h-offset]=web[offset:]
  for mode in ['raw','snapped']:
   for quality in ['default','none','low','medium','high']:
    file=OUT/f'{scene}-{requested}-{mode}-{quality}.rgba'
    subprocess.run([str(ROOT/'build/native-render-parity/source-canvas-clip/paint-live'),str(d),str(w),str(h),str(file),mode,quality],check=True)
    a=np.fromfile(file,np.uint8).reshape(h,w,4)
    diff=np.abs(a.astype(np.int16)-shifted.astype(np.int16))
    records.append(dict(scene=scene,requested=requested,geometry=mode,quality=quality,nativeHostMatchesIOS42Raw=bool(np.array_equal(a,native)),changedAgainstReadOnlyShiftedWeb=int(np.any(diff,axis=2).sum()),maxDelta=int(diff.max())))
report=dict(scope='Host CoreGraphics surrogate drawing actualiOS sourcePNG inputs. Raw host match to actual nativeiOS establishes only the observed matched quality route. Web62CSS fixture offset removed in-memory for diagnosis only; immutable oracle andfinalstrictgate unmodified. Actual.never iOS43 capture required before liveRGBA equality claim.',experiments=records)
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(records,indent=2))
