import hashlib
from pathlib import Path
import unittest

import cv2
import numpy as np

from word_pairs import word_masks,fit_line
from word_source_members import match_member
from physical_templates import font_pairs


class WordRegistrationTests(unittest.TestCase):
    def pair(self):
        a,_,b,_=font_pairs()[0]
        def record(p):return dict(path=p,SHA256=hashlib.sha256(Path(p).read_bytes()).hexdigest(),weight=None)
        return dict(regular=record(a),heavy=record(b))

    def test_character_order_is_part_of_the_image_match(self):
        pair=self.pair();_,ink=word_masks(pair,'あいう',False,1.)
        ink=cv2.resize(ink,None,fx=56/128,fy=56/128,interpolation=cv2.INTER_AREA)
        alpha=np.pad(ink,10)
        rgb=np.repeat(np.rint((1-alpha[:,:,None])*255).astype(np.uint8),3,axis=2)
        style={'fill':{'rgb':[0,0,0]},'background':{'rgb':[255,255,255]},'outline':{'present':False}}
        bbox=[0,0,rgb.shape[1],rgb.shape[0]];own=np.ones(alpha.shape,bool)
        good=fit_line(rgb,bbox,56,'あいう',own,style,pair)
        wrong=fit_line(rgb,bbox,56,'ういあ',own,style,pair)
        self.assertEqual(good.shape,(32,))
        self.assertGreater(good[18],.95)
        self.assertGreater(good[18],wrong[18]+.1)
        self.assertGreater(good[0],.7)

    def test_line_text_binding_checks_pixels_and_geometry(self):
        quad=[[0,0],[40,0],[40,100],[0,100]]
        candidates=[dict(sourceSHA256='wrong-image',polygon=quad,text='bad',confidence=1.),
                    dict(sourceSHA256='source',polygon=[[1,0],[41,0],[41,100],[1,100]],text='good',confidence=.8),
                    dict(sourceSHA256='source',polygon=[[100,0],[140,0],[140,100],[100,100]],text='bad',confidence=1.)]
        self.assertEqual(match_member(quad,candidates,'source')['text'],'good')
        self.assertIsNone(match_member(quad,candidates,'absent-source'))


if __name__=='__main__':unittest.main()
