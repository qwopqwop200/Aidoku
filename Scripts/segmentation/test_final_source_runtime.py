"""Focused source-only final-policy tests; an isolated Swift executable, no shared host build."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import cv2
import numpy as np

from apply_joint_mask_refinement import refine_source_mask
from accepted_assets import asset

REPO = Path(__file__).resolve().parents[2]


class FinalSourceRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.artifacts = tempfile.TemporaryDirectory(prefix='aidoku-segmentation-final-')
        cls.binary = Path(cls.artifacts.name) / 'final-policy'
        subprocess.run(['swiftc', '-O', str(REPO / 'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeSegmentationFinalPolicy.swift'),
                        str(Path(__file__).with_name('NativeFinalSegmentationReplay.swift')), '-o', str(cls.binary)], check=True)
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


if __name__ == '__main__':
    unittest.main()
