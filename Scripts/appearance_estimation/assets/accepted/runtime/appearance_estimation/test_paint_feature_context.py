import copy
import unittest
import numpy as np
from pixel_role_estimation import describe,features,VERSION as PIXEL_VERSION
from paint_feature_context import feature_prediction,VERSION
from select_pixel_feature_context import acceptable
import test_pixel_roles as pixel_fixtures


class BackgroundAffinityClassifier:
    classes_=np.arange(4)
    def __init__(self,column):self.column=column
    def predict_proba(self,x):
        score=np.full((len(x),4),.01);selected=np.where(x[:,self.column]<.02,2,0)
        score[np.arange(len(x)),selected]=.97
        return score


class IndependentPaintContextTests(unittest.TestCase):
    def test_output_background_correction_does_not_recondition_calibrated_pixel_colours(self):
        args=list(pixel_fixtures.PixelRoleTests().inputs());_,names=features(*args,np.array([0]));model=dict(version=PIXEL_VERSION,featureNames=names,
            classifier=BackgroundAffinityClassifier(names.index('background.colourDistance')),probabilityThreshold=.8)
        original=copy.deepcopy(args[-1]);baseline=describe(*args,model)
        args[-1]=copy.deepcopy(original);args[-1]['background']['rgb']=[0,0,0]
        changed=describe(*args,model);self.assertNotEqual(baseline['roles'],changed['roles'])
        retained=describe(*args,dict(model,featureContext=dict(version=VERSION)),feature_prediction=original)
        self.assertEqual(baseline['roles'],retained['roles'])
        self.assertEqual(args[-1]['background']['rgb'],[0,0,0])

    def test_unknown_feature_context_is_rejected(self):
        args=pixel_fixtures.PixelRoleTests().inputs()
        with self.assertRaises(ValueError):feature_prediction(args[0],args[1],{},args[-2],dict(featureContext=dict(version='unknown')))

    def test_point_gain_cannot_replace_lost_palette_or_rare_role(self):
        points=dict(accuracy=.98,macroF1=.98,confusion=np.diag([10,9,8,1]).tolist())
        reference=dict(points=points,palette=dict(colourRecall=.99,annotatedColourPrecision=.95))
        self.assertTrue(acceptable(reference,reference))
        lost=copy.deepcopy(reference);lost['palette']['colourRecall']=.98
        self.assertFalse(acceptable(lost,reference))
        lost=copy.deepcopy(reference);lost['points'].update(accuracy=.99,macroF1=.99,confusion=np.diag([11,9,8,0]).tolist())
        self.assertFalse(acceptable(lost,reference))


if __name__=='__main__':unittest.main()
