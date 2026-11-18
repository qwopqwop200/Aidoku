"""Global source width resolution, pairing, and TEST-independent selection."""
import unittest
import numpy as np
from width_resolution import project,predict,VERSION,helper_sha256
from calibrate_width import select_output_resolution


class SourceRegressor:
    def predict(self,x):return np.asarray(x)[:,0]


class WidthResolutionTests(unittest.TestCase):
    def test_native_resolution_is_global_bounded_and_idempotent(self):
        raw=np.linspace(.25,12,200)
        out=project(raw,.5)
        self.assertLessEqual(float(abs(out-raw).max()),.25)
        np.testing.assert_array_equal(project(out,.5),out)
        self.assertTrue((out>=.25).all())

    def test_legacy_model_unchanged_and_calibrated_model_binds_helper(self):
        x=np.array([[1.24],[2.8],[-.1]])
        legacy={'regressor':SourceRegressor()}
        np.testing.assert_array_equal(predict(legacy,x),[1.24,2.8,.25])
        model={**legacy,'outputResolutionPx':.5,'outputResolutionVersion':VERSION,'outputResolutionHelperSHA256':helper_sha256()}
        np.testing.assert_array_equal(predict(model,x),[1.,3.,.25])
        for key,value in [('outputResolutionVersion','stale'),('outputResolutionHelperSHA256','stale')]:
            broken={**model,key:value}
            with self.subTest(key=key),self.assertRaises(ValueError):predict(broken,x)

    def test_invalid_resolution_or_nonfinite_source_output_is_rejected(self):
        for resolution in [.3,-1,float('nan')]:
            with self.assertRaises(ValueError):project([1.],resolution)
        with self.assertRaises(ValueError):project([float('inf')],.5)

    def test_selector_ignores_test_targets_and_preserves_existing_resolution(self):
        raw=np.array([1.04,2.08,1.18,1.02,900.])
        presence=np.array([True,True,True,False,True]);target=np.array([1,2,1,2,np.nan])
        ranges=np.array([[.8,1.1],[1.8,2.1],[.8,1.1],[1.8,2.1],[np.nan,np.nan]])
        train=np.array([1,1,0,0,0],bool);dev=np.array([0,0,1,1,0],bool)
        first=select_output_resolution(raw,presence,target,ranges,train,dev,raw)
        target[-1]=-10000.;ranges[-1]=[-10001,-9999]
        second=select_output_resolution(raw,presence,target,ranges,train,dev,raw)
        self.assertEqual(first[0],second[0]);self.assertEqual(first[2],second[2])
        quantized=project(raw,.5)
        selected,values,meta=select_output_resolution(raw,presence,target,ranges,train,dev,quantized)
        for group in ['train','dev']:
            chosen=next(c for c in meta['candidates'] if c['resolutionPx']==selected)
            self.assertGreaterEqual(chosen['metrics'][group]['hits'],meta['baseline'][group]['hits'])
            self.assertLessEqual(chosen['metrics'][group]['MAEPx'],meta['baseline'][group]['MAEPx'])


if __name__=='__main__':unittest.main()
