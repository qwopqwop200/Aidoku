"""Reconcile existing segmentation with directly observed source paint."""
import numpy as np

from ink_weight_geometry import clean_fill_style
from palette_word_pairs import observe_palette
from segmented_ink_geometry import reconstruct as reconstruct_baseline


def reconstruct(rgb, ownership, style, evidence, cutoff=.5, em=None):
    alpha, valid, audit = reconstruct_baseline(rgb, ownership, style, evidence, cutoff, em,
                                               maximum_component_em=None)
    cleaned = clean_fill_style(style)
    if cleaned is None:
        return alpha, valid, audit
    color, known = observe_palette(rgb, ownership, cleaned)
    # Segmentation is uncertain about a boundary; a reliable direct paint
    # observation is stronger evidence there. Do not inflate a known background
    # pixel into a full opaque stroke merely because its mask probability is high.
    foreground = color*ownership
    corrected = np.where(known, foreground, alpha).astype(np.float32)
    return corrected, valid | known, dict(audit,
        suppressedKnownBackgroundPixels=int(((alpha > .5) & known & (foreground <= .25)).sum()),
        directColorOverridesSegmentation=True, longConnectedGlyphsRetained=True)
