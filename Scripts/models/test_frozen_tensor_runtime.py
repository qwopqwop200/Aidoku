"""Focused large-array packaging and mapped Foundation tensor parity."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import export_source_model_runtime as exporter
import numpy as np


class FrozenTensorRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary=tempfile.TemporaryDirectory(prefix='frozen-tensor-')
        cls.root=Path(cls.temporary.name)
        ensemble=exporter.ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble'
        cls.binary=cls.root/'replay'
        subprocess.run(['swiftc','-O',str(ensemble/'NativeAppearanceForest.swift'),
            str(ensemble/'NativeFrozenSourceModel.swift'),str(ensemble/'NativeFrozenTensor.swift'),
            str(exporter.ROOT/'Scripts/models/NativeFrozenTensorReplay.swift'),'-o',str(cls.binary)],check=True)

    @classmethod
    def tearDownClass(cls): cls.temporary.cleanup()

    def test_threshold_dtype_endian_rows_and_mapping(self):
        small=np.arange(999_999,dtype=np.float32)
        self.assertIsInstance(exporter.metadata_tree(small,'small',self.root),list)
        values=(np.arange(1_000_000,dtype=np.float32)/np.float32(7)).reshape(1000,1000)
        values[0,0]=-0.0
        cases=[values,values.astype('>f4'),np.asfortranarray(values),
               values.astype(np.float64)/3, np.arange(1_000_000,dtype=np.int32).reshape(1000,1000)]
        for i,array in enumerate(cases):
            with self.subTest(dtype=str(array.dtype),case=i):
                directory=self.root/str(i); directory.mkdir()
                record=exporter.metadata_tree(array,'bank/features',directory)
                self.assertEqual(record['shape'],list(array.shape))
                expected=np.ascontiguousarray(array,dtype=array.dtype.newbyteorder('<'))
                target=directory/record['tensorAsset']
                self.assertEqual(target.read_bytes(),expected.tobytes())
                self.assertEqual(record['sha256'],hashlib.sha256(expected.tobytes()).hexdigest())
                (directory/'descriptor.json').write_text(json.dumps(record))
                result=subprocess.run([str(self.binary),str(directory)],capture_output=True,text=True,check=True)
                reply=json.loads(result.stdout)
                self.assertEqual(reply['elementCount'],array.size)
                self.assertEqual(reply['byteCount'],array.nbytes)
                self.assertTrue(reply['metadataStaysRecord'])
                self.assertTrue(reply['rejectsInvalidRow'])
                np.testing.assert_array_equal(reply['first'],array[0].astype(np.float64))
                np.testing.assert_array_equal(reply['last'],array[-1].astype(np.float64))
                if record['dtype']=='f32':
                    np.testing.assert_array_equal(reply['floatBits'],expected[-1].view('<u4'))
                    self.assertEqual(reply['pointerBits'],int(expected[-1,-1].view('<u4')))
                changed=bytearray(target.read_bytes());changed[33]^=1;target.write_bytes(changed)
                failure=subprocess.run([str(self.binary),str(directory)],capture_output=True)
                self.assertNotEqual(failure.returncode,0,'Corrupted tensor must fail SHA verification')

    def test_accepted_bank_tensors_match_frozen_source(self):
        resources=exporter.ROOT/'Aidoku/Resources/Translation/SourceModels'
        index=json.loads((resources/'registry-index.json').read_text())
        full=resources/index['metadataAsset']
        self.assertEqual(hashlib.sha256(full.read_bytes()).hexdigest(),index['metadataSHA256'])
        graph=json.loads(full.read_text())['metadata']['tree']['font198']['optimizedGraph']
        source=exporter.load(exporter.ROOT/'Scripts/font_size_estimation/assets/accepted198/model.pkl.gz')
        banks=source['optimizedGraph']['measurementSpec']['referenceBanks']
        tensors=0
        for key in ('76','84'):
            record=graph['measurementSpec']['referenceBanks'][key]['features']
            original=banks[int(key)]['features'] if int(key) in banks else banks[key]['features']
            self.assertEqual(record['dtype'],'f32')
            self.assertEqual(record['shape'],list(original.shape))
            self.assertEqual(record['sha256'],hashlib.sha256(memoryview(np.ascontiguousarray(original)).cast('B')).hexdigest())
            directory=self.root/('realbank'+key);directory.mkdir()
            (directory/'tensors').symlink_to(resources/'tensors',target_is_directory=True)
            (directory/'descriptor.json').write_text(json.dumps(record))
            reply=json.loads(subprocess.run([str(self.binary),str(directory)],capture_output=True,text=True,check=True).stdout)
            np.testing.assert_array_equal(reply['first'],original[0].astype(float))
            np.testing.assert_array_equal(reply['last'],original[-1].astype(float))
            np.testing.assert_array_equal(reply['floatBits'],original[-1].view(np.uint32))
            tensors+=1
        self.assertEqual(tensors,2)
        self.assertLess(full.stat().st_size,6*1024*1024)
        old=Path('/tmp/source-model-pre-tensor-index.json')
        if old.exists(): self.assertEqual(index['heads'],json.loads(old.read_text())['heads'])

    def test_nonfinite_bits_remain_binary_and_small_arrays_unchanged(self):
        array=np.zeros((1000,1000),dtype=np.float32)
        array.view(np.uint32)[2,:4]=[0x80000000,0x7fc12345,0x7f800000,0xff800000]
        record=exporter.metadata_tree(array,'bank',self.root)
        self.assertEqual((self.root/record['tensorAsset']).read_bytes(),array.tobytes())
        graph=exporter.metadata_tree({'style_bank':np.zeros((2182,32),dtype=np.float32),
                                      'pca':np.eye(32),'flag':np.bool_(True)},'font198',self.root)
        self.assertIsInstance(graph['style_bank'],list)
        self.assertIsInstance(graph['pca'],list)
        self.assertIs(graph['flag'],True)
        self.assertLess(len(json.dumps(record)),256)


if __name__=='__main__': unittest.main()
