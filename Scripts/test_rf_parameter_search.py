import unittest

from rf_parameter_search import retained_mask_queries


class RFParameterSearchTests(unittest.TestCase):
    def test_frames_compete_for_shared_mask_budget(self):
        selected = [(q, 3, .9) for q in range(32)] + [(100, 2, .8)]
        self.assertEqual(retained_mask_queries(selected, .5), set(range(32)))

    def test_filtered_balloons_do_not_consume_budget(self):
        selected = [(q, 2, .4) for q in range(32)] + [(100, 2, .3)]
        self.assertEqual(retained_mask_queries(selected, .4), set(range(32)))
        self.assertEqual(retained_mask_queries(selected, .5), set())

    def test_duplicate_query_uses_only_one_slot(self):
        selected = [(0, 2, .9), (0, 3, .8), (1, 2, .7), (2, 2, .6)]
        self.assertEqual(retained_mask_queries(selected, .5, cap=2), {0, 1})


if __name__ == "__main__":
    unittest.main()
