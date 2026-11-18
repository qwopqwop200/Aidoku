"""Apply one calibrated image rule to peers from a single source page."""
import numpy as np

from features import render_policy


def classify_page(observations, predictions, policy):
    if len(observations) != len(predictions):
        raise ValueError('Directional page peer count differs')
    field = policy['direction']
    mode = policy['mode']
    q = policy['quantile']
    value = np.array([r[mode]['groups'][field]['quantiles'][q] for r in observations])
    count = np.array([r[mode]['groups'][field]['count'] for r in observations])
    usable = np.array([r[mode]['components'] >= 2 and r[mode]['groups'][field]['count'] >= 16
                       for r in observations], bool)
    baseline = np.array([r['sourceWeight'] == 'bold' for r in predictions])
    other = np.array([min((g['quantiles'][q] for name, g in r[mode]['groups'].items()
                          if name != field and g['count'] >= 16), default=0.) for r in observations])
    contrast = np.divide(value, other, out=np.zeros(len(value)), where=other > 0)
    controls = value[usable & ~baseline]
    relative = np.zeros(len(value))
    if len(controls) >= 2:
        relative = value/max(1e-6, np.quantile(controls, .25))
    result = (usable & (value >= policy['minimumWidthEm'])
              & (contrast >= policy['minimumDirectionContrast'])
              & (relative >= policy['minimumPageRelative'])
              & (count >= policy['minimumDirectionalRays']))
    score = policy['existingScoreField']
    if score != 'none':
        result &= np.array([r.get(score, 0.) >= policy['minimumExistingScore'] for r in predictions])
    # A mixed source requires aligned translated spans. Preserve the existing
    # whole-translation regular policy rather than forcing the paragraph bold.
    result &= np.array([r['sourceWeight'] == 'regular' for r in predictions])
    return result


def apply_page(observations, predictions, policy):
    added = classify_page(observations, predictions, policy)
    result = []
    for row, promote in zip(predictions, added):
        updated = dict(row, directionalInkRescueApplied=bool(promote))
        if promote:
            updated.update(render_policy('bold'))
        result.append(updated)
    return result


def measure_source_page(packets, ems, policy):
    """Fresh bounded source pixels/styles, no crop-ID or saved feature lookup."""
    import hashlib
    from pathlib import Path
    import directional_ink
    from ink_weight_geometry import clean_fill_style
    from palette_word_pairs import observe_palette

    digest = hashlib.sha256(Path(directional_ink.__file__).read_bytes()).hexdigest()
    if policy.get('measurementSHA256') != digest:
        raise ValueError('Directional rule requires a different measurement implementation')
    if policy['mode'] != 'color':
        raise ValueError('Source runtime requires color-backed directional policy')
    if len(packets) != len(ems):
        raise ValueError('Directional source em count differs')
    observations = []
    for packet, em in zip(packets, ems):
        rgb = np.asarray(packet['rgb'])
        own = np.asarray(packet['ownership'], bool)
        if rgb.shape != (*own.shape, 3) or not np.isfinite(em) or em <= 0:
            raise ValueError('Invalid directional source geometry')
        cleaned = clean_fill_style(packet['style'])
        color, known = (observe_palette(rgb, own, cleaned) if cleaned is not None
                        else (np.zeros(own.shape), own))
        observations.append(dict(color=directional_ink.measure(color*own, known, em)))
    return observations
