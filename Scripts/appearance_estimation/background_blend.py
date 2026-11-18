"""Probability blend of two source-only paint rankers with identical feature contracts."""
import numpy as np


class BackgroundBlend:
    def __init__(self,original,candidate,weight):
        if original.n_features_in_!=candidate.n_features_in_ or not np.array_equal(original.classes_,candidate.classes_):raise ValueError('Background ranker contract mismatch')
        if not 0<=weight<=1:raise ValueError('Invalid background probability blend')
        self.original=original;self.candidate=candidate;self.weight=float(weight)
        self.n_features_in_=original.n_features_in_;self.classes_=original.classes_
        self.component_estimators=(original,candidate)
    def predict_proba(self,x):return (1-self.weight)*self.original.predict_proba(x)+self.weight*self.candidate.predict_proba(x)
