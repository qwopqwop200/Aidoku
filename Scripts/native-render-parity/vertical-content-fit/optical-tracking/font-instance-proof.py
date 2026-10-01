"""Public font-instance/path/draw controls. No WK private API or app build."""
from pathlib import Path
import hashlib, json, subprocess
from pypdf import PdfReader
ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
OUT = ROOT / 'build/native-render-parity/vertical-ideograph-paint'
subprocess.run(['xcrun', 'swiftc', '-O', str(HERE / 'FontInstanceProbe.swift'), '-o', str(OUT / 'font-instance-probe')], check=True)
reports = []
for method in ['ct', 'cg']:
    subprocess.run([str(OUT / 'font-instance-probe'), str(OUT)] + (['--cg'] if method == 'cg' else []), check=True)
    rows = json.loads((OUT / (method + '-font-instance-report.json')).read_text())
    for row in rows:
        pdf = OUT / (row['name'] + '.pdf')
        reader = PdfReader(pdf)
        font = next(iter(reader.pages[0]['/Resources']['/Font'].values())).get_object()
        descendant = font['/DescendantFonts'][0].get_object() if '/DescendantFonts' in font else font
        descriptor = descendant['/FontDescriptor']
        format_key = next(k for k in ['/FontFile', '/FontFile2', '/FontFile3'] if k in descriptor)
        payload = descriptor[format_key].get_data()
        (OUT / (row['name'] + '-font.bin')).write_bytes(payload)
        row.update(embeddedFontFormat=format_key, embeddedFontSHA256=hashlib.sha256(payload).hexdigest(),
                   pdfSHA256=hashlib.sha256(pdf.read_bytes()).hexdigest())
        reports.append(row)
report = dict(scope='32 actual public-font controls: CT named font, actual vertical run, CG named font, NS named font; optical auto/none and horizontal/vertical descriptors; direct CTFontDrawGlyphs and CGFont.showGlyphs.',
              cases=len(reports), identicalPaths=all(r['commands'] == reports[0]['commands'] for r in reports),
              identicalEmbeddedFont=all(r['embeddedFontSHA256'] == reports[0]['embeddedFontSHA256'] for r in reports),
              sourceSHA256=hashlib.sha256((HERE / 'FontInstanceProbe.swift').read_bytes()).hexdigest(), rows=reports)
(OUT / 'font-instance-proof.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps({k:v for k,v in report.items() if k != 'rows'}, indent=2))
