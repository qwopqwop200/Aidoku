import unittest
from audit_saved_outline_layers import compare_layers


class PhysicalLayerMetricsTests(unittest.TestCase):
    def setUp(self):
        self.gt=dict(widthPx=6,layers=[dict(rgb=[255,255,255],widthPx=6,widthRangePx=[4,8]),
                                     dict(rgb=[0,120,240],widthPx=3,widthRangePx=[2,4])])
        self.layers=[dict(rgb=[255,255,255],widthPx=6),dict(rgb=[0,120,240],widthPx=3)]

    def test_colour_order_matters_even_with_correct_layer_count(self):
        result=compare_layers(self.gt,list(reversed(self.layers)))
        self.assertTrue(result['countMatches']);self.assertFalse(result['orderedColoursWithin10'])

    def test_physical_total_uses_layer_intervals_not_conflicting_nominal(self):
        result=compare_layers(self.gt,self.layers)
        self.assertTrue(result['nominalWidthDiffersFromLayerSum'])
        self.assertEqual(result['observedTotalWidthPx'],9)
        self.assertEqual(result['sumGTLayerWidthIntervalPx'],[6,12])
        self.assertTrue(result['orderedWidthsInIntervals']);self.assertTrue(result['observedTotalInSumInterval'])

    def test_missing_outer_ring_is_incomplete(self):
        result=compare_layers(self.gt,self.layers[:1])
        self.assertFalse(result['countMatches']);self.assertFalse(result['orderedColoursWithin10'])


if __name__=='__main__':unittest.main()
