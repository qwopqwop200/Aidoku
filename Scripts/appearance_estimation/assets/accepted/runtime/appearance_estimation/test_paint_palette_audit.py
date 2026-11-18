import unittest
import numpy as np
from audit_pixel_palettes import measure,histogram
from train_pixel_roles import preserves_role_hits


class PaintPaletteAuditTests(unittest.TestCase):
    def test_missing_secondary_substyle_is_not_an_all_colours_success(self):
        row=dict(fill=dict(rgb=[0,0,0],colors=[[0,0,0]]),substyles=[dict(fill=dict(rgb=[255,0,0]))])
        pred=dict(fill=dict(rgb=[0,0,0]))
        result=measure([row],[pred],[[]])
        self.assertEqual(result['targetColours'],2)
        self.assertEqual(result['coveredColours'],1)
        self.assertEqual(result['allColoursCoveredMulticolour'],0)
        result=measure([row],[pred],[[dict(rgb=[255,0,0])]])
        self.assertEqual(result['allColoursCoveredMulticolour'],1)

    def test_histogram_representative_is_an_observed_colour(self):
        pixels=np.array([[0,0,15],[0,15,0],[15,0,0]]*4,np.uint8)
        bins=histogram(pixels,np.ones(len(pixels)))
        self.assertEqual(len(bins),1)
        self.assertIn(tuple(bins[0]['rgb']),{tuple(p) for p in pixels})

    def test_higher_average_cannot_erase_rare_shadow_hits(self):
        old=np.diag([8,8,8,1]);new=np.diag([10,10,10,0])
        self.assertFalse(preserves_role_hits(dict(confusion=new),dict(confusion=old)))
        self.assertTrue(preserves_role_hits(dict(confusion=old+np.eye(4,dtype=int)),dict(confusion=old)))


if __name__=='__main__':unittest.main()
