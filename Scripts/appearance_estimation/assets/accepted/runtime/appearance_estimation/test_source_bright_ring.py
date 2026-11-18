import unittest
import numpy as np
from source_bright_ring import propose,corroborate


class BrightRingTests(unittest.TestCase):
    def source(self,panel=False,edge=False,gap=False):
        rgb=np.full((100,240,3),255,np.uint8);brown=[145,90,50];mask=np.zeros((100,240),bool)
        if panel:rgb[5:95,5:235]=brown;mask[5:95,5:235]=True
        for x in [20,90,160]:
            top=0 if edge else 20
            rgb[top:80,x:x+40]=brown;rgb[top+2:78,x+2:x+38]=[255,235,150]
            mask[top:80,x:x+40]=True
            if gap:rgb[top,x+20]=255
        p=dict(fill=dict(rgb=[255]*3),background=dict(rgb=[255]*3),outline=dict(present=True,rgb=[0]*3))
        return rgb,mask,[],40,[brown,[0]*3,[255]*3],p

    def test_repeated_finite_dark_rings_accept_bright_interiors(self):
        q=propose(*self.source());self.assertTrue(q['proposals'])
        self.assertEqual(q['proposals'][0]['rgb'],[145,90,50]);self.assertGreaterEqual(q['proposals'][0]['coreCount'],3)

    def test_thick_coloured_panel_is_not_a_glyph_outline(self):
        self.assertEqual(propose(*self.source(panel=True))['proposals'],[])

    def test_context_edge_cannot_be_closed_into_an_observed_ring(self):
        self.assertEqual(propose(*self.source(edge=True))['proposals'],[])

    def test_unrelated_ring_branch_at_crop_edge_does_not_erase_observed_local_holes(self):
        args=list(self.source());args[0][0:22,20:22]=[145,90,50];args[1][0:22,20:22]=True
        self.assertTrue(propose(*args)['proposals'])

    def test_small_closure_gap_never_becomes_new_colour_evidence(self):
        args=self.source(gap=True);p=propose(*args)
        self.assertTrue(p['proposals'])
        for q in p['proposals']:
            self.assertTrue(np.all(args[0]==q['rgb'],axis=2).any())
            self.assertGreaterEqual(q['holes'][0]['rawRingFraction'],.75)

    def test_source_semantics_are_required_independently_of_topology(self):
        args=self.source();p=propose(*args)['proposals'][0];h,w=args[1].shape
        arrays=dict(rf=np.zeros((h,w,27),np.float32),segPrimary=np.ones((h,w),np.float32),segBoundary=np.ones((h,w),np.float32),ocr=np.ones((h,w,8),np.float32))
        self.assertFalse(corroborate(p,arrays)['accepted'])
        arrays['rf'][:,:,15:17]=.2
        self.assertTrue(corroborate(p,arrays)['accepted'])
        arrays['segPrimary'][:]=0;arrays['segBoundary'][:]=0
        self.assertFalse(corroborate(p,arrays)['accepted'])

    def test_known_dark_fill_does_not_get_reinterpreted_as_bright_holes(self):
        args=list(self.source());args[-1]['fill']['rgb']=[25,50,100]
        self.assertFalse(propose(*args)['eligible'])


if __name__=='__main__':unittest.main()
