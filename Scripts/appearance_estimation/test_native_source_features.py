import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import numpy as np
from fused_source_appearance import extract
from pixel_role_estimation import features as pixel_features
from calibrate_width import measure
from adaptive_normal_width import measure as measure_adaptive,features as adaptive_features


class NativeSourceFeaturesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='aidoku-native-appearance-features-')
        cls.folder=Path(cls.temp.name);cls.root=Path(__file__).resolve().parents[2]
        env=dict(os.environ,DERIVED_FILE_DIR=str(cls.folder/'cv'))
        link=subprocess.run(['python3',str(cls.root/'Scripts/native-source-cv/build.py'),
                             '--primitives-only','--print-link-info'],env=env,check=True,capture_output=True,text=True)
        info=json.loads(link.stdout.splitlines()[-1]);ensemble=cls.root/'Aidoku/Core/Translation/NativeEngine/Ensemble'
        names=['SourceNativeInput','NativeAppearanceNumeric','NativeAppearanceImageOperations','NativeOpenCVImageOperations',
               'NativeAppearanceSourceFeatures209','NativeAppearancePixelFeatures71','NativeAppearanceOutlineWidthEvidence',
               'NativeAppearancePhysicalImage','NativeAppearanceAdaptiveWidth50','NativeAppearanceModelHeads',
               'NativeFrozenSourceModel','NativeAppearanceForest']
        cls.binary=cls.folder/'features'
        subprocess.run(['swiftc','-O','-I'+info['include'],*[str(ensemble/(name+'.swift')) for name in names],
                        str(cls.root/'Scripts/tests/NativeAppearanceFeaturesSmoke.swift'),*info['linkFlags'],
                        '-o',str(cls.binary)],check=True)

    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def test_source_palette209_pixel71_and_width8_match_original(self):
        rng=np.random.default_rng(219)
        for case in range(4):
            h,w=32,48
            palette=np.array([[20,40,60],[240,240,240],[200,40,20],[40,180,200]],np.uint8)
            rgb=palette[rng.integers(0,4,(h,w))] if case>1 else np.full((h,w,3),240,np.uint8)
            mask=np.zeros((h,w),np.uint8)
            for x in range(8,40,8):rgb[8:24,x:x+4]=palette[case%4];mask[8:24,x:x+4]=1
            rf=rng.uniform(0,1,(h,w,27)).astype(np.float16).astype(np.float32)
            p=rng.uniform(0,1,(h,w)).astype(np.float32);q=rng.uniform(0,1,(h,w)).astype(np.float32)
            ocr=rng.uniform(0,1,(h,w,8)).astype(np.float32)
            poly=[[4,4],[43,5],[42,28],[5,27]] if case%2 else [[4,4],[43,4],[43,28],[4,28]]
            geometry=dict(polygons=[poly],mergedPolygon=poly,fontPixels=18.)
            packet=extract(rgb,mask,rf,p,q,[poly],18.,merged_polygon=poly,ocr_maps=ocr)
            request=dict(width=w,height=h,rgb=rgb.ravel().tolist(),mask=mask.ravel().tolist(),rf=rf.ravel().tolist(),
                primary=p.ravel().tolist(),boundary=q.ravel().tolist(),ocr=ocr.ravel().tolist(),
                polygons=[poly],mergedPolygon=poly,font=18.)
            path=self.folder/f'{case}.json';path.write_text(json.dumps(request))
            result=subprocess.run([str(self.binary),str(path)],check=True,capture_output=True,text=True)
            native=json.loads(result.stdout)
            with self.subTest(case=case):
                self.assertEqual(native['colors'],packet['colors'])
                np.testing.assert_allclose(native['features'],packet['features'],rtol=2e-5,atol=2e-5)
                np.testing.assert_allclose(native['pair'],packet['pair'],rtol=1e-6,atol=1e-6)
                prediction=dict(fill=dict(rgb=packet['colors'][0]),outline=dict(rgb=packet['colors'][-1],present=True,probability=.7),
                                background=dict(rgb=packet['colors'][min(1,len(packet['colors'])-1)]))
                expected,_=pixel_features(rgb,mask,rf,p,q,ocr,geometry,prediction,np.arange(0,h*w,7))
                np.testing.assert_allclose(native['pixelFeatures'],expected,rtol=2e-5,atol=2e-5)
                _,width_vector=measure(rgb,mask.astype(bool),packet['colors'][0],packet['colors'][-1])
                np.testing.assert_allclose(native['widthVector'],width_vector,rtol=1e-12,atol=1e-12)
                adaptive=measure_adaptive(rgb,mask,packet['colors'][0],packet['colors'][-1],True,18.,[poly])
                np.testing.assert_allclose(native['adaptiveWidthFeatures'],adaptive_features(adaptive,18.),rtol=2e-5,atol=2e-5)


if __name__=='__main__':unittest.main()
