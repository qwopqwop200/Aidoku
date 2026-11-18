import unittest
import copy
import hashlib
from pathlib import Path
import numpy as np
import cv2
from source_shadow_observation import attach,validate_policy,add_neighborhoods,VERSION as OBSERVATION_VERSION
from shadow_displacement_evidence import VERSION as DISPLACEMENT_VERSION
from pixel_role_estimation import features,VERSION
from shadow_displacement_evidence import shifted


class FixedSourceRoles:
    classes_=np.array([0,1,2,3])
    def predict_proba(self,x):return np.tile([.1,.1,.7,.1],(len(x),1))


class WeakShadowRoles(FixedSourceRoles):
    def predict_proba(self,x):return np.tile([.1,.1,.8,0.],(len(x),1))


class SourceShadowObservationTests(unittest.TestCase):
    def source(self,component_count=3):
        width=50*component_count+20
        core=np.zeros((100,width),np.uint8)
        for x in [20+50*i for i in range(component_count)]:core[25:65,x:x+20]=1
        fringe=shifted(core,5,5);mask=(fringe|core)>0
        rgb=np.full((100,width,3),255,np.uint8);rgb[fringe>0]=160;rgb[core>0]=0
        geometry=dict(fontPixels=40)
        prediction=dict(fill=dict(rgb=[0,0,0]),outline=dict(present=False,probability=.1,rgb=[255,255,255],widthPx=0),
            background=dict(rgb=[255,255,255]),shadow=dict(present=True,rgb=None,offsetPx=None,opacity=None,blurRadiusPx=None))
        arrays=dict(rf=np.zeros((100,width,27),np.float32),segPrimary=mask.astype(np.float32),segBoundary=mask.astype(np.float32),ocr=np.zeros((100,width,8),np.float32))
        _,names=features(rgb,mask,arrays['rf'],arrays['segPrimary'],arrays['segBoundary'],arrays['ocr'],geometry,prediction,[0])
        model=dict(version=VERSION,featureNames=names,classifier=FixedSourceRoles(),probabilityThreshold=.5)
        return rgb,mask,arrays,geometry,prediction,model,{}

    def test_actual_source_proposal_and_component_validation_fill_missing_parameters(self):
        args=self.source();before=copy.deepcopy(args[4]);result=attach(*args)
        self.assertEqual(result['shadow']['rgb'],[160,160,160]);self.assertEqual(result['shadow']['offsetPx'],[5,5])
        self.assertEqual(result['shadow']['rgbInterpretation'],'observed-source-composite')
        self.assertIsNone(result['shadow']['opacity']);self.assertIsNone(result['shadow']['blurRadiusPx'])
        for field in ['fill','outline','background']:self.assertEqual(result[field],before[field])

    def test_existing_parameters_are_preserved(self):
        args=self.source();args[4]['shadow'].update(rgb=[1,2,3],offsetPx=[8,9])
        result=attach(*args)
        self.assertEqual(result['shadow']['rgb'],[1,2,3]);self.assertEqual(result['shadow']['offsetPx'],[8,9])

    def test_absent_shadow_does_not_require_or_run_source_role_evidence(self):
        args=list(self.source());args[4]['shadow']['present']=False;args[2]={};args[5]={}
        result=attach(*args)
        self.assertIsNone(result['shadow']['rgb']);self.assertIsNone(result['shadow']['offsetPx'])

    def test_sparse_pixel_role_confidence_does_not_erase_validated_physical_paint(self):
        args=self.source();args[5]['classifier']=WeakShadowRoles()
        result=attach(*args)
        self.assertEqual(result['shadow']['rgb'],[160,160,160])
        self.assertEqual(result['shadow']['sourceObservation']['proposal']['meanSourceShadowRoleProbability'],0.)

    def test_checkpoint_policy_rejects_mixed_models_and_changed_source_code(self):
        identities={'model.pkl':'model','pixel-role-model.pkl':'roles','width-model.pkl':'width','source-fill-palette-model.pkl':'fill'}
        policy=dict(presenceVersion=__import__('source_shadow_presence').VERSION,minimumUncorroboratedProbability=.7,
            presenceHelperSHA256=hashlib.sha256(Path(__file__).with_name('source_shadow_presence.py').read_bytes()).hexdigest(),version=OBSERVATION_VERSION,displacementVersion=DISPLACEMENT_VERSION,modelIdentities=identities,
            sourceHelperSHA256=hashlib.sha256(Path(__file__).with_name('source_shadow_observation.py').read_bytes()).hexdigest(),
            displacementHelperSHA256=hashlib.sha256(Path(__file__).with_name('shadow_displacement_evidence.py').read_bytes()).hexdigest(),
            nativeColourNeighborhoodsSHA256=hashlib.sha256(Path(__file__).with_name('native_colour_neighborhoods.py').read_bytes()).hexdigest(),
            localCoreHelperSHA256=hashlib.sha256(Path(__file__).with_name('local_source_core.py').read_bytes()).hexdigest(),
            glowHelperSHA256=hashlib.sha256(Path(__file__).with_name('shadow_glow_profiles.py').read_bytes()).hexdigest(),
            backgroundNormalizationSHA256=hashlib.sha256(Path(__file__).with_name('shadow_background_normalization.py').read_bytes()).hexdigest(),
            sourceCoreHelperSHA256=hashlib.sha256(Path(__file__).with_name('shadow_template_fit.py').read_bytes()).hexdigest())
        validate_policy(policy,identities)
        with self.assertRaises(ValueError):validate_policy(policy,dict(identities,**{'width-model.pkl':'different'}))
        with self.assertRaises(ValueError):validate_policy(dict(policy,sourceHelperSHA256='stale'),identities)

    def test_native_color_hypothesis_can_cross_old_bins_but_ambiguous_modes_abstain(self):
        positions=np.arange(40);probability=np.zeros(40);selected=np.ones((1,40),bool)
        model=dict(probabilityThreshold=.5)
        grey=np.array([[[126,126,126]]*20+[[129,129,129]]*20],np.uint8)
        result=add_neighborhoods(dict(available=False,rgb=None),grey,positions,probability,selected,selected,model)
        self.assertEqual(len(result['candidateHypotheses']),1)
        mixed=np.array([[[230,20,30]]*20+[[30,40,220]]*20],np.uint8)
        result=add_neighborhoods(dict(available=False,rgb=None),mixed,positions,probability,selected,selected,model)
        self.assertEqual(result['candidateHypotheses'],[])

    def test_local_bright_glyph_glow_is_observed_without_inventing_offset_or_intrinsic_opacity(self):
        args=list(self.source(6));core=np.zeros(args[1].shape,np.uint8)
        for x in [20+50*i for i in range(6)]:core[25:65,x:x+20]=1
        blur=cv2.GaussianBlur(core.astype(np.float32),(0,0),3)
        rgb=np.repeat(np.rint(220*(1-.7*blur)).astype(np.uint8)[:,:,None],3,axis=2);rgb[core>0]=255
        args[0]=rgb;args[1]=cv2.dilate(core,np.ones((19,19),np.uint8))>0;args[4]['fill']['rgb']=[255,255,255]
        result=attach(*args)
        self.assertIsNotNone(result['shadow']['rgb']);self.assertIsNone(result['shadow']['offsetPx'])
        self.assertIsNone(result['shadow']['opacity']);self.assertIsNone(result['shadow']['blurRadiusPx'])
        self.assertTrue(np.all(rgb==result['shadow']['rgb'],axis=2).any())
        first=copy.deepcopy(result)
        self.assertEqual(attach(*args),first,
            'Warm source replay must retain native glow corroboration and match fresh inference')

    def test_a_removal_mask_on_homogeneous_white_cannot_create_a_glow_colour(self):
        args=list(self.source(6));args[0][:]=255;args[4]['fill']['rgb']=[255,255,255]
        result=attach(*args)
        self.assertIsNone(result['shadow']['rgb']);self.assertIsNone(result['shadow']['offsetPx'])


if __name__=='__main__':unittest.main()
