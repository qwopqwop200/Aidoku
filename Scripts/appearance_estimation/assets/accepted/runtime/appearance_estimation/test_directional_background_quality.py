"""Focused candidate V5 contracts and stage ordering; synthetic native crops only."""
import copy
import pickle
import unittest
from unittest.mock import patch
from contextlib import ExitStack
import numpy as np
import directional_background_quality as q
import final_background_refinement as bg
from test_glyph_background_quality import BackgroundV4Guards

class Classifier:
    n_features_in_=600
    classes_=np.array([0,1])
    def get_params(self): return dict(q.CONFIG)
    def predict_proba(self,x):
        p=np.where(x[:,300]>0,.99,np.where(x[:,300]<0,.01,.5))
        return np.column_stack([1-p,p])

def payload():
    return dict(version=q.VERSION,sourceVersion=q.SOURCE_VERSION,sourceFeatureCount=150,featureCount=600,
        gate=q.GATE,configuration=dict(q.CONFIG),helperSHA256=q.helper_hashes(),sourceFeatureNames=list(q.SOURCE_NAMES),
        featureNames=list(q.FEATURE_NAMES),classifier=Classifier())

class DirectionalQualityTests(unittest.TestCase):
    def inputs(self):
        x=np.zeros((3,150),np.float32);x[1:,0]=1
        return [[0,0,0],[50,50,50],[60,60,60]],x

    def test_exact_schema_pair_and_config(self):
        from source_local_background_fusion import FEATURE_NAMES as base
        from glyph_background import FEATURE_NAMES as glyph
        from directional_background import FEATURE_NAMES as directional
        self.assertEqual(q.SOURCE_NAMES,tuple(base)+tuple('glyph.'+n for n in glyph)+tuple('directional.'+n for n in directional))
        self.assertEqual(len(q.SOURCE_NAMES),150);self.assertEqual(len(q.FEATURE_NAMES),600)
        self.assertEqual(q.CONFIG['random_state'],487);self.assertEqual(q.GATE,.95)
        a=np.zeros((2,150),np.float32);b=np.ones_like(a)
        np.testing.assert_array_equal(q.pair(a,b),np.column_stack([a,b,b-a,abs(b-a)]))

    def test_first_tie_antisymmetry_and_input_purity(self):
        rgb,x=self.inputs();before=x.copy();m=payload();state=pickle.dumps(m)
        chosen,e=q.choose(rgb,x,0,True,m)
        self.assertEqual(chosen,1);self.assertTrue(e['thresholdPassed'])
        _,r=q.choose(rgb,x,1,True,m)
        self.assertAlmostEqual(e['relativeQualityProbabilities'][1]+r['relativeQualityProbabilities'][0],1)
        np.testing.assert_array_equal(x,before);self.assertEqual(state,pickle.dumps(m))

    def test_no_anchors_abstains_without_classifier_call(self):
        rgb,x=self.inputs();m=payload()
        m['classifier'].predict_proba=lambda x: self.fail('Classifier called without anchors')
        chosen,e=q.choose(rgb,x,2,False,m)
        self.assertEqual(chosen,2);self.assertFalse(e['thresholdPassed'])

    def test_frozen_metadata_and_helpers_rejected(self):
        for key,value in [('version','stale'),('sourceVersion','stale'),('sourceFeatureCount',126),('featureCount',504),('gate',.9),('configuration',{}),('helperSHA256',{}),('sourceFeatureNames',[]),('featureNames',[])]:
            with self.subTest(key=key):
                m=payload();m[key]=value
                with self.assertRaises(ValueError): q.validate(m)

    def test_bad_classifier_classes_counts_configuration_methods(self):
        for key,value in [('n_features_in_',504),('classes_',np.array([1,0])),('classes_',np.array([0,1,2])),('predict_proba',None),('get_params',None),('get_params',lambda:dict(q.CONFIG,random_state=463))]:
            m=payload();setattr(m['classifier'],key,value)
            with self.assertRaises(ValueError): q.validate(m)

    def test_invalid_source_and_probabilities(self):
        rgb,x=self.inputs()
        for source in (x[:,:126],np.full_like(x,np.nan)):
            with self.assertRaises(ValueError): q.choose(rgb,source,0,True,payload())
        for baseline in (-1,3,True):
            with self.assertRaises(ValueError): q.choose(rgb,x,baseline,True,payload())
        for values in (np.ones((3,1)),np.full((3,2),np.nan),np.full((3,2),1.1)):
            m=payload();m['classifier'].predict_proba=lambda x:values
            with self.assertRaises(ValueError):q.choose(rgb,x,0,True,m)

class V5IntegrationTests(unittest.TestCase):
    def bundle(self):
        m=BackgroundV4Guards().bundle();m['version']=bg.DIRECTIONAL_MODEL_VERSION;m['directionalQualityModel']=payload()
        return m

    def test_new_model_and_policy_contract(self):
        m=self.bundle();bg.validate_model(m)
        p=BackgroundV4Guards().policy();p.update(modelVersion=bg.DIRECTIONAL_MODEL_VERSION,
            directionalQualityVersion=q.VERSION,directionalSourceVersion=q.SOURCE_VERSION,directionalQualityHelperSHA256=q.helper_hashes(),
            directionalSourceFeatureCount=150,directionalPairFeatureCount=600,directionalGate=q.GATE)
        bg.validate_policy(p,p['modelIdentities'])
        for name,value in [('directionalQualityVersion','stale'),('directionalSourceVersion','stale'),('directionalQualityHelperSHA256',{}),('directionalSourceFeatureCount',126),('directionalPairFeatureCount',504),('directionalGate',.9),('glyphQualityVersion','stale')]:
            with self.subTest(name=name),self.assertRaises(ValueError):bg.validate_policy(dict(p,**{name:value}),p['modelIdentities'])
        for component in ('glyphQualityModel','directionalQualityModel'):
            bad=copy.deepcopy(m);bad[component]['sourceVersion']='stale'
            with self.assertRaises(ValueError):bg.validate_model(bad)

    def test_v1_through_v5_helper_and_model_provenance(self):
        versions=(bg.VERSION,bg.V4_VERSION,bg.PREVIOUS_VERSION,bg.OLDER_VERSION,bg.LEGACY_VERSION,bg.MODEL_VERSION,bg.FUSED_MODEL_VERSION,bg.RELATIVE_MODEL_VERSION,bg.GLYPH_MODEL_VERSION,bg.DIRECTIONAL_MODEL_VERSION)
        for version in versions:
            pred=dict(background=dict(rgb=[9,9,9],primaryCorrectionEvidence=dict(version=version,previousRGB=[1,2,3])))
            self.assertEqual(bg.restore_baseline(pred),dict(background=dict(rgb=[1,2,3])))
        with self.assertRaises(ValueError):bg.restore_baseline(dict(background=dict(primaryCorrectionEvidence=dict(version='unknown'))))

    def run_stage(self,model,observed=True):
        colours=[[10,10,10],[20,20,20],[30,30,30]]
        prediction=dict(background=dict(rgb=colours[2],colors=colours[:2],observedContextWeights=[.5,.5]),fill=dict(rgb=[0,0,0]),outline=dict(rgb=[1,1,1]))
        rgb=np.zeros((8,8,3),np.uint8);own=np.zeros((8,8),bool)
        arrays=dict(rf=np.zeros((8,8,27),np.float32),segPrimary=np.zeros((8,8),np.float32),segBoundary=np.zeros((8,8),np.float32),ocr=np.zeros((8,8,8),np.float32))
        x=np.zeros((3,15),np.float32);extra=np.zeros((3,24),np.float32);order=[]
        def glyph(*args):
            order.append('glyph');self.assertEqual(args[1].shape,(3,126));self.assertEqual(args[2],2)
            return 1,dict(thresholdPassed=True)
        def directional(*args):
            order.append('directional');self.assertEqual(args[1].shape,(3,150));self.assertEqual(args[2],1)
            return (0 if args[3] else 1),dict(thresholdPassed=bool(args[3]))
        with ExitStack() as stack:
            for name,value in [('source_gradient_contour.restore_baseline',lambda p:p),('source_outer_shell.restore_baseline',lambda p:p),('final_background_refinement.source_summaries',lambda *a:({},{})),('final_background_refinement.feature_matrix',lambda *a:(colours,x)),('final_background_refinement.extra_features',lambda *a:np.zeros((3,87),np.float32)),('final_background_refinement.relative_quality.choose',lambda *a:(2,{})),('glyph_background.features',lambda *a:(extra,dict(observed=True))),('final_background_refinement.glyph_quality.choose',glyph),('directional_background.features',lambda *a:(extra,dict(observed=observed))),('final_background_refinement.directional_quality.choose',directional)]:
                stack.enter_context(patch(name,value))
            before=copy.deepcopy(prediction);state=pickle.dumps(model)
            out=bg.apply(rgb,own,own,{},prediction,model,20,arrays)
            warm=bg.apply(rgb,own,own,{},out,model,20,arrays)
            self.assertEqual(warm,out);self.assertEqual(prediction,before);self.assertEqual(state,pickle.dumps(model))
            self.assertEqual(bg.restore_baseline(out),before)
            for key in ('fill','outline'):self.assertEqual(out[key],before[key])
        return out,order

    def test_v4_runs_first_then_v5_with_baseline_evidence(self):
        out,order=self.run_stage(self.bundle())
        self.assertEqual(order,['glyph','directional','glyph','directional'])
        self.assertEqual(out['background']['rgb'],[10,10,10])
        e=out['background']['primaryCorrectionEvidence']
        self.assertEqual(e['version'],bg.VERSION);self.assertEqual(e['v4BaselineIndex'],1)
        self.assertEqual(e['v4BaselineRGB'],[20,20,20]);self.assertIn('directionalQualityEvidence',e);self.assertIn('glyphQualityEvidence',e)

    def test_no_directional_anchors_preserve_actual_v4(self):
        out,_=self.run_stage(self.bundle(),False)
        self.assertEqual(out['background']['rgb'],[20,20,20])
        self.assertFalse(out['background']['primaryCorrectionEvidence']['directionalQualityEvidence']['thresholdPassed'])

    def test_legacy_v4_never_calls_directional_and_preserves_state(self):
        model=BackgroundV4Guards().bundle();out,order=self.run_stage(model)
        self.assertEqual(order,['glyph','glyph']);self.assertEqual(out['background']['rgb'],[20,20,20])
        self.assertNotIn('directionalQualityEvidence',out['background']['primaryCorrectionEvidence'])

if __name__=='__main__':unittest.main()
