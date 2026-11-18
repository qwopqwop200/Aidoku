"""Focused synthetic contracts; real source experiment is the sidecar run.py."""
import unittest
import cv2
import numpy as np
from scipy.special import ndtr
from observed_shadow_boundary import (estimate, observed_body, _profile, _grids,
                                       select_offset, _colours, POLICY)


def fixture():
    h, w = 130, 350
    body = np.zeros((h, w), np.uint8)
    for x in [35, 100, 165, 230, 295]:
        cv2.rectangle(body, (x, 45), (x+12, 68), 1, -1)
    rgb = np.full((h, w, 3), 230, np.uint8); rgb[body > 0] = [240, 40, 30]
    rf = np.zeros((h, w, 27), np.float32); rf[:, :, 15:17] = .8
    seg = body.astype(np.float32); ocr = np.ones((h, w, 8), np.float32)
    prediction = dict(fill=dict(rgb=[240, 40, 30], colors=[]), outline=dict(present=False))
    polygons = [[[0, 0], [w-1, 0], [w-1, h-1], [0, h-1]]]
    return rgb, body, prediction, 30., polygons, rf, seg, seg, ocr


def outlined_fixture(joined=False, shadow=True):
    """Multicolour cores, white halos and antialias pixels on two local grounds.

    Joined fixture deliberately has ONE connected white body and >=6 fill seeds.
    Frame RF affinity exceeds text, as in the authentic positive controls.
    """
    h,w=240,560
    body=np.zeros((h,w),np.uint8);fills=np.zeros((h,w),np.uint8)
    positions=[(60+110*i,80) for i in range(4)] if not joined else [(55+62*i,80) for i in range(7)]
    colors=[[220,35,45],[25,60,225],[20,20,20]]
    for i,(x,y) in enumerate(positions):
        cv2.rectangle(body,(x,y),(x+30,y+42),1,-1)
        cv2.rectangle(fills,(x+4,y+4),(x+26,y+38),i%3+1,-1)
    if joined:
        cv2.rectangle(body,(55,99),(55+62*6+30,102),1,-1)
    bg=np.zeros((h,w,3),np.float32);bg[:]=[230,230,218];bg[:,w//2:]=[225,230,235]
    displaced=cv2.warpAffine(body.astype(np.float32),np.float32([[1,0,2],[0,1,3]]),(w,h))
    shade=.24*cv2.GaussianBlur(displaced,(13,13),2) if shadow else np.zeros((h,w))
    rgb=np.rint(bg*(1-shade[:,:,None])).astype(np.uint8)
    rgb[body>0]=[252]*3
    for i,color in enumerate(colors):rgb[fills==i+1]=color
    # A native antialias ring splits categorical fill and outline, until bridged.
    for i,color in enumerate(colors):
        f=fills==i+1;ring=f&~cv2.erode(f.astype(np.uint8),np.ones((5,5),np.uint8)).astype(bool)
        rgb[ring]=np.rint((np.asarray(color)+252)/2).astype(np.uint8)
    pred=dict(fill=dict(rgb=colors[0],colors=colors),outline=dict(present=True,rgb=[252]*3,widthPx=999))
    rf=np.zeros((h,w,27),np.float32);rf[:,:,15]=.5;rf[:,:,16]=.08;rf[:,:,21:23]=.9
    seg=body.astype(np.float32);ocr=np.ones((h,w,8),np.float32)
    return rgb,body,pred,36.,[[[0,0],[w-1,0],[w-1,h-1],[0,h-1]]],rf,seg,seg,ocr


class ObservedBoundaryTests(unittest.TestCase):
    def test_grid_recovers_shift_without_rgb_hypothesis(self):
        n = np.array([[1,0],[-1,0],[0,1],[0,-1]], float)
        data = .25 * ndtr(((n @ np.array([2, 3]))[:, None] - np.arange(1,25)) / 2)
        scores = _grids(n, data, 5)
        result = select_offset([scores]*6, [0,0,0,1,1,1], 5, [scores*0]*6)
        self.assertTrue(result['identified'], result)
        self.assertEqual(result['offsetPx'], [2,3])

    def test_symmetric_halo_and_boundary_optimum_abstain(self):
        n = np.array([[1,0],[-1,0],[0,1],[0,-1]], float)
        for shift in [[0,0], [5,3]]:
            data = .25 * ndtr(((n @ shift)[:,None] - np.arange(1,25)) / 2)
            s = _grids(n, data, 5)
            self.assertFalse(select_offset([s]*6, [0,0,0,1,1,1], 5, [s*0]*6)['identified'])

    def test_background_and_spatial_controls_reject(self):
        n = np.array([[1,0],[-1,0],[0,1],[0,-1]], float)
        def score(shift):
            return _grids(n, .25*ndtr(((n@shift)[:,None]-np.arange(1,25))/2), 5)
        s = score([2,3]); r = score([-2,-3])
        self.assertFalse(select_offset([s]*6,[0,0,0,1,1,1],5,[s]*6)['identified'])
        self.assertFalse(select_offset([s]*3+[r]*3,[0,0,0,1,1,1],5,[s*0]*6)['identified'])
        self.assertFalse(select_offset([s]*6,[0]*6,5,[s*0]*6)['identified'])

    def test_all_fill_colours_and_observed_outline_width(self):
        args = list(fixture()); rgb, mask, pred, _, polygons, rf, p, b, ocr = args
        rgb[45:69,100:113] = [30,80,240]; pred['fill']['colors'] = [[30,80,240]]
        pred['outline'] = dict(present=True,rgb=[255,255,255],widthPx=99)
        cv2.rectangle(rgb,(33,43),(49,70),(255,255,255),2)
        b[42:72,32:51] = 1; mask[42:72,32:51] = 1
        body, _ = observed_body(rgb,mask,pred,rf,p,b,ocr,polygons)
        self.assertTrue(body[55,105]); self.assertTrue(body[43,40])
        self.assertFalse(body[30,40])

    def test_missing_evidence_rejected(self):
        args = list(fixture()); args[5] = args[5][:,:,:26]
        with self.assertRaises(ValueError): estimate(*args)
        args = list(fixture()); args[8][0,0,0] = np.nan
        with self.assertRaises(ValueError): estimate(*args)

    def test_profile_censors_edges_neighbors_unstable_ground(self):
        rgb=np.full((60,60,3),200,np.uint8); body=np.zeros((60,60),bool)
        self.assertEqual(_profile(rgb,body,np.array([54,30]),np.array([1,0]))[1],'crop-before-local-baseline')
        body[30,16]=True
        self.assertEqual(_profile(rgb,body,np.array([10,30]),np.array([1,0]))[1],'neighbor-before-local-baseline')
        body[:]=False; rgb[30,13:35:2]=20
        self.assertEqual(_profile(rgb,body,np.array([10,30]),np.array([1,0]))[1],'unstable-or-missing-local-baseline')

    def test_no_shadow_full_estimator_abstains(self):
        result=estimate(*fixture())
        self.assertFalse(result['identified']); self.assertIsNone(result['rgb'])
        self.assertLessEqual(result['usableRays'],12*8)

    def test_rgb_native_medoid_without_offset_and_incompatible_palette(self):
        components=[]
        for i in range(6):
            profile=dict(data=np.r_[.2,np.zeros(23)], reference=np.array([230]*3),
                         witness=np.tile([184,184,184],(24,1)),coordinates=np.tile([i,1],(24,1)))
            components.append(dict(sector=int(i>=3),rays=[dict(profile=profile)]))
        c=_colours(components);self.assertEqual(c['rgb'],[184]*3)
        for component in components:
            p=dict(profile);p.update(reference=np.array([160]*3), witness=np.tile([128]*3,(24,1)))
            component['rays'].append(dict(profile=p))
        c=_colours(components);self.assertIsNone(c['rgb']);self.assertEqual(len(c['palette']),2)

    def test_multicolour_white_outline_full_pipeline_has_usable_rays(self):
        result=estimate(*outlined_fixture())
        self.assertGreaterEqual(result['components'],3,result)
        self.assertGreaterEqual(result['usableRays'],12)
        self.assertGreaterEqual(result['bodyEvidence']['selectedFillCoreSeeds'],3)
        self.assertFalse(result['bodyEvidence']['frameVetoUsed'])
        self.assertTrue(result['identified'],{k:v for k,v in result.items() if k!='profiles'})
        self.assertLessEqual(np.linalg.norm(np.array(result['offsetPx'])-[2,3]),2)

    def test_joined_white_halos_keep_full_native_contour_and_independent_cores(self):
        result=estimate(*outlined_fixture(joined=True))
        self.assertEqual(result['bodyEvidence']['nativeBodyComponents'],1)
        self.assertGreaterEqual(result['bodyEvidence']['selectedFillCoreSeeds'],6)
        self.assertGreaterEqual(result['components'],3,result)
        self.assertFalse(result['bodyEvidence']['partitionCreatesContour'])
        # Every selected profile origin belongs to the actual union's outer edge.
        args=outlined_fixture(joined=True)
        body,_=observed_body(args[0],args[1],args[2],args[5],args[6],args[7],args[8],args[4])
        edge=body&~cv2.erode(body.astype(np.uint8),np.ones((3,3),np.uint8)).astype(bool)
        for component in result['profiles']:
            for ray in component['rays']:
                x,y=map(int,ray['point']);self.assertTrue(edge[y,x])

    def test_outlined_zero_shadow_does_not_emit_offset(self):
        result=estimate(*outlined_fixture(shadow=False))
        self.assertGreaterEqual(result['components'],3)
        self.assertFalse(result['identified']);self.assertIsNone(result['rgb'])

    def test_missing_pseudo_is_censored_not_zero_or_lost_source_ray(self):
        from unittest.mock import patch
        with patch('observed_shadow_boundary._pseudo_origin',return_value=None):
            result=estimate(*outlined_fixture())
        self.assertGreaterEqual(result['sourceUsableRays'],24)
        self.assertEqual(result['pairedValidRays'],0)
        self.assertEqual(result['components'],0)
        self.assertFalse(result['identified']);self.assertIsNone(result['rgb'])
        self.assertGreaterEqual(sum(x['usableRays'] for x in result['sourceComponentLogs']),24)


if __name__ == '__main__': unittest.main()
