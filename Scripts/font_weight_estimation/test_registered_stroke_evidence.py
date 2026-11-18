import unittest

import numpy as np

from registered_stroke_evidence import profile


class RegisteredStrokeTests(unittest.TestCase):
    def test_same_centres_distinguish_normal_from_heavy_without_text_labels(self):
        regular = np.zeros((80, 80), np.float32)
        heavy = regular.copy()
        regular[10:70, 38:42] = 1
        heavy[10:70, 34:46] = 1
        valid = np.ones(regular.shape, bool)
        a = profile(regular, regular, heavy, valid, 60)
        b = profile(heavy, regular, heavy, valid, 60)
        self.assertTrue(a['usable'])
        self.assertAlmostEqual(a['medianWeightFraction'], 0.)
        self.assertAlmostEqual(b['medianWeightFraction'], 1.)

    def test_unrelated_thick_stroke_does_not_count_as_supported_reference_ink(self):
        regular = np.zeros((80, 80), np.float32)
        heavy = regular.copy()
        source = regular.copy()
        regular[10:70, 38:42] = 1
        heavy[10:70, 34:46] = 1
        source[10:70, 10:22] = 1
        result = profile(source, regular, heavy, np.ones(regular.shape, bool), 60)
        self.assertEqual(result['correspondingSourceSupport'], 0.)
        self.assertLess(result['medianWeightFraction'], 0.)


if __name__ == '__main__':
    unittest.main()
