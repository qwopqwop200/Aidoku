"""Independent source evidence must agree before numerical cohort repair."""
import unittest
import numpy as np
from cohort_repair import repair_cohorts


class CohortRepairTests(unittest.TestCase):
    def call(self, sizes=(20., 20., 38.), em=(20., 21., 23.), family=(0, 0, 0),
             affinity=None, quality=None, support=None, **kwargs):
        n = len(sizes)
        return repair_cohorts(sizes, np.ones((n, n))*.98 if affinity is None else affinity,
                              em, family, np.ones(n) if quality is None else quality,
                              np.ones(n) if support is None else support, **kwargs)

    def test_measured_size_overrides_wrong_numeric_scale(self):
        actual, trace = self.call(return_trace=True)
        np.testing.assert_array_equal(actual, [20., 20., 20.])
        self.assertEqual(len(trace), 1)
        self.assertEqual(trace[0]['left'], [0, 1])
        self.assertEqual(trace[0]['right'], [2])

    def test_equal_affinity_different_family_remains_separate(self):
        np.testing.assert_array_equal(self.call(family=(0, 0, 2)), [20., 20., 38.])

    def test_equal_family_different_measured_scale_remains_separate(self):
        np.testing.assert_array_equal(self.call(em=(20., 21., 31.)), [20., 20., 38.])

    def test_insufficient_source_affinity_remains_separate(self):
        np.testing.assert_array_equal(self.call(affinity=np.ones((3, 3))*.94), [20., 20., 38.])

    def test_unsupported_wrong_size_is_preserved(self):
        np.testing.assert_array_equal(self.call(support=(1., 1., 0.)), [20., 20., 38.])
        np.testing.assert_array_equal(self.call(quality=(1., 1., .49)), [20., 20., 38.])
        np.testing.assert_array_equal(self.call(em=(20., 21., 0.)), [20., 20., 38.])

    def test_mixed_families_block_cohort_anchor(self):
        np.testing.assert_array_equal(self.call(family=(0, 1, 0)), [20., 20., 38.])

    def test_family_agreement_relaxation_is_explicit(self):
        actual = self.call(family=(0, 1, 0), quality=(1., .5, 1.), minimum_family_agreement=.8)
        np.testing.assert_array_equal(actual, [20., 20., 20.])

    def test_original_cohort_missing_member_evidence_moves_with_cohort(self):
        np.testing.assert_array_equal(self.call(support=(1., 0., 1.)), [20., 20., 20.])

    def test_complete_physical_span_blocks_chaining(self):
        actual = self.call(sizes=(20., 22., 24.), em=(20., 24., 28.),
                           maximum_scale_ratio=1.25)
        self.assertEqual(len(set(actual)), 2)

    def test_rounded_collision_does_not_merge_unrelated_cohort(self):
        affinity = np.array([[1., .1, .99], [.1, 1., .1], [.99, .1, 1.]])
        actual = self.call(sizes=(20., 22., 24.), em=(20., 60., 23.),
                           affinity=affinity, family=(0, 1, 0))
        np.testing.assert_array_equal(actual, [20., 22., 24.])

    def test_fractional_unchanged_groups_are_not_rounded(self):
        np.testing.assert_array_equal(self.call(sizes=(20.5, 20.5, 38.5), family=(0, 0, 2)),
                                      [20.5, 20.5, 38.5])

    def test_input_arrays_not_mutated(self):
        arrays = [np.array([20., 20., 38.]), np.ones((3, 3)), np.array([20., 20., 23.]),
                  np.zeros(3), np.ones(3), np.ones(3)]
        copies = [v.copy() for v in arrays]
        repair_cohorts(*arrays)
        for a, b in zip(arrays, copies):
            np.testing.assert_array_equal(a, b)

    def test_row_permutation_preserves_output(self):
        sizes=np.array([20., 20., 38.]);em=np.array([20., 21., 23.]);order=np.array([2, 0, 1])
        actual=self.call(sizes=sizes[order], em=em[order])
        np.testing.assert_array_equal(actual[np.argsort(order)], self.call())

    def test_empty_and_singleton(self):
        np.testing.assert_array_equal(self.call(sizes=(), em=(), family=()), [])
        np.testing.assert_array_equal(self.call(sizes=(20.5,), em=(20.,), family=(0,)), [20.5])

    def test_invalid_data_and_policy_rejected(self):
        for change in ({'em':(20., 20., float('nan'))}, {'family':(0, 0, 1.5)},
                       {'quality':(1., 1., 2.)}, {'maximum_scale_ratio':.9},
                       {'minimum_affinity':float('nan')}, {'minimum_family_agreement':0.}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.call(**change)
        with self.assertRaises(ValueError):
            repair_cohorts(20., [[1.]], [20.], [0], [1.], [1.])
        with self.assertRaises(ValueError):
            self.call(affinity=np.array([[1., 0., 0.],[1.,1.,0.],[0.,0.,1.]]))

    def test_prediction_ratio_limit_still_applies(self):
        np.testing.assert_array_equal(self.call(sizes=(20., 20., 60.)), [20., 20., 60.])


if __name__ == '__main__':
    unittest.main()
