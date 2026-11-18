"""Actual native raster regression for a typography-only cached-layout update.

Synthetic text layers only; no model, source RGB, GT or provider call.
"""
from pathlib import Path
import hashlib, json, os, subprocess, tempfile, time

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / 'build/source-cluster-text-render/render'


def read(path):
    return json.loads(path.read_bytes())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


start = time.monotonic()
with tempfile.TemporaryDirectory(prefix='aidoku-retained-typography-') as directory:
    directory = Path(directory)
    baseline, output = directory / 'baseline', directory / 'updated'
    for name in ['layers', 'audits', 'owner-rasters']:
        (baseline / name).mkdir(parents=True)
    items = []
    for index, (ident, text, frame, alignment, size) in enumerate([
        ('left', '첫 문장\n끝', [20, 20, 120, 120], 'left', 18),
        ('center', '둘째 문장\n짧게', [170, 20, 120, 120], 'center', 18),
        ('unrelated', '유지\n문구', [315, 20, 65, 180], 'center', 20),
    ]):
        items.append(dict(id=ident, text=text, frame=frame, fontReference=size, fill=[0, 0, 0],
            outlineWidth=1.5, outline=[255, 255, 255], sourceFontWeight='regular', renderBold=False,
            sourceStyleGroupID='synthetic-style', typographyGroupID='legacy-' + ident,
            textAlignment=alignment, textPlacementGuide=dict(rectNormalized=[frame[0]/400, frame[1]/240,
                frame[2]/400, frame[3]/240], horizontal='center', vertical='center'),
            textExpansionPolicy=dict(allowedRectNormalized=[0, 0, 1, 1], candidates=[[0, 0, 1, 1]],
                maskCoverage=[1], backgroundRisk=[0], sourceFontPixels=size,
                kind='source-near-limited-expansion', sourceLineWidthScale=8)))
    page = dict(page='0001', width=400, height=240, items=items,
        layer=str(baseline / 'layers/0001.png'), audit=str(baseline / 'audits/0001.json'))
    request = dict(pages=[page])
    path = baseline / 'REQUEST.json'
    path.write_text(json.dumps(request))
    env = dict(os.environ, AIDOKU_RENDER_OWNER_ALPHA_ROOT=str(baseline / 'owner-rasters'),
               AIDOKU_BODY_FONT_COHORTS='0', AIDOKU_SOURCE_AWARE_DISPLAY_GUARD='1',
               AIDOKU_INITIAL_WORD_OBJECTIVE='1', AIDOKU_FINAL_PAGE_EDGE_GUARD='1')
    subprocess.run([str(BINARY), str(path)], env=env, check=True)
    old = read(baseline / 'audits/0001.json')
    old_rows = {row['id']: row for row in old['items']}
    old_receipt = {row['id']: row for row in read(baseline / 'owner-rasters/30303031/RECEIPT.json')['owners']}
    assert old_rows['left']['textAlignment'] == 'left'
    # A source-inferred cohort is supplied to an older cached mixed-alignment
    # raster. Text, source geometry and font references are unchanged.
    items[0]['typographyGroupID'] = items[1]['typographyGroupID'] = 'updated-source-cohort'
    path.write_text(json.dumps(request))
    subprocess.run([str(BINARY), '--refine-saved-typography', str(baseline), str(output)], check=True)
    new_rows = {row['id']: row for row in read(output / 'audits/0001.json')['items']}
    new_receipt = {row['id']: row for row in read(output / 'owner-rasters/30303031/RECEIPT.json')['owners']}
    assert new_rows['left']['textAlignment'] == new_rows['center']['textAlignment'] == 'center'
    for ident in old_rows:
        assert old_rows[ident]['fontPixels'] == new_rows[ident]['fontPixels']
        assert old_rows[ident]['textSHA256'] == new_rows[ident]['textSHA256']
        assert old_rows[ident]['utf16Expected'] == new_rows[ident]['utf16Visible']
    assert old_rows['unrelated'] == new_rows['unrelated']
    assert old_receipt['unrelated']['frame'] == new_receipt['unrelated']['frame']
    assert sha(Path(old_receipt['unrelated']['path'])) == sha(Path(new_receipt['unrelated']['path']))
    assert sha(Path(old_receipt['left']['path'])) != sha(Path(new_receipt['left']['path']))
print('PASS actual native cohort realignment; unrelated font, rows, position and PNG bytes preserved')
print('wallSeconds', round(time.monotonic() - start, 3))
