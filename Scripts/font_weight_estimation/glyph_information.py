"""Reference contour evidence, without lexical features or character-ID rules."""
from functools import lru_cache
import unicodedata

import cv2
import numpy as np

from native_pairs import glyph
from word_pairs import supported


@lru_cache(maxsize=4096)
def perimeter(path, digest, weight, char):
    if unicodedata.category(char)[0] not in 'LN' or ord(char) not in supported(path, digest):
        return 0.
    raster = glyph(dict(path=path, SHA256=digest, weight=weight), char)
    if raster is None:
        return 0.
    contours, _ = cv2.findContours((raster > 127).astype('uint8'), cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    return sum(cv2.arcLength(c, True) for c in contours)/128


def count(members, font, minimum_perimeter):
    if len(members) > 6:
        members = [members[i] for i in np.linspace(0, len(members)-1, 6).astype(int)]
    total, accepted = 0, []
    for member in members:
        x, y, w, h = member['bbox']
        if w <= 0 or h <= 0:
            continue
        duplicate = False
        for a, b, c, d in accepted:
            overlap = max(0., min(x+w, a+c)-max(x, a))*max(0., min(y+h, b+d)-max(y, b))
            if overlap/max(1e-6, min(w*h, c*d)) >= .8:
                duplicate = True
                break
        if duplicate:
            continue
        accepted.append((x, y, w, h))
        for char in unicodedata.normalize('NFC', member.get('text', '')):
            total += perimeter(font['path'], font['SHA256'], font.get('weight'), char) >= minimum_perimeter
    return int(total)
