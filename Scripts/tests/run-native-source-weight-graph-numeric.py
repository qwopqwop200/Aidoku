#!/usr/bin/env python3
"""Standalone synthetic Python/Swift graph oracle; no app/shared build or corpus.

Run from Aidoku with:
.venv-source-inference/bin/python Scripts/tests/run-native-source-weight-graph-numeric.py
Requires the existing trusted candidate and native-export in the sibling study.
All compiler caches, requests and executables are private TemporaryDirectory files.
The original Python modules are imported unchanged; no model fitting is performed.
"""
from __future__ import annotations

import copy
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

os.environ.setdefault('OMP_NUM_THREADS', '1')
os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'Scripts/models'), str(ROOT / 'Scripts/font_size_estimation'),
                str(ROOT / 'Scripts/appearance_estimation'), str(ROOT / 'Scripts/font_weight_estimation')]
import numpy as np
import export_font_weight_runtime as exporter
import runtime
from features import page_context
from physical_correction import white_body_bold
from weight_bands import confirmation

DRIVER = r'''
import Foundation
@main struct WeightGraphReplay {
    static func main() throws {
        let registry = try NativeFrozenSourceModel.Registry(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        let tree = try registry.metadataTreeFoundation
        let metadata = tree["font-weight/complete-complementary"] as! [String: Any]
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let requests = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        var models = [String: NativeFrozenSourceModel]()
        var replies = [[String: Any]]()
        for var request in requests {
            if let field = request["poison"] as? String {
                if field == "palette" {
                    var styles = request["styles"] as! [[String: Any]]
                    styles[0]["fill"] = ["rgb": [Double.nan, 255, 255]]
                    request["styles"] = styles
                } else {
                    var rows = request[field] as! [[Double]]
                    rows[0][0] = request["infinity"] as? Bool == true ? Double.infinity : Double.nan
                    request[field] = rows
                }
            }
            do {
                let action = request["action"] as! String
                let raw = request["raw"] as? [[Double]] ?? []
                let bundle = request["bundle"] as? [String: Any] ?? metadata
                let stages = request["stages"] as? [String: [[Double]]] ?? [:]
                let stub = request["stub"] as? [String: [Double]]
                var captured = [String: [[Double]]]()
                // Same probability signature as NativeSourceFontModelAccess.proba.
                let probability: NativeSourceWeightGraph.Probability = { id, rows in
                    captured[id] = rows
                    if request["badProbability"] as? Bool == true { return rows.map { _ in [Double.nan, Double.nan] } }
                    if let stub {
                        guard let scores = stub[id] else { throw NativeSourceFontGraphError.invalid("Missing stub") }
                        return scores.map { [1 - $0, $0] }
                    }
                    if models[id] == nil { models[id] = try registry.model(id) }
                    return try models[id]!.predictProbability(rows)
                }
                var reply = [String: Any]()
                switch action {
                case "context": reply["values"] = try NativeSourceWeightGraph.pageContext(raw)
                case "correction":
                    reply["value"] = try NativeSourceWeightGraph.whiteBodyBold(
                        style: request["style"] as! [String: Any], paired: request["signal"] as! [Double],
                        policy: request["policy"] as! [String: Any])
                case "confirmation":
                    reply["values"] = try NativeSourceWeightGraph.confirmation(raw, policy: request["policy"] as! [String: Any])
                default:
                    let styles = request["styles"] as? [[String: Any]] ?? []
                    let paired = request["paired"] as? [[Double]] ?? []
                    let mixed = request["mixed"] as? [Bool]
                    if action == "base" {
                        reply["rows"] = try NativeSourceWeightGraph.predictPage(bundle: bundle, raw: raw,
                            styles: styles, paired: paired, mixed: mixed, probability: probability)
                    } else if action == "complementary" {
                        reply["rows"] = try NativeSourceWeightGraph.predictComplementaryPage(bundle: bundle, raw: raw,
                            fill71v1: request["fill"] as? [[Double]] ?? [], styles: styles, paired: paired,
                            mixed: mixed, probability: probability)
                    } else {
                        reply["rows"] = try NativeSourceWeightGraph.predictBandPage(bundle: bundle, raw: raw,
                            fill71v1: request["fill"] as? [[Double]] ?? [], styles: styles, paired: paired,
                            bands: request["bands"] as? [[Double]] ?? [], mixed: mixed, probability: probability)
                    }
                }
                for (id, expected) in stages {
                    guard let actual = captured[id], actual.count == expected.count else {
                        throw NativeSourceFontGraphError.invalid("Missing captured head")
                    }
                    for i in actual.indices {
                        guard actual[i].count == expected[i].count else { throw NativeSourceFontGraphError.invalid("Head width") }
                        for j in actual[i].indices {
                            let a = actual[i][j], b = expected[i][j]
                            guard abs(a - b) <= 2e-12 * max(1, abs(b)) else {
                                throw NativeSourceFontGraphError.invalid("Context mismatch \(id) \(i) \(j)")
                            }
                        }
                    }
                }
                reply["calls"] = captured.count
                replies.append(reply)
            } catch { replies.append(["error": String(describing: error)]) }
        }
        try JSONSerialization.data(withJSONObject: replies, options: [.sortedKeys]).write(
            to: URL(fileURLWithPath: CommandLine.arguments[3]))
    }
}
'''


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--registry-dir',type=Path)
    arguments=parser.parse_args()
    started = time.monotonic()
    source = exporter.SOURCE
    if exporter.digest(source) != exporter.SHA:
        raise AssertionError('Trusted frozen candidate SHA differs')
    bundle = exporter.base.load(source)
    registry_dir = arguments.registry_dir.resolve() if arguments.registry_dir else source.parents[1] / 'native-export'
    portable = json.loads((registry_dir / 'registry.json').read_text())['metadata']['tree'][exporter.PREFIX]
    requests, expectations = [], []
    counts = {}

    def add(request, expected, kind):
        requests.append(request)
        expectations.append(expected)
        counts[kind] = counts.get(kind, 0) + 1

    rng = np.random.default_rng(20261112)
    for n in (1, 2, 3, 4, 5, 8, 17):
        x = rng.normal(size=(n, 9))
        x[:, 0] = 7
        x[:, 1] *= .00001
        x[-1, 2] = 1e6
        add(dict(action='context', raw=x.tolist()), dict(values=page_context(x).tolist()), 'context')
    for raw in ([], [[1], [1, 2]]):
        add(dict(action='context', raw=raw), 'error', 'invalid')

    policy = bundle['primary']['primary']['physicalCorrection']
    white = dict(fill=dict(rgb=[255, 255, 255]), background=dict(rgb=[0, 0, 0]))
    black = dict(fill=dict(rgb=[0, 0, 0]), background=dict(rgb=[255, 255, 255]))
    signals = []
    for fallback in (False, True):
        for field, threshold in ((16, policy['blackSansFit']), (19, policy['blackSansHeavyMargin']),
                                 (32, policy['serifFit']), (35, policy['serifHeavyMargin']),
                                 (19, policy['blackSansMinimumMargin'])):
            for value in (np.nextafter(threshold, -np.inf), threshold, np.nextafter(threshold, np.inf)):
                v = np.zeros(48)
                v[16], v[19], v[21] = .55, .12, 1
                v[32], v[35], v[37] = .5, .08, 1
                v[field] = value
                if fallback:
                    v[24:32], v[40:48] = v[16:24].copy(), v[32:40].copy()
                    v[16:24] = 0
                    v[32:40] = 0
                signals.append(v)
    # Independent paths: make the other family fail so each boundary matters.
    for family in ('sans', 'serif'):
        for fallback in (False, True):
            for field, threshold in (((16, .55), (19, .12)) if family == 'sans'
                                     else ((32, .5), (35, .08), (19, -.05))):
                for value in (np.nextafter(threshold, -np.inf), threshold, np.nextafter(threshold, np.inf)):
                    v = np.zeros(48)
                    v[21] = v[37] = 1
                    if family == 'sans': v[16], v[19] = .55, .12
                    else: v[32], v[35], v[19] = .5, .08, -.05
                    v[field] = value
                    if fallback:
                        v[24:32], v[40:48] = v[16:24].copy(), v[32:40].copy()
                        v[16:24] = v[32:40] = 0
                    add(dict(action='correction', style=white, signal=v.tolist(), policy=policy),
                        dict(value=bool(white_body_bold(white, v, policy))), 'independent correction')
    styles = [white, black, dict(white, outline=dict(present=True)),
              dict(white, fill=dict(rgb=[230, 255, 255])),
              dict(white, background=dict(rgb=[0, 0, 45]))]
    for style in styles:
        for signal in signals:
            add(dict(action='correction', style=style, signal=signal.tolist(), policy=policy),
                dict(value=bool(white_body_bold(style, signal, policy))), 'correction')
    add(dict(action='correction', style=dict(white, fill=dict(rgb=[255, 255])), signal=[0]*48, policy=policy),
        'error', 'invalid')

    band_policy = bundle['bandPolicy']
    good = np.zeros((8, 14))
    good[:, [0, 5, 12, 4]] = [.25, .5, .5, .15]
    bands = []
    for field, threshold in ((0, .25), (5, .5), (12, .5), (4, .15)):
        for value in (np.nextafter(threshold, -np.inf), threshold, np.nextafter(threshold, np.inf)):
            b = good.copy()
            b[:, field] = value
            bands.append(b.ravel())
    tied = good.copy()
    tied[0, 0] = 0  # Equal best fits: first row fails, later rows cannot rescue it.
    bands.extend([tied.ravel(), np.zeros(112)])
    for b in bands:
        add(dict(action='confirmation', raw=[b.tolist()], policy=band_policy),
            dict(values=confirmation([b], band_policy).tolist()), 'confirmation')
    add(dict(action='confirmation', raw=[[0]*15], policy=band_policy), 'error', 'invalid')

    class Stub:
        def __init__(self, scores): self.scores = np.asarray(scores)
        def predict_proba(self, x):
            assert len(x) == len(self.scores)
            return np.c_[1-self.scores, self.scores]

    paths = ['primary/primary', 'primary/polarity', 'body', 'physical', 'stem']

    def head(tree, path):
        for key in path.split('/'): tree = tree[key]
        return tree

    def graph(n, action='band', stub=True, bands_only=False, branches=False, omit_mixed=False):
        raw = rng.normal(size=(n, 866))
        fill = rng.normal(size=(n, 71))
        paired = rng.normal(size=(n, 48))
        b = rng.normal(size=(n, 112))
        if n:
            raw[:, :6] = 0
            b[:min(4, n)] = good.ravel()
            paired[0] = signals[0]
        style = [copy.deepcopy(white if i % 3 == 0 else black) for i in range(n)]
        mixed = [i % 5 == 4 for i in range(n)]
        if branches:
            style = [copy.deepcopy(black) for _ in range(n)]
            b[:] = good.ravel()
        if omit_mixed: mixed = None
        py, meta = copy.deepcopy(bundle), copy.deepcopy(portable)
        if bands_only:
            py['stem']['rawFeatureCount'] = meta['stem']['rawFeatureCount'] = 112
            py['stem']['featureCount'] = meta['stem']['featureCount'] = 336
        stubs = {}
        if stub:
            for path in paths:
                h, m = head(py, path), head(meta, path)
                t = h['threshold']
                # Exact inclusive threshold and either neighboring IEEE double.
                options = [0., np.nextafter(t, -np.inf), t, np.nextafter(t, np.inf), 1.]
                shift = paths.index(path)
                scores = [float(options[(i + shift) % 5]) for i in range(n)]
                if branches:
                    high_paths = [[], [0], [1], [4], [0, 1, 2, 3, 4], [2, 3, 4], [2, 3], [2]]
                    scores = [1. if shift in selected else 0. for selected in high_paths]
                stubs[m['model']['modelID']] = scores
                h['model'] = Stub(scores)
        if action == 'base':
            py, meta = py['primary']['primary'], meta['primary']['primary']
            expected = runtime.predict_page(py, raw, style, paired, mixed)
            used = ['primary/primary']
        elif action == 'complementary':
            py, meta = py['primary'], meta['primary']
            expected = runtime.predict_complementary_page(py, raw, fill, style, paired, mixed)
            used = paths[:2]
        else:
            expected = runtime.predict_band_page(py, raw, fill, style, paired, b, mixed)
            used = paths
            if n:
                bs = py['body']['model'].predict_proba(page_context(raw[:, :597]))[:, 1]
                ps = py['physical']['model'].predict_proba(page_context(np.c_[raw[:, :604], paired, raw[:, 604:]]))[:, 1]
                for i, row in enumerate(expected): row.update(bodyScore=float(bs[i]), physicalHeadScore=float(ps[i]))
        matrices = [raw, np.c_[raw[:, :597], fill, raw[:, 604:]], raw[:, :597],
                    np.c_[raw[:, :604], paired, raw[:, 604:]], b if bands_only else np.c_[raw, b]]
        stages = {head(portable, path)['model']['modelID']: page_context(matrices[paths.index(path)]).tolist()
                  for path in used} if n else {}
        req = dict(action=action, raw=raw.tolist(), fill=fill.tolist(), paired=paired.tolist(), bands=b.tolist(),
                   styles=style, mixed=mixed, stages=stages, bundle=meta)
        if omit_mixed: req.pop('mixed')
        if stub: req['stub'] = stubs
        add(req, dict(rows=expected, calls=len(used) if n else 0), 'stub graph' if stub else 'frozen graph')
        return req

    for action in ('base', 'complementary', 'band'):
        for n in (0, 1, 2, 5, 11): graph(n, action)
    graph(11, bands_only=True)
    graph(8, branches=True)
    graph(8, branches=True, omit_mixed=True)
    for n in (1, 2, 7): graph(n, stub=False)
    original = graph(5)
    for field in ('raw', 'paired', 'fill', 'bands', 'palette'):
        for infinity in (False, True):
            req = copy.deepcopy(original)
            req.update(poison=field, infinity=infinity)
            add(req, 'error', 'nonfinite')
    req = copy.deepcopy(original)
    req['badProbability'] = True
    add(req, 'error', 'nonfinite')
    for field, value in (('raw', [[0]*865]*5), ('fill', [[0]*70]*5), ('paired', [[0]*47]*5),
                         ('bands', [[0]*111]*5), ('styles', []), ('mixed', [False])):
        req = copy.deepcopy(original)
        req[field] = value
        add(req, 'error', 'invalid')
    for path, key, value in (('primary', 'fillVersion', 2), ('stem', 'rawFeatureCount', 977),
                             ('body', 'featureCount', 1790)):
        req = copy.deepcopy(original)
        head(req['bundle'], path)[key] = value
        add(req, 'error', 'invalid')
    req = copy.deepcopy(original)
    req['stub'][next(iter(req['stub']))] = [2.]*5
    add(req, 'error', 'invalid')

    ensemble = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble'
    sources = [ensemble / name for name in ('NativeAppearanceForest.swift', 'NativeFrozenSourceModel.swift',
                                           'NativeSourceFontGraphMath.swift', 'NativeSourceWeightGraph.swift')]
    with tempfile.TemporaryDirectory(prefix='native-weight-graph-') as temporary:
        work = Path(temporary)
        driver = work / 'WeightGraphReplay.swift'
        driver.write_text(DRIVER)
        before = time.monotonic()
        subprocess.run(['swiftc', '-O', '-module-cache-path', str(work / 'module-cache'),
                        *map(str, sources), str(driver), '-o', str(work / 'replay')], check=True)
        compile_seconds = time.monotonic() - before
        (work / 'request.json').write_text(json.dumps(requests, allow_nan=False))
        before = time.monotonic()
        subprocess.run([str(work / 'replay'), str(registry_dir), str(work / 'request.json'), str(work / 'reply.json')], check=True)
        execution_seconds = time.monotonic() - before
        replies = json.loads((work / 'reply.json').read_text())
    assert len(replies) == len(expectations)

    def compare(actual, expected, path):
        if isinstance(expected, dict):
            for key, value in expected.items():
                assert key in actual, (path, key, actual)
                compare(actual[key], value, path + '.' + key)
        elif isinstance(expected, list):
            assert len(actual) == len(expected), path
            for i, (a, e) in enumerate(zip(actual, expected)): compare(a, e, f'{path}[{i}]')
        elif isinstance(expected, (bool, str, int)):
            assert actual == expected, (path, actual, expected)
        else:
            np.testing.assert_allclose(actual, expected, rtol=2e-10, atol=2e-10, err_msg=path)

    for i, (actual, expected) in enumerate(zip(replies, expectations)):
        if expected == 'error': assert 'error' in actual, (i, actual)
        else:
            assert 'error' not in actual, (i, actual)
            compare(actual, expected, str(i))
    print(json.dumps(dict(passed=True, cases=counts, total=len(requests), compileSeconds=compile_seconds,
                          executionSeconds=execution_seconds, totalSeconds=time.monotonic()-started,
                          appBuild=False, sourceImages=False, training=False,registryDirectory=str(registry_dir)), indent=2))


if __name__ == '__main__': main()
