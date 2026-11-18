"""Measure optional OCR/mask evidence bound to source pixels, never translation."""
import hashlib
from functools import lru_cache
from pathlib import Path


@lru_cache(maxsize=4)
def verified_fonts(specification):
    if len(specification)!=4:raise ValueError('Expected four physical reference fonts')
    paths=[]
    for path,expected in specification:
        if not Path(path).is_file():return None
        if hashlib.sha256(Path(path).read_bytes()).hexdigest()!=expected:raise ValueError('Physical reference font identity differs')
        paths.append(path)
    return paths


def measure_evidence(bundle,rgb,bbox,prior,source_text,ownership):
    if not (bundle.get('physicalConsensus') or bundle.get('sourceClustering')) or not source_text or ownership is None:return None
    paths=verified_fonts(tuple((r['path'],r['SHA256']) for r in bundle['physicalReferenceFonts']))
    if paths is None:return None
    try:from template_features import template_features
    except ImportError:return None
    return template_features(rgb,bbox,prior,source_text,paths,refine=True,ownership=ownership)


def predicted_mask(meta,source_hash,source_size):
    if meta.get('GTMaskUsed') is not False or meta.get('predictedMask') is not True:raise ValueError('Only predicted ownership masks are allowed')
    if meta['sourceSHA256']!=source_hash or [meta['width'],meta['height']]!=list(source_size):raise ValueError('Ownership/source identity differs')
    from ownership_features import page_mask
    return page_mask(meta['maskPath'],meta['maskSHA256'],meta['width'],meta['height'])


@lru_cache(maxsize=8)
def source_packet(path,expected_sha,source_hash):
    import json
    raw=Path(path).read_bytes()
    if hashlib.sha256(raw).hexdigest()!=expected_sha:raise ValueError('Source OCR packet identity differs')
    packet=json.loads(raw)
    if hashlib.sha256(Path(packet['image']).read_bytes()).hexdigest()!=source_hash:raise ValueError('OCR/source image identity differs')
    return {r['id']:r.get('source','') for r in packet['regions']}


def row_source_text(row):
    if 'sourceOCR' in row:
        meta=row['sourceOCR'];return source_packet(meta['path'],meta['SHA256'],row['sourceImageSHA256']).get(row['regionID'],'')
    return row.get('sourceText','')
