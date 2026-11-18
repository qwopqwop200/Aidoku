"""Read-only, source-authenticated native classifier observations; no GT inputs."""
from pathlib import Path

import numpy as np

from evaluate_gt import sha
from native_boundary_policy_replay import cache_path
from native_predict import classifier_identity,observation_contract,load_classifier_observation


class SourceBoundaryVotes:
    def __init__(self,base,primary_cache,producer,boundary_cache):
        self.base,self.primary_cache,self.producer,self.boundary_cache=map(Path,(base,primary_cache,producer,boundary_cache))
        self.primary_identity,self.primary_trees=classifier_identity(self.base/'recall-full-rf-native-pixel-forest.json')
        self.boundary_identity,self.boundary_trees=classifier_identity(self.producer/'boundary-forest.json')
        self.primary_binary=sha(self.base/'native-pixel-rf-segmentation')
        self.boundary_binary=sha(self.producer/'native-boundary-refiner')

    def load(self,row):
        source={k:row[k] for k in ['id','rgb','rf','width','height','polygons','fontPixels']}
        pc=observation_contract(source,self.base,self.primary_identity,self.primary_binary,True)
        qc=observation_contract(source,self.base,self.boundary_identity,self.boundary_binary,True)
        qc.update(primaryClassifierSHA256=self.primary_identity,primaryExecutableSHA256=self.primary_binary,
            schema='source-boundary-classifier-observation-v1')
        p=load_classifier_observation(cache_path(self.primary_cache,pc),pc,self.primary_trees)
        q=load_classifier_observation(cache_path(self.boundary_cache,qc),qc,self.boundary_trees)
        if p is None or q is None:raise ValueError('Missing or stale native source observations')
        primary,native=p;boundary,other=q
        if not np.array_equal(native,other):raise ValueError('Native observations disagree on source extraction')
        return primary,boundary,native
