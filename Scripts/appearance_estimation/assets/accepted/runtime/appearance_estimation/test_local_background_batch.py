"""Worker source isolation, exact field preservation, and mutation detection."""
import copy
from pathlib import Path
import pickle
import tempfile
import unittest
from unittest.mock import patch
import numpy as np
from PIL import Image
from optimize_appearance import digest,save
import apply_final_background as batch
from test_local_background_fusion import inputs


class LocalBackgroundBatchTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        self.args=inputs();rgb,own,_,packet,prediction,model,font,arrays=self.args
        prediction['itemID']='synthetic'
        Image.fromarray(rgb).save(self.root/'source.png');Image.fromarray(own.astype(np.uint8)*255).save(self.root/'synthetic.png')
        self.source=dict(itemID='synthetic',crop=str(self.root/'source.png'),cropSHA256=digest(self.root/'source.png'),page='synthetic',sourceImageSHA256='source-hash',pageSize=[100,100],cropBounds=[1,2,26,22],individualPolygonsCrop=[],mergedPolygonCrop=[],fontPixels=font,maxContextFraction=.15)
        self.entry=dict(itemID='synthetic',identity=dict(sourceRGBSHA256=self.source['cropSHA256'],predictedMaskSHA256=digest(self.root/'synthetic.png'),polygons=[],mergedPolygon=[],fontPixels=font),packet={**packet,'fontPixels':font})
        save(self.root/'synthetic.json',self.entry)
        path=self.root/'final-background-model.pkl'
        with path.open('wb') as stream:pickle.dump(model,stream)
        options={name:str(self.root) for name in ['features','masks','estimator','source_root','ocr_evidence']}
        batch.initialize(path,digest(path),options,{'source-hash':[self.source]})

    def execute(self):
        with patch.object(batch,'load_expensive',return_value=(self.args[7],{},{})):
            return batch.process_one((self.source,self.args[4]))

    def test_source_whitelist_excludes_styles_and_rejects_unfiltered_requests(self):
        row={**self.source,'fill':{'rgb':[1,2,3]},'review':{'GT':True}}
        self.assertEqual(batch.geometry_only(row),self.source)
        self.source['GTShadow']={'rgb':[1,2,3]}
        with self.assertRaisesRegex(ValueError,'whitelisted'):self.execute()

    def test_per_side_context_limit_is_not_a_page_area_limit(self):
        self.source.update(pageSize=[25,25],cropBounds=[0,0,25,20])
        result,provenance,_=self.execute();self.assertEqual(result['background']['rgb'],[255]*3)
        self.assertTrue(provenance['expensiveSourceLoaded'])
        self.source['maxContextFraction']=.151
        with self.assertRaises(ValueError):self.execute()

    def test_injected_nonbackground_mutation_is_rejected(self):
        def bad(*args,**kwargs):
            result=copy.deepcopy(args[4]);result['shadow']['extra']=True;return result
        with patch.object(batch.refinement,'apply',side_effect=bad):
            with self.assertRaisesRegex(ValueError,'another output'):self.execute()

    def test_concurrent_source_mutation_cannot_be_published(self):
        original=batch.refinement.apply
        def mutate(*args,**kwargs):
            result=original(*args,**kwargs)
            Image.fromarray(np.zeros((20,25,3),np.uint8)).save(self.root/'source.png')
            return result
        with patch.object(batch.refinement,'apply',side_effect=mutate):
            with self.assertRaisesRegex(ValueError,'inputs changed'):self.execute()


if __name__=='__main__':unittest.main()
