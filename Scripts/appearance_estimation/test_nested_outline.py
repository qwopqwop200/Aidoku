import unittest
import cv2
import numpy as np
from nested_outline import measure,recover_presence


def render():
    core=np.zeros((120,260),np.uint8)
    for x in [15,95,175]:cv2.putText(core,'A',(x,85),cv2.FONT_HERSHEY_SIMPLEX,2,1,5,cv2.LINE_8)
    inner=cv2.dilate(core,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(15,15)))
    outer=cv2.dilate(inner,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(5,5)))
    rgb=np.full((120,260,3),[180,200,210],np.uint8)
    rgb[outer>0]=[0,0,0];rgb[inner>0]=[255,255,255];rgb[core>0]=[0,0,0]
    prediction=dict(fill=dict(rgb=[0,0,0]),outline=dict(rgb=[255,255,255],present=False,probability=.2))
    return rgb,outer>0,prediction


class NestedContourTests(unittest.TestCase):
    def test_same_colour_fill_and_outer_contour_can_have_white_ring(self):
        rgb,mask,p=render();old=rgb.copy();old_mask=mask.copy()
        result=recover_presence(rgb,mask,p,50)
        self.assertTrue(result['outline']['present'])
        self.assertFalse(p['outline']['present'])
        self.assertEqual(result['outline']['probability'],.2)
        self.assertIn('nestedContourEvidence',result['outline'])
        np.testing.assert_array_equal(rgb,old);np.testing.assert_array_equal(mask,old_mask)

    def test_rectangular_sign_background_is_not_glyph_outline(self):
        rgb,mask,p=render();rgb[:]=[0,0,0];rgb[6:-6,6:-6]=[255,255,255]
        for x in [15,95,175]:cv2.putText(rgb,'A',(x,85),cv2.FONT_HERSHEY_SIMPLEX,2,(0,0,0),5,cv2.LINE_8)
        self.assertFalse(measure(rgb,np.ones_like(mask),p,50)['reliable'])

    def test_plain_text_and_glyph_counters_do_not_become_outline(self):
        rgb,mask,p=render();rgb[:]=[255,255,255]
        for x in [15,95,175]:cv2.putText(rgb,'A',(x,85),cv2.FONT_HERSHEY_SIMPLEX,2,(0,0,0),5,cv2.LINE_8)
        self.assertFalse(measure(rgb,np.ones_like(mask),p,50)['reliable'])

    def test_misaligned_geometry_is_rejected(self):
        rgb,mask,p=render()
        with self.assertRaises(ValueError):measure(rgb,mask[:90],p,50)


if __name__=='__main__':unittest.main()
