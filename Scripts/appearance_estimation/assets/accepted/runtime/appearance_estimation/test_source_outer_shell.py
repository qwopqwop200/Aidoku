"""Focused physical, preservation, ownership-contract and warm-reset checks."""
import sys,copy,unittest,inspect
from pathlib import Path
S=Path(__file__).resolve().parent
import numpy as np
import cv2
import source_outer_shell as shell
def scene(kind,width=2,scale=4):
    h,w=100,280;primary=[145,90,45];font=45.
    core=np.zeros((h*scale,w*scale),np.uint8)
    # Multiple unrelated silhouettes, not repeated circles with a privileged centre.
    for i,ch in enumerate('HAXT'):
        cv2.putText(core,ch,((18+63*i)*scale,70*scale),cv2.FONT_HERSHEY_SIMPLEX,
                    1.5*scale,1,4*scale,cv2.LINE_8)
    distance=cv2.distanceTransform(1-core,cv2.DIST_L2,5)/scale
    bg=np.full((h*scale,w*scale,3),[135,165,195],np.uint8)
    if kind in ['white-background','white-background-hidden-halo']:bg[:]=255
    if kind=='partial-white':bg[:h*scale//2]=255
    if kind=='panel':
        cv2.rectangle(bg,(8*scale,12*scale),(266*scale,84*scale),(255,255,255),-1)
    if kind=='near-panel':
        cv2.rectangle(bg,(10*scale,30*scale),(267*scale,77*scale),(255,255,255),-1)
    halo=kind in ['halo','partial-white','white-background-hidden-halo','crop-truncated','neighbour','soft-halo']
    rgb=bg.copy()
    if halo:rgb[distance<=2+width]=[255,255,255]
    if kind=='directional-bright-fringe':
        fringe=np.zeros_like(core);fringe[3*scale:]=core[:-3*scale]
        fringe=cv2.dilate(fringe,np.ones((3*scale,3*scale),np.uint8))
        rgb[fringe>0]=255
    rgb[distance<=2]=primary;rgb[core>0]=[245,215,90]
    if kind=='neighbour':
        cv2.putText(rgb,'Z',(260*scale,35*scale),cv2.FONT_HERSHEY_SIMPLEX,scale,[145,90,45],3*scale)
    rgb=cv2.resize(rgb,(w,h),interpolation=cv2.INTER_AREA)
    native=cv2.resize(core.astype(np.float32),(w,h),interpolation=cv2.INTER_AREA)>.9
    if kind=='AA-only':
        # A one-ring image blurred into its coloured exterior must not invent opaque white.
        rgb=cv2.GaussianBlur(rgb,(0,0),.65)
    if kind=='soft-halo':rgb=cv2.GaussianBlur(rgb,(0,0),.65)
    if kind=='crop-truncated':rgb=rgb[38:72];native=native[38:72]
    return rgb,native,primary,font



def inputs(kind='halo',width=2):
    rgb,core,primary,font=scene(kind,width)
    _,labels=cv2.connectedComponents(core.astype(np.uint8),8)
    seeds=[]
    for i in range(1,int(labels.max())+1):
        yy,xx=np.where(labels==i);k=len(xx)//2
        seeds.append(dict(xy=[int(xx[k]),int(yy[k])],confirmed=True))
    diagnostic=dict(version='unit-source-contract',semantic=dict(groups=[dict(confirmedSeeds=len(seeds),seeds=seeds)]))
    prediction=dict(fill=dict(rgb=[245,215,90]),outline=dict(present=True,rgb=primary,widthPx=9,
        widthRangePx=[8,10],probability=.95),background=dict(rgb=[135,165,195]),
        shadow=dict(present=False),opaqueOtherState={'keep':[1,2,3]})
    return rgb,dict(fontPixels=font),prediction,diagnostic


class OuterShellTests(unittest.TestCase):
    def test_api_is_external_threshold_and_no_runtime_artifact_io(self):
        self.assertEqual(list(inspect.signature(shell.refine).parameters),['rgb','geometry','prediction','diagnostic','threshold'])
        text=(S/'source_outer_shell.py').read_text()+(S/'source_outer_shell_geometry.py').read_text()
        for forbidden in ['.read_text(','.read_bytes(','open(','0.009548','from bright_ring','from mechanism']:
            self.assertNotIn(forbidden,text)

    def test_halo_native_witness_and_strict_field_preservation(self):
        rgb,g,p,d=inputs();before=copy.deepcopy(p)
        out,report=shell.refine(rgb,g,p,d,0.)
        self.assertTrue(report['applied']);self.assertEqual(p,before)
        layers=out['outline']['observedLayers'];self.assertEqual(len(layers),2)
        self.assertEqual(layers[0]['rgb'],p['outline']['rgb'])
        x,y=layers[1]['nativeRGBWitnessXY'];self.assertEqual(layers[1]['rgb'],rgb[y,x].tolist())
        self.assertEqual(shell.restore_baseline(out),p)
        clean=copy.deepcopy(out);clean['outline'].pop('observedLayers');clean['outline'].pop(shell.TAG)
        self.assertEqual(clean,p)
        self.assertAlmostEqual(layers[1]['widthPx'],2,delta=.5)

    def test_restore_exact_presence_value_and_idempotent_warm(self):
        rgb,g,p,d=inputs()
        for initial in ['absent',[],None,[dict(rgb=[9,8,7],widthPx=8)]]:
            base=copy.deepcopy(p)
            if initial!='absent':base['outline']['observedLayers']=copy.deepcopy(initial)
            with self.subTest(initial=initial):
                first,one=shell.refine(rgb,g,base,d,0.)
                self.assertTrue(one['applied'])
                second,two=shell.refine(rgb,g,first,d,0.)
                self.assertEqual(first,second);self.assertEqual(one,two)
                self.assertEqual(shell.restore_baseline(first),base)
                declined,rep=shell.refine(rgb,g,first,d,1.)
                self.assertFalse(rep['applied']);self.assertEqual(declined,base)
                lost,rep=shell.refine(rgb,g,first,{},0.)
                self.assertFalse(rep['applied']);self.assertEqual(lost,base)

    def test_existing_multiple_layers_unchanged(self):
        rgb,g,p,d=inputs();p['outline']['observedLayers']=[{'rgb':[1,2,3],'widthPx':3},{'rgb':[4,5,6],'widthPx':4}]
        out,r=shell.refine(rgb,g,p,d,0.)
        self.assertEqual(out,p);self.assertEqual(r['reason'],'existing-multiple-layers-preserved')

    def test_identical_hidden_halo_and_white_background_abstain(self):
        a=inputs('white-background');b=inputs('white-background-hidden-halo')
        np.testing.assert_array_equal(a[0],b[0])
        for rgb,g,p,d in [a,b]:
            out,r=shell.refine(rgb,g,p,d,0.)
            self.assertFalse(r['applied']);self.assertEqual(out,p)
            self.assertGreater(r['counts'].get('white-right-censored',0),0)

    def test_realistic_negative_scenes(self):
        for kind in ['panel','near-panel','AA-only','no-halo','directional-bright-fringe']:
            rgb,g,p,d=inputs(kind)
            out,r=shell.refine(rgb,g,p,d,0.)
            with self.subTest(kind=kind):self.assertFalse(r['applied']);self.assertEqual(out,p)

    def test_unconfirmed_or_missing_ownership_cannot_emit(self):
        rgb,g,p,d=inputs();d['semantic']['groups'][0]['confirmedSeeds']=2
        d['semantic']['groups'][0]['seeds']=d['semantic']['groups'][0]['seeds'][:2]
        out,r=shell.refine(rgb,g,p,d,0.)
        self.assertFalse(r['applied']);self.assertEqual(out,p)
        p['outline']['present']=False
        out,r=shell.refine(rgb,g,p,{},0.);self.assertEqual(out,p)

    def test_invalid_policy_and_warm_tag_fail_closed(self):
        rgb,g,p,d=inputs()
        for value in [float('nan'),float('inf'),-.1]:
            with self.assertRaises(ValueError):shell.refine(rgb,g,p,d,value)
        p['outline'][shell.TAG]={'version':'unknown'}
        with self.assertRaises(ValueError):shell.restore_baseline(p)


if __name__=='__main__':unittest.main()
