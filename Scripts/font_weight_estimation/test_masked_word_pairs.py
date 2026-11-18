"""Registration must retain scale and order when foreground occludes a word."""
import unittest

import cv2
import numpy as np

from masked_word_pairs import correlation, prepare, fit
import test_word_pairs
from word_pairs import word_masks


class MaskedWordTests(unittest.TestCase):
    def test_unknown_pixels_do_not_act_as_background(self):
        pattern = np.array([[0, 1, 0], [1, 1, 1], [0, 1, 0]], np.float32)
        source = np.pad(pattern, 2)
        observed = np.ones(source.shape, bool)
        observed[4:] = False
        source[4:] = 0
        scores = correlation(source, observed, pattern)
        self.assertGreater(scores[2, 2], .999)
        self.assertIsNone(correlation(source, observed, np.zeros((20, 20), np.float32)))

    def test_hidden_lower_letters_preserve_reference_scale(self):
        pair = test_word_pairs.WordRegistrationTests().pair()
        _, ink = word_masks(pair, 'あいうえ', True, 1.)
        ink = cv2.resize(ink, None, fx=56/128, fy=56/128,
                         interpolation=cv2.INTER_AREA)
        alpha = np.pad(ink, 10)
        rgb = np.repeat(np.rint((1-alpha[:, :, None])*255).astype(np.uint8), 3, axis=2)
        rgb[rgb.shape[0]//2:] = [255, 0, 0]
        style = dict(fill=dict(rgb=[0, 0, 0]), background=dict(rgb=[255, 255, 255]),
                     outline=dict(present=False))
        bbox = [10, 10, ink.shape[1], ink.shape[0]]
        own = np.ones(alpha.shape, bool)
        good = fit(prepare(rgb, bbox, 56, 'あいうえ', own, style, 0), pair, True)
        wrong = fit(prepare(rgb, bbox, 56, 'ういあえ', own, style, 0), pair, True)
        self.assertGreater(good[18], .9)
        self.assertGreater(good[18], wrong[18]+.1)
        self.assertAlmostEqual(good[22], 1., delta=.1)
        self.assertGreater(good[0], .7)


if __name__ == '__main__':
    unittest.main()
