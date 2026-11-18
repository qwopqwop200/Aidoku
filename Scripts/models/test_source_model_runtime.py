"""Focused Swift/Python learned-operator parity. No full app or image build.

Run with .venv-source-inference/bin/python -m unittest discover -s Scripts/models
-p test_source_model_runtime.py. Real accepted heads plus trained synthetic edge
cases are tested; expected predictions exist only in a temporary test directory.
"""
import json
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import warnings

import export_source_model_runtime as exporter
import numpy as np


class SourceModelRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='frozen-source-parity-')
        cls.work=Path(cls.temp.name)
        cls.binary=cls.work/'replay'
        ensemble=exporter.ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble'
        subprocess.run(['swiftc','-O',str(ensemble/'NativeAppearanceForest.swift'),
            str(ensemble/'NativeFrozenSourceModel.swift'),
            str(exporter.ROOT/'Scripts/models/NativeFrozenSourceModelReplay.swift'),
            '-o',str(cls.binary)],check=True)

    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()

    def replay(self, cases):
        registry=dict(schema=1,sourceOnly=True,GTAtInference=False,heads={})
        requests=[]; expected={}; expected_trees={}
        def json_rows(rows): return [[None if np.isnan(v) else float(v) for v in row] for row in rows]
        for key,model,rows in cases:
            head=exporter.export_model(model)
            path=self.work/(str(len(requests))+'.plist')
            path.write_bytes(plistlib.dumps(head,fmt=plistlib.FMT_BINARY,sort_keys=False))
            registry['heads'][key]=dict(asset=path.name,sha256=hashlib.sha256(path.read_bytes()).hexdigest(),kind=head['kind'],featureCount=head['featureCount'])
            classifier=hasattr(model,'predict_proba')
            trees=type(model).__name__ in ('ExtraTreesRegressor','RandomForestRegressor')
            requests.append(dict(id=key,rows=json_rows(rows),probability=classifier,trees=trees))
            with warnings.catch_warnings():
                warnings.simplefilter('ignore')
                v=model.predict_proba(rows) if classifier else (model.transform(rows) if head['kind'] in ('pca','scaler') else model.predict(rows))
            if isinstance(v,list): v=np.concatenate(v,axis=1)
            v=np.asarray(v)
            if v.ndim==1:v=v[:,None]
            expected[key]=v
            if trees:
                expected_trees[key]=np.stack([np.asarray(t.predict(rows)).reshape(len(rows),-1) for t in model.estimators_],axis=1)
            if classifier: requests.append(dict(id=key+'#labels',rows=json_rows(rows),probability=False,trees=False))
            if classifier:
                registry['heads'][key+'#labels']=registry['heads'][key]
                expected[key+'#labels']=np.asarray(model.predict(rows) if hasattr(model,'predict') else np.asarray(model.classes_)[np.argmax(v,axis=1)]).astype(float).reshape(len(rows),-1)
        (self.work/'registry.json').write_text(json.dumps(registry))
        request=self.work/'requests.json'; reply=self.work/'replies.json'
        request.write_text(json.dumps(requests,allow_nan=False))
        subprocess.run([str(self.binary),str(self.work),str(request),str(reply)],check=True)
        for response in json.loads(reply.read_text()):
            key=response['id']
            np.testing.assert_allclose(response['values'],expected[key],rtol=2e-10,atol=2e-10,err_msg=key)
            if key in expected_trees:
                np.testing.assert_allclose(response['trees'],expected_trees[key],rtol=2e-10,atol=2e-10,err_msg=key+' trees')
        return len(requests)

    def test_real_selected_heads_all_stages(self):
        rng=np.random.default_rng(198)
        count=0
        # One source artifact at a time bounds memory; every selected head is exercised.
        for prefix,path in exporter.source_paths():
            objects={}; docs=exporter.collect(exporter.load(path),prefix,objects=objects)
            cases=[]
            for key,model in objects.items():
                n=docs[key]['featureCount']
                # Finite probes cover zero, signs, source-like feature ranges and learned split neighborhoods.
                rows=np.vstack([np.zeros(n),rng.normal(size=n),rng.uniform(-10,255,size=n)])
                source_root=exporter.ROOT.parent/'font-size-estimation-20261110'
                if key=='font198/optimizedGraph/baseModel/model' and (source_root/'round6/features.npz').exists():
                    with np.load(source_root/'round6/features.npz',allow_pickle=False) as source:
                        rows=np.vstack([rows,source['X'][:3]])
                if key=='font198/optimizedGraph/lateModels/style_encoder/model' and (source_root/'round187/features.npz').exists():
                    with np.load(source_root/'round187/features.npz',allow_pickle=False) as source:
                        state=docs[key]['metadata']
                        features=np.clip(source['X'][:3,:255],-state['clip'],state['clip'])
                        features=(features-np.asarray(state['mean']))/np.asarray(state['std'])
                        rows=np.vstack([rows,features])
                if docs[key]['kind']=='scaler': rows=rows.astype(float)
                cases.append((key,model,rows))
            count+=self.replay(cases)
            print(prefix,len(cases),'real learned heads passed',flush=True)
        self.assertGreaterEqual(count,60)

    def test_metadata_lazy_eager_precision_and_checksum(self):
        import struct
        directory=self.work/'metadata'; directory.mkdir()
        probe=0.032605205295338016
        doc=dict(schema=1,sourceOnly=True,GTAtInference=False,heads={},sourceArtifacts={'font198':'approved'},
                 metadata={'tree':{'font198':{'probe':probe}}})
        full=directory/'registry.json'; full.write_text(json.dumps(doc))
        index={k:v for k,v in doc.items() if k!='metadata'}
        index.update(metadataAsset='registry.json',metadataSHA256=hashlib.sha256(full.read_bytes()).hexdigest())
        (directory/'registry-index.json').write_text(json.dumps(index))
        expected=str(struct.unpack('<Q',struct.pack('<d',probe))[0])
        for flag in ('--metadata','--metadata-eager'):
            result=subprocess.run([str(self.binary),str(directory),flag],capture_output=True,text=True,check=True)
            self.assertEqual(result.stdout.strip(),expected)
        full.write_text(full.read_text().replace('0.032605205295338016','0.03260520529533802'))
        result=subprocess.run([str(self.binary),str(directory),'--metadata'],capture_output=True)
        self.assertNotEqual(result.returncode,0,'Changed metadata must fail authentication')

    def test_missing_directions_and_float32_thresholds(self):
        from sklearn.ensemble import RandomForestClassifier,HistGradientBoostingClassifier,ExtraTreesRegressor
        rng=np.random.default_rng(21); x=rng.normal(size=(100,4)); labels=(x[:,0]>0).astype(int)
        missing=x.copy(); missing[::3,0]=np.nan
        probes=np.array([[np.nan,0,0,0],[0,0,0,0],[1,0,0,0],[-1,0,0,0]],dtype=float)
        cases=[('nan-rf',RandomForestClassifier(n_estimators=4,max_depth=3,random_state=9).fit(missing,labels),probes),
               ('nan-hgb',HistGradientBoostingClassifier(max_iter=4,min_samples_leaf=3).fit(missing,labels),probes)]
        model=ExtraTreesRegressor(n_estimators=2,max_depth=3,random_state=9).fit(x,x[:,0])
        threshold=model.estimators_[0].tree_.threshold[0]
        feature=model.estimators_[0].tree_.feature[0]
        boundary=np.zeros((3,4))
        boundary[:,feature]=[np.nextafter(np.float32(threshold),np.float32(-np.inf)),
                             threshold,np.nextafter(np.float32(threshold),np.float32(np.inf))]
        cases.append(('float32-split',model,boundary));self.replay(cases)

    def test_multioutput_transform_and_links(self):
        from sklearn.ensemble import ExtraTreesClassifier,ExtraTreesRegressor,HistGradientBoostingRegressor
        from sklearn.linear_model import Ridge,HuberRegressor,QuantileRegressor
        from sklearn.preprocessing import StandardScaler
        from sklearn.decomposition import PCA
        rng=np.random.default_rng(44); x=rng.normal(size=(90,5)); y=x[:,0]*2-x[:,1]
        models=[ExtraTreesRegressor(n_estimators=3,random_state=7).fit(x,np.c_[y,y*3]),
                ExtraTreesClassifier(n_estimators=3,random_state=7).fit(x,np.c_[y>0,np.digitize(y,[-1,0,1])]),
                ExtraTreesClassifier(n_estimators=3,random_state=7).fit(np.tile(x,(2,1)),np.arange(180)%40),
                Ridge().fit(x,np.c_[y,y*3]),HuberRegressor().fit(x,y),QuantileRegressor(alpha=.1).fit(x,y),
                StandardScaler().fit(x),StandardScaler(with_mean=False,with_std=False).fit(x),
                PCA(3,whiten=True).fit(x),
                HistGradientBoostingRegressor(loss='poisson',max_iter=3,min_samples_leaf=3).fit(x,np.exp(y))]
        self.replay([(str(i),m,x[:5]) for i,m in enumerate(models)])


if __name__=='__main__': unittest.main()
