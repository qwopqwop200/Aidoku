"""Operational entry points must dispatch the selected graph, never old48."""
import gzip
import pickle
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'inpainting_compare'))
from estimator import load_model,predict_matrix
import font_size_runtime


class OptimizedDispatchTests(unittest.TestCase):
    def test_gzip_model_loader(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'bundle.pkl.gz'
            with gzip.open(path,'wb') as stream:
                pickle.dump({'optimizedGraph':{'version':'accepted-font198-v1'}},stream)
            bundle=load_model(path)
            self.assertEqual(bundle['optimizedGraph']['version'],'accepted-font198-v1')
        load_model.cache_clear()

    def test_matrix_only_api_cannot_silently_bypass_optimized_graph(self):
        with self.assertRaisesRegex(ValueError,'source signals'):
            predict_matrix({'optimizedGraph':{'version':'accepted-font198-v1'}},[],[],[])

    def test_render_bridge_calls_optimized_source_adapter(self):
        bundle={'optimizedGraph':{'version':'accepted-font198-v1'}}
        items=[{'id':'dynamic-row','fontReference':20.}]
        marker=[{'id':'dynamic-row','fontReference':24.}]
        with patch('estimator.load_model',return_value=bundle),patch('optimized_runtime.estimate_page',return_value=marker) as run:
            result=font_size_runtime.estimate_page(items,'fresh-image.png','fresh-source-sha','accepted.pkl.gz',
                source_texts={'dynamic-row':'source'},mask_metadata={'predictedMask':True},
                source_confidences={'dynamic-row':.9},source_roles={'dynamic-row':'dialogue'})
        self.assertIs(result,marker)
        args=run.call_args.args
        self.assertIs(args[0],bundle)
        self.assertIs(args[1],items)
        self.assertEqual(args[-2],{'dynamic-row':.9})
        self.assertEqual(args[-1],{'dynamic-row':'dialogue'})


if __name__=='__main__':unittest.main()
