import copy,unittest
import numpy as np
from glyph_background import features,FEATURE_NAMES

class GlyphBackgroundTests(unittest.TestCase):
    def source(self):
        own=np.zeros((16,16),bool);own[2:14,2:14]=True
        rgb=np.full((16,16,3),[220,20,20],np.uint8);rgb[own]=[20,100,220];rgb[7:10,7]=0
        rf=np.zeros((16,16,27),np.float32);rf[:,:,15:17]=1
        ocr=np.zeros((16,16,8),np.float32);ocr[:,:,0]=1
        seg=np.zeros((16,16),np.float32);seg[7:10,7]=1
        arrays=dict(rf=rf,ocr=ocr,segPrimary=seg,segBoundary=np.zeros_like(seg))
        return rgb,own,own.copy(),[[20,100,220],[220,20,20]],25.,arrays

    def test_real_background_inside_removal_mask_is_not_discarded(self):
        args=self.source();x,e=features(*args)
        self.assertTrue(e['observed']);self.assertGreater(e['insideOwnPixels'],0)
        self.assertEqual(x[0,FEATURE_NAMES.index('near.colourFraction')],1.)
        self.assertEqual(x[1,FEATURE_NAMES.index('near.colourFraction')],0.)

    def test_rf_or_ocr_missing_cannot_invent_anchors(self):
        for name in ('rf','ocr'):
            args=list(self.source());args[-1][name][:]=0
            x,e=features(*args);self.assertFalse(e['observed']);self.assertFalse(x.any())

    def test_palette_permutation_equivariance_and_input_purity(self):
        args=list(self.source());before=copy.deepcopy(args);a,_=features(*args);args[3]=args[3][::-1];b,_=features(*args)
        np.testing.assert_array_equal(a,b[::-1]);np.testing.assert_array_equal(args[0],before[0]);np.testing.assert_array_equal(args[-1]['segPrimary'],before[-1]['segPrimary'])

    def test_neighbour_union_suppresses_only_other_predicted_text(self):
        args=list(self.source());base,_=features(*args);args[2][:]=True;x,e=features(*args)
        self.assertTrue(e['observed']);self.assertEqual(x[0,FEATURE_NAMES.index('near.colourFraction')],base[0,FEATURE_NAMES.index('near.colourFraction')])
        self.assertEqual(x[1,FEATURE_NAMES.index('outer.colourFraction')],0)

    def test_invalid_source_rejected(self):
        args=list(self.source());args[-1]['segPrimary'][0,0]=np.nan
        with self.assertRaises(ValueError):features(*args)

if __name__=='__main__':unittest.main()
