"""User-reviewed merge GT (split11 v8), read from the unified GT file.

Rebuilds the page entries the merge scorers used to read from
labels/merge-gt-20261023/dataset-split11-20261024-v8.json. Excluded pages are not in the
unified file; both scorers skipped them anyway.
"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))  # tools dir
from workspace import GT  # noqa: E402
import json
from functools import lru_cache

UNIFIED = str(GT)
DATASET = 'merge-gt-current-user-split11-20261024-v8'
SOURCE = 'source:7eae90882f994a87f88272a6d5c4b551c7dbdddb8f68f35352600b8c850a6bc1'


@lru_cache(maxsize=1)
def load():
    """Returns {'review_pages': [...], 'pages': [{page, status, width, height, regions, ...}]}."""
    with open(UNIFIED) as f:
        data = json.load(f)
    source = next(s for s in data['sources'] if s['source_id'] == SOURCE)
    review_pages = source['evidence'][0]['root_metadata']['review_pages']
    pages = []
    for r in data['records']:
        if r.get('dataset_id') != DATASET or r['scope'] != 'historical_accepted_partition':
            continue
        label = r['label']
        page = {
            'page': r['page_id'],
            'status': label['source_page_status'],
            'width': r['page_size'][0],
            'height': r['page_size'][1],
            'regions': label['source_observation_context']['regions'],
            'gt_partition': label['gt_partition'],
            'merge_groups': label['merge_groups'],
        }
        for key in ('evaluation_region_ids', 'excluded_regions'):
            if key in label:
                page[key] = label[key]
        pages.append(page)
    pages.sort(key=lambda p: p['page'])
    return {'review_pages': review_pages, 'pages': pages}
