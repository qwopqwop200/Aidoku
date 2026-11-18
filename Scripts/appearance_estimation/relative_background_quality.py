"""Pure frozen relative BG comparator. No I/O, GT, IDs or source extraction.

Caller computes V2 first on restored pre-native-gradient source X102 and passes
that V2 index on EVERY call, including warm replay. Original palette + restored
RAW incumbent order is retained, including identical RGB rows. Reusing the
relative winner as baseline would introduce an unfrozen sequential tournament.
"""
import numpy as np

VERSION = 'source-relative-background-quality-v1'
CLASSIFIER = 'train-all-palette-pairs-hgb31-v1'
FEATURE_VERSION = 'source102-pair-A-B-BminusA-absdiff-v1'
SOURCE_FEATURE_VERSION = 'exact-local-background-rf27-seg2-ocr8-interactions6-v1'
SOURCE_FEATURE_COUNT = 102
FEATURE_COUNT = 408
THRESHOLD = .95
_RF = tuple(f'rfClass{c}{suffix}' for c in range(5) for suffix in
    ('MaxMaskProbability', 'MeanMaskProbability', 'BoxConfidence')) + tuple(
    f'rfOwnerClass{c}{suffix}' for c in range(5) for suffix in ('MaskProbability', 'Affinity')) + (
    'rfSemanticMargin', 'rfMaskUncertainty')
_OCR = ('ocrBoxSupport', 'ocrDetAvailable', 'ocrDetectorConfidence', 'ocrRecAvailable',
        'ocrRecognitionConfidence', 'ocrTokensAvailable', 'ocrMinimumTokenConfidence', 'ocrMeanTokenConfidence')
_SIGNALS = _RF + ('segPrimary','segBoundary') + _OCR + (
    'balloonNonText','frameNonText','ownerBalloonNonText','ownerFrameNonText','textSeg','sfxSeg')
SOURCE_FEATURE_NAMES = (
    'candidateLabLDiv100','candidateLabADiv100','candidateLabBDiv100','observedContextWeight',
    'visibleColourFraction','borderColourFraction','localNearestMass','localColourFraction',
    'localRelativeColourFraction','backgroundRoleColourDistanceDiv100','backgroundRoleObservedMass',
    'fillColourDistanceDiv100','outlineColourDistanceDiv100','localMatchedFraction','localLog1pPixelCountDiv10'
) + tuple('localConditionalMean.'+n for n in _SIGNALS) + tuple('localJointMass.'+n for n in _SIGNALS) + ('localSupportObserved',)
FEATURE_NAMES = tuple(prefix+name for prefix in ('xA.','xB.','BminusA.','absBminusA.') for name in SOURCE_FEATURE_NAMES)


def pair_features(a, b):
    """Float32 [N,408], subtraction AFTER float32 cast, exactly as frozen fit."""
    a=np.asarray(a,dtype=np.float32); b=np.asarray(b,dtype=np.float32)
    if (a.ndim!=2 or a.shape!=b.shape or a.shape[1]!=SOURCE_FEATURE_COUNT
            or not np.isfinite(a).all() or not np.isfinite(b).all()):
        raise ValueError('Expected aligned finite N x 102 source descriptors')
    delta=b-a
    return np.column_stack([a,b,delta,np.abs(delta)]).astype(np.float32)


def validate_model(model):
    """Structural binding only; caller authenticates helperSHA256 without I/O here."""
    if not isinstance(model,dict):raise ValueError('Expected relative quality model dict')
    expected=dict(version=VERSION,classifierVersion=CLASSIFIER,featureVersion=FEATURE_VERSION,
        sourceFeatureVersion=SOURCE_FEATURE_VERSION,featureCount=FEATURE_COUNT,
        sourceFeatureCount=SOURCE_FEATURE_COUNT,configuration=dict(minimumRelativeProbability=THRESHOLD))
    if any(model.get(k)!=v for k,v in expected.items()):
        raise ValueError('Relative quality version/schema/configuration mismatch')
    if (tuple(model.get('featureNames',()))!=FEATURE_NAMES
            or tuple(model.get('sourceFeatureNames',()))!=SOURCE_FEATURE_NAMES):
        raise ValueError('Relative quality feature names/order mismatch')
    h=model.get('helperSHA256')
    if not isinstance(h,str) or len(h)!=64 or any(c not in '0123456789abcdef' for c in h):
        raise ValueError('Relative quality helper SHA256 missing')
    clf=model.get('classifier')
    if (not callable(getattr(clf,'predict_proba',None)) or getattr(clf,'n_features_in_',None)!=FEATURE_COUNT
            or not np.array_equal(getattr(clf,'classes_',None),[0,1])):
        raise ValueError('Expected binary 408-feature relative quality classifier')


def _positive(clf, features):
    values=np.asarray(clf.predict_proba(features))
    if (values.shape!=(len(features),2) or not np.isfinite(values).all()
            or np.any(values<0) or np.any(values>1)):
        raise ValueError('Invalid relative quality classifier probabilities')
    return values[:,1]


def choose(colours, source_features102, baseline_index, model):
    """Return (index, relative-only report), preserving every caller-owned input.

    A=current V2 choice; B=each proposal. q=(p(A,B)+1-p(B,A))/2;
    q[A]=.5. np.argmax selects FIRST ORIGINAL index on exact ties. Accept >=.95,
    otherwise A. No deduplication or special identical-RGB rejection: duplicate
    RGB may have different descriptors; frozen experiment retains those rows.
    """
    validate_model(model)
    x=np.asarray(source_features102,dtype=np.float32)
    rgb=np.asarray(colours)
    if (x.ndim!=2 or x.shape[1]!=SOURCE_FEATURE_COUNT or len(x)==0
            or not np.isfinite(x).all()):raise ValueError('Expected finite nonempty N x 102 source descriptors')
    if (rgb.shape!=(len(x),3) or not np.issubdtype(rgb.dtype,np.number)
            or not np.isfinite(rgb).all() or np.any(rgb<0) or np.any(rgb>255)):
        raise ValueError('Expected aligned N x 3 candidate RGB palette')
    if isinstance(baseline_index,(bool,np.bool_)) or not isinstance(baseline_index,(int,np.integer)) or not 0<=baseline_index<len(x):
        raise ValueError('Invalid V2 baseline candidate index')
    baseline_index=int(baseline_index)
    a=np.repeat(x[baseline_index:baseline_index+1],len(x),axis=0)
    clf=model['classifier']
    forward=_positive(clf,pair_features(a,x)); reverse=_positive(clf,pair_features(x,a))
    relative=(forward+1-reverse)/2
    relative[baseline_index]=.5
    proposal=int(np.argmax(relative)); passed=bool(relative[proposal]>=THRESHOLD)
    chosen=proposal if passed else baseline_index
    report=dict(version=VERSION,classifierVersion=CLASSIFIER,sourceOnly=True,GTAtInference=False,
        baselineIndex=baseline_index,proposalIndex=proposal,chosenIndex=chosen,
        minimumRelativeProbability=THRESHOLD,thresholdPassed=passed,
        changedIndex=chosen!=baseline_index,changedRGB=not np.array_equal(rgb[chosen],rgb[baseline_index]),
        relativeQualityProbability=float(relative[chosen]),
        proposalRelativeQualityProbability=float(relative[proposal]),
        relativeQualityProbabilities=relative.tolist(),
        pairForwardBetterProbabilities=forward.tolist(),pairReverseBetterProbabilities=reverse.tolist(),
        comparator='CURRENT V2 final choice',scoreSemantics='Relative proposal quality; distinct from V2 binary within10 scores',
        tieHandling='First original candidate index; duplicates retained',
        antisymmetry='(p(A,B)+1-p(B,A))/2; current baseline self probability=.5')
    return chosen,report
