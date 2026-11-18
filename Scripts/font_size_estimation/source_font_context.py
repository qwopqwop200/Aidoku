"""In-memory handoff from one fresh source-font call; no weight activation.

Packets/signals/spec retain the actual call objects, not archived row features.
Consumers must preserve their order and keep packet priors distinct from final ems.
Missing word/glyph/RF observations remain missing; paragraph text is not words.
"""
from dataclasses import dataclass
from typing import Any, Mapping, Sequence

import numpy as np


@dataclass(frozen=True)
class SourceFontObservations:
    """Caller-owned original observations, in their original coordinate systems.

    Word members retain their original records (including geometry/provenance).
    Array mappings retain the caller's names and coordinate metadata; no ID-based
    resource resolution or synthetic members are performed by this adapter.
    The weight consumer binds RGB bytes/SHA, sourceSHA256, page cropBounds and
    valid maps before aligning primary/boundary/native and RF27 observations.
    """

    original_word_members: Sequence[Mapping[str, Any]] | None = None
    glyph_arrays: Mapping[str, Any] | None = None
    rf_arrays: Mapping[str, Any] | None = None


def ordered_observations(observations, count):
    if observations is None:
        return (None,) * count
    observations = tuple(observations)
    if len(observations) != count:
        raise ValueError('Source observations must match packet order and count')
    if any(value is not None and not isinstance(value, SourceFontObservations)
           for value in observations):
        raise TypeError('Expected SourceFontObservations or None per packet')
    return observations


@dataclass(frozen=True)
class SourceFontContext:
    """Optional result, separate from receipts and prediction-stage diagnostics.

    ``fresh_font_signals['style187']`` is the fresh (N, 262) residual array;
    ``angles131`` has shape (N,). Neither is a return_stages prediction.
    Empty batches have no measured signals. Crop bounds are page-space LTRB;
    direct packet callers without crop provenance receive None for those bounds.
    Objects are borrowed for handoff and must be treated as read-only by consumers.
    """

    packets: tuple[dict[str, Any], ...]
    original_priors: np.ndarray
    final_source_ems: np.ndarray
    measurement_spec: Mapping[str, Any]
    fresh_font_signals: Mapping[str, Any]
    packet_order: tuple[int, ...]
    crop_bounds: tuple[tuple[int, int, int, int] | None, ...]
    source_observations: tuple[SourceFontObservations | None, ...]


def make_context(packets, priors, values, measurement_spec, signals, observations):
    count = len(packets)
    priors = np.asarray(priors, float).copy()
    values = np.asarray(values, float).copy()
    if priors.shape != (count,) or values.shape != (count,):
        raise ValueError('Source font context batch differs')
    if count:
        for name, shape in [('style187', (count, 262)), ('angles131', (count,))]:
            value = np.asarray(signals[name])
            if value.shape != shape or not np.isfinite(value).all():
                raise ValueError(f'Fresh source font {name} contract differs')
    return SourceFontContext(
        tuple(packets), priors, values, measurement_spec, signals,
        tuple(range(count)),
        tuple(tuple(p['cropBounds']) if 'cropBounds' in p else None for p in packets),
        observations,
    )
