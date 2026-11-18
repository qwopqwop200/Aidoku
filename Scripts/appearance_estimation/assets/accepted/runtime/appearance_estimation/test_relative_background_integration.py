"""Regression checks for frozen V2 baseline + relative source comparator."""
import copy
from pathlib import Path
import tempfile
import unittest
import numpy as np
import final_background_refinement as bg
import relative_background_quality as quality
from test_local_background_fusion import inputs

class ConfidentWrong:
    def predict_proba(self,x):
        p=np.full(len(x),.05);p[-1]=.999
        return np.column_stack([1-p,p])

class BrighterBetter:
    n_features_in_=408
    classes_=np.array([0,1])
    def predict_proba(self,x):
        p=np.where(x[:,204]>0,.999,np.where(x[:,204]<0,.001,.5))
        return np.column_stack([1-p,p])

def model():
    m=inputs()[5]
    m.update(version=bg.RELATIVE_MODEL_VERSION,classifier=ConfidentWrong())
    m['relativeQualityModel']=dict(version=quality.VERSION,classifierVersion=quality.CLASSIFIER,
        featureVersion=quality.FEATURE_VERSION,sourceFeatureVersion=quality.SOURCE_FEATURE_VERSION,
        featureCount=408,sourceFeatureCount=102,featureNames=list(quality.FEATURE_NAMES),
        sourceFeatureNames=list(quality.SOURCE_FEATURE_NAMES),helperSHA256=bg.relative_helper_sha256(),
        configuration=dict(minimumRelativeProbability=.95),classifier=BrighterBetter())
    return m

class RelativeBackgroundIntegration(unittest.TestCase):
    def test_high_binary_confidence_can_be_overruled_without_conflating_scores(self):
        a=list(inputs());a[5]=model()
        out=bg.apply(*a[:7],source_arrays=a[7]);e=out['background']['primaryCorrectionEvidence']
        self.assertEqual(out['background']['rgb'],[255]*3)
        self.assertEqual(e['v2BaselineIndex'],2)
        self.assertEqual(e['score'],.05)
        self.assertGreater(e['relativeQualityEvidence']['relativeQualityProbability'],.95)
        self.assertEqual(bg.restore_baseline(out),a[4])

    def test_warm_v1_v2_v3_recompute_same_frozen_baseline(self):
        a=list(inputs());a[5]=model();out=bg.apply(*a[:7],source_arrays=a[7])
        for version in (bg.LEGACY_VERSION,bg.PREVIOUS_VERSION,bg.VERSION):
            a[4]=copy.deepcopy(out);a[4]['background']['primaryCorrectionEvidence']['version']=version
            self.assertEqual(bg.apply(*a[:7],source_arrays=a[7]),out)

    def test_later_native_heads_only_restore_descriptor_view(self):
        a=list(inputs());a[5]=model();cold=bg.apply(*a[:7],source_arrays=a[7])
        a[4]=copy.deepcopy(cold);a[4]['outline'].update(rgb=[12,34,56],
            gradientContourCorrection=dict(version='source-confirmed-primary-contour-v2',previousRGB=[255]*3),
            observedLayers=[dict(rgb=[255]*3,widthPx=1.)],
            outerShellCorrection=dict(version='source-owned-finite-secondary-layer-v1',
                previousObservedLayersPresent=False,previousObservedLayersValue=None))
        before=copy.deepcopy(a[4]);warm=bg.apply(*a[:7],source_arrays=a[7])
        self.assertEqual(warm['background'],cold['background'])
        self.assertEqual(warm['outline'],before['outline'])
        self.assertEqual(a[4],before)

    def test_relative_model_and_source_arrays_are_authenticated(self):
        a=list(inputs());a[5]=model()
        with self.assertRaises(ValueError):bg.apply(*a[:7])
        for key,value in [('helperSHA256','a'*64),('featureCount',407),('sourceFeatureNames',[])]:
            broken=copy.deepcopy(a[5]);broken['relativeQualityModel'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):bg.validate_model(broken)

    def test_policy_binds_relative_helper_separately(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            for name in bg.MODEL_NAMES:(root/name).write_bytes(name.encode())
            policy=bg.make_policy(root,model(),root/'final-background-model.pkl')
            bg.validate_policy(policy,policy['modelIdentities'])
            policy['relativeQualityHelperSHA256']='0'*64
            with self.assertRaises(ValueError):bg.validate_policy(policy,policy['modelIdentities'])

if __name__=='__main__':unittest.main()
