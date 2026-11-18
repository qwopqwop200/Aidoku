import unittest
from unittest.mock import patch
import numpy as np
from live_weight_context import infer_live_page


class LiveSourceWeightContextTests(unittest.TestCase):
    def fixture(self):
        rgb=np.zeros((8,9,3),np.uint8)
        packet=dict(rgb=rgb,rf=np.zeros((8,9,27),np.float32),rfModelWeightsSHA256='a'*64,
                    cropOrigin=[10,20],bbox=[1,1,5,6],wordMembers=[dict(text='ab',sourceIndex=2,
                    bbox=[1,1,5,6],polygon=[[1,1],[6,1],[6,7],[1,7]])])
        measured=dict(rgb=rgb,memberPolygons=[[[1,1],[6,1],[6,7]]],sourceHash='hash')
        trace=dict(primary=np.zeros((8,9),np.float32),boundary=np.zeros((8,9),np.float32),
                   rawNative=np.zeros((8,9),np.uint8),observationValid=np.ones((8,9),bool))
        return measured,packet,(None,None,trace)

    def test_live_records_keep_provenance_and_renderer_geometry(self):
        m,p,s=self.fixture();saved=list(m['memberPolygons'])
        def infer(bundle,packets,**kwargs):
            self.assertEqual(packets[0]['memberPolygons'],[])
            self.assertEqual(packets[0]['cropBounds'],[10,20,19,28])
            observation=kwargs['source_observations'][0]
            self.assertFalse(observation.glyph_arrays['GTMaskUsed'])
            self.assertEqual(observation.original_word_members[0]['sourceIndex'],2)
            self.assertEqual(observation.original_word_members[0]['sourceSHA256'],'hash')
            self.assertTrue(kwargs['return_context'])
            return [20.], 'context'
        with patch('optimized_runtime.infer_packets',side_effect=infer), \
             patch('live_weight_context.infer_context',return_value=[dict(sourceWeight='regular')]) as weight:
            values=infer_live_page({}, {}, [m],[p],[s],page_size=[100,200],source_identity='hash')
        self.assertEqual(values[0]['sourceWeight'],'regular')
        self.assertEqual(m['memberPolygons'],saved)
        self.assertEqual(weight.call_args.args[2][0]['frame'],[11,21,5,6])

    def test_missing_observed_support_is_not_fabricated(self):
        m,p,s=self.fixture();s[2]['observationValid']=np.zeros((8,9),bool)
        with self.assertRaisesRegex(ValueError,'coverage'):
            infer_live_page({}, {}, [m],[p],[s],page_size=[100,200],source_identity='hash')

    def test_missing_word_records_are_not_paragraph_split(self):
        m,p,s=self.fixture();del p['wordMembers']
        with self.assertRaisesRegex(ValueError,'word records'):
            infer_live_page({}, {}, [m],[p],[s],page_size=[100,200],source_identity='hash')

if __name__=='__main__':unittest.main()
