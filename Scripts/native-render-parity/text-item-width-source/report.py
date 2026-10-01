"""Independent pinned-source eligibility audit, reusing existing host captures."""
from pathlib import Path
import hashlib,json,struct
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'build/native-render-parity/text-item-width-source';SRC=OUT/'primary-source'
CORPUS=ROOT/'build/native-render-parity/float-line-width-54'
COMMIT='dd5fe1011df7e3438ac4889356abcab7681df46d'
paths={
'LayoutUnits.h':'layout/LayoutUnits.h',
'TextUtil.cpp':'layout/formattingContexts/inline/text/TextUtil.cpp',
'WidthIterator.cpp':'platform/graphics/WidthIterator.cpp',
'FontCascade.cpp':'platform/graphics/FontCascade.cpp',
'FontCascade.h':'platform/graphics/FontCascade.h',
'InlineItemsBuilder.cpp':'layout/formattingContexts/inline/InlineItemsBuilder.cpp',
'InlineLine.cpp':'layout/formattingContexts/inline/InlineLine.cpp',
'TextOnlySimpleLineBuilder.cpp':'layout/formattingContexts/inline/TextOnlySimpleLineBuilder.cpp',
'InlineLineBuilder.cpp':'layout/formattingContexts/inline/InlineLineBuilder.cpp',
'InlineDisplayContentBuilder.cpp':'layout/formattingContexts/inline/display/InlineDisplayContentBuilder.cpp',
'InlineDisplayLineBuilder.cpp':'layout/formattingContexts/inline/display/InlineDisplayLineBuilder.cpp',
'InlineFormattingUtils.cpp':'layout/formattingContexts/inline/InlineFormattingUtils.cpp',
'InlineLineTypes.h':'layout/formattingContexts/inline/InlineLineTypes.h'}
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
web=json.loads((CORPUS/'web.json').read_text());native=json.loads((CORPUS/'native.json').read_text());assert len(web)==len(native)==144
capture=(CORPUS/'Capture.swift').read_text();assert "whiteSpace:'pre',wordBreak:'keep-all'" in capture
pairs=[]
for w,n in zip(web,native):
 assert w['text']==n['text']
 assert struct.pack('f',w['spacing'])==struct.pack('f',n['spacing']) and struct.pack('f',w['size'])==struct.pack('f',n['size'])
 text=w['text'];assert text==text.strip(' ') and '  ' not in text and not any(c.isspace() and c!=' ' for c in text)
 pairs.append(dict(text=text,size=w['size'],spacing=w['spacing'],webOrigin=w['x'],wordItemOrigin=n['itemX'],exact=w['x']==n['itemX']))
canvas=[dict(text=w['text'],size=w['size'],spacing=w['spacing'],web=w['canvasWidth'],native=n['policyWidth']) for w,n in zip(web,native) if w['canvasWidth']!=n['policyWidth']]
report=dict(scope='Independent source derivation and eligibility audit; reuse of existing 144-case hosted macOS keep-all capture, no app edits or new capture',sourceCommit=COMMIT,
 source={name:dict(url=f'https://github.com/WebKit/WebKit/blob/{COMMIT}/Source/WebCore/{path}',sha256=sha(SRC/name)) for name,path in paths.items()},
 corpus=dict(inputFiles={n:sha(CORPUS/n) for n in ['Capture.swift','web.json','native.json','web-normal-break-control.json']},cases=144,wordItemOriginsExact=sum(p['exact'] for p in pairs),canvasResiduals=canvas,records=pairs),
 rules=[
 dict(file='LayoutUnits.h',lines=[39,50],contract='Pinned inline layout aliases use Float units and Float point/rect types, independently of 1/64 block LayoutUnit geometry'),
 dict(file='TextUtil.cpp',lines=[65,103],contract='With kerning/shaping, extend non-whitespace item into its following ASCII space; measure full fragment, subtract tracked single-space width plus wordSpacing, and clamp each item to nonnegative Float'),
 dict(file='TextUtil.cpp',lines=[109,123],contract='Pinned preserved-whitespace branch falls through to TextRun measurement; collapsed whitespace takes single-space width. Newer cached source differs here.'),
 dict(file='FontCascade.h',lines=[159,162,358,374],contract='Single-space string measurement uses the ordinary FontCascade width path; default non-speed text rendering enables kerning/shaping'),
 dict(file='WidthIterator.cpp',lines=[487,487,512,517,839,859],contract='Accumulate natural advances first; apply spacing after shaping per visible character with nonzero base width; operations remain Float'),
 dict(file='InlineItemsBuilder.cpp',lines=[788,799,886,965],contract='Cache item widths with trailing-space optimization; split preserved ASCII whitespace from keep-all non-whitespace items; LF and special space semantics are separate'),
 dict(file='InlineLine.cpp',lines=[482,528],contract='Append item widths in source order to the Float logical line/run extent; do not replace by one whole-string measure'),
 dict(file='TextOnlySimpleLineBuilder.cpp',lines=[103,120],contract='Compute alignment after closing the line from its logical content-right extent'),
 dict(file='InlineFormattingUtils.cpp',lines=[214,232,278,280],contract='Center offset is half positive remaining Float width; soft pre-wrap trailing space hangs, but final/forced rows hang only conditionally')],
 eligibleScope=['Actual private keep-all line-flow provenance, with matching pre/pre-wrap whitespace mode; no normal, strict, legacy wholeWords, controlled blocks, preformatted rows or authored forced breaks',
 'No authored leading/trailing whitespace; single internal ASCII SP only; soft-row trailing space can be stripped only using genuine soft-row provenance',
 'Identity horizontal scale, centered LTR text, no word spacing/autospace/expansion/tab dependencies',
 'Natural shaping has one glyph per scalar, exact source indices, matching painted fonts/glyphs, identity run matrices, finite nonnegative advances'],
 unsupported=['Normal word-break splits items at different legal positions; the earlier normal control must remain separate',
 'Repeated preserved spaces, TAB/LF/CR/FF, NBSP/ideographic/zero-width space, bidi/control formatting, clusters/ligatures/color fonts require separate policy evidence',
 'Whole-string Canvas width retains one To kerning ULP residual; 144 DOM-origin equality is not a universal Canvas or font-shaping proof',
 'Only alignment measurement is supported by this scope; glyph positions, line breaks and CSS client/scroll metrics are unchanged'])
(OUT/'eligibility-report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(dict(cases=144,wordItemOriginsExact=report['corpus']['wordItemOriginsExact'],canvasResiduals=canvas,sourceFiles=len(paths)),indent=2))
