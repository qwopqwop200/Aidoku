"""Compare embedded glyph contours, pairing the real PDF text by literal order.

Use the bundled Python (pypdf) and fontTools 4.59.0 in OUT/probe-deps.
PDF subset glyph names are identifiers, not evidence of a physical font index.
"""
from pathlib import Path
import hashlib, io, json, re, sys
from pypdf import PdfReader
from pypdf.generic import ContentStream
ROOT = Path(__file__).resolve().parents[4]
OUT = ROOT / 'build/native-render-parity/vertical-ideograph-paint'
sys.path.insert(0, str(OUT / 'probe-deps'))
from fontTools.t1Lib import T1Font
from fontTools.misc import psLib
from fontTools.cffLib import CFFFontSet
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.boundsPen import BoundsPen

# Quartz writes sparse unused Type1 Subrs slots. Keep those empty when parsing;
# only referenced/defined charstrings are drawn and compared below.
original_unpack = psLib.unpack_item
psLib.unpack_item = lambda item: b'' if item is None else original_unpack(item)

def inspect(name):
    path = OUT / (name + '.pdf')
    reader = PdfReader(path)
    resources = reader.pages[0]['/Resources']['/Font']
    assert len(resources) == 1
    font = next(iter(resources.values())).get_object()
    cmap_data = font['/ToUnicode'].get_data()
    ranges = re.findall(rb'<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>', cmap_data)
    cmap = {}
    for low, high, target in ranges:
        low, high, target = int(low, 16), int(high, 16), int(target, 16)
        if low == high:
            cmap[low] = chr(target)
    descendant = font['/DescendantFonts'][0].get_object() if '/DescendantFonts' in font else font
    descriptor = descendant['/FontDescriptor']
    payload_key = next(k for k in ['/FontFile', '/FontFile2', '/FontFile3'] if k in descriptor)
    payload = descriptor[payload_key].get_data()
    payload_path = OUT / (name + '-font.bin')
    payload_path.write_bytes(payload)
    if payload_key == '/FontFile':
        parsed = T1Font(str(payload_path)); parsed.parse()
        glyphs = parsed.font['CharStrings']
        encoding = {}; cursor = 0
        for value in font['/Encoding']['/Differences']:
            if isinstance(value, int): cursor = value
            else: encoding[cursor] = str(value).lstrip('/'); cursor += 1
        width = 1
    else:
        parsed = CFFFontSet(); parsed.decompile(io.BytesIO(payload), None)
        glyphs = parsed[parsed.fontNames[0]].CharStrings
        encoding = {code: 'cid' + str(code).zfill(5) for code in cmap}
        width = 2
    codes = []
    for operands, operator in ContentStream(reader.pages[0]['/Contents'], reader).operations:
        if operator != b'Tj': continue
        value = operands[0]
        data = value.get_original_bytes() if hasattr(value, 'get_original_bytes') else bytes(value)
        assert len(data) % width == 0
        codes += [int.from_bytes(data[i:i+width], 'big') for i in range(0, len(data), width)]
    rows = []
    for code in codes:
        glyph = glyphs[encoding[code]]
        pen = RecordingPen(); glyph.draw(pen)
        bounds = BoundsPen(None); glyph.draw(bounds)
        rows.append(dict(code=code, mappedUnicode=cmap[code], glyphName=encoding[code],
                         bounds=bounds.bounds, commands=pen.value))
    return dict(pdfSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
                embeddedFontSHA256=hashlib.sha256(payload).hexdigest(),
                fontSubtype=str(font['/Subtype']), embeddedFontFormat=payload_key,
                toUnicode=cmap_data.decode(), rows=rows)

web, native = inspect('0-web'), inspect('0-native')
literal = json.loads((OUT / '0.json').read_text())[0]['a']['text']
assert len(web['rows']) == len(native['rows']) == len(literal)
comparisons = []
for char, w, n in zip(literal, web['rows'], native['rows']):
    assert w['mappedUnicode'] == n['mappedUnicode']
    comparisons.append(dict(literalScalar=char, mappedUnicode=w['mappedUnicode'],
        webCode=w['code'], nativeCode=n['code'], webGlyphName=w['glyphName'], nativeGlyphName=n['glyphName'],
        webBounds=w['bounds'], nativeBounds=n['bounds'], webCommands=len(w['commands']), nativeCommands=len(n['commands']),
        exactCommands=w['commands'] == n['commands'], exactBounds=w['bounds'] == n['bounds']))
report = dict(scope='Actual embedded PDF glyph programs; paired literal order and equal embedded Unicode mappings. Different subset identifiers do not establish physical font identity.',
              literalText=literal, web=web, native=native, comparisons=comparisons)
(OUT / 'outline-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(comparisons, ensure_ascii=False, indent=2))
