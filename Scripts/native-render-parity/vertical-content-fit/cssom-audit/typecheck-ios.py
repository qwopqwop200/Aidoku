"""SDK-only isolated staged capture check; no build, install, simulator, app edits."""
from pathlib import Path
import subprocess,json,hashlib
ROOT=Path(__file__).resolve().parents[4];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/vertical-content-fit/current47-audit/ios-stage';OUT.mkdir(parents=True,exist_ok=True)
snapshot=OUT.parent/'source-snapshot'
test=OUT/'Capture.swift';test.write_text((HERE/'NativeVerticalCSSOMParityCapture.staged.swift').read_text().replace('@testable import Aidoku\n',''))
sources=[p for p in snapshot.glob('*.swift') if p.name!='Probe.swift']+[test]
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
frameworks=dev/'Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks'
plugin=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
cmd=['xcrun','swiftc','-typecheck','-swift-version','6','-strict-concurrency=complete','-target','arm64-apple-ios18.0-simulator','-sdk',sdk,'-F',str(frameworks),'-load-plugin-library',str(plugin),*map(str,sources)]
r=subprocess.run(cmd,text=True,capture_output=True)
(OUT/'typecheck.log').write_text(r.stdout+r.stderr)
report=dict(passed=r.returncode==0,scope='isolated iOS SDK typecheck only; does not execute WK or simulator',sourceSHA256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
(OUT/'typecheck-report.json').write_text(json.dumps(report,indent=2));print(r.stderr);print('PASS' if r.returncode==0 else 'FAIL');raise SystemExit(r.returncode)
