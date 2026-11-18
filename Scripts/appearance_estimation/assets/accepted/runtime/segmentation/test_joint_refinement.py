"""Independent pixel unions, calibration isolation and floating split precision."""
import unittest
from unittest.mock import patch
import numpy as np

import audit_joint_mask_refinement as joint
from audit_edge_limited_growth import source_signals
from audit_kernel_free_completion import metrics
from compiled_point_predict import predict


class JointRefinementTests(unittest.TestCase):
    def test_compiled_splits_keep_double_thresholds_between_float32_values(self):
        low = np.float32(1.)
        high = np.nextafter(low, np.float32(2.))
        threshold = (float(low) + float(high)) / 2
        features = np.array([[low], [high]], np.float32)
        split = np.array([[0, -1, -1]], np.int32)
        thresholds = np.array([[threshold, 0, 0]], np.float64)
        left = np.array([[1, 0, 0]], np.int32)
        right = np.array([[2, 0, 0]], np.int32)
        leaf = np.array([[0, -2, 2]], np.float64)
        actual = predict(features, np.arange(2), 0., split, thresholds, left, right, leaf)
        np.testing.assert_allclose(actual, 1 / (1 + np.exp([2., -2.])), atol=1e-15, rtol=0)

    def test_source_edges_and_outward_color_delta_preserve_flat_sources(self):
        rgb = np.full((9, 13, 3), [30, 80, 100], np.uint8)
        base = np.zeros((9, 13), bool)
        base[4, 6] = True
        for field in source_signals(rgb, base, 40):
            np.testing.assert_array_equal(field, 0)
        rgb[4, 6] = [200, 180, 190]
        delta = source_signals(rgb, base, 40)[-1]
        self.assertEqual(delta[4, 6], 0)
        self.assertGreater(delta[0, 0], 0)

    def test_joint_count_search_matches_direct_masks_and_dev_ignores_test_labels(self):
        bins = 32
        rng = np.random.default_rng(18)
        cases = {}
        for split in ['train', 'dev', 'test']:
            distance = rng.integers(0, 15, 150)
            distance[:40] = 0
            cases[split] = (distance, rng.integers(0, 3, 150), rng.integers(0, bins, 150),
                            (rng.random(150) < .4) & (distance <= 12))

        def measure():
            inside, outside, total = {}, {}, {}
            for split, (distance, group, scores, gt) in cases.items():
                inside[split] = np.zeros((3, 2, bins), np.int64)
                outside[split] = np.zeros((2, 13, bins), np.int64)
                for i in range(len(gt)):
                    label = 0 if gt[i] else 1
                    if distance[i] == 0:
                        inside[split][group[i], label, scores[i]] += 1
                    elif distance[i] <= 12:
                        outside[split][label, distance[i], scores[i]] += 1
                total[split] = int(gt.sum())
            with patch.object(joint, 'BINS', bins):
                return joint.summarize(inside, outside, total)

        result = measure()
        for candidate in result.values():
            if candidate is None:
                continue
            counts = []
            for split, (distance, group, scores, gt) in cases.items():
                protected = group >= 1 if candidate['protection'] == 'anyStrong' else (
                    group == 2 if candidate['protection'] == 'consensus' else np.zeros(len(gt), bool))
                mask = (distance == 0) & (protected | (scores >= candidate['interiorThresholdCode']))
                mask |= (distance > 0) & ((distance <= candidate['coreRadiusPixels']) |
                        ((distance <= candidate['outerRadiusPixels']) & (scores >= candidate['exteriorThresholdCode'])))
                c = np.array([np.count_nonzero(mask & gt), np.count_nonzero(mask & ~gt),
                              np.count_nonzero(~mask & gt)])
                self.assertEqual(candidate['bySplit'][split], metrics(c))
                counts.append(c)
            self.assertEqual(candidate['all'], metrics(sum(counts)))
        old = result['devRecall99999']
        distance, group, scores, gt = cases['test']
        cases['test'] = distance, group, scores, ~gt
        changed = measure()['devRecall99999']
        keys = ['protection', 'coreRadiusPixels', 'outerRadiusPixels',
                'interiorThresholdCode', 'exteriorThresholdCode']
        self.assertEqual([old[k] for k in keys], [changed[k] for k in keys])


if __name__ == '__main__':
    unittest.main()
