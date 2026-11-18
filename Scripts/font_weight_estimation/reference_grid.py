"""Render reference weights on one family frame with common baselines.

Face selection and subsequent stem comparison must preserve the SAME origins,
advances and union bounds. Otherwise an independently cropped700face supplies a
scale for a differently cropped400/900pair, which changes the measured width.
"""
from functools import lru_cache
import math

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageChops

from word_pairs import font, key, supported, VERTICAL_ROTATE

EM = 128


def record(k):
    return dict(path=k[0], SHA256=k[1], weight=k[2])


@lru_cache(maxsize=128)
def _masks(regular, heavy, frame_regular, frame_heavy, text, vertical, tracking):
    records = [record(k) for k in (regular, heavy, frame_regular, frame_heavy)]
    if any(ord(c) not in supported(r['path'], r['SHA256']) for c in text for r in records):
        return None
    faces = [font(r) for r in records]
    if vertical:
        shape = (3*EM, math.ceil((len(text)+2)*EM*tracking))
        images = [Image.new('L', shape) for _ in faces]
        for face, image in zip(faces, images):
            for i, char in enumerate(text):
                cell = Image.new('L', (EM*3, EM*3))
                ImageDraw.Draw(cell).text((1.5*EM, 1.8*EM), char, font=face, fill=255, anchor='ms')
                raster = np.asarray(cell)
                if char in VERTICAL_ROTATE:
                    raster = cv2.rotate(raster, cv2.ROTATE_90_CLOCKWISE)
                # Same em cell for every face. Preserve its bearings rather
                # than recentering each face's independently cropped glyph.
                y = round(EM*tracking*(i+1)-EM)
                overlay = Image.new('L', shape)
                overlay.paste(Image.fromarray(raster), (0, y))
                image.paste(ImageChops.lighter(image, overlay))
    else:
        advances = [max(f.getlength(c) for f in faces[2:])*tracking for c in text]
        width = math.ceil(sum(advances)+2*EM)
        images = [Image.new('L', (width, 3*EM)) for _ in faces]
        for face, image in zip(faces, images):
            draw = ImageDraw.Draw(image)
            x = float(EM)
            for char, advance in zip(text, advances):
                draw.text((x, 1.5*EM), char, font=face, fill=255, anchor='ls')
                x += advance
    rasters = [np.asarray(image) for image in images]
    yy, xx = np.nonzero((rasters[2] > 0) | (rasters[3] > 0))
    if not len(xx):
        return None
    bounds = (slice(yy.min(), yy.max()+1), slice(xx.min(), xx.max()+1))
    return tuple(np.asarray(r[bounds], np.float32)/255 for r in rasters[:2])


def masks(pair, text, vertical=False, tracking=1.):
    frame = pair.get('_frame', pair)
    return _masks(key(pair['regular']), key(pair['heavy']), key(frame['regular']),
                  key(frame['heavy']), text, bool(vertical), float(tracking))
