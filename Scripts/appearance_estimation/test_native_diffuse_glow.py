"""Source-only native dip/recovery parity; standalone binary, no app build."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import numpy as np
from scipy.ndimage import distance_transform_edt
from shadow_glow_profiles import estimate
from shadow_background_normalization import estimate_observed


class NativeDiffuseGlowTests(unittest.TestCase):
    def test_finite_local_source_glow_matches_accepted_policy(self):
        binary=os.environ.get('AIDOKU_NATIVE_GLOW_BINARY','/tmp/aidoku-source-glow-smoke')
        self.assertTrue(Path(binary).exists(),'Compile Scripts/tests/NativeAppearanceGlowSmoke.swift first')
        for kind in ['glow','AA','crisp','none','texture','clipped','tinted']:
            mask=np.zeros((210,360),bool)
            for x in [50,130,210,290]:mask[85:125,x:x+16]=True
            distance=distance_transform_edt(~mask)
            shade=np.exp(-distance/4)*.4
            if kind=='AA':shade=(distance<=1)*.4
            if kind=='crisp':shade=(distance<=5)*.4
            if kind=='none':shade[:]=0
            if kind=='texture':shade=.4*(np.sin(np.indices(mask.shape)[1]/4)+1)/2
            color=np.array([240,210,180] if kind=='tinted' else [255,255,255])
            rgb=np.rint(color[None,None,:]*(1-shade[:,:,None])).astype(np.uint8);rgb[mask]=color
            if kind=='clipped':rgb=rgb[80:130].copy();mask=mask[80:130].copy()
            h,w=mask.shape
            polygons=[[[0,0],[w-1,0],[w-1,h-1],[0,h-1]]]
            pred=dict(fill=dict(rgb=color.tolist()),outline=dict(present=False,rgb=[0,0,0],widthPx=0),background=dict(rgb=color.tolist()))
            profile=estimate(rgb,mask,pred,40,polygons)
            paint=None
            if profile['identified'] and profile['coreEvidence'].get('usedLocalFallback'):
                paint=estimate_observed(profile['positiveProfileLogs'],profile['componentEvidence'],pred['background']['rgb'])
            expected=dict(profile={k:v for k,v in profile.items() if k!='positiveProfileLogs'},paint=paint)
            request=dict(width=w,height=h,rgb=rgb.ravel().tolist(),mask=mask.astype(np.uint8).ravel().tolist(),font=40.,prediction=pred)
            with tempfile.TemporaryDirectory(prefix='aidoku-glow-parity-') as folder:
                path=Path(folder)/'source.json';path.write_text(json.dumps(request))
                actual=json.loads(subprocess.run([binary,str(path)],check=True,capture_output=True,text=True).stdout)
            with self.subTest(kind=kind):
                self.compare(actual,expected)

    def compare(self,actual,expected,path=''):
        if isinstance(expected,dict):
            self.assertEqual(set(actual),set(expected),path)
            for key in expected:self.compare(actual[key],expected[key],path+'.'+key)
        elif isinstance(expected,list):
            self.assertEqual(len(actual),len(expected),path)
            for i,(a,e) in enumerate(zip(actual,expected)):self.compare(a,e,f'{path}[{i}]')
        elif isinstance(expected,(int,float)) and not isinstance(expected,bool):
            self.assertAlmostEqual(actual,expected,delta=3e-5,msg=path)
        else:self.assertEqual(actual,expected,path)


if __name__=='__main__':unittest.main()
