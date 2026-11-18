import copy
import unittest
from calibrate_shadow import width_snapshot_matches


class ShadowSnapshotTests(unittest.TestCase):
    def fixture(self):
        row=dict(itemID='source-a',fill=dict(rgb=[20,20,20]),outline=dict(rgb=[250,250,250],present=False,widthPx=0),background=dict(rgb=[230,230,230]))
        return row,dict(items=[copy.deepcopy(row)],sourceRoleModelSHA256='model-before')

    def test_authenticated_postprocessed_widths_are_preserved(self):
        raw,snapshot=self.fixture();snapshot['items'][0]['outline'].update(rgb=[140,90,45],present=True,widthPx=6)
        self.assertTrue(width_snapshot_matches(snapshot,[raw],'model-before',['source-a']))
        self.assertEqual(snapshot['items'][0]['outline']['widthPx'],6)

    def test_changed_role_model_cannot_reuse_incompatible_source_widths(self):
        raw,snapshot=self.fixture();snapshot['items'][0]['outline']['rgb']=[140,90,45]
        self.assertFalse(width_snapshot_matches(snapshot,[raw],'different-model',['source-a']))

    def test_identity_and_order_must_match_even_with_same_model_hash(self):
        raw,snapshot=self.fixture();snapshot['items'][0]['itemID']='another-source'
        self.assertFalse(width_snapshot_matches(snapshot,[raw],'model-before',['source-a']))


if __name__=='__main__':unittest.main()
