import unittest

import numpy as np

from directional_ink import measure


class DirectionalInkTests(unittest.TestCase):
    def test_horizontal_and_vertical_pen_widths_remain_separate(self):
        alpha = np.zeros((100, 100), np.float32)
        alpha[20:80, 20:32] = 1
        alpha[20:24, 20:70] = 1
        result = measure(alpha, np.ones(alpha.shape, bool), 60)
        groups = result['groups']
        self.assertGreater(groups['verticalStems']['quantiles'][2],
                           2*groups['horizontalStems']['quantiles'][2])
        self.assertGreater(result['directionContrast'], 2)

    def test_unknown_pixels_cannot_supply_strokes(self):
        alpha = np.zeros((100, 100), np.float32)
        alpha[20:80, 20:32] = 1
        result = measure(alpha, np.zeros(alpha.shape, bool), 60)
        self.assertEqual(result['components'], 0)
        self.assertEqual(result['minimumDirectionalMedian'], 0)

    def test_touching_letters_keep_local_strokes_even_when_the_word_is_long(self):
        alpha = np.zeros((100, 240), np.float32)
        for x in (20, 80, 140, 200):
            alpha[20:80, x:x+8] = 1
        alpha[48:52, 20:208] = 1
        result = measure(alpha, np.ones(alpha.shape, bool), 60, maximum_component_em=None)
        self.assertEqual(result['components'], 1)
        self.assertGreater(result['groups']['verticalStems']['count'], 128)
        self.assertGreater(result['groups']['horizontalStems']['count'], 128)


if __name__ == '__main__':
    unittest.main()
