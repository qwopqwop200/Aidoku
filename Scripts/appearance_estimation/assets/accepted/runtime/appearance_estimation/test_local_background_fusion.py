"""Pure runtime pairing, legacy parity, local support and mixed-precision tests."""
import copy
from pathlib import Path
import tempfile
import unittest
import numpy as np
import final_background_refinement as current
from source_local_background_fusion import FEATURE_NAMES,EXTRA_FEATURE_NAMES,FEATURE_VERSION,extra_features


class SourceClassifier:
    def predict_proba(self,x):
        self.last=np.asarray(x).copy()
        probabilities=np.full(len(x),.02);probabilities[0]=.98
        return np.column_stack([1-probabilities,probabilities])


def inputs(fused=True):
    rgb=np.full((20,25,3),255,np.uint8);own=np.zeros((20,25),bool);own[6:14,10:15]=True;rgb[own]=0
    context=own.copy();packet=dict(colors=[[255]*3,[120]*3,[0]*3])
    prediction=dict(fill=dict(rgb=[0]*3),outline=dict(rgb=[255]*3,present=True,widthPx=2),
        background=dict(rgb=[120]*3,colors=[[255]*3,[120]*3],observedContextWeights=[.7,.3],candidateScores=[.8,.5]),
        pixelRoleEvidence=dict(roles=dict(background=dict(observedColours=[dict(rgb=[255]*3,observedMass=.8)]))),
        shadow=dict(present=False,rgb=None),opaque={'unchanged':[1,2,3]})
    arrays=dict(rf=np.full((20,25,27),.25,np.float32),segPrimary=np.full((20,25),.125,np.float32),segBoundary=np.full((20,25),.5,np.float32),ocr=np.full((20,25,8),.75,np.float32))
    model=dict(version=current.MODEL_VERSION,featureCount=15,classifier=SourceClassifier(),configuration=dict(maximumIncumbentScore=.1,minimumNewScore=.95))
    if fused:model.update(version=current.FUSED_MODEL_VERSION,featureVersion=FEATURE_VERSION,featureCount=102,baseFeatureCount=15,extraFeatureCount=87,featureNames=list(FEATURE_NAMES),extraFeatureNames=list(EXTRA_FEATURE_NAMES),helperSHA256=current.fusion_helper_sha256())
    return rgb,own,context,packet,prediction,model,20.,arrays


class LocalBackgroundFusionTests(unittest.TestCase):
    def test_legacy15_rgb_and_all_nonowned_fields_match_original(self):
        args=inputs(False);expected=copy.deepcopy(args[4]);expected['background']['rgb']=[255]*3
        actual=current.apply(*args[:7]);actual['background'].pop('primaryCorrectionEvidence',None)
        self.assertEqual(actual,expected)

    def test_fused102_only_changes_background_rgb_and_own_evidence(self):
        args=inputs();before=copy.deepcopy(args[4]);out=current.apply(*args[:7],source_arrays=args[7])
        self.assertEqual(args[4],before);self.assertEqual(out['background']['rgb'],[255]*3)
        self.assertEqual(args[5]['classifier'].last.shape,(3,102))
        self.assertEqual(current.restore_baseline(out),before)
        warm=list(args);warm[4]=out
        self.assertEqual(current.apply(*warm[:7],source_arrays=warm[7]),out)
        old=current.apply(*inputs(False)[:7]);old['background']['primaryCorrectionEvidence']['version']=current.LEGACY_VERSION;warm[4]=old
        migrated=current.apply(*warm[:7],source_arrays=warm[7]);self.assertEqual(current.restore_baseline(migrated),before)
        self.assertEqual(migrated['background']['primaryCorrectionEvidence']['version'],current.VERSION)

    def test_float16_runtime_and_float32_replay_have_identical_inputs_and_output(self):
        args=inputs();wide=current.apply(*args[:7],source_arrays=args[7]);matrix=args[5]['classifier'].last.copy()
        half={name:value.astype(np.float16) for name,value in args[7].items()}
        narrow=current.apply(*args[:7],source_arrays=half)
        np.testing.assert_array_equal(matrix,args[5]['classifier'].last);self.assertEqual(wide,narrow)

    def test_fused_model_requires_authentic_feature_schema_helper_and_arrays(self):
        args=inputs()
        with self.assertRaises(ValueError):current.apply(*args[:7])
        for key,value in [('helperSHA256','stale'),('featureVersion','stale'),('featureCount',15),('featureNames',list(reversed(FEATURE_NAMES)))]:
            broken=copy.deepcopy(args[5]);broken[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):current.apply(*args[:5],broken,args[6],source_arrays=args[7])
        broken={**args[7],'rf':np.zeros((19,25,27),np.float32)}
        with self.assertRaises(ValueError):current.apply(*args[:7],source_arrays=broken)

    def test_new_features_do_not_sample_outside_local_nontext_collar(self):
        args=inputs();colours=args[4]['background']['colors']+[args[4]['background']['rgb']]
        baseline=extra_features(args[0],args[1],args[2],colours,args[6],args[7])
        arrays={name:value.copy() for name,value in args[7].items()}
        for value in arrays.values():value[0]=0
        changed=extra_features(args[0],args[1],args[2],colours,args[6],arrays)
        np.testing.assert_array_equal(changed,baseline)
        empty=extra_features(args[0],args[1],np.ones_like(args[1]),colours,args[6],args[7])
        np.testing.assert_array_equal(empty,np.zeros((3,87),np.float32))

    def test_policies_bind_all_models_source_artifact_and_both_helpers(self):
        args=inputs()
        with tempfile.TemporaryDirectory() as directory:
            folder=Path(directory)
            for name in current.MODEL_NAMES:(folder/name).write_bytes(name.encode())
            policy=current.make_policy(folder,args[5],folder/'final-background-model.pkl')
            current.validate_policy(policy,policy['modelIdentities'])
            for name in current.MODEL_NAMES:
                bad={**policy['modelIdentities'],name:'a'*64}
                with self.subTest(name=name),self.assertRaises(ValueError):current.validate_policy(policy,bad)
            for key in ['helperSHA256','localFusionHelperSHA256','sourceArtifactSHA256']:
                bad={**policy,key:'stale'}
                with self.subTest(key=key),self.assertRaises(ValueError):current.validate_policy(bad,policy['modelIdentities'])


if __name__=='__main__':unittest.main()
