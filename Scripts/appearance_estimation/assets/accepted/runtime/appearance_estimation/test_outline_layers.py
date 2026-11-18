import unittest
import cv2
import numpy as np
from outline_layers import measure,attach
from apply_outline_layers import check_dev_admission


def render(two=True):
    core=np.zeros((160,280),np.uint8)
    cv2.putText(core,'ABC',(15,110),cv2.FONT_HERSHEY_SIMPLEX,2.8,1,10,cv2.LINE_8)
    inner=cv2.dilate(core,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(9,9)))
    outer=cv2.dilate(inner,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(11,11)))
    rgb=np.full((160,280,3),[160,140,90],np.uint8)
    if two:rgb[outer>0]=[50,120,220]
    rgb[inner>0]=[250,250,250];rgb[core>0]=[230,40,130]
    prediction=dict(fill=dict(rgb=[230,40,130]),outline=dict(present=True,rgb=[250,250,250],widthPx=4),background=dict(rgb=[160,140,90]))
    colors=[[230,40,130],[250,250,250],[50,120,220],[160,140,90]]
    return rgb,outer>0,prediction,colors


class OutlineLayerTests(unittest.TestCase):
    def test_publishing_rejects_false_rings_and_lost_coverage(self):
        previous=dict(falsePositive=0,truePositive=1)
        with self.assertRaises(ValueError):check_dev_admission(dict(falsePositive=1,truePositive=2),previous)
        with self.assertRaises(ValueError):check_dev_admission(dict(falsePositive=0,truePositive=0),previous)
        check_dev_admission(dict(falsePositive=0,truePositive=1),previous)

    def test_two_rings_from_original_pixels(self):
        rgb,mask,p,colors=render();before=rgb.copy();old_mask=mask.copy()
        result=measure(rgb,mask,p,90,colors)
        self.assertTrue(result['reliable'])
        self.assertEqual([r['rgb'] for r in result['layers']],[[250,250,250],[50,120,220]])
        self.assertLess(abs(result['totalWidthPx']-9),2)
        np.testing.assert_array_equal(rgb,before);np.testing.assert_array_equal(mask,old_mask)

    def test_background_does_not_become_second_ring(self):
        rgb,mask,p,colors=render(False);result=measure(rgb,mask,p,90,colors)
        self.assertFalse(result['reliable'])

    def test_predicted_mask_is_not_a_clipping_boundary(self):
        rgb,mask,p,colors=render()
        core=np.all(rgb==p['fill']['rgb'],axis=2)
        y,x=np.where(core);polygons=[[[x.min(),y.min()],[x.max(),y.min()],[x.max(),y.max()],[x.min(),y.max()]]]
        result=measure(rgb,core,p,90,colors,polygons)
        self.assertTrue(result['reliable'])
        self.assertLess(abs(result['totalWidthPx']-9),2)


if __name__=='__main__':unittest.main()
