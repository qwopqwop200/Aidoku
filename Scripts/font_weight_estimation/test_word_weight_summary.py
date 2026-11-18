import unittest

import numpy as np

from word_weight_summary import summarize


class WeightSummaryTests(unittest.TestCase):
    def test_different_reference_intervals_share_the_same_numeric_weight(self):
        x = np.zeros((1, 2, 2, 32))
        x[:, :, :, 18] = .9
        x[:, :, :, -1] = 1
        for field in (0, 9, 10, 11):
            x[:, 0, :, field] = .6  #400 + .6*(900-400) =700
            x[:, 1, :, field] = 0.  #700 + 0*(900-700) =700
        y = summarize(x.reshape(1, -1), [[400, 900], [700, 900]])
        np.testing.assert_allclose(y.reshape(1, 6, 32)[:, :, 0], .6)
        reversed_y = summarize(x[:, ::-1].reshape(1, -1), [[700, 900], [400, 900]])
        np.testing.assert_allclose(y, reversed_y)

    def test_missing_fit_does_not_invent_heavy_weight(self):
        result = summarize(np.zeros((2, 64)), [[700, 900]])
        np.testing.assert_array_equal(result, np.zeros((2, 192)))


if __name__ == '__main__':
    unittest.main()
