"""Double-threshold, double-sum HGB replay; source features remain Float32."""
import numpy as np
from numba import njit


@njit(cache=True)
def predict(features, indices, intercept, split_feature, threshold, left, right, leaf_value):
    probabilities = np.empty(len(indices), np.float64)
    for i in range(len(indices)):
        pixel = indices[i]
        raw = intercept
        for tree in range(split_feature.shape[0]):
            node = 0
            while split_feature[tree, node] >= 0:
                feature = split_feature[tree, node]
                if np.float64(features[pixel, feature]) <= threshold[tree, node]:
                    node = left[tree, node]
                else:
                    node = right[tree, node]
            raw += leaf_value[tree, node]
        if raw >= 0:
            probabilities[i] = 1. / (1. + np.exp(-raw))
        else:
            value = np.exp(raw)
            probabilities[i] = value / (1. + value)
    return probabilities


class CompiledPointPredictor:
    def __init__(self, model):
        nodes = [stage[0].nodes for stage in model._predictors]
        maximum = max(len(n) for n in nodes)
        shape = (len(nodes), maximum)
        features = np.full(shape, -1, np.int32)
        thresholds = np.zeros(shape, np.float64)
        left, right = np.zeros(shape, np.int32), np.zeros(shape, np.int32)
        values = np.zeros(shape, np.float64)
        for t, tree in enumerate(nodes):
            for n, node in enumerate(tree):
                if node['is_categorical']:
                    raise ValueError('Categorical splits not supported')
                features[t, n] = -1 if node['is_leaf'] else node['feature_idx']
                thresholds[t, n] = node['num_threshold']
                left[t, n], right[t, n], values[t, n] = node['left'], node['right'], node['value']
        self.arguments = (float(model._baseline_prediction[0, 0]), features, thresholds, left, right, values)
        self.feature_count = model.n_features_in_

    def probabilities(self, features, indices):
        if features.dtype != np.float32 or features.ndim != 2 or features.shape[1] != self.feature_count:
            raise ValueError('Require source Float32 feature matrix')
        return predict(features, indices, *self.arguments)
