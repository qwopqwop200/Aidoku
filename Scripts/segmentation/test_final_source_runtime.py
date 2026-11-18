"""Focused source-only final-policy tests; an isolated Swift executable, no shared host build."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import cv2
import numpy as np

from apply_joint_mask_refinement import refine_source_mask
from source_mask_runtime import SourceMaskRuntime, SourceMaskProducer, POLICY_SHA
from accepted_assets import asset, EXPECTED_RF_WEIGHTS, ASSET_DIRECTORY
from evaluate_gt import sha

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO.parent / 'segmentation-improvement-20261109'


class FinalSourceRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.artifacts = tempfile.TemporaryDirectory(prefix='aidoku-segmentation-final-')
        cls.binary = Path(cls.artifacts.name) / 'final-policy'
        subprocess.run(['swiftc', '-O', str(REPO / 'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeSegmentationFinalPolicy.swift'),
                        str(Path(__file__).with_name('NativeFinalSegmentationReplay.swift')), '-o', str(cls.binary)], check=True)
        cls.observation_binary = Path(cls.artifacts.name) / 'source-observations'
        engine = REPO / 'Aidoku/Core/Translation/NativeEngine'
        layout = [engine / 'Layout' / n for n in ['NativeRFDETRSemanticGrid.swift',
            'NativeRFDETRLayoutModels.swift', 'NativeRFDETRSourceSupportGrid.swift']]
        names = ['NativeEnsembleRemovalSourceFactory.swift', 'NativePixelRFFeatures.swift', 'NativePixelRFForest.swift',
            'NativePixelRFEvidence.swift', 'NativePixelRFSegmentation.swift', 'NativePixelRFBoundaryFeatures.swift',
            'NativePixelRFBoundarySegmentation.swift', 'NativeSourceSegmentationObservations.swift']
        subprocess.run(['swiftc', '-O', '-module-cache-path', str(Path(cls.artifacts.name) / 'module-cache'),
            *map(str, layout + [engine / 'Ensemble' / n for n in names]),
            str(Path(__file__).with_name('NativeSourceSegmentationReplay.swift')),
            '-o', str(cls.observation_binary)], check=True)
        cls.config = json.loads(asset('policy').read_text())['policy']

    @classmethod
    def tearDownClass(cls):
        cls.artifacts.cleanup()

    def native(self, inputs):
        proc = subprocess.run([str(self.binary)], input=''.join(json.dumps(i) + '\n' for i in inputs),
                              text=True, capture_output=True, check=True)
        return [json.loads(line) for line in proc.stdout.splitlines()]

    def test_exact_native_policy_parity_on_sparse_empty_and_weak_source_observations(self):
        rng = np.random.default_rng(1109)
        inputs, expected = [], []
        for ordinal in range(40):
            h, w = 13, 17
            base = (rng.random((h, w)) < .03).astype(np.uint8) * 255
            if ordinal == 0: base[:] = 0
            if ordinal == 1: base[:] = 255
            p = rng.integers(0, 14, (h, w)).astype(np.float32) / 64
            q = rng.integers(0, 11, (h, w)).astype(np.float32) / 48
            distance = cv2.distanceTransform((base == 0).astype(np.uint8), cv2.DIST_C, 3).astype(np.int32)
            codes = rng.integers(2400, 4000, (h, w), dtype=np.uint16)
            codes[(base == 0) & (distance > 12)] = 65535
            auxiliary = rng.choice(np.array([0, 3139, 3140, 8191], np.uint16), (h, w))
            style = rng.random(18)
            # Equality goes to the right bin; preserve calibrated saturation.
            if ordinal > 2:
                style[1] = self.config['ensembleMembers'][0]['boundariesByFeature'][0][ordinal % 15]
            mask = refine_source_mask(base > 0, distance, np.zeros_like(base), codes, self.config, style, 40)
            strength = np.minimum(64, np.ceil(np.maximum(p, q) * 64 - 1e-6)).astype(np.int32)
            mask[(mask > 0) & (strength <= 12) & (auxiliary < 3140)] = 0
            inputs.append(dict(width=w, height=h, base=base.ravel().tolist(), primary=p.ravel().tolist(),
                               boundary=q.ravel().tolist(), jointCodes=codes.ravel().tolist(), style=style.tolist(),
                               auxiliaryCodes=auxiliary.ravel().tolist()))
            expected.append(mask.ravel())
        for result, mask in zip(self.native(inputs), expected):
            np.testing.assert_array_equal(result['mask'], mask)
        malformed = dict(inputs[-1], auxiliaryCodes=[])
        self.assertIn('error', self.native([malformed])[0])

    def test_live_array_inference_matches_accepted_saved_prediction_without_target_access(self):
        self.assertEqual(sha(ROOT / 'oof-style-pruning/SOURCE-POLICY.json'), POLICY_SHA)
        runtime = SourceMaskRuntime(native_command=[str(self.binary), '--segmentation-final-jsonl'])
        # Metadata supplies source paths only. No GT target is passed to runtime.
        producer = SourceMaskProducer(final_runtime=runtime)
        self.assertEqual(Path(producer.primary_model).parent, ASSET_DIRECTORY.resolve())
        self.assertEqual(Path(producer.boundary_binary).parent, ASSET_DIRECTORY.resolve())
        from source_boundary_votes import SourceBoundaryVotes
        from prepare_full_rf import load_case_features
        votes = SourceBoundaryVotes(ROOT / 'boundary-lean', ROOT / 'deep-classifier-observations',
                                    ROOT / 'edge-context60-native', ROOT / 'edge-context60-observations')
        rows = json.loads((ROOT / 'boundary-lean/evaluation-manifest.json').read_text())['items']
        for split in ['train', 'dev', 'test']:
            candidates = [r for r in rows if r['split'] == split and r['width'] * r['height'] >= 4096]
            row = min(candidates, key=lambda r: r['width'] * r['height'])
            shape = (row['height'], row['width'])
            p, q, native = votes.load(row)
            best = json.loads((ROOT / 'BEST-RESULT.json').read_text())['modelPackage']
            completed = np.fromfile((ROOT / best).parent / 'native-masks' / (row['id'] + '.u8'), np.uint8).reshape(shape)
            rgb = np.fromfile(row['rgb'], np.uint8).reshape(*shape, 3)
            with np.load(row['rf']) as z: coarse = z['support'].astype(np.float32) / 255
            full = load_case_features(row, ROOT / 'boundary-lean')
            affinity = json.loads((ROOT / 'boundary-lean/rf-full/crops' / (row['id'] + '.json')).read_text())['affinityScores']
            mask, audit, trace = runtime.predict(rgb=rgb, primary=p, boundary=q, native=native, completed=completed,
                coarse_rf=coarse, full_rf=full, font=row['fontPixels'], affinity=affinity)
            fresh, fresh_audit, fresh_trace = producer.predict(rgb=rgb, polygons=row['polygons'],
                font=row['fontPixels'], coarse_rf=coarse, full_rf=full, affinity=affinity,
                rf_model_weights_sha256=EXPECTED_RF_WEIGHTS)
            np.testing.assert_array_equal(fresh_trace['primary'], p)
            np.testing.assert_array_equal(fresh_trace['boundary'], q)
            np.testing.assert_array_equal(fresh, mask)
            # Current MAIN typed native producer, independently compiled from current Swift sources.
            folder = Path(self.artifacts.name)
            rgb.tofile(folder / 'rgb.u8'); coarse.tofile(folder / 'coarse.f32'); full.tofile(folder / 'full.f32')
            prefix = str(folder / 'current')
            request = dict(rgb=str(folder / 'rgb.u8'), coarseRF=str(folder / 'coarse.f32'),
                fullRF=str(folder / 'full.f32'), width=shape[1], height=shape[0], polygons=row['polygons'],
                fontPixels=row['fontPixels'], output=prefix, rfModelWeightsSHA256=EXPECTED_RF_WEIGHTS)
            subprocess.run([str(self.observation_binary)],
                input=json.dumps(request) + '\n', text=True, check=True, capture_output=True)
            np.testing.assert_array_equal(np.fromfile(prefix + '.p.f32', np.float32).reshape(shape), p)
            np.testing.assert_array_equal(np.fromfile(prefix + '.q.f32', np.float32).reshape(shape), q)
            np.testing.assert_array_equal(np.fromfile(prefix + '.native.u8', np.uint8).reshape(shape), native)
            np.testing.assert_array_equal(np.fromfile(prefix + '.completed.u8', np.uint8).reshape(shape), completed)
            self.assertTrue(fresh_audit['primaryClassifiersFresh'])
            self.assertTrue(fresh_audit['boundaryClassifierFresh'])
            from PIL import Image
            with Image.open(ROOT / 'oof-style-pruning/actual-target' / (row['id'] + '.png')) as image:
                np.testing.assert_array_equal(mask, np.asarray(image))
            self.assertFalse(audit['GTRead'])
            self.assertFalse(audit['storedMaskRead'])
            self.assertEqual(audit['finalPolicyEngine'], 'native-swift')
            packet = dict(width=shape[1], height=shape[0], primary=p.ravel().tolist(), boundary=q.ravel().tolist(),
                          base=(trace['base'].astype(np.uint8) * 255).ravel().tolist(),
                          jointCodes=trace['jointCodes'].ravel().tolist(), style=trace['style'].tolist(),
                          auxiliaryCodes=trace['auxiliaryCodes'].ravel().tolist())
            np.testing.assert_array_equal(self.native([packet])[0]['mask'], mask.ravel())
            print('SOURCE-CROP-PARITY', row['id'], 'pixels', mask.size, 'foreground', np.count_nonzero(mask))


if __name__ == '__main__':
    unittest.main()
