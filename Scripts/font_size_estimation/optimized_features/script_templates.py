"""Script-specific physical font matching without transcript identity features."""

import unicodedata, numpy as np
from template_features import template_features
from technical_ocr_metrics import SMALL_KANA


def scripts(text):
    buckets = [[], [], []]
    for c in unicodedata.normalize("NFC", text or ""):
        code = ord(c)
        if c in SMALL_KANA:
            continue
        if 12352 <= code <= 12543 or 65381 <= code <= 65439:
            buckets[0].append(c)
        elif (
            13312 <= code <= 40959 or 63744 <= code <= 64255 or 131072 <= code <= 195103
        ):
            buckets[1].append(c)
        elif code < 592 and (c.isalpha() or c.isdigit()):
            buckets[2].append(c)
    return ["".join(x) for x in buckets]


def script_templates(rgb, bbox, prior, text, paths, ownership):
    return np.concatenate(
        [
            template_features(
                rgb,
                bbox,
                prior,
                value,
                paths,
                refine=True,
                ownership=ownership,
                max_target_side=1600,
                glyph_limit=2,
            )
            for value in scripts(text)
        ]
    )
