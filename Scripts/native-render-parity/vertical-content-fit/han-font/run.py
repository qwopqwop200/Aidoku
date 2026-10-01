#!/usr/bin/env python3
"""Real frozen WK Han font/PDF against native CoreText optical sizing."""
from pathlib import Path
import json,re,subprocess
ROOT=Path(__file__).resolve().parents[4];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/vertical-han-font';OUT.mkdir(parents=True,exist_ok=True)
BASE=ROOT/'build/native-render-parity/vertical-content-fit'
OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
assert (BASE/'dom.json').exists(), 'Run vertical-content-fit/run.py first to capture frozen CSS.'
fixture=json.loads((BASE/'dom.json').read_text())[396]['a']
assert fixture['script']=='han' and fixture['font']==20 and fixture['width']==8.5
script=(BASE/'capture.js').read_text()
script=re.sub(r' const jobs=.*?;\n',' const jobs='+json.dumps([fixture],ensure_ascii=False)+';\n',script,count=1)
script=script.replace('node.remove();return result;','return result;')
(OUT/'capture.js').write_text(script)
subprocess.run(['xcrun','swiftc',str(HERE/'Capture.swift'),'-o',str(OUT/'capture')],check=True)
def capture(script,name):
    path=OUT/(name+'.js');path.write_text(script)
    subprocess.run([str(OUT/'capture'),str(path),str(OUT/(name+'.json'))],check=True)
    (OUT/(name+'.pdf')).write_bytes((OUT/'web.pdf').read_bytes())
    return json.loads((OUT/(name+'.json')).read_text())
original=capture(script,'dom')[0]
fonts=re.findall(rb'/BaseFont\s*/([^\s/<>]+)',(OUT/'dom.pdf').read_bytes())
font_names=[v.decode().split('+')[-1] for v in fonts]
assert font_names==['PingFangSC-Semibold'],font_names
controls=[{}, {'fontSynthesis':'none'}, {'fontOpticalSizing':'none'}]
jobs=[dict(fixture,overrides=c) for c in controls]
control_script=re.sub(r' const jobs=.*?;\n',' const jobs='+json.dumps(jobs,ensure_ascii=False)+';\n',script,count=1)
control_script=control_script.replace('node.textContent=a.text;', 'Object.assign(node.style,a.overrides);node.textContent=a.text;')
control_script=control_script.replace('const result={a,itemBox,',"const ctx=document.createElement('canvas').getContext('2d');ctx.font=c.font;const measured=ctx.measureText('天');const result={a,itemBox,canvas:[measured.width,measured.actualBoundingBoxLeft,measured.actualBoundingBoxRight],")
observations=capture(control_script,'controls')
subprocess.run(['xcrun','swiftc','-O',str(OVERLAY/'NativeTranslationTypography.swift'),str(OVERLAY/'NativeTextPaintGeometry.swift'),str(HERE/'FontProbe.swift'),'-o',str(OUT/'font-probe')],check=True)
subprocess.run([str(OUT/'font-probe'),str(OUT/'native-fonts.json')],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['xcrun','swift',str(HERE/'OpticalProbe.swift'),str(OUT/'native-optical.json')],check=True,stdout=subprocess.DEVNULL)
native=json.loads((OUT/'native-optical.json').read_text())
plain=next(n for n in native if n['optical']==0 and not n['family'])
optical=next(n for n in native if n['optical']==20 and not n['family'])
auto=next(n for n in native if n['optical']=='auto')
vertical=next(n for n in native if n.get('verticalForms') is True)
horizontal=next(n for n in native if n.get('verticalForms') is False)
assert auto['width']==optical['width']
assert abs(horizontal['width']-20.14)<1e-10 and abs(vertical['width']-19.76)<1e-10
assert plain['name']==optical['name']==auto['name']==font_names[0]
assert abs(optical['width']-observations[0]['canvas'][0])<0.000002
assert observations[0]['itemBox'][3]==observations[1]['itemBox'][3]==20.140625
assert observations[2]['itemBox'][3]==19.765625
report=dict(passed=True,case=396,font=font_names[0],nativePlainAdvance=plain['width'],nativeOpticalAdvance=optical['width'],nativeOpticalAutoAdvance=auto['width'],nativeOpticalAutoWithTracking=horizontal['width'],nativeVerticalFormsAutoWithTracking=vertical['width'],webCanvasAdvance=observations[0]['canvas'][0],
    webInlineExtent=observations[0]['itemBox'][3],webOpticalNoneInlineExtent=observations[2]['itemBox'][3],webSynthesisNoneInlineExtent=observations[1]['itemBox'][3],
    cause='Same native/WK font face; CSS auto retains optical tracking in vertical inline extent. Public CT optical auto reproduces horizontal advance, while kCTVerticalForms suppresses that optical tracker. Descriptor-only production fix does not suffice.',
    primarySource='https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/graphics/cocoa/UnrealizedCoreTextFont.cpp',
    scope='Actual frozen WK DOM/PDF and native CT font/run diagnostics. This is an advance/face proof, not final PNG equality or iOS verification.')
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
