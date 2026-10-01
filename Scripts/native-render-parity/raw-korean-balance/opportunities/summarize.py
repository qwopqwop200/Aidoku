#!/usr/bin/env python3
"""Summarize actual public CF tokenizer and bounded host WK observations."""
import json,pathlib
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[3]
OUT=ROOT/'build/native-render-parity/raw-korean-balance/opportunities'
a=json.loads((OUT/'capture.json').read_text())
checks=[]
for web in a['WKWebView']:
 if web['wordBreak']!='normal' or web['overflowWrap']!='normal':continue
 neutral=next(x for x in a['CFStringTokenizer'] if x['text']==web['text'] and x['locale']=='und')
 english=next(x for x in a['CFStringTokenizer'] if x['text']==web['text'] and x['locale']=='en_US')
 checks.append(dict(text=web['text'],CFUndEnds=neutral['ends'],CFEnglishEnds=english['ends'],observedWebKitNormalEnds=web['observedEnds'],equal=neutral['ends']==web['observedEnds']))
report=dict(OS=a['OS'],cases=len(checks),equal=sum(c['equal'] for c in checks),checks=checks,
 scope='Bounded actual WK width sweep and public CFStringTokenizer kCFStringTokenizerUnitLineBreak. Not proof of full legal opportunities or any pixel equivalence.',
 locale='Frozen raw node explicitly lang=ko for Korean, ja/zh/und by fontScript. und neutral tokenizer is an experimental Mechanical-analysis hypothesis, not a default-document-locale equivalence.',
 sources=['https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/layout/formattingContexts/inline/text/TextUtil.cpp','https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/rendering/BreakLines.h'])
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({k:report[k] for k in ['OS','cases','equal']}))
