"""Pure comparator tests; no training, GT, image/map IO or production edits."""
import copy, hashlib, pickle, unittest
from pathlib import Path
import numpy as np
import relative_background_quality as q

class DirectionalClassifier:
    n_features_in_=408
    classes_=np.array([0,1])
    def __init__(self,p=.95):self.p=p
    def predict_proba(self,x):
        delta=x[:,204]
        p=np.where(delta>0,self.p,np.where(delta<0,1-self.p,.5))
        return np.column_stack([1-p,p])

def payload(p=.95):
    return dict(version=q.VERSION,classifierVersion=q.CLASSIFIER,featureVersion=q.FEATURE_VERSION,
      sourceFeatureVersion=q.SOURCE_FEATURE_VERSION,featureCount=q.FEATURE_COUNT,
      sourceFeatureCount=q.SOURCE_FEATURE_COUNT,featureNames=list(q.FEATURE_NAMES),
      sourceFeatureNames=list(q.SOURCE_FEATURE_NAMES),helperSHA256=hashlib.sha256(Path(q.__file__).read_bytes()).hexdigest(),
      configuration=dict(minimumRelativeProbability=.95),classifier=DirectionalClassifier(p))

def descriptors(values):
    x=np.zeros((len(values),102),np.float32);x[:,0]=values;return x

class Tests(unittest.TestCase):
    def test_pair_schema_float32_parity(self):
        rng=np.random.default_rng(271);a=rng.normal(size=(13,102)).astype(np.float32);b=rng.normal(size=(13,102)).astype(np.float32)
        d=b-a;expected=np.column_stack([a,b,d,np.abs(d)]).astype(np.float32)
        np.testing.assert_array_equal(q.pair_features(a,b),expected)
        swapped=q.pair_features(b,a)
        np.testing.assert_array_equal(swapped[:,:102],b)
        np.testing.assert_array_equal(swapped[:,204:306],-d)
        np.testing.assert_array_equal(swapped[:,306:],np.abs(d))
        self.assertEqual(len(q.FEATURE_NAMES),408);self.assertEqual(len(set(q.FEATURE_NAMES)),408)

    def test_frozen_source_schema_and_cached_pair_parity(self):
        import importlib.util
        workspace=next(root for root in Path(__file__).resolve().parents if (root/'appearance-estimation-20261109/rf-seg-fusion/background-relative-quality-study/SOURCE102.npz').is_file())
        base=workspace/'appearance-estimation-20261109/rf-seg-fusion'
        path=base/'final-background-local-fusion-study/candidate-scripts/source_local_background_fusion.py'
        spec=importlib.util.spec_from_file_location('frozen_local_schema',path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        self.assertEqual(q.SOURCE_FEATURE_NAMES,m.FEATURE_NAMES)
        with np.load(base/'background-relative-quality-study/SOURCE102.npz') as z:x=z['x'][:16]
        a=np.repeat(x[:1],len(x),axis=0);d=x-a
        np.testing.assert_array_equal(q.pair_features(a,x),np.column_stack([a,x,d,np.abs(d)]).astype(np.float32))

    def test_threshold_inclusive(self):
        j,r=q.choose([[0,0,0],[1,1,1]],descriptors([0,1]),0,payload(.95))
        self.assertEqual(j,1);self.assertTrue(r['thresholdPassed']);self.assertEqual(r['relativeQualityProbability'],.95)

    def test_below_threshold_fallback(self):
        j,r=q.choose([[0,0,0],[1,1,1]],descriptors([0,1]),0,payload(.9499))
        self.assertEqual(j,0);self.assertFalse(r['thresholdPassed'])

    def test_stable_first_original_order_tie(self):
        j,r=q.choose([[1,1,1],[2,2,2],[0,0,0]],descriptors([1,1,0]),2,payload())
        self.assertEqual(j,0);self.assertEqual(r['proposalIndex'],0)

    def test_identical_rgb_different_descriptor_not_deduplicated(self):
        j,r=q.choose([[5,5,5],[5,5,5]],descriptors([1,0]),1,payload())
        self.assertEqual(j,0);self.assertTrue(r['changedIndex']);self.assertFalse(r['changedRGB'])

    def test_identical_descriptor_self_and_singleton(self):
        for rgb,x,base in [([[5,5,5],[5,5,5]],descriptors([0,0]),1),([[5,5,5]],descriptors([0]),0)]:
            j,r=q.choose(rgb,x,base,payload());self.assertEqual(j,base)
            self.assertTrue(all(v==.5 for v in r['relativeQualityProbabilities']))

    def test_swap_antisymmetry(self):
        rgb=[[1,1,1],[2,2,2]];x=descriptors([0,1]);m=payload(.98)
        _,a=q.choose(rgb,x,0,m);_,b=q.choose(rgb,x,1,m)
        self.assertAlmostEqual(a['relativeQualityProbabilities'][1]+b['relativeQualityProbabilities'][0],1,places=15)

    def test_warm_replay_starts_from_current_v2(self):
        rgb=[[1,1,1],[2,2,2],[3,3,3]];x=descriptors([0,1,2]);m=payload(.98)
        cold=q.choose(rgb,x,0,m)
        self.assertEqual(cold,q.choose(rgb,x,0,m));self.assertEqual(cold,q.choose(rgb,x,0,m))

    def test_source_and_model_immutability(self):
        rgb=np.array([[1,1,1],[2,2,2]],np.uint8);x=descriptors([0,1]);m=payload();before=pickle.dumps(m)
        xr=x.copy();cr=rgb.copy();x.flags.writeable=False;rgb.flags.writeable=False
        q.choose(rgb,x,0,m)
        np.testing.assert_array_equal(x,xr);np.testing.assert_array_equal(rgb,cr);self.assertEqual(before,pickle.dumps(m))

    def test_relative_evidence_distinct(self):
        _,r=q.choose([[1,1,1],[2,2,2]],descriptors([0,1]),0,payload())
        self.assertIn('relativeQualityProbability',r)
        self.assertNotIn('score',r);self.assertNotIn('incumbentScore',r);self.assertNotIn('binaryBackgroundScores',r)

    def test_invalid_inputs_and_model_rejected(self):
        rgb=[[1,1,1],[2,2,2]];x=descriptors([0,1]);m=payload()
        for base in [-1,2,True,.1]:
            with self.assertRaises(ValueError):q.choose(rgb,x,base,m)
        for xx in [np.zeros((2,101)),np.full((2,102),np.nan),np.zeros((0,102))]:
            with self.assertRaises(ValueError):q.choose(rgb,xx,0,m)
        bad=copy.deepcopy(m);bad['featureNames'][0]='wrong'
        with self.assertRaises(ValueError):q.choose(rgb,x,0,bad)
        bad=copy.deepcopy(m);bad['configuration']['minimumRelativeProbability']=.99
        with self.assertRaises(ValueError):q.choose(rgb,x,0,bad)

if __name__=='__main__':unittest.main()
