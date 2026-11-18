import copy
import hashlib
from pathlib import Path
import sys
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
from PIL import Image

import font_context_adapter as adapter
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'inpainting_compare'))
import font_weight_runtime


class ContextTests(unittest.TestCase):
    def fixture(self):
        rgb=np.full((12,8,3),255,np.uint8)
        record=dict(sourceSHA256='source',GTMaskUsed=False,cropBounds=(10,20,18,32),
                    rgb=rgb,sourceRGBSHA256=hashlib.sha256(rgb.tobytes()).hexdigest(),
                    valid=np.ones((12,8),bool),primary=np.ones((12,8)),
                    boundary=np.ones((12,8)),native=np.ones((12,8),np.uint8),
                    rf=np.ones((12,8,27)),rfModelWeightsSHA256='f'*64)
        word=dict(sourceSHA256='source',sourceIndex=7,text='願い',coordinateSpace='page',
                  polygon=[[11,21],[17,21],[17,31],[11,31]],bbox=[11,21,6,10])
        observation=SimpleNamespace(glyph_arrays=record,rf_arrays=record,original_word_members=[word])
        packet=dict(rgb=rgb,bbox=[0,0,8,12],prior=10.,sourceHash='source',sourceRegionID='owner',sourceOrder=0,
                    ownership=np.ones((12,8),bool),style={},text='願い',
                    memberPolygons=[[[1,1],[7,1],[7,11],[1,11]]])
        context=SimpleNamespace(packets=(packet,),packet_order=(0,),crop_bounds=((10,20,18,32),),
            original_priors=np.array([10.]),final_source_ems=np.array([9.]),source_observations=(observation,),
            measurement_spec={},fresh_font_signals={'style187':np.zeros((1,262)),'angles131':np.zeros(1)})
        item=dict(id='owner',frame=[10,20,8,12],fontReference=9.)
        return context,[item]

    def test_reuses_same_call_arrays_and_actual_word_without_mutation(self):
        context,items=self.fixture()
        result=adapter.packets_from_context(context,items,'source')
        self.assertEqual(result[0]['wordMembers'][0]['bbox'],[1,1,6,10])
        self.assertEqual(result[0]['wordMembers'][0]['sourceIndex'],7)
        self.assertEqual(result[0]['prior'],10.)
        self.assertEqual(context.source_observations[0].original_word_members[0]['bbox'],[11,21,6,10])
        with patch('source_runtime.infer_page',return_value=[]) as infer:
            adapter.infer_context({},context,items,'source')
        self.assertIs(infer.call_args.kwargs['fresh_font_signals'],context.fresh_font_signals)
        self.assertIs(infer.call_args.args[2],context.final_source_ems)

    def test_empty_page_does_not_fabricate_or_require_measured_residuals(self):
        context=SimpleNamespace(packets=(),packet_order=(),crop_bounds=(),source_observations=(),
            original_priors=np.empty(0),final_source_ems=np.empty(0),fresh_font_signals={},measurement_spec={})
        with patch('source_runtime.infer_page',side_effect=AssertionError('No observations on empty page')):
            self.assertEqual(adapter.infer_context({},context,[],'source'),[])

    def test_different_weight_geometry_remeasures_only_the_residual_contract(self):
        context,items=self.fixture()
        context.packets[0]['memberPolygons']=[]
        packets=adapter.packets_from_context(context,items,'source')
        with patch('source_runtime._font_paths',return_value=['fonts']), \
                patch('source_runtime._legacy_residual',return_value=np.ones(262)) as measured, \
                patch('source_runtime._source_angle',return_value=3.):
            signals,reused=adapter.weight_signals(context,packets)
        self.assertEqual(reused,[False])
        np.testing.assert_array_equal(signals['style187'],np.ones((1,262)))
        self.assertEqual(signals['angles131'][0],3.)
        self.assertEqual(context.fresh_font_signals['style187'].sum(),0.)
        self.assertEqual(context.packets[0]['memberPolygons'],[])
        self.assertEqual(measured.call_args.args[0]['memberPolygons'],packets[0]['memberPolygons'])

    def test_empty_original_words_are_valid_but_missing_is_not(self):
        context,items=self.fixture()
        context.source_observations[0].original_word_members=[]
        self.assertEqual(adapter.packets_from_context(context,items,'source')[0]['wordMembers'],[])
        context.source_observations[0].original_word_members=None
        with self.assertRaisesRegex(ValueError,'Original word'):
            adapter.packets_from_context(context,items,'source')

    def test_rejects_wrong_source_pixels_order_and_word_pairing(self):
        for mutation in ('source','pixels','order','word'):
            context,items=self.fixture()
            record=context.source_observations[0].glyph_arrays
            if mutation=='source':record['sourceSHA256']='other'
            elif mutation=='pixels':record['rgb'][0,0,0]=0
            elif mutation=='order':context.packet_order=(1,)
            else:context.source_observations[0].original_word_members[0]['bbox']=[0,0,6,10]
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):
                adapter.packets_from_context(context,items,'source')

    def test_page_alignment_preserves_unobserved_pixels(self):
        context,items=self.fixture()
        observation=context.source_observations[0]
        record=dict(observation.glyph_arrays)
        record['cropBounds']=(11,20,18,32)
        record['rgb']=record['rgb'][:,1:]
        record['sourceRGBSHA256']=hashlib.sha256(record['rgb'].tobytes()).hexdigest()
        for key in ('primary','boundary','native','valid'):record[key]=record[key][:,1:]
        observation.glyph_arrays=record
        evidence=adapter.packets_from_context(context,items,'source')[0]['glyphEvidence']
        self.assertFalse(evidence['valid'][:,0].any())
        self.assertTrue(evidence['valid'][:,1:].all())

    def test_producer_publishes_weight_and_protects_mixed(self):
        context,items=self.fixture()
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'source.png'
            rgb=np.full((32,18,3),255,np.uint8);Image.fromarray(rgb).save(path)
            sha=hashlib.sha256(path.read_bytes()).hexdigest()
            with patch.object(adapter,'infer_context',return_value=[dict(sourceWeight='mixed',renderBold=False)]) as infer:
                receipts=font_weight_runtime.estimate_page(items,path,sha,source_context=context,weight_bundle={})
            self.assertIs(infer.call_args.args[1],context)
        self.assertEqual(items[0]['sourceFontWeight'],'mixed')
        self.assertFalse(items[0]['renderBold'])
        self.assertTrue(receipts[0]['existingGlyphRFUsed'])

    def test_missing_context_pair_and_invalid_render_result_fail_before_mutation(self):
        context,items=self.fixture()
        with self.assertRaisesRegex(ValueError,'both'):
            font_weight_runtime.estimate_page(items,'absent','bad',source_context=context)
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'source.png';Image.fromarray(np.full((32,18,3),255,np.uint8)).save(path)
            before=copy.deepcopy(items)
            with patch.object(adapter,'infer_context',return_value=[dict(sourceWeight='mixed',renderBold=True)]):
                with self.assertRaisesRegex(ValueError,'render policy'):
                    font_weight_runtime.estimate_page(items,path,hashlib.sha256(path.read_bytes()).hexdigest(),
                                                     source_context=context,weight_bundle={})
            self.assertEqual(items,before)


if __name__=='__main__':unittest.main()
