import copy
import gzip
import json
from pathlib import Path
import tempfile
import unittest
import numpy as np
from fused_source_appearance import extract,VERSION
from source_confidence_evidence import raster,SOURCE_FIELDS


def fixture():
    rgb=np.full((45,65,3),[150,170,190],np.uint8);mask=np.zeros((45,65),bool)
    rgb[12:34,12:26]=[250,30,120];mask[12:34,12:26]=True
    rgb[12:34,40:54]=[30,70,120];mask[12:34,40:54]=True
    rf=np.full((45,65,27),.2,np.float32);p=np.full((45,65),.3,np.float32);q=np.full((45,65),.4,np.float32)
    ocr=np.zeros((45,65,8),np.float32);poly=[[[10,10],[28,10],[28,36],[10,36]]]
    return rgb,mask,rf,p,q,ocr,poly


class FusedSourceAppearanceTests(unittest.TestCase):
    def test_all_soft_evidence_affects_features_and_rgb_is_immutable(self):
        rgb,mask,rf,p,q,ocr,poly=fixture();before=rgb.copy()
        a=extract(rgb,mask,rf,p,q,poly,25,ocr_maps=ocr)
        for kind in ['rf','primary','boundary','ocr']:
            args=[rgb,mask,rf.copy(),p.copy(),q.copy()];maps=ocr.copy()
            if kind=='rf':args[2][:,:,2]=.9
            elif kind=='primary':args[3][:]=.9
            elif kind=='boundary':args[4][:]=.9
            else:maps[:,:,2]=.9
            b=extract(*args,poly,25,ocr_maps=maps)
            self.assertEqual(a['colors'],b['colors'])
            self.assertFalse(np.array_equal(a['features'],b['features']),kind)
        np.testing.assert_array_equal(rgb,before);self.assertEqual(a['version'],VERSION)

    def test_boxes_inform_ownership_but_never_remove_external_colour(self):
        rgb,mask,rf,p,q,ocr,poly=fixture()
        a=extract(rgb,mask,rf,p,q,poly,25,ocr_maps=ocr)
        wide=[[[0,0],[64,0],[64,44],[0,44]]]
        b=extract(rgb,mask,rf,p,q,wide,25,merged_polygon=wide[0],ocr_maps=ocr)
        self.assertEqual(a['colors'],b['colors'])
        self.assertIn([30,70,120],a['colors'])
        self.assertFalse(np.array_equal(a['features'],b['features']))
        self.assertFalse(a['bboxActsAsHardClip'])

    def test_source_planes_must_have_original_geometry_and_valid_probabilities(self):
        rgb,mask,rf,p,q,ocr,poly=fixture()
        with self.assertRaises(ValueError):extract(rgb,mask,rf[:40],p,q,poly,25,ocr_maps=ocr)
        with self.assertRaises(ValueError):extract(rgb,mask,rf,p,q,poly,25)
        rf[0,0,0]=np.nan
        with self.assertRaises(ValueError):extract(rgb,mask,rf,p,q,poly,25,ocr_maps=ocr)

    def test_ocr_adapter_excludes_gt_iou_and_text_fields(self):
        features=[1,.8,1,.9,0,0,0]
        def document(forbidden):
            return dict(sourceSHA256='source',value=dict(width=30,height=20,featureNames=SOURCE_FIELDS+['detectorReferenceIoU'],
                rows=[dict(polygon=[[2,2],[25,2],[25,17],[2,17]],features=features+[forbidden],text=str(forbidden),joint=[forbidden])]))
        with tempfile.TemporaryDirectory() as folder:
            paths=[]
            for i in [0,1]:
                path=Path(folder)/(str(i)+'.json.gz')
                with gzip.open(path,'wt') as f:json.dump(document(i*10000),f)
                paths.append(path)
            a=raster(paths[0],'source',[30,20],[0,0,30,20]);b=raster(paths[1],'source',[30,20],[0,0,30,20])
            np.testing.assert_array_equal(a,b)
            self.assertAlmostEqual(float(a[5,5,2]),.8,places=6)
            with self.assertRaises(ValueError):raster(paths[0],'different-source',[30,20],[0,0,30,20])


if __name__=='__main__':unittest.main()
