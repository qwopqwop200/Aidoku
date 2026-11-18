"""Load the accepted frozen weight bytes and resolve identical font assets."""
import gzip
import hashlib
import json
from pathlib import Path
import pickle

ACCEPTED_SHA256 = 'fc68d62720f2b874d9af46d5e525efebcbb388ec45b24feb503f3a1005e756fc'


def load_accepted_model(path=None):
    if path is None:
        selection = Path(__file__).with_name('ACTIVE-ESTIMATOR.json')
        record = json.loads(selection.read_text())
        path = (selection.parent/record['model']).resolve()
        if hashlib.sha256(path.read_bytes()).hexdigest() != record['modelSHA256']:
            raise ValueError('Active source weight model bytes differ')
    path = Path(path)
    raw = path.read_bytes()
    if path.suffix == '.gz':
        raw = gzip.decompress(raw)
    if hashlib.sha256(raw).hexdigest() != ACCEPTED_SHA256:
        raise ValueError('Source weight model is not the accepted frozen candidate')
    model = pickle.loads(raw)
    fonts = Path(__file__).resolve().parents[2]/'Aidoku/Resources/Translation/SourceReferenceFonts.bundle/fonts'
    def resolve(value):
        if isinstance(value, dict):
            if {'path', 'SHA256'} <= value.keys():
                candidates = list(fonts.glob(value['SHA256']+'.*'))
                target = candidates[0] if len(candidates) == 1 else Path(value['path'])
                if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != value['SHA256']:
                    raise ValueError('Accepted source weight font asset differs')
                value['path'] = str(target)
            for child in value.values():
                resolve(child)
        elif isinstance(value, (list, tuple)):
            for child in value:
                resolve(child)
    resolve(model)
    return model, dict(path=str(path.resolve()), sourceModelSHA256=ACCEPTED_SHA256,
                       storedSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
                       modelTrainingPerformed=False, existingLearnedWeightsChanged=False)
