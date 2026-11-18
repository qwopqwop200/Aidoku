import copy,unittest
import numpy as np
import glyph_background_quality as q

class Classifier:
    n_features_in_=504
    classes_=np.array([0,1])
    def get_params(self):return q.CONFIG
    def predict_proba(self,x):
        d=x[:,252];p=np.where(d>0,.99,np.where(d<0,.01,.5))
        return np.column_stack([1-p,p])

def model():
    return dict(version=q.VERSION,sourceVersion=q.SOURCE_VERSION,sourceFeatureCount=126,featureCount=504,
        gate=q.GATE,configuration=q.CONFIG,helperSHA256=q.helper_hashes(),sourceFeatureNames=list(q.SOURCE_NAMES),featureNames=list(q.FEATURE_NAMES),classifier=Classifier())

class GlyphQualityTests(unittest.TestCase):
    def inputs(self):
        x=np.zeros((3,126),np.float32);x[1:,0]=1
        return [[0,0,0],[50,50,50],[60,60,60]],x

    def test_relative_choice_first_tie_and_purity(self):
        rgb,x=self.inputs();before=x.copy();chosen,e=q.choose(rgb,x,0,True,model())
        self.assertEqual(chosen,1);self.assertTrue(e['thresholdPassed']);np.testing.assert_array_equal(x,before)

    def test_missing_source_anchors_abstain(self):
        m=model();m['classifier'].predict_proba=lambda x:(_ for _ in ()).throw(AssertionError('No source anchor'))
        rgb,x=self.inputs();chosen,e=q.choose(rgb,x,0,False,m)
        self.assertEqual(chosen,0);self.assertFalse(e['thresholdPassed'])

    def test_current_self_probability_is_not_inflated(self):
        rgb,x=self.inputs();x[:]=0;chosen,e=q.choose(rgb,x,2,True,model())
        self.assertEqual(chosen,2);self.assertEqual(e['relativeQualityProbabilities'],[.5,.5,.5])

    def test_schema_gate_and_hash_changes_rejected(self):
        rgb,x=self.inputs()
        for key,value in [('gate',.9),('featureCount',503),('helperSHA256',{}),('sourceFeatureNames',[])]:
            m=copy.deepcopy(model());m[key]=value
            with self.assertRaises(ValueError):q.choose(rgb,x,0,True,m)

    def test_invalid_inputs_rejected(self):
        rgb,x=self.inputs()
        for base in (-1,3,True):
            with self.assertRaises(ValueError):q.choose(rgb,x,base,True,model())
        x[0,0]=np.nan
        with self.assertRaises(ValueError):q.choose(rgb,x,0,True,model())

class BaseClassifier:
    n_features_in_=102
    classes_=np.array([0,1])
    def predict_proba(self,x):return np.full((len(x),2),.5)

class BackgroundV4Guards(unittest.TestCase):
    def bundle(self):
        import final_background_refinement as bg
        from test_relative_background_quality import payload
        return dict(version=bg.GLYPH_MODEL_VERSION,featureVersion=bg.FUSED_FEATURE_VERSION,featureCount=102,
            baseFeatureCount=15,extraFeatureCount=87,featureNames=list(bg.FUSED_FEATURE_NAMES),extraFeatureNames=list(bg.EXTRA_FEATURE_NAMES),
            helperSHA256=bg.fusion_helper_sha256(),configuration=dict(maximumIncumbentScore=.1,minimumNewScore=.95),
            classifier=BaseClassifier(),relativeQualityModel=payload(),glyphQualityModel=model())

    def policy(self):
        import final_background_refinement as bg
        ids={n:'0'*64 for n in bg.MODEL_NAMES}
        return dict(enabled=True,version=bg.VERSION,modelVersion=bg.GLYPH_MODEL_VERSION,
            helperSHA256=bg.helper_sha256(),modelIdentities=ids,sourceArtifactSHA256=ids['final-background-model.pkl'],
            localFusionHelperSHA256=bg.fusion_helper_sha256(),relativeQualityHelperSHA256=bg.relative_helper_sha256(),
            glyphQualityVersion=q.VERSION,glyphQualityHelperSHA256=q.helper_hashes(),glyphSourceFeatureCount=24,glyphPairFeatureCount=504,
            featureVersion=bg.FUSED_FEATURE_VERSION,featureCount=102)

    def test_correct_v4_model_and_policy_validate(self):
        import final_background_refinement as bg
        bg.validate_model(self.bundle());p=self.policy();bg.validate_policy(p,p['modelIdentities'])

    def test_wrong_base_positive_class_and_shape_rejected(self):
        import final_background_refinement as bg
        for name,value in [('classes_',np.array([1,0])),('n_features_in_',101),('predict_proba',None)]:
            m=self.bundle();setattr(m['classifier'],name,value)
            with self.assertRaises(ValueError):bg.validate_model(m)

    def test_glyph_and_fused_policy_schema_must_match_runtime(self):
        import final_background_refinement as bg
        for name,value in [('glyphQualityVersion','stale'),('glyphSourceFeatureCount',125),('glyphPairFeatureCount',503),('featureVersion','stale'),('featureCount',101)]:
            p=self.policy();p[name]=value
            with self.assertRaises(ValueError):bg.validate_policy(p,p['modelIdentities'])

    def test_old_v2_warm_provenance_restores_exactly(self):
        import final_background_refinement as bg
        p=dict(background=dict(rgb=[10,20,30],primaryCorrectionEvidence=dict(version=bg.OLDER_VERSION,previousRGB=[1,2,3])))
        self.assertEqual(bg.restore_baseline(p),dict(background=dict(rgb=[1,2,3])))

if __name__=='__main__':unittest.main()
