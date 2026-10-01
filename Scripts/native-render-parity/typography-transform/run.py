#!/usr/bin/env python3
import pathlib,subprocess,time,json
root=pathlib.Path(__file__).resolve().parents[3]
build=root/'build/native-render-parity/typography-transform';build.mkdir(parents=True,exist_ok=True)
start=time.monotonic()
subprocess.run(['swiftc','-O','Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationTypography.swift',
               'Scripts/native-render-parity/typography-transform/main.swift','-o',str(build/'transform')],cwd=root,check=True)
compiled=time.monotonic()-start;start=time.monotonic()
report=json.loads(subprocess.check_output([str(build/'transform')],cwd=root))
report.update(compileSeconds=compiled,executionSeconds=time.monotonic()-start)
(build/'report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report))
