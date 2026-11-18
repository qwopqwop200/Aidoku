"""Global native-pixel output resolution, learned from TRAIN/DEV intervals."""
import numpy as np

VERSION='native-scalar-width-resolution-v1'
RESOLUTIONS=(0.,.125,.25,.5,1.)


def project(values, resolution):
    resolution=float(resolution)
    if resolution not in RESOLUTIONS:
        raise ValueError('Unsupported source width output resolution')
    values=np.asarray(values,dtype=float)
    if not np.isfinite(values).all():raise ValueError('Nonfinite source width output')
    values=np.maximum(.25,values)
    return np.maximum(.25,np.rint(values/resolution)*resolution) if resolution else values


ADAPTIVE_VERSION='adaptive-native-normal-width-regression-v1'


def validate_adaptive(model):
    extension=model.get('adaptiveNormalRefinement')
    if extension is None:return None
    from adaptive_normal_width import VERSION as measurement_version
    import hashlib
    from pathlib import Path
    observed_hash=hashlib.sha256(Path(__file__).with_name('adaptive_normal_width.py').read_bytes()).hexdigest()
    if (not isinstance(extension,dict) or extension.get('version')!=ADAPTIVE_VERSION
            or extension.get('measurementVersion')!=measurement_version
            or extension.get('helperSHA256')!=observed_hash
            or extension.get('sourceFeatureCount')!=662 or extension.get('featureCount')!=50
            or extension.get('scale') not in (.25,.5,1.)
            or getattr(extension.get('regressor'),'n_features_in_',None)!=712):
        raise ValueError('Adaptive native width model/source contract mismatch')
    if extension.get('forestConsensus') is not None:
        from forest_width_consensus import validate_model
        validate_model(extension['regressor'],extension['forestConsensus'])
    return extension


def native_features(model,rgb,mask,prediction,font_pixels,polygons=None):
    """Source-only measured normal features; no scalar predicted width is used."""
    if validate_adaptive(model) is None:return None
    from adaptive_normal_width import measure,features
    evidence=measure(rgb,mask,prediction['fill']['rgb'],prediction['outline']['rgb'],
        prediction['outline']['present'],font_pixels,polygons)
    result=features(evidence,font_pixels)
    if result.shape!=(50,) or not np.isfinite(result).all():raise ValueError('Invalid native width measurement vector')
    return result


def raw(model,matrix,normal=None):
    extension=validate_adaptive(model)
    if extension is None:return np.maximum(.25,model['regressor'].predict(matrix))
    x=np.asarray(matrix,dtype=float);n=np.asarray(normal,dtype=float)
    if (x.ndim!=2 or x.shape[1]!=662 or n.shape!=(len(x),50)
            or not np.isfinite(x).all() or not np.isfinite(n).all()):
        raise ValueError('Adaptive width requires aligned source662/native50 matrices')
    if extension.get('forestConsensus') is None:
        candidate=np.maximum(.25,extension['regressor'].predict(np.column_stack([x,n])))
    else:
        from forest_width_consensus import predict as consensus_predict
        candidate=np.maximum(.25,consensus_predict(extension['regressor'],np.column_stack([x,n]),extension['forestConsensus']))
    if extension['scale']==1.:return candidate
    base=np.maximum(.25,model['regressor'].predict(matrix))
    return np.maximum(.25,base*(1-extension['scale'])+candidate*extension['scale'])


def predict(model,matrix,normal=None):
    resolution=model.get('outputResolutionPx',0.)
    if resolution and model.get('outputResolutionVersion')!=VERSION:
        raise ValueError('Width output resolution version mismatch')
    if resolution and model.get('outputResolutionHelperSHA256')!=helper_sha256():
        raise ValueError('Width output resolution helper changed')
    return project(raw(model,matrix,normal),resolution)


def helper_sha256():
    import hashlib
    from pathlib import Path
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def reference_predict(model,matrix):
    """Independent physical geometry for existing downstream paint observers.

    A new nominal style-width head must not silently redefine the silhouette on
    which an already calibrated displacement observer was trained/validated.
    """
    extension=validate_adaptive(model)
    resolution=extension.get('sourceGeometryReferenceResolutionPx',model.get('outputResolutionPx',0.)) if extension else model.get('outputResolutionPx',0.)
    return project(model['regressor'].predict(matrix),resolution)
