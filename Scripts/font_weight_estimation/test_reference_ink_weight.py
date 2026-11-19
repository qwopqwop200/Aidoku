import unittest

import numpy as np

from reference_ink_weight import stroke_profile


class ReferenceInkTests(unittest.TestCase):
    def test_stroke_profile_measures_pen_width_instead_of_glyph_extent(self):
        narrow = np.zeros((80, 80), np.float32)
        broad = narrow.copy()
        narrow[10:70, 30:34] = 1
        broad[10:70, 30:38] = 1
        a = stroke_profile(narrow, np.ones(narrow.shape, bool), 40)
        b = stroke_profile(broad, np.ones(broad.shape, bool), 40)
        self.assertAlmostEqual(float(b[1]/a[1]), 2., delta=.3)


if __name__ == '__main__':
    unittest.main()
