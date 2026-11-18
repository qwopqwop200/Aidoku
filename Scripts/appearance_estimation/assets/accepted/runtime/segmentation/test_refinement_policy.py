"""Mask-level checks independent of dataset calibration and GT files."""
import unittest
import cv2
import numpy as np

from apply_joint_mask_refinement import refine_source_mask


class RefinementPolicyTests(unittest.TestCase):
    def setUp(self):
        self.base = np.zeros((7, 7), bool)
        self.base[3, 3] = True
        self.distance = cv2.distanceTransform((~self.base).astype(np.uint8), cv2.DIST_C, 3).astype(np.int32)
        self.group = np.zeros((7, 7), np.uint8)
        self.codes = np.full((7, 7), 3300, np.uint16)
        self.weak = dict(protection='none', interiorThresholdCode=3000, exteriorThresholdCode=3200,
                         coreRadiusPixels=0, outerRadiusPixels=3)
        self.strong = dict(self.weak, interiorThresholdCode=3100, exteriorThresholdCode=3400)
        self.rgb = np.full((7, 7, 3), 100, np.uint8)

    def predict(self, config, votes=None):
        before = self.codes.copy()
        result = refine_source_mask(self.base, self.distance, self.group, self.codes,
                                    config, np.zeros(18), 40, self.rgb, votes) > 0
        np.testing.assert_array_equal(before, self.codes)
        return result

    def test_recovery_uses_source_geometry_and_does_not_remove_strong_pixels(self):
        policy = dict(strong=self.strong, weak=self.weak, metric='manhattan', radiusPixels=1)
        expected = self.base.copy()
        expected[2:5, 3] = expected[3, 2:5] = True
        np.testing.assert_array_equal(self.predict(dict(confidenceRecovery=policy)), expected)
        policy = dict(policy, weakSignalGate=dict(radiusPixels=0, minimumContrast=1))
        np.testing.assert_array_equal(self.predict(dict(confidenceRecovery=policy)), self.base)

    def test_empty_strong_mask_retains_weak_mask_even_on_uniform_source(self):
        empty = dict(self.strong, interiorThresholdCode=4000, exteriorThresholdCode=4000)
        policy = dict(strong=empty, weak=self.weak, metric='chebyshev', radiusPixels=1,
                      weakSignalGate=dict(radiusPixels=0, minimumContrast=1))
        np.testing.assert_array_equal(self.predict(dict(confidenceRecovery=policy)), True)

    def test_shared_source_majority_has_no_mutating_member_side_effects(self):
        config = dict(ensembleMembers=[self.weak, self.strong, self.strong], requiredVotes=2)
        np.testing.assert_array_equal(self.predict(config), self.base)

    def test_source_vote_corroboration_rescues_only_supported_flat_pixels(self):
        p = np.zeros((7, 7), np.float32)
        q = p.copy()
        p[3, 4] = 1 / 64
        policy = dict(strong=self.strong, weak=self.weak, metric='manhattan', radiusPixels=1,
                      weakSignalGate=dict(radiusPixels=0, minimumContrast=1),
                      sourceCorroboration=dict(neighborReference='strong', minimumNeighbors=9,
                                              minimumPrimaryVotes=1, minimumBoundaryVotes=49))
        expected = self.base.copy()
        expected[3, 4] = True
        np.testing.assert_array_equal(self.predict(dict(confidenceRecovery=policy), (p, q)), expected)


if __name__ == '__main__':
    unittest.main()
