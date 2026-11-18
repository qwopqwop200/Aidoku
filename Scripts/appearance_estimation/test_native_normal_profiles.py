"""Bounded real OpenCV/Swift parity for source normal contour/ring evidence.

Uses existing read-only native archives; never builds shared host/app caches.
"""
import copy
import json
from pathlib import Path
import pickle
import subprocess
import tempfile
import unittest

import optimize_appearance
import cv2
import numpy as np
import outline_layers
import outline_layer_discovery as discovery
from test_outline_layers import render


class NativeNormalProfilesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='native-normal-profiles-')
        cls.directory=Path(cls.temp.name);cls.root=Path(__file__).resolve().parents[2]
        ensemble=cls.root/'Aidoku/Core/Translation/NativeEngine/Ensemble'
        names=['SourceNativeInput','NativeAppearanceNumeric','NativeAppearanceImageOperations','NativeOpenCVImageOperations',
               'NativeAppearanceSourceFeatures209','NativeAppearancePhysicalImage','NativeAppearanceModelHeads',
               'NativeFrozenSourceModel','NativeAppearanceForest','NativeAppearanceNormalProfiles']
        cls.binary=cls.directory/'replay'
        cls.sources=[str(ensemble/(n+'.swift')) for n in names]
        command=['swiftc','-O','-swift-version','5','-I'+str(cls.root/'Vendor/NativeSourceCV/include'),*cls.sources,
                 str(cls.root/'Scripts/tests/NativeAppearanceNormalProfilesReplay.swift'),
                 '-L'+str(cls.root/'build/native-source-cv-host'),'-lAidokuSourceCV','-lAidokuOpenCV','-lAidokuFreeType',
                 '-lc++','-lz','-framework','CoreText','-framework','Accelerate','-o',str(cls.binary)]
        subprocess.run(command,check=True)
        cls.assets=cls.root/'Aidoku/Resources/Translation/SourceModels'
        accepted=cls.root/'Scripts/appearance_estimation/assets/accepted'
        cls.roles=pickle.loads((accepted/'model.pkl').read_bytes())
        cls.context=pickle.loads((accepted/'pixel-role-model.pkl').read_bytes())['featureContext']['roleModel']

    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def compare(self,actual,expected,path=''):
        if isinstance(expected,dict):
            self.assertEqual(set(actual),set(expected),path)
            for key,value in expected.items():self.compare(actual[key],value,path+'/'+key)
        elif isinstance(expected,(list,tuple)):
            self.assertEqual(len(actual),len(expected),path)
            for i,value in enumerate(expected):self.compare(actual[i],value,path+'/'+str(i))
        elif isinstance(expected,(float,np.floating)):
            self.assertAlmostEqual(actual,float(expected),delta=max(2e-6,abs(float(expected))*2e-7),msg=path)
        else:self.assertEqual(actual,expected,path)

    def run_case(self,rgb,mask,prediction,colors,font=90.,polygons=None,role_root='appearance/model'):
        h,w=mask.shape;prediction=copy.deepcopy(prediction)
        prediction.update(fillIndex=colors.index(prediction['fill']['rgb']),outlineIndex=colors.index(prediction['outline']['rgb']),
                          backgroundIndex=colors.index(prediction['background']['rgb']))
        n=len(colors)
        packet=dict(colors=colors,fontPixels=font,features=np.zeros((n,209),np.float32),pair=np.zeros((n,n,6),np.float32))
        poly=polygons or [[[0,0],[w-1,0],[w-1,h-1],[0,h-1]]]
        request=dict(width=w,height=h,rgb=rgb.ravel().tolist(),mask=mask.astype(np.uint8).ravel().tolist(),font=font,
                     colors=colors,polygons=poly,prediction=prediction,features=packet['features'].tolist(),pair=packet['pair'].tolist(),roleRoot=role_root)
        path=self.directory/'request.json';path.write_text(json.dumps(request))
        native=json.loads(subprocess.run([str(self.binary),str(path),str(self.assets)],capture_output=True,text=True,check=True).stdout)
        rings=outline_layers.measure(rgb,mask,prediction,font,colors,poly)
        primary=discovery.measure(rgb,mask,prediction,font,colors,poly,primary_only=True)
        order=discovery.measure(rgb,mask,prediction,font,colors,poly)
        attached=outline_layers.attach(copy.deepcopy(prediction),rings)
        corrected=discovery.correct_primary(rgb,mask,prediction,packet,poly)
        corrected=discovery.refresh_conditioned_background(corrected,prediction,packet,self.roles if role_root=='appearance/model' else self.context)
        expected=dict(rings=rings,primary=primary,discovery=order,attached=attached,corrected=corrected)
        for key,value in expected.items():self.compare(native[key],value,key)
        return native

    def test_rings_clipping_absence_core_and_profile_subsampling(self):
        rgb,mask,prediction,colors=render()
        result=self.run_case(rgb,mask,prediction,colors)
        self.assertTrue(result['rings']['reliable'])
        rgb2,mask2,prediction2,colors2=render(False)
        self.assertFalse(self.run_case(rgb2,mask2,prediction2,colors2)['rings']['reliable'])
        self.run_case(rgb[65:110],mask[65:110],prediction,colors)
        core=np.all(rgb==prediction['fill']['rgb'],axis=2)
        self.run_case(rgb,core,prediction,colors)
        self.run_case(np.tile(rgb,(2,2,1)),np.tile(mask,(2,2)),prediction,colors)
        absent=copy.deepcopy(prediction);absent['outline']['present']=False
        self.run_case(rgb,mask,absent,colors)
        self.run_case(rgb,np.zeros_like(mask),prediction,colors)

    def test_saved_original_source_crop_profiles(self):
        root=self.root.parent/'font-size-estimation-20261110/round126/missing-source-styles/fresh-style-inference'
        for key in ('source-0115-region-3','source-0049-region-4'):
            directory=root/'runtime'/key
            if not (directory/'evidence.npz').exists():self.skipTest('Optional original source packet unavailable')
            with np.load(directory/'evidence.npz',allow_pickle=False) as evidence:
                h,w=evidence['segPrimary'].shape
                geometry=json.loads(str(evidence['geometryJSON']))
            rgb=np.fromfile(root/'crops'/(key+'.rgb'),dtype=np.uint8).reshape(h,w,3)
            mask=np.fromfile(directory/'primary.u8',dtype=np.uint8).reshape(h,w)>0
            prediction=json.loads((directory/'appearance.json').read_text())
            colors=[]
            for role in ('fill','outline','background'):
                for color in [prediction[role]['rgb']]+prediction[role].get('colors',[]):
                    if color not in colors:colors.append(color)
            with self.subTest(source=key):
                self.run_case(rgb,mask,prediction,colors,font=geometry['fontPixels'],polygons=geometry['polygons'])

    def test_primary_correction_refreshes_each_conditioned_background_root(self):
        rgb,mask,prediction,colors=render()
        prediction['outline']['rgb']=colors[2]
        for root in ('appearance/model','appearance/pixel-role-model/featureContext/roleModel'):
            result=self.run_case(rgb,mask,prediction,colors,role_root=root)
            self.assertEqual(result['corrected']['outlineIndex'],1)
            self.assertEqual(result['corrected']['outline']['rgb'],colors[1])
            self.assertEqual(result['corrected']['outline']['colorDecision'],'source-normal-contour-consensus')


if __name__=='__main__':unittest.main()
