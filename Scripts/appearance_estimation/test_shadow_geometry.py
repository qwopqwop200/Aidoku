import unittest
import cv2
import numpy as np
from shadow_template_fit import estimate


def render(offset=(2,3),blur=1.2,shadow=True,fill=(240,20,130),outline=(255,255,255)):
    core=np.zeros((110,150),np.uint8)
    for x in [25,60,95]:core[30:80,x:x+12]=1
    body=cv2.dilate(core,np.ones((5,5),np.uint8))
    shifted=cv2.warpAffine(body.astype(np.float32),np.float32([[1,0,offset[0]],[0,1,offset[1]]]),(150,110))
    alpha=cv2.GaussianBlur(shifted,(0,0),blur) if shadow else np.zeros_like(shifted)
    rgb=np.rint(255-55*alpha[:,:,None]).repeat(3,axis=2).astype(np.uint8)
    rgb[body>0]=outline;rgb[core>0]=fill
    prediction=dict(fill=dict(rgb=list(fill)),outline=dict(rgb=list(outline),present=True,widthPx=2),
                    background=dict(rgb=[255,255,255]))
    return rgb,(body>0)|(alpha>.02),prediction


class ShadowGeometryTests(unittest.TestCase):
    def test_blur_is_not_mistaken_for_translation(self):
        rgb,mask,p=render();before=rgb.copy();before_mask=mask.copy()
        result=estimate(rgb,mask,p,56)
        self.assertTrue(result['identified'])
        self.assertLess(np.max(np.abs(np.array(result['offsetPx'])-[2,3])),.85)
        self.assertLess(np.max(np.abs(np.array(result['observedCompositeRGB'])-200)),12)
        self.assertIsNone(result['opacity']);self.assertIsNone(result['blurRadiusPx'])
        np.testing.assert_array_equal(rgb,before);np.testing.assert_array_equal(mask,before_mask)

    def test_negative_horizontal_translation(self):
        rgb,mask,p=render(offset=(-3,2));result=estimate(rgb,mask,p,56)
        self.assertTrue(result['identified'])
        self.assertLess(np.max(np.abs(np.array(result['offsetPx'])-[-3,2])),.85)

    def test_recall_protection_mask_is_not_exact_paint(self):
        rgb,mask,p=render();result=estimate(rgb,np.ones_like(mask),p,56)
        self.assertTrue(result['identified'])
        self.assertLess(np.max(np.abs(np.array(result['offsetPx'])-[2,3])),.85)

    def test_coloured_outline_does_not_become_a_shadow(self):
        rgb,mask,p=render(shadow=False,fill=(255,255,255),outline=(220,90,5))
        result=estimate(rgb,mask,p,56)
        self.assertFalse(result['identified'])

    def test_localisation_boxes_do_not_clip_external_shadow(self):
        rgb,mask,p=render()
        polygons=[[[x,30],[x+11,30],[x+11,79],[x,79]] for x in [25,60,95]]
        result=estimate(rgb,mask,p,56,polygons=polygons)
        self.assertTrue(result['identified'])
        self.assertLess(np.max(np.abs(np.array(result['offsetPx'])-[2,3])),.85)


if __name__=='__main__':unittest.main()
