"""Robust native-width consensus of existing fitted source trees, no new fit."""
import hashlib
import math
from pathlib import Path
import numpy as np

VERSION='source-width-trimmed-upper-forest-consensus-v1'
CONFIG=dict(trimFraction=.2,upperQuantile=.6,upperScale=.5)


def helper_sha256():
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def validate_model(regressor,policy):
    expected=dict(version=VERSION,configuration=CONFIG,helperSHA256=helper_sha256(),
                  sourceFeatureCount=712,sourceOnly=True,GTAtInference=False)
    if policy!=expected:raise ValueError('Width forest consensus policy/hash mismatch')
    if (getattr(regressor,'n_features_in_',None)!=712
            or len(getattr(regressor,'estimators_',[]))!=192
            or any(getattr(t,'n_features_in_',None)!=712 for t in regressor.estimators_)):
        raise ValueError('Expected frozen 192-tree,712-source-feature width forest')


def aggregate(tree_predictions):
    """Trees x cases -> native scalar; independent of input tree order."""
    values=np.asarray(tree_predictions,dtype=float)
    if values.ndim!=2 or values.shape[0]<5 or values.shape[1]<1 or not np.isfinite(values).all():
        raise ValueError('Expected finite nonempty tree-by-case width predictions')
    ordered=np.sort(values,axis=0);trim=int(np.floor(len(values)*CONFIG['trimFraction']))
    # fsum fixes the reduction order across singleton and batched inference;
    # 1-ulp differences otherwise flip widths exactly on a half-pixel tie.
    retained=ordered[trim:len(values)-trim]
    center=np.asarray([math.fsum(column)/len(retained) for column in retained.T])
    upper=np.quantile(ordered,CONFIG['upperQuantile'],axis=0)
    return center*(1-CONFIG['upperScale'])+upper*CONFIG['upperScale']


def predict(regressor,matrix,policy):
    validate_model(regressor,policy)
    x=np.asarray(matrix,dtype=float)
    if x.ndim!=2 or x.shape[1]!=712 or not np.isfinite(x).all():
        raise ValueError('Expected finite N x712 source-only matrix')
    if not len(x):return np.empty(0)
    # sklearn's forest validates/casts once, then asks every tree to skip it.
    # Match that path rather than repeating 192 identical checks per crop.
    validated=np.ascontiguousarray(x,dtype=np.float32)
    if not np.isfinite(validated).all():raise ValueError('Source matrix exceeds float32 tree range')
    return aggregate(np.asarray([tree.predict(validated,check_input=False) for tree in regressor.estimators_]))
