from pathlib import Path
import re,subprocess,json,hashlib
root=Path(__file__).resolve().parents[3]
folder=Path(__file__).parent
main=(folder/'staged/NativeTranslationRenderer.swift').read_text()
paint=(folder/'staged/NativeTranslationRenderer+PaintOrder.swift').read_text()
original=(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationRenderer.swift').read_text()
out=root/'build/native-render-parity/source-canvas-async-bridge'
out.mkdir(parents=True,exist_ok=True)
helper=out/'NativeAsyncBridgeSDK.swift'
prepared=main[main.index('    /// Private worker value.'):main.index('\n    static func initialSlantedTypography')]
worker=main[main.index('private actor NativeTranslationRenderWorker'):main.index('\n/// Native bitmap composition.')]
async_methods=(folder/'async_methods.swift.txt').read_text()
privates='\n'.join(re.findall(r'    private static func [\s\S]*?\n    }',original))
order=paint[paint.index('    static func orderedPaintCommands('):paint.rindex('\n}')]
ui=(root/'Scripts/native-render-parity/source-canvas-clip/staged/NativeSourceCanvasHierarchyCompositor.swift').read_text()
gate=(root/'Scripts/native-render-parity/render-admission/staged/NativeTranslationRenderAdmission.swift').read_text()
tests=(folder/'staged/NativeRenderAsyncBridgeTests.swift').read_text().replace('@testable import Aidoku\n','')
alpha=(folder/'staged/NativeSourceCanvasAlphaPaintParityCapture.swift').read_text().replace('@testable import Aidoku\n','')
helper.write_text('@testable import Aidoku\nimport UIKit\nimport CoreText\n'+gate+'\n'+ui+'\n'+worker+'\nextension NativeTranslationRenderer {\n'+prepared+async_methods+privates+'\n'+order+'\n}\n'+tests+'\n'+alpha)
runner=root/'Scripts/native-render-parity/source-canvas-clip/ios/typecheck-foreign-background-capture.py'
result=subprocess.run(['python3',str(runner),'--build-label','65-production62-main','--helper',str(helper),'--expected-count','0'],cwd=root,capture_output=True,text=True)
(out/'typecheck.log').write_text(result.stdout+result.stderr)
print(result.stdout+result.stderr)
report={'passed':result.returncode==0,'scope':'Strict Swift6 actual SDK semantics of verbatim staged worker/prepare/finish/ordered command helpers and UI/admission against Root production62; no runtime or full-source build', 'files':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [folder/'staged/NativeTranslationRenderer.swift',folder/'staged/NativeTranslationRenderer+PaintOrder.swift',folder/'staged/NativeRenderAsyncBridgeTests.swift',folder/'staged/NativeSourceCanvasAlphaPaintParityCapture.swift',root/'Scripts/native-render-parity/source-canvas-clip/staged/NativeSourceCanvasHierarchyCompositor.swift',root/'Scripts/native-render-parity/render-admission/staged/NativeTranslationRenderAdmission.swift',helper]}}
(out/'report.json').write_text(json.dumps(report,indent=2))
raise SystemExit(result.returncode)
