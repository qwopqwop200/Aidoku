import unittest

import cv2
import numpy as np

from ink_weight_geometry import opposed_widths, clean_fill_style


class OpposedStrokeTests(unittest.TestCase):
    def test_background_and_outline_do_not_thicken_the_fill(self):
        style = dict(fill=dict(rgb=[250, 220, 70], colors=[[255, 255, 255], [140, 80, 30]]),
                     background=dict(rgb=[255, 255, 255]), outline=dict(present=True, rgb=[140, 80, 30]))
        cleaned = clean_fill_style(style)
        self.assertEqual(cleaned['fill']['colors'], [[250., 220., 70.]])
        self.assertEqual(len(style['fill']['colors']), 2)

    def widths(self, width):
        alpha = np.zeros((80, 80), np.float32)
        alpha[10:70, 30:30+width] = 1
        return opposed_widths(alpha, np.ones(alpha.shape, bool), alpha > .5, 40)

    def test_thicker_stroke_has_larger_opposed_edge_width(self):
        thin, support = self.widths(4)
        heavy, _ = self.widths(8)
        self.assertGreater(support, .5)
        self.assertAlmostEqual(float(np.median(heavy)/np.median(thin)), 2., delta=.3)

    def test_unknown_boundary_does_not_become_a_thin_stroke(self):
        alpha = np.zeros((80, 80), np.float32)
        alpha[10:70, 30:38] = 1
        valid = np.ones(alpha.shape, bool)
        valid[:, 35:] = False
        widths, _ = opposed_widths(alpha, valid, (alpha > .5) & valid, 40)
        self.assertEqual(len(widths), 0)


if __name__ == '__main__':
    unittest.main()
