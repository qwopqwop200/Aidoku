import unittest
from unittest.mock import patch

import numpy as np

from color_consistent_ink import reconstruct


class ColorConsistentInkTests(unittest.TestCase):
    def test_known_background_is_not_inflated_but_unknown_ink_is_preserved(self):
        rgb = np.zeros((4, 4, 3), np.uint8)
        own = np.ones((4, 4), bool)
        alpha = np.ones((4, 4), np.float32)
        color = np.zeros((4, 4), np.float32)
        color[:, 1] = 1
        known = np.ones((4, 4), bool)
        known[:, 2] = False
        style = dict(fill=dict(rgb=[255, 255, 255]), background=dict(rgb=[0, 0, 0]))
        with patch('color_consistent_ink.reconstruct_baseline', return_value=(alpha, known, {})), \
             patch('color_consistent_ink.observe_palette', return_value=(color, known)):
            result, _, audit = reconstruct(rgb, own, style, {})
        np.testing.assert_array_equal(result[:, 0], 0)
        np.testing.assert_array_equal(result[:, 1], 1)
        np.testing.assert_array_equal(result[:, 2], 1)
        self.assertEqual(audit['suppressedKnownBackgroundPixels'], 8)


if __name__ == '__main__':
    unittest.main()
