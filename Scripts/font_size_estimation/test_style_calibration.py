"""Synthetic source-only checks; no experiment data, query labels, or images."""
import copy
import unittest

import numpy as np

from style_calibration import calibrate_style


class StyleCalibrationTests(unittest.TestCase):
    def setUp(self):
        self.config = dict(whitening=False, styleDimensions=1, sourceSizeDistanceWeight=0.,
                           neighbors=1, neighborAggregation='mean',
                           TRAINSourceExcludedDistanceQuantile=1., maximumCalibrationLogSpread=10.,
                           strength=1., clip=10., quantum=.000001)
        self.source = dict(style=np.array([[0.]]), referenceFamily=np.array([0]),
                           measuredEm=np.array([10.]), quality=np.array([1.]),
                           support=np.array([1.]), sourceGroup=np.array(['query']))
        self.bank = dict(style=np.array([[1.], [2.]]), referenceFamily=np.array([0, 0]),
                         measuredEm=np.array([10., 10.]), quality=np.array([1., 1.]),
                         calibrationRatio=np.array([1., 2.]), sourceGroup=np.array(['a', 'b']))

    def run_stage(self, before=None, cohorts=None, pages=None, **kwargs):
        n = len(self.source['style'])
        before = np.full(n, 10.) if before is None else before
        cohorts = [[i] for i in range(n)] if cohorts is None else cohorts
        pages = [[i] for i in range(len(cohorts))] if pages is None else pages
        return calibrate_style(before, cohorts, pages, config=self.config,
                               source_evidence=self.source, train_bank=self.bank,
                               return_diagnostics=True, **kwargs)

    def repeat_source(self, n):
        self.source = {k: np.repeat(v, n, axis=0) for k, v in self.source.items()}

    def test_distance_power_uses_weighted_log_ratios(self):
        self.config['neighbors'] = 2
        for power in (1., 2., 3.):
            self.config['inverseDistancePower'] = power
            result, d = self.run_stage()
            expected = 10 * 2**((1/2**power)/(1+1/2**power))
            self.assertAlmostEqual(result[0], expected, places=5)
            self.assertAlmostEqual(d['ratioSpread'][0], np.log(2)/2)

    def test_distance_floor_and_lower_weighted_median(self):
        self.bank['style'][:] = 0
        self.config.update(neighbors=2, neighborAggregation='median')
        result, d = self.run_stage()
        self.assertEqual(result[0], 10.)
        np.testing.assert_array_equal(d['referenceIndices'][0, :2], [0, 1])

    def test_stable_ties_same_source_exclusion_and_source_diversity(self):
        for key in self.bank:
            self.bank[key] = np.repeat(self.bank[key][:1], 5, axis=0)
        self.bank['sourceGroup'] = np.array(['query', 'a', 'a', 'b', 'c'])
        self.config['neighbors'] = 3
        _, d = self.run_stage()
        np.testing.assert_array_equal(d['referenceIndices'][0, :4], [1, 3, 4, -1])
        self.bank['sourceGroup'][0] = 'renamed'
        self.source['sourceGroup'][0] = 'renamed'
        _, renamed = self.run_stage()
        np.testing.assert_array_equal(d['referenceIndices'], renamed['referenceIndices'])

    def test_family_restriction_and_no_neighbors(self):
        self.bank['referenceFamily'][0] = 1
        result, d = self.run_stage()
        self.assertEqual(result[0], 20.)
        self.assertEqual(d['referenceIndices'][0, 0], 1)
        self.source['referenceFamily'][0] = 3
        result, d = self.run_stage()
        self.assertEqual(result[0], 10.)
        self.assertTrue(np.isinf(d['distance'][0]).all())

    def test_source_size_distance_changes_nearest(self):
        self.bank['measuredEm'][0] = 100.
        self.assertEqual(self.run_stage()[1]['referenceIndices'][0, 0], 0)
        self.config['sourceSizeDistanceWeight'] = 1.
        result, d = self.run_stage()
        self.assertEqual(d['referenceIndices'][0, 0], 1)
        self.assertEqual(result[0], 20.)

    def test_whitening_variance_floor_and_dimension_selection(self):
        self.source['style'] = np.array([[0., 999.]])
        self.bank['style'] = np.array([[1., -999.], [2., 0.]])
        self.config['whitening'] = True
        _, d = self.run_stage(explained_variance=[4., 0.])
        self.assertEqual(d['distance'][0, 0], .5)
        _, d = self.run_stage(explained_variance=[0., 0.])
        self.assertEqual(d['distance'][0, 0], 1000.)

    def test_support_quality_and_em_admission_boundaries(self):
        self.bank['calibrationRatio'][:] = 2
        for field, value, admitted in [('support', 0., False), ('support', .001, True),
                                        ('quality', .3, False), ('quality', .300001, True),
                                        ('measuredEm', 1.999, False), ('measuredEm', 2., True)]:
            with self.subTest(field=field, value=value):
                original = self.source[field].copy()
                self.source[field][:] = value
                _, d = self.run_stage()
                self.assertEqual(d['rowPoints'][0] > 0, admitted)
                self.source[field] = original

    def test_cohort_quality_power_and_numeric_support_weight(self):
        self.repeat_source(3)
        self.source['measuredEm'][:] = [10., 20., 30.]
        self.source['quality'][:] = [1., .5, 1.]
        self.source['support'][:] = [1., 100., 1.]
        result, d = self.run_stage(cohorts=[[0, 1, 2]], pages=[[0]])
        np.testing.assert_array_equal(result, [20., 20., 20.])
        self.assertEqual(d['proposals'][0], 20.)
        self.source['support'][1] = 1.
        self.source['quality'][2] = .4
        np.testing.assert_array_equal(self.run_stage(cohorts=[[0, 1, 2]], pages=[[0]])[0], [10.]*3)

    def test_spread_gate_includes_equality(self):
        self.config['neighbors'] = 2
        _, d = self.run_stage()
        self.config['maximumCalibrationLogSpread'] = d['ratioSpread'][0]
        self.assertGreater(self.run_stage()[0][0], 10.)
        self.config['maximumCalibrationLogSpread'] = np.nextafter(d['ratioSpread'][0], 0)
        self.assertEqual(self.run_stage()[0][0], 10.)

    def test_distance_quantile_is_computed_only_from_train_queries(self):
        self.repeat_source(3)
        self.source['style'][:, 0] = [0., -2., -100.]
        self.bank['calibrationRatio'][:] = 2
        self.config['TRAINSourceExcludedDistanceQuantile'] = .5
        result, d = self.run_stage(train_indices=[0, 1])
        self.assertEqual(d['distanceLimit'], 2.)
        np.testing.assert_array_equal(result, [20., 10., 10.])
        with self.assertRaises(ValueError):
            self.run_stage()
        self.bank['sourceGroup'] = np.array(['query', 'query'])
        with self.assertRaises(ValueError):
            self.run_stage(train_indices=[0])

    def test_strength_log_clip_and_bankers_rounding(self):
        self.bank['calibrationRatio'][:] = 2
        self.config.update(strength=.5, clip=np.log(1.1), quantum=1.)
        self.assertEqual(self.run_stage()[0][0], 11.)
        self.source['support'][:] = 0
        self.repeat_source(4)
        self.config['quantum'] = 2.
        np.testing.assert_array_equal(self.run_stage(before=[9., 11., 13., .1])[0], [8., 12., 12., 2.])

    def test_collision_rolls_back_entire_page_only(self):
        self.repeat_source(4)
        self.source['support'][:] = 0
        self.config['quantum'] = 2.
        result, d = self.run_stage(before=[11., 13., 15., 11.], pages=[[0, 1, 2], [3]])
        np.testing.assert_array_equal(result, [11., 13., 15., 12.])
        self.assertEqual(d['collisionPages'], [0])

    def test_empty_bank_empty_queries_and_input_immutability(self):
        original = copy.deepcopy((self.source, self.bank, self.config))
        a, _ = self.run_stage()
        b, _ = self.run_stage()
        np.testing.assert_array_equal(a, b)
        for current, prior in zip((self.source, self.bank), original[:2]):
            for key in current:
                np.testing.assert_array_equal(current[key], prior[key])
        self.assertEqual(self.config, original[2])
        self.bank = {k: v[:0] for k, v in self.bank.items()}
        np.testing.assert_array_equal(self.run_stage()[0], [10.])
        self.source = {k: v[:0] for k, v in self.source.items()}
        self.assertEqual(self.run_stage(before=[], cohorts=[], pages=[])[0].shape, (0,))

    def test_rejects_nonfinite_fields_and_forbidden_query_labels(self):
        for data in (self.source, self.bank):
            for key in data.keys() - {'sourceGroup'}:
                for value in (np.nan, np.inf, -np.inf):
                    with self.subTest(key=key, value=value):
                        original = data[key]
                        data[key] = np.full(original.shape, value)
                        with self.assertRaises(ValueError):
                            self.run_stage()
                        data[key] = original
        for key in ('strength', 'clip', 'quantum', 'sourceSizeDistanceWeight', 'inverseDistancePower'):
            self.config[key] = np.inf
            with self.assertRaises(ValueError):
                self.run_stage()
            if key in original_config():
                self.config[key] = original_config()[key]
            else:
                del self.config[key]
        self.source['fontSizePx'] = np.array([10.])
        with self.assertRaises(ValueError):
            self.run_stage()

    def test_rejects_malformed_shapes_ranges_and_cohort_records(self):
        for before, cohorts, pages in [([0.], [[0]], [[0]]), ([np.nan], [[0]], [[0]]),
                                        ([10.], [[0.]], [[0]]), ([10.], [[-1]], [[0]]),
                                        ([10.], [[0], [0]], [[0, 1]]), ([10.], [], []),
                                        ([10.], [[0]], [[1]]), ([10.], [[0]], [[0], [0]])]:
            with self.subTest(before=before, cohorts=cohorts, pages=pages), self.assertRaises(ValueError):
                self.run_stage(before, cohorts, pages)
        for key, value in [('referenceFamily', [1.5]), ('quality', [1.1]),
                           ('support', [-1.]), ('style', [0.]), ('sourceGroup', [np.nan]),
                           ('sourceGroup', ['']), ('measuredEm', [-1.])]:
            original = self.source[key]
            self.source[key] = np.asarray(value)
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.run_stage()
            self.source[key] = original
        for key, value in [('calibrationRatio', .25), ('calibrationRatio', 4.),
                           ('quality', .5), ('measuredEm', 1.)]:
            original = self.bank[key].copy()
            self.bank[key][:] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.run_stage()
            self.bank[key] = original
        self.repeat_source(2)
        with self.assertRaises(ValueError):
            self.run_stage([10., 11.], [[0, 1]], [[0]])
        with self.assertRaises(ValueError):
            self.run_stage([10., 10.], [[0], [1]], [[0, 1]])

    def test_rejects_bad_config_variance_and_numeric_overflow(self):
        for key, value in [('neighbors', 0), ('neighbors', 32), ('neighbors', True),
                           ('whitening', 1), ('styleDimensions', 2), ('styleDimensions', 1.5),
                           ('quantum', 0.), ('strength', -1.), ('clip', float('nan')),
                           ('inverseDistancePower', -1.), ('neighborAggregation', 'mode'),
                           ('TRAINSourceExcludedDistanceQuantile', 0.)]:
            previous = self.config.copy()
            self.config[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.run_stage()
            self.config = previous
        self.config['whitening'] = True
        for variance in (None, [], [-1.], [np.nan]):
            with self.assertRaises(ValueError):
                self.run_stage(explained_variance=variance)
        self.config['whitening'] = False
        self.source['style'][0, 0] = 1e300
        with self.assertRaises(ValueError):
            self.run_stage()


def original_config():
    return dict(strength=1., clip=10., quantum=.000001, sourceSizeDistanceWeight=0.)


if __name__ == '__main__':
    unittest.main()
