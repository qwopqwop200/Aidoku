from pathlib import Path
import hashlib,json,subprocess
ROOT=Path(__file__).resolve().parents[4]
OUT=ROOT/'build/native-render-parity/source-canvas-clip/affine-module-tests';OUT.mkdir(parents=True,exist_ok=True)
helper=ROOT/'Scripts/native-render-parity/source-canvas-clip/staged/NativeCanvasTextureResampler+AffineCandidate.swift'
tests=[ROOT/'AidokuTests/Translation/NativeEngine/NativeCanvasTextureResamplerTests.swift',ROOT/'Scripts/native-render-parity/source-canvas-clip/staged/NativeCanvasAffineTextureResamplerTests.swift']
snapshot=OUT/'NativeCanvasTextureResampler.swift';snapshot.write_bytes(helper.read_bytes())
test=OUT/'Tests.swift';test.write_text('\n'.join(p.read_text().replace('@testable import Aidoku\n','') for p in tests)+'\n@main struct HostTests {static func main() async {exit(await Testing.__swiftPMEntryPoint())}}\n')
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());framework=dev/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
cmd=['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(framework),'-load-plugin-library',str(macro),str(snapshot),str(test),'-Xlinker','-rpath','-Xlinker',str(framework),'-o',str(OUT/'tests')]
r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(OUT/'compile.log').write_text(r.stdout);print(r.stdout,end='')
if not r.returncode:
 r=subprocess.run([str(OUT/'tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(OUT/'tests.log').write_text(r.stdout);print(r.stdout,end='')
(OUT/'report.json').write_text(json.dumps(dict(passed=r.returncode==0,testDeclarations=13,parameterCases=15,scope='Actual staged affine API plus all 6 existing production primitive tests; PMA Float-over, bounded tiled whole/crop agreement across nonuniform/fractional/rotation, invalid-before-upload, session close, cancellation. No actual iOS affine integration or minification parity claim.',sourceSHA256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [helper,*tests]},artifactSHA256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [snapshot,test,OUT/'tests',OUT/'tests.log'] if p.exists()}),indent=2))
raise SystemExit(r.returncode)
