import unittest

import numpy as np

from registered_stroke_evidence import profile as binary_profile
from soft_stroke_profile import profile


class SoftStrokeProfileTests(unittest.TestCase):
    def test_alpha_width_change_is_visible_when_binary_masks_are_identical(self):
        regular = np.zeros((80, 80), np.float32)
        regular[10:70, 30:36] = 1
        regular[10:70, [30, 35]] = .6
        source = regular.copy()
        source[10:70, [30, 35]] = .9
        heavy = np.zeros_like(regular)
        heavy[10:70, 28:38] = 1
        known = np.ones(regular.shape, bool)
        old = binary_profile(source, regular, heavy, known, 60)
        new = profile(source, regular, heavy, known, 60)
        self.assertAlmostEqual(old['medianWeightFraction'], 0.)
        self.assertGreater(new['medianWeightFraction'], .05)

    def test_normal_and_heavy_endpoints_remain_zero_and_one(self):
        regular = np.zeros((80, 80), np.float32)
        regular[10:70, 30:34] = 1
        heavy = regular.copy()
        heavy[10:70, 28:36] = 1
        known = np.ones(regular.shape, bool)
        self.assertAlmostEqual(profile(regular, regular, heavy, known, 60)['medianWeightFraction'], 0.)
        self.assertAlmostEqual(profile(heavy, regular, heavy, known, 60)['medianWeightFraction'], 1.)


if __name__ == '__main__':
    unittest.main()
