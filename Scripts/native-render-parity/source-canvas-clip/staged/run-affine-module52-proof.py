from pathlib import Path
import hashlib,json,subprocess
ROOT=Path(__file__).resolve().parents[4]
OUT=ROOT/'build/native-render-parity/source-canvas-clip/affine-module52-proof';OUT.mkdir(parents=True,exist_ok=True)
helper=ROOT/'Scripts/native-render-parity/source-canvas-clip/staged/NativeCanvasTextureResampler+AffineCandidate.swift'
driver=ROOT/'Scripts/native-render-parity/source-canvas-clip/staged/affine-module52-proof.swift'
reference=ROOT/'build/native-render-parity/verify-source-canvas-transform-build52-snapshot'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
manifest={str(p.relative_to(ROOT)):sha(p) for p in [helper,driver,*reference.rglob('*.rgba'),*reference.rglob('web-dom-and-saved-masks.json')]}
(OUT/'source-manifest.json').write_text(json.dumps(manifest,indent=2))
hcopy=OUT/'NativeCanvasTextureResampler.swift';hcopy.write_bytes(helper.read_bytes());dcopy=OUT/'Driver.swift';dcopy.write_bytes(driver.read_bytes())
command=['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete',str(hcopy),str(dcopy),'-o',str(OUT/'probe')]
(OUT/'compile-command.json').write_text(json.dumps(command,indent=2))
r=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(OUT/'compile.log').write_text(r.stdout);print(r.stdout,end='')
if not r.returncode:
 r=subprocess.run([str(OUT/'probe'),str(reference),str(OUT)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(OUT/'probe.log').write_text(r.stdout);print(r.stdout,end='')
assert all(sha(ROOT/p)==v for p,v in manifest.items()),'Proof sources changed during execution'
results=json.loads((OUT/'all-eight-results.json').read_text()) if not r.returncode else []
report={'completed':r.returncode==0,'allRGBAExact':len(results)==8 and all(x['metrics']['changedPixels']==0 for x in results),'exactCaptures':sum(x['metrics']['changedPixels']==0 for x in results),'captureCount':len(results),'fullVsCropExact':bool(results) and all(x['cropAgreement']['changedPixels']==0 for x in results),'scope':'Current staged bounded affine implementation replay of immutable actual iOS52 full RGBA; same source/DOM/matrix. Six capture results exact; rotation residuals remain FAIL. No production consumer/iOS integration/minification claim. All frame/crop/PMA assertions executed in actual compiled driver.','results':results,'sourceSHA256':manifest,'artifactSHA256':{p.name:sha(p) for p in [hcopy,dcopy,OUT/'probe',OUT/'probe.log'] if p.exists()}}
(OUT/'report.json').write_text(json.dumps(report,indent=2));raise SystemExit(r.returncode)
