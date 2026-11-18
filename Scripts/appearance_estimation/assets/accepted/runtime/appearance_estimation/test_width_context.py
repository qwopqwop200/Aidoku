import copy
import unittest
import numpy as np
from calibrate_width import width_features
from width_context import VERSION


class ReferenceBackground:
    def predict_proba(self,x):return np.array([[.9,.1],[.1,.9],[.6,.4]])


class IndependentWidthContextTests(unittest.TestCase):
    def test_background_display_choice_does_not_change_independent_physical_width_features(self):
        packet=dict(fontPixels=20,features=np.arange(12).reshape(3,4).tolist(),pair=np.arange(54).reshape(3,3,6).tolist(),maskFraction=.4)
        first=dict(fillIndex=0,outlineIndex=1,backgroundIndex=0);second=dict(first,backgroundIndex=2);vector=np.arange(8)
        self.assertFalse(np.array_equal(width_features(packet,first,vector),width_features(packet,second,vector)))
        context=dict(backgroundContextRanker=ReferenceBackground(),backgroundContextConditioned=False,backgroundContextVersion=VERSION)
        np.testing.assert_array_equal(width_features(packet,first,vector,context),width_features(packet,second,vector,context))
        self.assertEqual(first['backgroundIndex'],0);self.assertEqual(second['backgroundIndex'],2)
        with self.assertRaises(ValueError):width_features(packet,first,vector,dict(context,backgroundContextVersion='stale'))


if __name__=='__main__':unittest.main()
