"""Reject mixed source checkpoints and mutation outside observed layer outputs."""
import copy
from pathlib import Path
import tempfile
import unittest
from source_outer_shell_policy import make_policy, validate_policy, digest, MODEL_NAMES, PRIMARY_POLICY
from apply_outer_shell import assert_layers_only


class OuterShellPolicyTests(unittest.TestCase):
    def test_pairing_binds_threshold_all_models_primary_policy_and_helpers(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for name in (*MODEL_NAMES,PRIMARY_POLICY):
                (root/name).write_bytes(name.encode())
            policy=make_policy(root,.02)
            identities={name:digest(root/name) for name in MODEL_NAMES}
            primary=digest(root/PRIMARY_POLICY)
            validate_policy(policy,identities,primary)
            for key in MODEL_NAMES:
                with self.subTest(model=key),self.assertRaises(ValueError):
                    validate_policy(policy,{**identities,key:'stale'},primary)
            with self.assertRaises(ValueError):validate_policy(policy,identities,'stale')
            bad=copy.deepcopy(policy);bad['helperSHA256']['source_outer_shell_geometry.py']='stale'
            with self.assertRaises(ValueError):validate_policy(bad,identities,primary)
            for threshold in [float('nan'),float('inf'),-.1]:
                with self.subTest(threshold=threshold),self.assertRaises(ValueError):make_policy(root,threshold)

    def test_final_head_cannot_modify_any_other_output_or_provenance(self):
        before=dict(itemID='case',outline=dict(rgb=[1,2,3],present=True,widthPx=2,probability=.8),
                    fill=dict(rgb=[4,5,6]),background=dict(rgb=[7,8,9]),shadow=dict(present=False),other={'original':[1]})
        after=copy.deepcopy(before);after['outline'].update(observedLayers=[{'rgb':[1,2,3],'widthPx':2}],outerShellCorrection={})
        assert_layers_only(before,after)
        for field in ['itemID','outline','fill','background','shadow','other']:
            changed=copy.deepcopy(after)
            if field=='itemID':changed[field]='different'
            else:changed[field]['unexpected']=True
            with self.subTest(field=field),self.assertRaises(ValueError):assert_layers_only(before,changed)


if __name__=='__main__':unittest.main()
