"""Source fill, pose, and reference-glyph measurements in original em units."""

import unicodedata

import cv2
import numpy as np

from font_metric_features import glyph_measurement
from template_features import glyph_bitmap, best_template_match, refine_template_match

from .glyph_residuals import glyph_style
from .joint_glyphs import joint_glyphs

SMALL_KANA = frozenset("ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ")
SCALES = (0.4, 0.55, 0.7, 0.85, 1.0, 1.15, 1.3, 1.5)


def target_slice(array, bbox):
    x, y, w, h = bbox
    return array[
        max(0, int(y)) : min(array.shape[0], int(np.ceil(y + h))),
        max(0, int(x)) : min(array.shape[1], int(np.ceil(x + w))),
    ]


def pose_angle(polygon):
    vertices = cv2.boxPoints(cv2.minAreaRect(np.asarray(polygon, np.float32)))
    edges = np.roll(vertices, -1, axis=0) - vertices
    edge = edges[np.argmax(np.linalg.norm(edges, axis=1))]
    angle = np.degrees(np.arctan2(edge[1], edge[0]))
    return float((angle + 45) % 90 - 45)


def rotate(array, bbox, angle, *, nearest=False, border=0):
    """Rigid rotation within existing observations; no additional source pixels."""
    h, w = array.shape[:2]
    matrix = cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1.0)
    cosine, sine = abs(matrix[0, 0]), abs(matrix[0, 1])
    nw, nh = int(np.ceil(w * cosine + h * sine)), int(np.ceil(h * cosine + w * sine))
    matrix[0, 2] += (nw - w) / 2
    matrix[1, 2] += (nh - h) / 2
    flags = cv2.INTER_NEAREST if nearest else cv2.INTER_LINEAR
    value = cv2.warpAffine(array, matrix, (nw, nh), flags=flags, borderValue=border)
    x, y, bw, bh = bbox
    corners = np.array([[x, y], [x + bw, y], [x + bw, y + bh], [x, y + bh]])
    points = corners @ matrix[:, :2].T + matrix[:, 2]
    lo, hi = points.min(axis=0), points.max(axis=0)
    return value, np.r_[lo, hi - lo]


def prepare_alpha(alpha, bbox, prior, *, angle=0.0, complete=False):
    if abs(angle) > 0.1:
        alpha, bbox = rotate(alpha, bbox, angle)
    if not complete:
        alpha = target_slice(alpha, bbox)
    scale = min(1.0, 1600 / max(alpha.shape))
    if scale < 1:
        alpha = cv2.resize(
            alpha, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA
        )
    return alpha, prior * scale, scale


def anchor_chars(text, reference, limit=2, *, exclude_small=False):
    chars = []
    for char in sorted(set(unicodedata.normalize("NFC", text or ""))):
        if char.isspace() or unicodedata.category(char)[0] in "MCPZS":
            continue
        if exclude_small and char in SMALL_KANA:
            continue
        dims = glyph_measurement(reference, char)
        if dims is not None and dims[4] > 0.05:
            chars.append((dims[4], char))
    return [char for _, char in sorted(chars, key=lambda p: (-p[0], p[1]))[:limit]]


def fill_templates(
    alpha,
    unit,
    original_prior,
    oriented_prior,
    text,
    fonts,
    reference,
    *,
    previous=None
):
    """135/143/167 layouts: 16 values per font and two source support scalars."""
    chars = anchor_chars(text, reference)
    old = (
        None
        if previous is None
        else np.asarray(previous)[: len(fonts) * 16].reshape(-1, 16)
    )
    selected = None if old is None else np.argsort(-old[:, 13])[:2]
    values = []
    for index, font in enumerate(fonts):
        if old is not None and (index not in selected or old[index, 13] < 0.35):
            values.extend(old[index])
            continue
        observations = []
        for char in chars:
            bitmap = glyph_bitmap(font, char)
            if bitmap is None:
                continue
            matches = []
            for factor in SCALES:
                match = best_template_match(alpha, bitmap, unit, factor)
                if match is not None and match[0] >= 0:
                    matches.append((match[0], factor, match[1], match[2]))
            if not matches:
                continue
            coarse = max(matches, key=lambda match: match[0])
            score, factor, margin = refine_template_match(
                alpha, bitmap, unit, coarse, affine=old is not None
            )
            observations.append(
                (
                    factor * oriented_prior / original_prior,
                    score,
                    margin,
                    float(factor <= 0.4 or factor >= 1.5),
                )
            )
        if not observations:
            values.extend([0.0] * 16)
            continue
        observations = np.asarray(observations)
        values.extend(np.quantile(observations, [0, 0.5, 1], axis=0).T.ravel())
        values.extend(observations[np.argmax(observations[:, 1])])
    return np.r_[values, float(bool(chars)), len(chars) / 2]


def joint_templates(alpha, unit, prior, oriented_prior, text, fonts, previous):
    chars = anchor_chars(text, fonts[0], 4, exclude_small=True)
    old = np.asarray(previous)[:128].reshape(8, 16)
    indices = np.argsort(-old[:, 13])[:2]
    factors = old[:, 12] * prior / oriented_prior
    value = joint_glyphs(alpha, chars, fonts, indices, unit, factors)
    value = value.reshape(2, 2, 12)
    value[:, :, [0, 1, 5, 6, 7]] *= oriented_prior / prior
    return value.ravel()


def style_residuals(alpha, bbox, angle, text, reference, fonts, native, prior):
    observed = np.ones(alpha.shape, np.uint8)
    if abs(angle) > 0.1:
        alpha, _ = rotate(alpha, bbox, angle)
        observed, _ = rotate(observed, bbox, angle, nearest=True)
    scale = min(1.0, 1600 / max(alpha.shape))
    if scale < 1:
        alpha = cv2.resize(
            alpha, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA
        )
        observed = cv2.resize(
            observed, (alpha.shape[1], alpha.shape[0]), interpolation=cv2.INTER_NEAREST
        )
    template = np.asarray(native)[:64].reshape(4, 16)
    index = int(np.argmax(template[:, 13]))
    em = float(template[index, 1] * prior * scale)
    chars = anchor_chars(text, reference, 4, exclude_small=True)
    value = (
        glyph_style(alpha, observed > 0, chars, fonts[index], em)
        if em >= 2 and template[index, 13] > 0.2
        else np.zeros(258)
    )
    return np.r_[value, np.eye(4)[index] if value[-3] > 0 else np.zeros(4)]
