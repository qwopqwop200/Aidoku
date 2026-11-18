"""Reuse authenticated existing RF/soft-glyph predictions; never train models."""
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[3]


@lru_cache(maxsize=4)
def runtime_index(path):
    packet = json.loads(Path(path).read_text())
    if packet.get('GTMaskUsed') is not False or packet.get('sourceOnly') is not True:
        raise ValueError('Existing runtime index is not source-only')
    return list(packet['items'].values())


def align_array(values, donor_bounds, target_bounds):
    dl, dt, dr, db = donor_bounds
    tl, tt, tr, tb = target_bounds
    if values.shape[:2] != (db-dt, dr-dl):
        raise ValueError('Existing prediction/source bounds differ')
    result = np.zeros((tb-tt, tr-tl, *values.shape[2:]), values.dtype)
    valid = np.zeros((tb-tt, tr-tl), bool)
    l, t, r, b = max(dl, tl), max(dt, tt), min(dr, tr), min(db, tb)
    if l < r and t < b:
        result[t-tt:b-tt, l-tl:r-tl] = values[t-dt:b-dt, l-dl:r-dl]
        valid[t-tt:b-tt, l-tl:r-tl] = True
    return result, valid


@lru_cache(maxsize=1)
def source_reader():
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'segmentation'))
    from source_boundary_votes import SourceBoundaryVotes
    root = ROOT/'segmentation-improvement-20261109'
    base = root/'boundary-lean'
    data = json.loads((base/'evaluation-manifest.json').read_text())
    # Explicit source whitelist: target/status/GT mask fields never propagate.
    keys = ('id', 'rgb', 'rf', 'width', 'height', 'polygons', 'fontPixels', 'sourceSHA256')
    rows = {r['id']: {k: r[k] for k in keys} for r in data['items']}
    reader = SourceBoundaryVotes(base, root/'deep-classifier-observations',
                                 root/'edge-context60-native', root/'edge-context60-observations')
    return base, rows, reader


def load_existing(row, identity, rgb):
    base, rows, reader = source_reader()
    donor = identity.get('predictionSourceItem')
    if donor not in rows:
        prediction = identity.get('predictionPath')
        if not prediction:
            return None
        prediction = Path(prediction)
        archive = prediction.parent/'evidence.npz'
        if not archive.exists():
            return None
        if hashlib.sha256(prediction.read_bytes()).hexdigest() != identity['predictionSHA256']:
            raise ValueError('Existing source style prediction identity differs')
        records = runtime_index(str(prediction.parents[2]/'INDEX.json'))
        record = next((r for r in records if r['sourceSHA256'] == row['sourceImageSHA256']
                       and r['imageSHA256'] == identity['sourceCropSHA256']), None)
        if record is None:
            raise ValueError('Existing source glyph source binding missing')
        cached_image = Path(record['image'])
        if hashlib.sha256(cached_image.read_bytes()).hexdigest() != record['imageSHA256']:
            raise ValueError('Existing source glyph RGB artifact changed')
        with Image.open(cached_image) as image:
            donor_rgb = np.asarray(image.convert('RGB'))
        aligned_rgb, valid = align_array(donor_rgb, record['cropBounds'], row['cropBounds'])
        if rgb.shape != aligned_rgb.shape or not valid.any() or not np.array_equal(rgb[valid], aligned_rgb[valid]):
            raise ValueError('Existing source glyph pixel alignment differs')
        with np.load(archive, allow_pickle=False) as data:
            if str(data['sourceRGBSHA256'].item()) != record['imageSHA256']:
                raise ValueError('Existing source glyph evidence pixels differ')
            result = dict(primary=data['segPrimary'], boundary=data['segBoundary'], rf=data['rf'].astype(np.float32),
                          rfModelWeightsSHA256=str(data['rfModelWeightsSHA256'].item()))
        shape = donor_rgb.shape[:2]
        if (result['primary'].shape != shape or result['boundary'].shape != shape
                or result['rf'].shape != (*shape, 27)):
            raise ValueError('Existing source glyph cache geometry differs')
        result['native'] = np.fromfile(prediction.parent/'base.u8', np.uint8).reshape(shape)
        for key in ('primary', 'boundary', 'native', 'rf'):
            result[key] = align_array(result[key], record['cropBounds'], row['cropBounds'])[0]
        result.update(valid=valid, donor=prediction.parent.name,
                      sourceSHA256=row['sourceImageSHA256'], GTMaskUsed=False,
                      newModelCreated=False, modelsReinferred=False)
        return result
    source = rows[donor]
    case_path = base/'rf-full/crops'/(donor+'.json')
    case = json.loads(case_path.read_text())
    if source['sourceSHA256'] != row['sourceImageSHA256'] or case['sourceSHA256'] != row['sourceImageSHA256']:
        raise ValueError('Existing glyph predictions refer to another source image')
    if case['pageSize'] != row['pageSize']:
        raise ValueError('Existing glyph/source dimensions differ')
    donor_rgb = np.fromfile(source['rgb'], np.uint8).reshape(source['height'], source['width'], 3)
    aligned_rgb, valid = align_array(donor_rgb, case['cropBounds'], row['cropBounds'])
    if not valid.any() or rgb.shape != aligned_rgb.shape or not np.array_equal(rgb[valid], aligned_rgb[valid]):
        raise ValueError('Existing glyph predictions do not match current crop pixels')
    primary, boundary, native = reader.load(source)
    from prepare_full_rf import load_case_features
    rf = load_case_features(source, base)
    result = {name: align_array(array, case['cropBounds'], row['cropBounds'])[0]
              for name, array in dict(primary=primary, boundary=boundary, native=native, rf=rf).items()}
    result.update(valid=valid, donor=donor, sourceSHA256=row['sourceImageSHA256'],
                  rfModelWeightsSHA256=case['modelWeightsSHA256'], GTMaskUsed=False,
                  newModelCreated=False, modelsReinferred=False)
    return result
