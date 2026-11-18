"""Frozen-source parity, warm replay, pairing and output-boundary regression tests."""
import copy
import gzip
import json
from pathlib import Path
import pickle
import unittest

import numpy as np
from PIL import Image
from optimize_appearance import read, digest
import final_background_refinement as refinement
from apply_final_background import geometry_only, source_context

ROOT = Path(__file__).resolve().parents[3]
if not (ROOT / 'labels').is_dir(): ROOT = ROOT.parent
BASE = ROOT / 'appearance-estimation-20261109/rf-seg-fusion'
STUDY = BASE / 'appearance-common-causes-study'
GT = ROOT / 'labels/appearance-merged830-20261109-r64-review3/appearance-gt.json'
MASKS = ROOT / 'segmentation-improvement-20261109/oof-style-pruning/actual-target'


class FinalBackgroundRefinementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = read(GT)['items']
        # Frozen summary fixtures require their original pre-correction inputs.
        # Current champion predictions deliberately evolve as later heads improve.
        with gzip.open(STUDY / 'FROZEN-SOURCE-INPUTS.json.gz', 'rt') as stream:
            cls.predictions = json.load(stream)
        if [r['itemID'] for r in cls.rows] != [p['itemID'] for p in cls.predictions]:
            raise ValueError('Frozen source test correspondence changed')
        with (STUDY / 'local-primary-ranker.pkl').open('rb') as stream:
            cls.model = pickle.load(stream)
        cls.geometry = [geometry_only(row) for row in cls.rows]
        cls.neighbors = {}
        for geometry in cls.geometry:
            cls.neighbors.setdefault(geometry['sourceImageSHA256'], []).append(geometry)
        cls.index = {r['itemID']: i for i, r in enumerate(cls.rows)}

    def source(self, i):
        geometry = self.geometry[i]
        packet = read(BASE / 'features' / (geometry['itemID'] + '.json'))['packet']
        rgb = np.asarray(Image.open(geometry['crop']).convert('RGB'))
        own = np.asarray(Image.open(MASKS / (geometry['itemID'] + '.png'))) > 0
        context, _ = source_context(geometry, self.neighbors[geometry['sourceImageSHA256']], MASKS, BASE / 'features')
        return rgb, own, context, packet

    def test_exact_all_frozen_source_summaries(self):
        with gzip.open(STUDY / 'LOCAL-EXTERIOR-SOURCE.json.gz', 'rt') as stream:
            expected_local = json.load(stream)
        with gzip.open(STUDY / 'FROZEN-EXTERIOR-SOURCE.json.gz', 'rt') as stream:
            expected_exterior = json.load(stream)
        for i, prediction in enumerate(self.predictions):
            with self.subTest(itemID=prediction['itemID']):
                rgb, own, context, packet = self.source(i)
                local, exterior = refinement.source_summaries(rgb, own, context, packet, prediction, self.rows[i]['fontPixels'])
                self.assertEqual(local, expected_local[i])
                self.assertEqual(exterior, expected_exterior[i])

    def test_changed_predictions_match_frozen_classifier_and_warm_replay(self):
        changes = read(STUDY / 'RANKER-PAIRED-CHANGES.json')
        for change in changes:
            i = self.index[change['itemID']]
            before = copy.deepcopy(self.predictions[i])
            args = self.source(i)
            result = refinement.apply(*args, before, self.model, self.rows[i]['fontPixels'])
            self.assertEqual(result['background']['rgb'], change['afterRGB'])
            self.assertEqual(before, self.predictions[i], 'Caller prediction mutated')
            self.assertEqual(refinement.restore_baseline(result), before)
            self.assertEqual(refinement.apply(*args, result, self.model, self.rows[i]['fontPixels']), result)
            for key in before:
                if key != 'background': self.assertEqual(result[key], before[key])
            for key in before['background']:
                if key != 'rgb': self.assertEqual(result['background'][key], before['background'][key])

    def test_warm_replay_recomputes_when_upstream_styles_change(self):
        i = self.index['p0076-M000']
        args = self.source(i)
        warm = refinement.apply(*args, self.predictions[i], self.model, self.rows[i]['fontPixels'])
        warm['fill']['rgb'] = [80, 90, 100]
        clean = refinement.restore_baseline(warm)
        self.assertEqual(refinement.apply(*args, warm, self.model, self.rows[i]['fontPixels']),
                         refinement.apply(*args, clean, self.model, self.rows[i]['fontPixels']))

    def test_policy_rejects_every_model_and_helper_mismatch(self):
        identities = {name: 'a' * 64 for name in refinement.MODEL_NAMES}
        policy = dict(enabled=True, version=refinement.VERSION, modelVersion=refinement.MODEL_VERSION,
            helperSHA256=refinement.helper_sha256(), modelIdentities=identities, sourceArtifactSHA256='a' * 64)
        refinement.validate_policy(policy, identities)
        for name in identities:
            with self.subTest(name=name), self.assertRaises(ValueError):
                refinement.validate_policy(policy, dict(identities, **{name: 'b' * 64}))
        with self.assertRaises(ValueError):
            refinement.validate_policy(dict(policy, helperSHA256='stale'), identities)
        with self.assertRaises(ValueError):
            refinement.validate_policy(dict(policy, sourceArtifactSHA256='stale'), identities)

    def test_runtime_geometry_whitelist_and_context_shape_guards(self):
        source = geometry_only(dict(self.rows[0], maliciousStyle='must not enter source'))
        self.assertNotIn('fill', source)
        self.assertNotIn('review', source)
        self.assertNotIn('maliciousStyle', source)
        i = self.index['p0076-M000']
        rgb, own, context, packet = self.source(i)
        with self.assertRaises(ValueError):
            refinement.apply(rgb, own, np.zeros_like(context), packet, self.predictions[i], self.model, 20)
        with self.assertRaises(ValueError):
            refinement.apply(rgb, own, context, packet, self.predictions[i], dict(self.model, version='wrong'), 20)


if __name__ == '__main__':
    unittest.main()
