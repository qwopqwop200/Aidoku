import copy,hashlib
from pathlib import Path
import unittest
import numpy as np
from width_resolution import native_features,predict,raw,validate_adaptive,ADAPTIVE_VERSION,VERSION,helper_sha256
from adaptive_normal_width import VERSION as MEASUREMENT_VERSION

class Base:
    def predict(self,x):return np.full(len(x),4.)
class Native:
    n_features_in_=712
    def predict(self,x):return np.asarray(x)[:,-50]

def model():
    return dict(regressor=Base(),outputResolutionPx=.5,outputResolutionVersion=VERSION,outputResolutionHelperSHA256=helper_sha256(),
        adaptiveNormalRefinement=dict(version=ADAPTIVE_VERSION,measurementVersion=MEASUREMENT_VERSION,sourceFeatureCount=662,featureCount=50,
            helperSHA256=hashlib.sha256(Path(__file__).with_name('adaptive_normal_width.py').read_bytes()).hexdigest(),scale=1.,regressor=Native()))

class AdaptiveWidthRuntimeTests(unittest.TestCase):
    def test_native_matrix_is_used_and_projection_is_last(self):
        m=model();x=np.zeros((2,662));n=np.zeros((2,50));n[:,0]=[2.3,6.8]
        np.testing.assert_allclose(raw(m,x,n),[2.3,6.8]);np.testing.assert_equal(predict(m,x,n),[2.5,7.])
        m['adaptiveNormalRefinement']['scale']=.5
        np.testing.assert_equal(predict(m,x,n),[3.,5.5])
    def test_missing_wrong_sized_or_nonfinite_native_inputs_fail_closed(self):
        m=model();x=np.zeros((2,662))
        for n in (None,np.zeros((1,50)),np.zeros((2,49)),np.full((2,50),np.nan)):
            with self.subTest(shape=np.asarray(n).shape),self.assertRaises(ValueError):predict(m,x,n)
        for key,value in [('helperSHA256','0'*64),('version','stale'),('featureCount',49),('measurementVersion','stale')]:
            bad=copy.deepcopy(m);bad['adaptiveNormalRefinement'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):validate_adaptive(bad)
    def test_legacy_and_absent_source_observations_are_unchanged(self):
        x=np.zeros((2,662));np.testing.assert_equal(predict(dict(regressor=Base()),x),[4.,4.])
        rgb=np.full((10,12,3),255,np.uint8);mask=np.ones((10,12),bool);p=dict(fill=dict(rgb=[0,0,0]),outline=dict(rgb=[255]*3,present=False))
        self.assertIsNone(native_features(dict(regressor=Base()),rgb,mask,p,20))
        n=native_features(model(),rgb,mask,p,20);np.testing.assert_equal(n,np.zeros(50))

if __name__=='__main__':unittest.main()
