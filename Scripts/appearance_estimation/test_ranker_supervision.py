import unittest
from unittest.mock import patch
import numpy as np
from optimize_appearance import train_ranker


class RecordingClassifier:
    def __init__(self,**kwargs):pass
    def fit(self,x,y,sample_weight):self.labels=y.copy();return self


class PaintSupervisionTests(unittest.TestCase):
    def test_less_exact_secondary_background_remains_a_training_positive(self):
        # Both source paints are valid; white is a less exact sample of the second annotation.
        row=dict(evaluationSplit='train',background=dict(colors=[[0,0,0],[240,240,240]]))
        packet=dict(colors=[[0,0,0],[255,255,255],[255,0,0]],features=np.zeros((3,35)).tolist())
        configuration=dict(leaves=7,iterations=2,regularization=10)
        with patch('optimize_appearance.HistGradientBoostingClassifier',RecordingClassifier):
            legacy=train_ranker([row],[packet],'background',configuration)
            per_paint=train_ranker([row],[packet],'background',dict(configuration,perPaintBackgroundSupervision=True))
        np.testing.assert_array_equal(legacy.labels,[1,0,0])
        np.testing.assert_array_equal(per_paint.labels,[1,1,0])


if __name__=='__main__':unittest.main()
