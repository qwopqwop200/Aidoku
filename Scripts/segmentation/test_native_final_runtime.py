"""Exact selected native context83/style78 graph; isolated OpenCV/Swift artifacts."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import cv2
import numpy as np

from accepted_assets import EXPECTED_RF_WEIGHTS
from source_mask_runtime import SourceMaskRuntime, source_matrix, _math, quantize

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO.parent / 'segmentation-improvement-20261109'


class NativeFinalRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory(prefix='aidoku-native-final-')
        cls.artifacts = Path(cls.folder.name)
        path = REPO / 'Scripts/native-source-cv/build.py'
        spec = importlib.util.spec_from_file_location('segmentation_cv_build', path)
        bridge = importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
        start = time.monotonic()
        info = bridge.build(environment={'PLATFORM_NAME':'macosx', 'ARCHS':'arm64',
            'DERIVED_FILE_DIR':str(cls.artifacts/'cv')}, primitives_only=True)
        cls.bridge_seconds = time.monotonic()-start
        cls.binary = cls.artifacts/'native-selected-final'
        engine = REPO / 'Aidoku/Core/Translation/NativeEngine'
        layout = ['NativeRFDETRSemanticGrid.swift','NativeRFDETRLayoutModels.swift','NativeRFDETRSourceSupportGrid.swift']
        names = ['NativeEnsembleRemovalSourceFactory.swift','NativePixelRFFeatures.swift','NativePixelRFForest.swift',
            'NativePixelRFEvidence.swift','NativePixelRFSegmentation.swift','NativePixelRFBoundaryFeatures.swift',
            'NativePixelRFBoundarySegmentation.swift','NativeSourceSegmentationObservations.swift',
            'NativeSegmentationFinalPolicy.swift','NativeSegmentationFinalFeatures.swift',
            'NativeSelectedSourceSegmentationProducer.swift','NativeSegmentationOpenCVOperations.swift',
            'NativeSelectedSourceSegmentationModels.swift','NativeSelectedSourceSegmentationInput.swift','SourceNativeInput.swift',
            'NativeAppearanceForest.swift','NativeFrozenSourceModel.swift']
        sources=[engine/'Layout'/n for n in layout]+[engine/'Ensemble'/n for n in names]
        # Other authorized workers edit their generic runtime concurrently. Freeze
        # this small compilation unit rather than compiling files that can change.
        snapshot=cls.artifacts/'sources';snapshot.mkdir()
        frozen=[]
        for source in sources+[Path(__file__).with_name('NativeSelectedFinalRuntimeReplay.swift')]:
            copied=snapshot/source.name;copied.write_bytes(source.read_bytes());frozen.append(copied)
        include=cls.artifacts/'include';include.mkdir()
        (include/'AidokuNativeCV.h').write_bytes((Path(info['include'])/'AidokuNativeCV.h').read_bytes())
        (include/'module.modulemap').write_text('module AidokuNativeCV { header "AidokuNativeCV.h" export * }\n')
        start=time.monotonic()
        subprocess.run(['swiftc','-O','-I',str(include),'-module-cache-path',str(cls.artifacts/'module-cache'),
            *map(str,frozen),
            *info['linkFlags'],'-o',str(cls.binary)],check=True)
        cls.swift_seconds=time.monotonic()-start
        print('ISOLATED-BUILD-TIMES',json.dumps(dict(bridgeSeconds=cls.bridge_seconds,swiftSeconds=cls.swift_seconds)))

    @classmethod
    def tearDownClass(cls): cls.folder.cleanup()

    def compare(self, row):
        from prepare_full_rf import load_case_features
        from PIL import Image
        shape=(row['height'],row['width']);h,w=shape
        rgb=np.fromfile(row['rgb'],np.uint8).reshape(h,w,3)
        with np.load(row['rf']) as z:coarse=z['support'].astype(np.float32)/255
        full=load_case_features(row,ROOT/'boundary-lean')
        case=json.loads((ROOT/'boundary-lean/rf-full/crops'/(row['id']+'.json')).read_text())
        self.assertEqual(case['modelWeightsSHA256'],EXPECTED_RF_WEIGHTS)
        folder=self.artifacts
        rgb.tofile(folder/'source.rgb');coarse.tofile(folder/'coarse.f32');full.tofile(folder/'full.f32')
        output=str(folder/'current')
        request=dict(rgb=str(folder/'source.rgb'),coarseRF=str(folder/'coarse.f32'),fullRF=str(folder/'full.f32'),
            width=w,height=h,polygons=row['polygons'],fontPixels=row['fontPixels'],affinity=case['affinityScores'],
            rfModelWeightsSHA256=case['modelWeightsSHA256'],output=output)
        start=time.monotonic()
        process=subprocess.run([str(self.binary),str(REPO/'Aidoku/Resources/Translation/SegmentationAcceptedFinal'),
            str(REPO/'Aidoku/Resources/Translation/SourceModels')],input=json.dumps(request)+'\n',text=True,capture_output=True)
        if process.returncode:
            self.fail(process.stderr[-4000:])
        audit=json.loads(process.stdout)
        read=lambda suffix,dtype:np.fromfile(output+suffix,dtype)
        p=read('.p.f32',np.float32).reshape(shape);q=read('.q.f32',np.float32).reshape(shape)
        raw=read('.native.u8',np.uint8).reshape(shape);completed=read('.completed.u8',np.uint8).reshape(shape)
        runtime=SourceMaskRuntime()
        expected,reference,trace=runtime.predict(rgb=rgb,primary=p,boundary=q,native=raw,completed=completed,
            coarse_rf=coarse,full_rf=full,font=row['fontPixels'],affinity=case['affinityScores'])
        edge=source_matrix(rgb,p,raw,coarse,full,max(1.,row['fontPixels']))
        context,_=_math.context_features(np.column_stack([edge,q.ravel()]),trace['base'],row['fontPixels'])
        reports=[]
        for name,count,codes in [('context83',83,trace['jointCodes']),('style78',78,trace['auxiliaryCodes'])]:
            positions=read('.'+name+'.positions.i32',np.int32)
            actual_features=read('.'+name+'.f32',np.float32).reshape(-1,count)
            if name=='context83': expected_features=context[positions]
            else:
                raw_distance=cv2.distanceTransform((raw==0).astype(np.uint8),cv2.DIST_C,3)
                style=_math.style_features(rgb,raw>0,raw_distance,p,p,row['fontPixels'],case).astype(np.float32)
                expected_features=np.column_stack([edge[positions],np.broadcast_to(style,(len(positions),18))])
            delta=np.abs(actual_features-expected_features)
            report=dict(head=name,rows=len(positions),maxFeatureError=float(delta.max()) if len(delta) else 0.,
                differingFeatureColumns=np.flatnonzero(np.any(actual_features!=expected_features,axis=0)).tolist())
            print('FEATURES',row['id'],json.dumps(report),flush=True);reports.append(report)
            np.testing.assert_allclose(actual_features,expected_features,atol=2e-6,rtol=0)
            native_codes=read('.'+name+'.codes.u16',np.uint16)
            np.testing.assert_array_equal(native_codes,codes.ravel()[positions])
        np.testing.assert_allclose(audit['sourceStyle18'],trace['style'],atol=2e-7,rtol=0)
        native=read('.mask.u8',np.uint8).reshape(shape)
        np.testing.assert_array_equal(native,expected)
        with Image.open(ROOT/'oof-style-pruning/actual-target'/(row['id']+'.png')) as image:
            np.testing.assert_array_equal(native,np.asarray(image))
        self.assertEqual(audit['finalPolicyEngine'],'native-context83-style78')
        self.assertFalse(audit['legacyFallback'])
        print('FRESH-NATIVE-FINAL-PARITY',row['id'],native.size,int(np.count_nonzero(native)),
              'seconds',round(time.monotonic()-start,3),flush=True)

    def test_fresh_native_final_exact_on_train_dev_test_source_crops(self):
        rows=json.loads((ROOT/'boundary-lean/evaluation-manifest.json').read_text())['items']
        for split in ['train','dev','test']:
            row=min((r for r in rows if r['split']==split and r['width']*r['height']>=4096),
                    key=lambda r:r['width']*r['height'])
            with self.subTest(split=split):self.compare(row)


if __name__=='__main__':unittest.main()
