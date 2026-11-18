import copy
import unittest
import numpy as np
from pixel_role_estimation import features,describe,VERSION
from test_fused_source_appearance import fixture


class SourceColourClassifier:
    classes_=np.arange(4)
    def predict_proba(self,x):
        result=np.full((len(x),4),.01)
        selected=np.where(x[:,0]>.8,0,2)
        result[np.arange(len(x)),selected]=.97
        return result


class PixelRoleTests(unittest.TestCase):
    def inputs(self):
        rgb,mask,rf,p,q,ocr,polygons=fixture()
        geometry=dict(polygons=polygons,mergedPolygon=[[10,10],[54,10],[54,36],[10,36]],fontPixels=25)
        prediction=dict(fill=dict(rgb=[250,30,120]),outline=dict(rgb=[250,250,250],present=True,probability=.9),
            background=dict(rgb=[150,170,190]),shadow=dict(present=False))
        return rgb,mask,rf,p,q,ocr,geometry,prediction

    def test_pixel_source_evidence_is_consumed_without_mutation(self):
        args=list(self.inputs());rgb_before=args[0].copy();prediction_before=copy.deepcopy(args[-1]);positions=np.array([20*65+20])
        baseline,names=features(*args,positions)
        for index in [2,3,4,5]:
            changed=list(args);changed[index]=args[index].copy();changed[index][...]=.9
            actual,_=features(*changed,positions)
            self.assertFalse(np.array_equal(baseline,actual))
        np.testing.assert_array_equal(args[0],rgb_before);self.assertEqual(args[-1],prediction_before)
        with self.assertRaises(ValueError):features(*args,np.array([-1]))

    def test_role_palettes_are_observed_source_colours(self):
        args=self.inputs();_,names=features(*args,np.array([0]))
        model=dict(version=VERSION,featureNames=names,classifier=SourceColourClassifier(),probabilityThreshold=.8)
        result=describe(*args,model)
        observed={tuple(c) for c in args[0].reshape(-1,3)}
        self.assertGreater(result['roles']['fill']['confidentSamples'],8)
        for role in result['roles'].values():
            for colour in role['observedColours']:self.assertIn(tuple(colour['rgb']),observed)
        self.assertEqual(result['roles']['shadowComposite']['observedColours'],[])

    def test_fill_calibration_does_not_raise_outline_or_background_thresholds(self):
        args=self.inputs();_,names=features(*args,np.array([0]))
        model=dict(version=VERSION,featureNames=names,classifier=SourceColourClassifier(),probabilityThreshold=.8)
        before=describe(*args,model)
        after=describe(*args,dict(model,roleProbabilityThresholds=dict(fill=.99)))
        self.assertGreater(before['roles']['fill']['confidentSamples'],0)
        self.assertEqual(after['roles']['fill']['confidentSamples'],0)
        for role in ['outline','background','shadowComposite']:
            self.assertEqual(before['roles'][role],after['roles'][role])


if __name__=='__main__':unittest.main()
