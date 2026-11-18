import unittest

import numpy as np

from palette_word_pairs import observe_palette


class SourcePaletteTests(unittest.TestCase):
    def test_recolored_fill_is_not_negative_background_evidence(self):
        style = dict(fill=dict(rgb=[13, 91, 167], colors=[[88, 62, 120]]),
                     background=dict(rgb=[255, 255, 255],
                                     colors=[[134, 92, 138], [88, 62, 120]]))
        rgb = np.array([[[13, 91, 167], [88, 62, 120], [134, 92, 138], [255, 255, 255]]], np.uint8)
        alpha, observed = observe_palette(rgb, np.ones((1, 4), bool), style)
        np.testing.assert_allclose(alpha, [[1, 1, 0, 0]], atol=1e-5)
        self.assertTrue(observed.all())
        _, unknown = observe_palette(rgb, np.zeros((1, 4), bool), style)
        np.testing.assert_array_equal(unknown, [[False, False, True, True]])

    def test_palette_permutation_does_not_change_observations(self):
        rgb = np.array([[[10, 20, 30], [90, 80, 70], [255, 255, 255]]], np.uint8)
        own = np.ones((1, 3), bool)
        def style(colors):
            return dict(fill=dict(rgb=[10, 20, 30], colors=colors), background=dict(rgb=[255, 255, 255]))
        a, av = observe_palette(rgb, own, style([[90, 80, 70], [10, 20, 30]]))
        b, bv = observe_palette(rgb, own, style([[10, 20, 30], [90, 80, 70]]))
        np.testing.assert_array_equal(a, b)
        np.testing.assert_array_equal(av, bv)


if __name__ == '__main__':
    unittest.main()
