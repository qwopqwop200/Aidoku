#!/usr/bin/env python3
"""Exercise saved inside-mask lexical relocation with the existing native binary.

Synthetic text/alpha only: no dataset RGB, compilation, or shared-cache writes.
Artifacts and subprocess logs are retained in a printed temporary directory.
"""
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / 'build/source-cluster-text-render/render'
WIDTH, HEIGHT = 500, 400
PAGE = '0001'
KEY = PAGE.encode().hex()


def read(path):
    return json.loads(path.read_bytes())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def normalized(rect):
    x, y, width, height = rect
    return [x / WIDTH, y / HEIGHT, width / WIDTH, height / HEIGHT]


def policy(rect, inside=False):
    result = dict(allowedRectNormalized=normalized(rect),
                  candidates=[normalized(rect)], maskCoverage=[1],
                  backgroundRisk=[0], sourceFontPixels=22,
                  kind='inside-balloon-mask' if inside else 'source-near-limited-expansion',
                  sourceLineWidthScale=8)
    if inside:
        x, _, width, height = rect
        result['maskRectNormalized'] = normalized(rect)
        result['maskSpansNormalized'] = [x / WIDTH, (x + width) / WIDTH] * int(height)
    return result


def item(oid, text, frame):
    return dict(id=oid, text=text, frame=frame, fontReference=22,
                fill=[0, 0, 0], outline=[255, 255, 255], outlineWidth=1.5,
                sourceFontWeight='regular', renderBold=False, textAlignment='center',
                textPlacementGuide=dict(rectNormalized=normalized(frame),
                                        horizontal='center', vertical='center'),
                textExpansionPolicy=policy(frame))


def snapshot(directory):
    audit_path = directory / 'audits' / f'{PAGE}.json'
    receipt_path = directory / 'owner-rasters' / KEY / 'RECEIPT.json'
    rows = {row['id']: row for row in read(audit_path)['items']}
    owners = {owner['id']: owner for owner in read(receipt_path)['owners']}
    return rows, owners


def assert_ownership(row, text):
    length = len(text.encode('utf-16-le')) // 2
    assert row['utf16Expected'] == row['utf16Visible'] == length, row
    cursor = 0
    raw = text.encode('utf-16-le')
    strings = []
    for location, count in row['lineRangesUTF16']:
        assert location == cursor and count > 0, row['lineRangesUTF16']
        strings.append(raw[2 * location:2 * (location + count)].decode('utf-16-le'))
        cursor += count
    assert cursor == length and ''.join(strings) == text
    assert strings == row['actualCoreTextLineStrings']


def assert_retained(before, after, old, new, texts):
    assert before.keys() == after.keys() == old.keys() == new.keys()
    for oid, text in texts.items():
        assert_ownership(before[oid], text)
        assert_ownership(after[oid], text)
        for field in ('fontPixels', 'renderFontName', 'lineHeightPixels',
                      'textSHA256', 'sourceFrame', 'fillRGB', 'displayOutlineRGB',
                      'outlineOutwardPixels'):
            assert before[oid][field] == after[oid][field], (oid, field)
    assert before['unrelated'] == after['unrelated']
    assert old['unrelated']['frame'] == new['unrelated']['frame']
    assert sha(Path(old['unrelated']['path'])) == sha(Path(new['unrelated']['path']))


def assert_incumbent(directory, baseline, before, old):
    after, new = snapshot(directory)
    assert before == after, directory
    for oid in old:
        assert old[oid]['frame'] == new[oid]['frame'], oid
        assert sha(Path(old[oid]['path'])) == sha(Path(new[oid]['path'])), oid
    for relative in ('layers/0001.png', 'audits/0001.json'):
        assert sha(baseline / relative) == sha(directory / relative), relative
    proof = read(directory / 'SAVED-TYPOGRAPHY-REPLAY.json')['pages'][0]
    assert proof['changedOwners'] == [], proof
    return proof


def main():
    start = time.monotonic()
    assert BINARY.is_file() and os.access(BINARY, os.X_OK), BINARY
    binary_hash = sha(BINARY)
    artifacts = Path(tempfile.mkdtemp(prefix='aidoku-saved-interior-lexical-')).resolve()
    print('binary', BINARY, flush=True)
    print('binarySHA256', binary_hash, flush=True)
    print('artifacts', artifacts, flush=True)
    baseline = artifacts / 'baseline'
    for name in ('layers', 'audits', 'owner-rasters'):
        (baseline / name).mkdir(parents=True, exist_ok=True)
    # Old center lies < half a complete-word width from the page's left edge.
    # The future mask has ample width to the right; source/guide stay fixed.
    items = [item('broken', '모두에게 보여버려서!', [8, 40, 80, 260]),
             item('unrelated', '그대로', [350, 60, 120, 150])]
    texts = {value['id']: value['text'] for value in items}
    request = dict(pages=[dict(page=PAGE, width=WIDTH, height=HEIGHT, items=items,
                              layer=str(baseline / 'layers/0001.png'),
                              audit=str(baseline / 'audits/0001.json'))])
    request_path = baseline / 'REQUEST.json'
    write(request_path, request)
    env = dict(os.environ, AIDOKU_RENDER_OWNER_ALPHA_ROOT=str(baseline / 'owner-rasters'),
               AIDOKU_BODY_FONT_COHORTS='0', AIDOKU_SOURCE_AWARE_DISPLAY_GUARD='1',
               AIDOKU_INITIAL_WORD_OBJECTIVE='0')
    runs = []

    def run(name, arguments):
        log = artifacts / f'{name}.log'
        began = time.monotonic()
        with log.open('w') as stream:
            result = subprocess.run([str(BINARY), *map(str, arguments)], env=env,
                                    stdout=stream, stderr=subprocess.STDOUT, check=False)
        record = dict(name=name, command=[str(BINARY), *map(str, arguments)],
                      log=str(log), elapsedSeconds=time.monotonic() - began,
                      returncode=result.returncode)
        runs.append(record)
        print(json.dumps(record), flush=True)
        assert result.returncode == 0, (record, log.read_text()[-6000:])

    run('baseline', [request_path])
    before, old = snapshot(baseline)
    assert before['broken']['softWordCuts'] > 0, before['broken']

    def replay(name, capacity, inside):
        value = deepcopy(request)
        value['pages'][0]['items'][0]['textExpansionPolicy'] = policy(capacity, inside)
        # Only admission support changes: source geometry/content/style is exact.
        for original, changed in zip(items, value['pages'][0]['items']):
            assert {k: v for k, v in original.items() if k != 'textExpansionPolicy'} == {
                k: v for k, v in changed.items() if k != 'textExpansionPolicy'}
        write(request_path, value)
        output = artifacts / name
        run(name, ['--refine-saved-readability', baseline, output])
        return output

    capacity = [0, 20, 300, 340]
    relocated = replay('relocated', capacity, True)
    after, new = snapshot(relocated)
    proof = read(relocated / 'SAVED-TYPOGRAPHY-REPLAY.json')['pages'][0]
    assert proof['changedOwners'] == ['broken'], proof
    assert after['broken']['savedTypographyRefinement'] is True
    assert after['broken']['softWordCuts'] < before['broken']['softWordCuts'], proof
    assert after['broken']['actualCoreTextLineStrings'] != before['broken']['actualCoreTextLineStrings']
    assert_retained(before, after, old, new, texts)
    ox, oy, ow, oh = old['broken']['frame']
    nx, ny, nw, nh = new['broken']['frame']
    # Replay first recenters a wider painted candidate on the incumbent. Recreate
    # that pre-admission origin algebraically; page admission must reject it.
    fixed_left = (ox + ow / 2) - nw / 2
    assert nw > ow and fixed_left < -2, (old['broken'], new['broken'], fixed_left)
    assert nx >= capacity[0] and ny >= capacity[1]
    assert nx + nw <= capacity[0] + capacity[2]
    assert ny + nh <= capacity[1] + capacity[3]
    placement = after['broken']['finalPlacement']
    assert placement['shiftOutputPixels'][0] > 2, placement
    assert nx + nw / 2 > ox + ow / 2 + 2
    assert placement['domainContained'] and placement['pageContained']
    assert placement['peerAlphaCollisions'] == placement['peerReadableBlockConflicts'] == 0

    # Same free rectangular capacity, but exterior policy pins the incumbent
    # origin. This must shape a wider word and fail final placement, not silently
    # succeed via a different word split or untested no-proposal path.
    fixed = replay('fixed-origin-control', capacity, False)
    fixed_proof = assert_incumbent(fixed, baseline, before, old)
    diagnostics = fixed_proof['proposalDiagnostics']['broken']
    assert any(event['event'] == 'selected-word-width' for event in diagnostics), fixed_proof
    assert any('NativeFinalTextPaintAdmission.Failure.noSafePlacement("broken")' in rejection['reason']
               for rejection in fixed_proof['rejected'] if rejection['owner'] == 'broken'), fixed_proof

    # No safe capacity: same narrow source box as both allowed rect and mask.
    # Even interior relocation may not invent support beyond those bounds.
    unsafe = replay('no-safe-capacity', items[0]['frame'], True)
    unsafe_proof = assert_incumbent(unsafe, baseline, before, old)
    assert unsafe_proof['rejected'], unsafe_proof
    assert sha(BINARY) == binary_hash, 'Concurrent binary replacement invalidates the comparison'
    summary = dict(status='PASS', binary=str(BINARY), binarySHA256=binary_hash,
                   artifacts=str(artifacts), runs=runs,
                   cutsBefore=before['broken']['softWordCuts'], cutsAfter=after['broken']['softWordCuts'],
                   fixedIncumbentLeft=fixed_left, relocatedFrame=new['broken']['frame'],
                   relocationShift=placement['shiftOutputPixels'],
                   fontPixels=after['broken']['fontPixels'], face=after['broken']['renderFontName'],
                   pitch=after['broken']['lineHeightPixels'],
                   completeUTF16=True, unrelatedOwnerBytesAndFrameUnchanged=True,
                   noSafeCapacityByteIdentical=True, elapsedSeconds=time.monotonic() - start)
    write(artifacts / 'RESULT.json', summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
