"""Synthetic orchestration and source-cache checks; no training or frozen replay."""
from contextlib import ExitStack
from copy import deepcopy
import io
from pathlib import Path
import pickle
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
from PIL import Image

import adaptive_normal_width
import calibrate_width as calibration


class ConstantRegressor:
    def __init__(self, value, count=662):
        self.value=value
        self.n_features_in_=count

    def predict(self, matrix):
        assert matrix.shape[1]==self.n_features_in_
        return np.full(len(matrix),self.value)


class InlinePool:
    def __init__(self, **kwargs):pass
    def __enter__(self):return self
    def __exit__(self, *args):pass
    def map(self, function, payloads, **kwargs):return map(function,payloads)


def extension():
    return dict(version='adaptive-native-normal-width-regression-v1',sourceFeatureCount=662,
                featureCount=50,helperSHA256=calibration.digest(Path(adaptive_normal_width.__file__)),
                measurementVersion=adaptive_normal_width.VERSION,
                regressor=ConstantRegressor(3.2,712),scale=1.)


class AdaptiveCalibrationTests(unittest.TestCase):
    def run_calibration(self, adaptive=True, plain_value=8., test_target=3., family='both'):
        with tempfile.TemporaryDirectory() as folder, ExitStack() as stack:
            root=Path(folder);out=root/'out';out.mkdir();masks=root/'masks';masks.mkdir()
            (out/'features').mkdir();(out/'model.pkl').write_bytes(b'source-role-model')
            rows=[];pred=[];packets=[]
            for i,group in enumerate(['train','dev','test','train']):
                item=str(i);crop=root/(item+'.png');mask=masks/(item+'.png')
                Image.fromarray(np.full((4,4,3),200,np.uint8)).save(crop)
                Image.fromarray(np.full((4,4),255,np.uint8)).save(mask)
                row=dict(itemID=item,crop=str(crop),cropSHA256=calibration.digest(crop),
                         individualPolygonsCrop=[[[0,0],[3,0],[3,3]]],group=group,
                         outline=dict(present=True,widthPx=test_target if group=='test' else 3.,
                                      widthRangePx=[test_target-.1,test_target+.1] if group=='test' else [2.9,3.1]))
                rows.append(row)
                pred.append(dict(itemID=item,fill=dict(rgb=[200,200,200]),
                                 outline=dict(rgb=[20,20,20],present=i!=3)))
                packets.append(dict(version='synthetic-source-v1',fontPixels=20.+i,marker=i))
                calibration.save(out/'features'/(item+'.json'),dict(packet=packets[-1]))
            calibration.save(root/'gt.json',dict(items=rows))
            calibration.save(out/'predictions.json',dict(items=pred))
            incumbent=dict(regressor=ConstantRegressor(1.),featureVersion='synthetic-source-v1')
            if adaptive:
                incumbent.update(adaptiveNormalRefinement=extension(),outputResolutionPx=.5,
                                 outputResolutionVersion=calibration.WIDTH_RESOLUTION_VERSION,
                                 outputResolutionHelperSHA256=calibration.width_helper_sha256())
            (out/'width-model.pkl').write_bytes(pickle.dumps(incumbent))
            # This directory belongs to the old eight-ray worker and must not be
            # used for adaptive features, even when item IDs are identical.
            (out/'width-features').mkdir();sentinel=out/'width-features'/'sentinel.json'
            sentinel.write_text('untouched eight-ray cache')
            feature_calls=[];raw_calls=[];predict_calls=[];fits=[]
            actual_raw=calibration.width_resolution.raw
            actual_predict=calibration.predict_width

            def measure_normal(rgb,mask,fill,outline,present,font_pixels,polygons=None):
                self.assertEqual(fill,[200]*3)
                self.assertEqual(outline,[20]*3)
                feature_calls.append((font_pixels,present,polygons))
                return np.full(50,font_pixels if present else 0.)

            actual_worker=calibration.adaptive_worker
            def source_worker(payload):
                self.assertEqual(set(payload[2]),{'version','helperSHA256','measurementVersion'})
                return actual_worker(payload)

            def raw(model,matrix,normal=None):
                raw_calls.append((deepcopy(model),matrix.copy(),None if normal is None else normal.copy()))
                if model.get('adaptiveNormalRefinement') is not None:
                    self.assertEqual(normal.shape,(4,50))
                    np.testing.assert_array_equal(matrix[:,0],[0,1,2,3])
                    np.testing.assert_array_equal(normal[:,0],[20,21,22,0])
                else:self.assertIsNone(normal)
                return actual_raw(model,matrix,normal=normal)

            def predict(model,matrix,normal=None):
                predict_calls.append((matrix.copy(),normal))
                return actual_predict(model,matrix,normal=normal)

            def factory(which):
                model=ConstantRegressor(plain_value if family in ('both',which) else 8.)
                def fit(matrix,target,**kwargs):
                    fits.append((matrix.copy(),target.copy()))
                    return model
                model.fit=fit
                # Local functions cannot be pickled: selected artifacts only
                # need the synthetic regressor state, not this mock fit method.
                return model

            # Keep mock fit out of the saved object's state.
            def pickle_dump(model,stream):
                model=deepcopy(model)
                model['regressor'].__dict__.pop('fit',None)
                stream.write(pickle.dumps(model))

            for name,value in [('ProcessPoolExecutor',InlinePool),('assign_splits',lambda r:None),
                               ('split',lambda r:r['group']),
                               ('worker',lambda payload:dict(itemID=payload[0]['itemID'],vector=[0.]*8,evidence=dict(suggestedWidthPx=1.))),
                               ('width_features',lambda packet,*args:np.r_[packet['marker'],np.zeros(661)]),
                               ('HistGradientBoostingRegressor',lambda **kw:factory('hgb')),
                               ('ExtraTreesRegressor',lambda **kw:factory('et')),
                               ('adaptive_worker',source_worker),
                               ('predict_width',predict)]:
                stack.enter_context(patch.object(calibration,name,value))
            stack.enter_context(patch.object(calibration.width_resolution,'raw',raw,create=True))
            stack.enter_context(patch.object(adaptive_normal_width,'measure',measure_normal))
            stack.enter_context(patch.object(adaptive_normal_width,'features',lambda evidence,font:evidence))
            stack.enter_context(patch.object(calibration.pickle,'dump',pickle_dump))
            stack.enter_context(patch('sys.argv',['calibrate_width','--gt',str(root/'gt.json'),'--masks',str(masks),'--out',str(out),'--jobs','1']))
            stack.enter_context(patch('sys.stdout',io.StringIO()))
            calibration.main()
            artifact=pickle.loads((out/'width-model.pkl').read_bytes())
            result=calibration.read(out/'WIDTH-RESULTS.json')
            output=calibration.read(out/'predictions-with-width.json')['items']
            self.assertEqual(sentinel.read_text(),'untouched eight-ray cache')
            for matrix,target in fits:
                np.testing.assert_array_equal(matrix[:,0],[0,3])
                np.testing.assert_array_equal(target,[3,3])
            return artifact,result,output,feature_calls,raw_calls,predict_calls

    def test_incumbent_extension_retained_through_raw_selection_and_save(self):
        artifact,result,output,features,raw,predict=self.run_calibration()
        self.assertEqual(artifact['regressor'].value,1.)
        self.assertEqual(artifact['adaptiveNormalRefinement']['regressor'].n_features_in_,712)
        self.assertEqual(artifact['adaptiveNormalRefinement']['scale'],1.)
        self.assertEqual([f[0] for f in features],[20,21,22,23])
        self.assertEqual([f[1] for f in features],[True,True,True,False])
        self.assertEqual(len(predict),1)
        self.assertIn('adaptiveNormalRefinement',raw[-1][0])
        self.assertEqual([p['outline']['widthPx'] for p in output],[3,3,3,0])
        self.assertEqual(artifact['outputResolutionPx'],.5)
        replay=calibration.predict_width(artifact,raw[-1][1],normal=raw[-1][2])
        np.testing.assert_array_equal(replay[:3],[p['outline']['widthPx'] for p in output[:3]])
        self.assertFalse(result['outputResolutionSelection']['TESTUsedForSelection'])
        changed=self.run_calibration(test_target=1000.)
        self.assertEqual(artifact['outputResolutionSelection'],changed[0]['outputResolutionSelection'])

    def test_plain_winner_discards_extension_in_both_search_families(self):
        for family in ['hgb','et']:
            with self.subTest(family=family):
                # Perfect plain predictions beat a deliberately poor incumbent.
                original=extension
                def poor_extension():
                    ext=original();ext['regressor']=ConstantRegressor(6.,712);return ext
                with patch(__name__+'.extension',poor_extension):
                    artifact,_,output,_,raw,_=self.run_calibration(plain_value=3.,family=family)
                self.assertNotIn('adaptiveNormalRefinement',artifact)
                self.assertNotIn('adaptiveNormalRefinement',raw[-1][0])
                self.assertIsNone(raw[-1][2])
                self.assertEqual([p['outline']['widthPx'] for p in output],[3,3,3,0])

    def test_legacy_incumbent_does_not_request_native_measurements(self):
        artifact,_,_,features,raw,predict=self.run_calibration(adaptive=False)
        self.assertEqual(features,[])
        self.assertNotIn('adaptiveNormalRefinement',artifact)
        self.assertIsNone(predict[0][1])
        self.assertIsNone(raw[-1][2])

    def test_source_whitelist_cache_identity_and_absent_zero(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);crop=root/'crop.png';mask=root/'id.png'
            Image.fromarray(np.full((4,4,3),200,np.uint8)).save(crop)
            Image.fromarray(np.full((4,4),255,np.uint8)).save(mask)
            row=dict(itemID='id',crop=str(crop),cropSHA256=calibration.digest(crop),
                     individualPolygonsCrop=[[[0,0],[2,0],[2,2]]],
                     outline=dict(widthPx=999),style='GT forbidden',labels=['forbidden'])
            prediction=dict(itemID='id',fill=dict(rgb=[200]*3),outline=dict(rgb=[20]*3,present=True,widthPx=777))
            job=calibration.adaptive_jobs([row],[prediction],[dict(fontPixels=24.)],root)[0]
            self.assertEqual(set(job),{'itemID','crop','cropSHA256','mask','predictedMaskSHA256','fill','outline','present','fontPixels','polygons'})
            self.assertEqual(job['outline'],[20]*3)
            ext=extension();calls=[]
            def measure_normal(rgb,mask,fill,outline,present,font_pixels,polygons=None):
                calls.append((rgb.copy(),mask.copy(),fill,outline,present,font_pixels,polygons))
                return np.ones(50)
            with patch.object(adaptive_normal_width,'measure',measure_normal),patch.object(adaptive_normal_width,'features',lambda evidence,font:evidence):
                first=calibration.adaptive_worker((job,str(root),ext))
                self.assertEqual(first,calibration.adaptive_worker((job,str(root),ext)))
                self.assertEqual(len(calls),1)
                variants=dict(fill=[199]*3,outline=[21]*3,present=False,fontPixels=25.,polygons=None)
                for key,value in variants.items():
                    with self.subTest(key=key):
                        calibration.adaptive_worker((job,str(root),ext))
                        before=len(calls);changed={**job,key:value}
                        result=calibration.adaptive_worker((changed,str(root),ext))
                        self.assertEqual(len(calls),before+1)
                        self.assertNotEqual(first['identity'],result['identity'])
                        if key=='present':np.testing.assert_array_equal(result['vector'],np.zeros(50))
                for key,path in [('cropSHA256',crop),('predictedMaskSHA256',mask)]:
                    before=len(calls);image=np.asarray(Image.open(path)).copy();image.flat[0]=0
                    Image.fromarray(image).save(path)
                    job[key]=calibration.digest(path)
                    calibration.adaptive_worker((job,str(root),ext))
                    self.assertEqual(len(calls),before+1)
                before=len(calls)
                with patch.object(adaptive_normal_width,'VERSION','new-measurement'):
                    calibration.adaptive_worker((job,str(root),{**ext,'measurementVersion':'new-measurement'}))
                self.assertEqual(len(calls),before+1)
                with self.assertRaisesRegex(ValueError,'helper changed'):
                    calibration.adaptive_worker((job,str(root),{**ext,'helperSHA256':'stale'}))
                crop.write_bytes(b'changed source')
                with self.assertRaisesRegex(ValueError,'source changed'):
                    calibration.adaptive_worker((job,str(root),ext))

    def test_source_worker_matches_shared_native_feature_contract(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);crop=root/'crop.png';mask_path=root/'id.png'
            rgb=np.full((32,32,3),110,np.uint8)
            rgb[6:26,6:26]=20;rgb[10:22,10:22]=220
            mask=np.zeros((32,32),np.uint8);mask[10:22,10:22]=255
            Image.fromarray(rgb).save(crop);Image.fromarray(mask).save(mask_path)
            prediction=dict(itemID='id',fill=dict(rgb=[220]*3),outline=dict(rgb=[20]*3,present=True))
            row=dict(itemID='id',crop=str(crop),cropSHA256=calibration.digest(crop))
            job=calibration.adaptive_jobs([row],[prediction],[dict(fontPixels=24.)],root)[0]
            ext=extension()
            expected=calibration.width_resolution.native_features(dict(adaptiveNormalRefinement=ext),
                rgb,mask>0,prediction,24.,polygons=None)
            actual=calibration.adaptive_worker((job,str(root),ext))
            np.testing.assert_array_equal(actual['vector'],expected)
            absent=calibration.adaptive_worker(({**job,'present':False},str(root),ext))
            np.testing.assert_array_equal(absent['vector'],np.zeros(50))


if __name__=='__main__':unittest.main()
