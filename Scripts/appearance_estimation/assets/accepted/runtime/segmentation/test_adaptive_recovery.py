"""Direct-mask checks for the adaptive-kernel calibration and source features."""
import unittest
import numpy as np

from audit_adaptive_dilation import BINS, MAX_DISTANCE, candidates
from train_context_recovery import context_features


class AdaptiveRecoveryTests(unittest.TestCase):
    def test_histogram_counts_match_explicit_union_masks(self):
        rng = np.random.default_rng(204)
        hist, base, cases = {}, {}, {}
        for split in ['train', 'dev', 'test']:
            distance = rng.integers(0, MAX_DISTANCE + 1, 400)
            score = rng.integers(0, BINS, 400)
            gt = rng.random(400) < .3
            codes = distance * BINS + score
            outside = distance > 0
            hist[split] = np.stack([
                np.bincount(codes[outside & gt], minlength=(MAX_DISTANCE + 1) * BINS),
                np.bincount(codes[outside & ~gt], minlength=(MAX_DISTANCE + 1) * BINS)
            ]).reshape(2, MAX_DISTANCE + 1, BINS)
            base[split] = np.array([np.count_nonzero(~outside & gt),
                                    np.count_nonzero(~outside & ~gt),
                                    np.count_nonzero(outside & gt)])
            cases[split] = distance, score, gt
        for core, outer, totals in candidates(hist, base):
            for split, (distance, score, gt) in cases.items():
                for threshold in [0, 1, BINS // 2, BINS - 1]:
                    mask = (distance <= core) | ((distance <= outer) & (score >= threshold))
                    expected = [np.count_nonzero(mask & gt), np.count_nonzero(mask & ~gt),
                                np.count_nonzero(~mask & gt)]
                    np.testing.assert_array_equal(totals[split][:, threshold], expected)

    def test_nearest_consensus_color_is_exact_at_source_seeds(self):
        rng = np.random.default_rng(15)
        features = np.zeros((9, 13, 61), np.float32)
        features[:, :, 2:5] = rng.random((9, 13, 3))
        seeds = np.zeros((9, 13), bool)
        seeds[1, 1] = seeds[4, 8] = seeds[7, 2] = True
        features[:, :, 0][seeds] = features[:, :, 60][seeds] = 1
        augmented, names = context_features(features.reshape(-1, 61), seeds, 20)
        for name in ['nearestConsensusDistanceRelativeFont', 'nearestConsensusRGBMaxDifference',
                     'nearestConsensusRGBMeanDifference']:
            np.testing.assert_array_equal(augmented[seeds.ravel(), 61 + names.index(name)], 0)
        self.assertTrue(np.isfinite(augmented).all())
        empty, _ = context_features(features.reshape(-1, 61) * 0, seeds & False, 20)
        self.assertTrue(np.isfinite(empty).all())


if __name__ == '__main__':
    unittest.main()
