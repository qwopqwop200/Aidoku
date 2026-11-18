import unittest
from refine_heads import reference_colour_trial


class RetainedColourContextTests(unittest.TestCase):
    def test_background_head_carries_its_conditioned_feature_schema(self):
        current=dict(featureVersion='source-v2',background='current',conditionedBackground=False)
        previous=dict(featureVersion='source-v2',background='validated',conditionedBackground=True,perPaintBackgroundSupervision=True)
        trial=reference_colour_trial(current,previous,'background')
        self.assertEqual(trial['background'],'validated');self.assertTrue(trial['conditionedBackground']);self.assertTrue(trial['perPaintBackgroundSupervision'])
        self.assertFalse(current['conditionedBackground'])
        with self.assertRaises(ValueError):reference_colour_trial(current,dict(previous,featureVersion='old'),'background')


if __name__=='__main__':unittest.main()
