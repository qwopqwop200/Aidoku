#!/usr/bin/env python3
"""Standalone synthetic native closed-barrier smoke; no image/model/host build.

Only NativeSourceClosedBarrierInterior + NativeSourcePixelInterior are compiled.
A locked, fixed cache under the OS temporary directory is separate from all app,
iOS and image-translation caches. Results go to stdout, never dataset artifacts.
--query accepts one JSON fixture with RGB/mask arrays, not an image path.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble' / name for name in (
    'NativeSourcePixelInterior.swift', 'NativeSourceClosedBarrierInterior.swift')]
CACHE = Path(tempfile.gettempdir()) / 'aidoku-source-closed-barrier-smoke-v1'
MAIN = r'''
import CoreGraphics
import Foundation
struct Input: Decodable {
    let rgb: [UInt8], width: Int, height: Int, predicted: [UInt8], source: [Double]
    let sourceOpaque: Bool?
    let maxPixelsPerPolarity: Int?, maxWorkUnits: Int?, cancelAfterPolls: Int?
    let special: String?
}
func query(_ data: Data) -> [String: Any] {
    guard let q = try? JSONDecoder().decode(Input.self, from: data), q.source.count == 4 else {
        return ["available": false, "status": "invalid-query", "mask": NSNull()]
    }
    // Policy-only records, explicitly not fabricated raster/topology evidence.
    // Both supported records meet every association gate; selection must remain
    // ambiguous rather than conveniently preferring either one.
    if q.special == "association-supported-ambiguity" || q.special == "association-unsupported-ring" {
        var selection = NativeSourceClosedBarrierInterior.AssociationSelection()
        let hits = q.special == "association-supported-ambiguity" ? [25, 75] : [24, 75]
        var accepted: [Bool] = []
        for hit in hits {
            accepted.append(selection.consider(componentSourceHits: hit, sourcePixels: 100,
                sourceCoverage: 0.9, predictedAgreement: 0.6, predictedCoverage: 0.3))
        }
        return ["associationOnly": true, "accepted": accepted,
                "eligibleComponents": selection.eligibleComponents, "ambiguous": selection.ambiguous]
    }
    var s = q.source
    if q.special == "nan" { s[0] = .nan }
    if q.special == "infinite" { s[3] = .infinity }
    if q.special == "overflow-source" { s = [Double.greatestFiniteMagnitude, 1, Double.greatestFiniteMagnitude, 5] }
    var limits = NativeSourceClosedBarrierInterior.Limits()
    if let value = q.maxPixelsPerPolarity { limits.maxPixelsPerPolarity = value }
    if let value = q.maxWorkUnits { limits.maxWorkUnits = value }
    var polls = 0
    let r = NativeSourceClosedBarrierInterior.make(rgb: q.rgb, width: q.width, height: q.height,
        predicted: q.predicted, source: CGRect(x: s[0], y: s[1], width: s[2], height: s[3]),
        sourceOpaque: q.sourceOpaque ?? false, limits: limits, isCancelled: {
            polls += 1
            return q.cancelAfterPolls.map { polls >= $0 } ?? false
        })
    let mask: Any = r.mask.map {
        ["rect": [Int($0.rect.minX), Int($0.rect.minY), Int($0.rect.width), Int($0.rect.height)],
         "bytes": $0.bytes] as [String: Any]
    } ?? NSNull()
    return ["available": r.available, "status": r.status, "mask": mask,
            "evidenceKind": r.evidenceKind, "metrics": r.metrics, "cancellationPolls": polls]
}
while let line = readLine() {
    let data = try JSONSerialization.data(withJSONObject: query(Data(line.utf8)), options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}
'''


def build():
    binary = CACHE / 'closed-barrier-query'
    payloads = [p.read_bytes() for p in SOURCES] + [MAIN.encode()]
    signature = hashlib.sha256(b'\0'.join(payloads)).hexdigest()
    marker = CACHE / 'signature'
    if binary.exists() and marker.exists() and marker.read_text() == signature:
        return binary, 0.0
    for path, payload in zip(SOURCES, payloads):
        (CACHE / path.name).write_bytes(payload)
    (CACHE / 'main.swift').write_text(MAIN)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(CACHE / 'clang-modules'))
    start = time.monotonic()
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(CACHE / 'swift-modules'),
                    *[str(CACHE / p.name) for p in SOURCES], str(CACHE / 'main.swift'),
                    '-o', str(binary)], check=True, env=env)
    marker.write_text(signature)
    return binary, time.monotonic() - start


def canvas(w=64, h=56):
    return dict(width=w, height=h, rgb=[128] * (w*h*3), predicted=[0] * (w*h),
                source=[18, 16, 22, 22], sourceOpaque=True)


def color(q, x, y, value):
    q['rgb'][3*(y*q['width']+x):3*(y*q['width']+x)+3] = (
        [value]*3 if isinstance(value, int) else list(value))


def box(q, left, top, right, bottom, value):
    for y in range(top, bottom+1):
        for x in range(left, right+1):
            if x in (left, right) or y in (top, bottom):
                color(q, x, y, value)


def rectangle(q, left, top, right, bottom):
    return {y*q['width']+x for y in range(top, bottom) for x in range(left, right)}


def prediction(q, pixels):
    q['predicted'] = [255 if p in pixels else 0 for p in range(q['width']*q['height'])]


def room(value=255):
    q = canvas()
    box(q, 8, 7, 52, 47, value)
    expected = rectangle(q, 9, 8, 52, 47)
    prediction(q, expected)
    return q, expected


def actual_pixels(result, width):
    if result['mask'] is None:
        return set()
    x, y, w, h = result['mask']['rect']
    values = result['mask']['bytes']
    assert len(values) == w*h and set(values) <= {0, 1}
    return {(y+dy)*width+x+dx for dy in range(h) for dx in range(w) if values[dy*w+dx]}


def fixtures():
    cases = []

    def add(name, q, expected=None, status=None):
        cases.append((name, q, expected, status))

    for name, value in [('white-closed', 255), ('white-threshold', 224),
                        ('black-closed', 0), ('black-threshold', 48)]:
        q, expected = room(value)
        add(name, q, expected)
    # The barrier threshold requires all RGB channels, not luminance or one channel.
    for name, value in [('white-channel-fails', (255, 223, 255)),
                        ('black-channel-fails', (0, 49, 0))]:
        q, _ = room(value)
        add(name, q, status='no-closed-associated-component')
    q, expected = room()
    q['source'] = [18.2, 16.1, 21.6, 21.8]
    add('fractional-full-source', q, expected)
    q, expected = room()
    box(q, 23, 20, 30, 28, 255)
    color(q, 33, 24, 255)
    add('inset-letter-holes-filled', q, expected)
    q, expected = room()
    for y in range(7, 16):
        color(q, 29, y, 255)
        expected.discard(y*q['width']+29)
    add('letter-attached-to-border-not-filled', q, expected)
    q, _ = room()
    for y in range(7, 48):
        color(q, 29, y, 255)
    add('border-letter-divides-source', q, status='no-closed-associated-component')
    for gap in [(30, 7), (8, 7), (8, 29), (52, 47)]:
        q, _ = room()
        color(q, *gap, 128)
        add('open-curve-' + str(gap), q, status='no-closed-associated-component')
    q, _ = room()
    q['rgb'] = [128] * len(q['rgb'])
    box(q, 0, 0, 63, 55, 255)
    color(q, 0, 25, 128)
    add('open-ROI-curve', q, status='no-closed-associated-component')
    q = canvas()
    box(q, 0, 5, 50, 50, 255)
    # The room continues beyond the left crop edge: no observed closing wall.
    for y in range(6, 50):
        color(q, 0, y, 128)
    q['source'] = [0, 10, 20, 20]
    prediction(q, rectangle(q, 0, 6, 50, 50))
    add('component-touching-ROI', q, status='no-closed-associated-component')
    # Two disjoint rooms: the source-associated room wins, not the larger room.
    q = canvas(96, 56)
    box(q, 4, 7, 36, 47, 255)
    box(q, 45, 3, 92, 52, 255)
    q['source'] = [12, 16, 16, 20]
    expected = rectangle(q, 5, 8, 36, 47)
    prediction(q, expected)
    add('two-bodies-source-association', q, expected)
    q = canvas(96, 56)
    box(q, 4, 7, 36, 47, 255)
    box(q, 45, 3, 92, 52, 255)
    q['source'] = [12, 16, 60, 20]
    prediction(q, rectangle(q, 5, 8, 36, 47) | rectangle(q, 46, 4, 92, 52))
    add('two-bodies-spanning-source', q, status='no-closed-associated-component')
    for polarity, value in [('white224', 255), ('black48', 0)]:
        q, _ = room(value)
        box(q, 12, 11, 48, 43, value)
        q['source'] = [18, 16, 22, 22]
        # The surrounding double-line annulus has ZERO raw source hits. Its
        # filled envelope covers the source but must not compete with the real
        # inner room. Check the exact inner domain, not just availability.
        expected = rectangle(q, 13, 12, 48, 43)
        add('nested-doubleline-unsupported-ring-' + polarity, q, expected, 'available-' + polarity)
    q, _ = room()
    box(q, 10, 9, 50, 45, 0)
    expected = rectangle(q, 11, 10, 50, 45)
    add('dual-polarity-conservative-intersection', q, expected,
        'available-conservative-intersection')
    q, _ = room()
    box(q, 17, 14, 43, 40, 0)
    add('polarity-conflict-no-convenient-room', q, status='polarity-conflict')
    q, _ = room()
    box(q, 10, 9, 50, 45, 0)
    box(q, 12, 11, 48, 43, 0)
    # Raw seed support resolves the false black ambiguity, but the remaining
    # black interior is too small to agree with white: conflict must STILL veto.
    add('dual-doubleline-ring-still-polarity-conflict', q, status='polarity-conflict')
    for special in ['association-supported-ambiguity', 'association-unsupported-ring']:
        q, _ = room()
        q['special'] = special
        add(special, q)
    q, _ = room()
    prediction(q, rectangle(q, 20, 20, 28, 28))
    add('low-predicted-agreement', q, status='no-closed-associated-component')
    # Larger canvas to make predicted coverage smaller than .3 while agreement remains 1.
    q = canvas(128, 112)
    box(q, 8, 7, 52, 47, 255)
    q['predicted'] = [1] * len(q['predicted'])
    add('low-predicted-coverage', q, status='no-closed-associated-component')
    q, _ = room()
    q['source'] = [4, 10, 36, 25]
    add('low-source-coverage', q, status='no-closed-associated-component')
    # No geometric clipping before source association, including subpixel clipping.
    for source in [[-0.01, 10, 30, 20], [18, 16, 47, 22], [18, 16, 22, 41],
                   [64, 1, 1, 1], [1e100, 0, 1, 1]]:
        q, _ = room()
        q['source'] = source
        add('truncated-source-' + str(source), q, status='source-roi-truncated')
    for special in ['nan', 'infinite', 'overflow-source']:
        q, _ = room()
        q['special'] = special
        add(special, q, status='invalid-source')
    for source in [[18, 16, 0, 22], [18, 16, -1, 22], [18.1, 16.1, 0.1, 0.1]]:
        q, _ = room()
        q['source'] = source
        add('empty-source-' + str(source), q,
            status='invalid-source' if source[2] <= 0 else 'empty-source-samples')
    for opaque in [False, None]:
        q, _ = room()
        q['sourceOpaque'] = opaque
        add('opacity-unknown-' + str(opaque), q, status='opacity-unknown')
    q, _ = room()
    q['predicted'] = [0] * len(q['predicted'])
    add('empty-prediction', q, status='empty-predicted')
    for field, value in [('width', 0), ('height', -1), ('rgb', [0]), ('predicted', [])]:
        q, _ = room()
        q[field] = value
        add('malformed-' + field, q, status='invalid-input')
    q, _ = room()
    q.update(width=2001, height=2000, rgb=[], predicted=[])
    add('hard-four-million-pixel-budget', q, status='pixel-budget-exceeded')
    q, _ = room()
    q['maxPixelsPerPolarity'] = 100
    add('lower-pixel-budget', q, status='pixel-budget-exceeded')
    q, _ = room()
    q.update(width=2000, height=2000, rgb=[], predicted=[])
    add('exact-pixel-budget-valid-size-invalid-arrays', q, status='invalid-input')
    q, _ = room()
    q.update(width=9_223_372_036_854_775_807, height=2, rgb=[], predicted=[])
    add('dimension-product-overflow-guard', q, status='pixel-budget-exceeded')
    for field, value in [('maxPixelsPerPolarity', 4_000_001), ('maxWorkUnits', 128_000_001),
                         ('maxWorkUnits', 0)]:
        q, _ = room()
        q[field] = value
        add('invalid-limit-' + str((field, value)), q, status='invalid-limits')
    for limit in [1, 10_000, 60_000]:
        q, _ = room()
        q['maxWorkUnits'] = limit
        add('work-budget-' + str(limit), q, status='work-budget-exceeded')
    for polls in [1, 5, 50]:
        q, _ = room()
        q['cancelAfterPolls'] = polls
        add('cancelled-' + str(polls), q, status='cancelled')
    # A synthetic curved barrier, with an analytic row-span domain. Several
    # diagonal corner-only leaks exercise complement-8 rather than flood-4.
    q = canvas()
    for y in range(8, 47):
        for x in range(9, 53):
            if abs(x-30)+abs(y-27) == 19:
                color(q, x, y, 255)
    prediction(q, {y*64+x for y in range(56) for x in range(64) if abs(x-30)+abs(y-27) < 19})
    q['source'] = [25, 22, 10, 10]
    # One-pixel diagonal diamond does not close under complement-8.
    add('diagonal-curve-leaks-under-eight', q, status='no-closed-associated-component')
    # A closed digital ellipse drawn as a two-pixel morphological shell.
    q = canvas()
    inside = {(x, y) for y in range(56) for x in range(64)
              if ((x-30)/22)**2 + ((y-27)/20)**2 < 1}
    boundary = {(x+dx, y+dy) for x, y in inside for dx in range(-1, 2) for dy in range(-1, 2)} - inside
    for x, y in boundary:
        color(q, x, y, 255)
    expected = {y*64+x for x, y in inside}
    prediction(q, expected)
    add('closed-digital-ellipse', q, expected)
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--query', type=Path, help='one numerical JSON fixture; no images loaded')
    args = parser.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)
    with (CACHE / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        binary, compile_seconds = build()
        if args.query:
            run = subprocess.run([str(binary)], input=args.query.read_text().strip()+'\n',
                                 text=True, capture_output=True, check=True)
            print(run.stdout, end='')
            return
        cases = fixtures()
        start = time.monotonic()
        run = subprocess.run([str(binary)], input=''.join(json.dumps(q)+'\n' for _, q, _, _ in cases),
                             text=True, capture_output=True, check=True)
        execution_seconds = time.monotonic()-start
        outputs = [json.loads(line) for line in run.stdout.splitlines()]
        assert len(outputs) == len(cases)
        checks = 0
        failures = []
        records = []
        for (name, q, expected, status), result in zip(cases, outputs):
            def require(value, message):
                nonlocal checks
                checks += 1
                if not value:
                    failures.append(name + ': ' + message)
            if q.get('special', '').startswith('association-'):
                supported = q['special'] == 'association-supported-ambiguity'
                require(result['associationOnly'], 'association-only evidence is explicit')
                require(result['accepted'] == ([True, True] if supported else [False, True]),
                        'actual raw-source support threshold before eligibility')
                require(result['eligibleComponents'] == (2 if supported else 1), 'supported eligible count')
                require(result['ambiguous'] == supported, 'two supported eligible records stay ambiguous')
                records.append(dict(case=name, associationOnly=True, ambiguous=result['ambiguous']))
                continue
            require(result['evidenceKind'] == 'source-closed-colour-barrier', 'distinct evidence kind')
            if status:
                require(result['status'] == status, f"status {result['status']} != {status}")
            require(result['available'] == (expected is not None), 'availability')
            if name == 'dual-doubleline-ring-still-polarity-conflict':
                require(result['metrics']['black48EligibleComponents'] == 1,
                        'no false ambiguity from unsupported black ring')
                require(result['metrics']['black48UnsupportedComponents'] >= 1,
                        'black ring excluded before envelope')
                require(result['metrics']['polarityIoU'] < .8, 'polarity guard remains active')
            if expected is not None:
                actual = actual_pixels(result, q['width'])
                require(actual == expected, f'exact analytic domain: mismatch {len(actual ^ expected)}')
                require(result['metrics'].get('sourceCoverage', 0) >= .9, 'source coverage')
                require(result['metrics'].get('predictedAgreement', 0) >= .6, 'prediction agreement')
                require(result['metrics'].get('predictedCoverage', 0) >= .3, 'prediction coverage')
                require(result['metrics']['workUnits'] <= q.get('maxWorkUnits', 128_000_000), 'work bound')
                for polarity in ['white224', 'black48']:
                    support = result['metrics'].get(polarity+'ComponentSourceSupport')
                    if support is not None:
                        require(support >= .25, polarity+': original component source support')
                if name.startswith('nested-doubleline-unsupported-ring-'):
                    polarity = name.rsplit('-', 1)[-1]
                    require(result['metrics'][polarity+'UnsupportedComponents'] >= 1,
                            'surrounding raw-unsupported ring excluded')
                    require(result['metrics'][polarity+'EligibleComponents'] == 1,
                            'only source-supported interior eligible')
                    require(result['metrics'][polarity+'EnvelopesChecked'] == 1,
                            'unsupported ring rejected BEFORE outer envelope')
            else:
                require(result['mask'] is None, 'no rejected diagnostic mask can leak into placement')
                if result['status'] in ('cancelled', 'work-budget-exceeded'):
                    require(result['metrics']['workUnits'] <= q.get('maxWorkUnits', 128_000_000),
                            'bounded partial work audit')
            records.append(dict(case=name, status=result['status'], available=result['available']))
        summary = dict(passed=not failures, cases=len(cases), checks=checks, failures=failures,
                       compileSeconds=round(compile_seconds, 3), executionSeconds=round(execution_seconds, 3),
                       cache=str(CACHE), records=records, datasetImagesRead=0, imagesViewed=0,
                       sharedHostBuilds=0, productionAdmission=False)
        print(json.dumps(summary, indent=2))
        if failures:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
