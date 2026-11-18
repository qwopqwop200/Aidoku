"""Fresh bounded-source measurements for the accepted font198 prediction graph.

Public integration: ``measure_packets(packets, measurement_spec) -> signals``.
Each packet contains RGB uint8 pixels, bbox (xywh in crop coordinates), prior,
text, predicted ownership, native (156), evidence (291), pageSize (width,height),
sourceGroup and sourceHash. Native/evidence may be omitted and measured here;
fresh CE additionally needs confidence, role and cropOrigin in page coordinates.

Late physical stages require source-predicted ``style`` and optionally
``memberPolygons`` in crop coordinates. Missing style is an explicit error,
never a fabricated all-zero late feature. No page, item or prediction lookup is
performed. Asset packaging is separate from pixel measurement.
"""

import hashlib
import json
from pathlib import Path
import unicodedata
from collections import defaultdict

import cv2
import numpy as np

from estimator import features
from font_metric_features import default_font_paths, font_metric_features
from glyph_body_features import glyph_body_features
from technical_ocr_metrics import technical_metrics
from template_features import template_features

from optimized_features.cadence import cadence_features
from optimized_features.color_bodies import color_bodies
from optimized_features.components import extract as extract_components
from optimized_features.fill_alpha import predicted_fill_alpha
from optimized_features.geometry import geometry_style_features
from optimized_features.masked import masked_features
from optimized_features.paint_area import paint_area, glyph_area
from optimized_features.script_templates import script_templates
from optimized_features.templates import (
    fill_templates,
    joint_templates,
    pose_angle,
    prepare_alpha,
    rotate,
    style_residuals,
    target_slice,
)

FEATURE_VERSION = "font198-source-v1"
SIGNAL_WIDTHS = {
    "native156": 156,
    "CE291": 291,
    "masked65": 180,
    "cadence69": 122,
    "colors100": 128,
    "templates103": 66,
    "templates115": 198,
    "templates131": 66,
    "paint130": 40,
    "templates135": 130,
    "templates143": 130,
    "joint147": 48,
    "joint158": 48,
    "templates167": 66,
    "areas169": 21,
    "style187": 262,
}
ROLES = ("dialogue", "narration", "story_text")

# Names and layouts are a contract with the prediction graph, not stage IDs
# selected from a source identity. Every quantity below is freshly observable.
SIGNAL_DERIVATIONS = {
    "native156": "estimator.features(version=4): target RGB, bbox, source prior",
    "CE291": "146 font metrics +18 OCR counts/confidence +66 legacy templates +3 roles +56 owned glyph body +2 normalized page center",
    "masked65": "180 owned color/component/depth/contour/autocorrelation summaries",
    "cadence69": "122 owned column cadence values; character_count=expm1(CE291[146])",
    "components75": "198 DCT/HOG/aspect/relative-size/color/fill descriptor values per owned connected glyph; sizes in px and batch row indices",
    "neighbors76": "eight cosine TRAIN-prototype neighbors of components75; emPerComponentScale, distance, support",
    "neighbors84": "same query with component descriptor[-5] and [-4:-1] multiplied by3 and renormalized",
    "colors100": "128 source-owned Lab color-cluster body/depth/contour statistics",
    "templates103": "66 native templates: four pinned fonts, four source anchors,1600-side target, refined; early83/87 still construct explicit zero legacy slice",
    "templates115": "198 native templates,66 each for kana/Han/Latin, two source anchors each",
    "geometry128": "X45 paint/oriented member summaries; physical14 widths in px; oriented prior=physical[3]",
    "paint130": "40 values: four log fill-alpha-area em ratios for each of eight fonts, eight diagnostics",
    "templates131": "66 deskewed templates103 when prior/orientedPrior>=1.1 and source members exist; otherwise freshly measured103 fallback",
    "templates135": "130 fill-alpha templates, eight fonts, two anchors; em normalized to original prior",
    "templates143": "130 values, pose-corrected affine refinement of top two135 fonts with score>=.35",
    "joint147": "48 joint distinct-position glyph fits, two143 fonts x two summaries x12 fields, bbox target",
    "joint158": "48 joint147 values remeasured using complete bounded crop iff outsideTargetAlphaFraction>=.01 and alphaMass>10",
    "templates167": "66 complete-crop pose-corrected fill templates with four pinned native fonts",
    "areas169": "21 values: exp(paint130[:4])*sqrt(originalFontGlyphArea/nativeFontGlyphArea) for four native fonts +five coverages",
    "style187": "262 glyph-normalized residuals:255 spatial/moment summaries +support/quality/spread +four-family indicator",
}


def _root(root):
    root = Path(root)
    return (
        root if (root / "round166").is_dir() else root / "font-size-estimation-20261110"
    )


def _font_record(path):
    path = Path(path).resolve()
    return {
        "path": str(path),
        "SHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "faceIndex": 0,
    }


def dependency_paths(root):
    """Only pinned fonts and TRAIN reference banks; no measured row archives."""
    root = _root(root)
    spec_path = root / "round166/FONTS.json"
    fonts = json.loads(spec_path.read_text())["fonts"]
    return [
        spec_path,
        *map(Path, default_font_paths()),
        *sorted((root / "round120/fonts").glob("*.ttf")),
        *(Path(font["path"]) for font in fonts),
        root / "round76/font-reference-bank.npz",
        root / "round84/font-reference-bank.npz",
    ]


def bundle_measurements(root):
    """Build a portable spec containing assets, never source-row measurements.

    Packaging may replace each font record's path with its packaged location;
    bytes must retain the recorded SHA256. Native font order is fixed by166.
    Banks76/84 are fitted TRAIN prototypes, queried solely by glyph descriptor.
    Prototype source exclusions are reconstructed and verified offline using
    source-only metadata. No per-row descriptors are exported in this spec.
    """
    root = _root(root)
    fonts = [_font_record(path) for path in default_font_paths()]
    native_fonts = json.loads((root / "round166/FONTS.json").read_text())["fonts"]
    for record in native_fonts:
        if _font_record(record["path"])["SHA256"] != record["SHA256"]:
            raise ValueError("Native reference font hash differs")
    banks = {}
    for number in (76, 84):
        with np.load(
            root / f"round{number}/font-reference-bank.npz", allow_pickle=False
        ) as data:
            banks[str(number)] = {
                key: data[key].copy()
                for key in ("features", "emPerComponentScale", "support")
            }
        banks[str(number)]["exclusionAvailable"] = True
    extended = fonts + [
        _font_record(path) for path in sorted((root / "round120/fonts").glob("*.ttf"))
    ]
    if len(extended) != 8 or len(native_fonts) != 4:
        raise ValueError("Expected eight extended and four native fonts")
    identities, exclusions = _prototype_provenance(root, banks)
    for number in (76, 84):
        banks[str(number)]["excludedBySourceGroup"] = exclusions[str(number)]
    return {
        "featureVersion": FEATURE_VERSION,
        "fonts": fonts,
        "extendedFonts": extended,
        "nativeFonts": native_fonts,
        "referenceBanks": banks,
        "sourceIdentityGroups": identities,
        "prototypeExclusionAvailable": True,
    }


def _source_identity_rows(document):
    """Project only validated pixel identities; query/annotation labels are ignored."""
    rows = []
    for item in document["items"]:
        identity = {}
        for field in ("sourceImageSHA256", "cropSHA256"):
            value = item[field]
            if (
                not isinstance(value, str)
                or len(value) != 64
                or any(char not in "0123456789abcdef" for char in value)
            ):
                raise ValueError(f"Invalid source provenance {field}")
            identity[field] = value
        rows.append(identity)
    return rows


def _prototype_provenance(root, banks):
    """Offline audit of TRAIN membership and each median prototype's sources."""
    rows = _source_identity_rows(
        json.loads((root / "round35/SOURCE-ONLY-MANIFEST.json").read_text())
    )
    parents = list(range(len(rows)))

    def find(index):
        while parents[index] != index:
            parents[index] = parents[parents[index]]
            index = parents[index]
        return index

    seen = {}
    for index, row in enumerate(rows):
        for field in ("sourceImageSHA256", "cropSHA256"):
            key = field, row[field]
            if key in seen:
                parents[find(index)] = find(seen[key])
            seen[key] = index
    identities = {}
    for index, row in enumerate(rows):
        group = find(index)
        identities[group] = min(
            identities.get(group, row["sourceImageSHA256"]), row["sourceImageSHA256"]
        )
    row_groups = ["g:" + identities[find(index)] for index in range(len(rows))]
    mapping = {
        row["sourceImageSHA256"]: row_groups[index] for index, row in enumerate(rows)
    }
    train = np.array(
        [
            int(hashlib.sha256(identities[find(index)].encode()).hexdigest()[:8], 16)
            % 10
            < 6
            for index in range(len(rows))
        ]
    )
    with np.load(root / "round75/components.npz", allow_pickle=False) as data:
        descriptors, indices, hashes = (
            data[key] for key in ("features", "indices", "hashes")
        )
    if (
        descriptors.ndim != 2
        or descriptors.shape[1] != 198
        or indices.shape != (len(descriptors),)
        or hashes.shape != indices.shape
        or not np.issubdtype(indices.dtype, np.integer)
        or np.any(indices < 0)
        or np.any(indices >= len(rows))
        or not np.isfinite(descriptors).all()
    ):
        raise ValueError("Invalid source provenance component binding")
    selected = np.flatnonzero(train[indices])
    exclusions = {}
    for number in (76, 84):
        desc = descriptors.copy()
        if number == 84:
            desc[:, -5] *= 3
            desc[:, -4:-1] *= 3
            desc /= np.linalg.norm(desc, axis=1)[:, None]
        buckets = defaultdict(list)
        for index in selected:
            color = tuple(np.round(desc[index, -4:-1] * 80).astype(int))
            buckets[(str(hashes[index]), color)].append(index)
        reference = np.asarray(
            [np.median(desc[ids], axis=0) for ids in buckets.values()], np.float32
        )
        reference /= np.linalg.norm(reference, axis=1)[:, None]
        stored = banks[str(number)]["features"]
        if reference.shape != stored.shape or not np.allclose(
            reference, stored, rtol=0, atol=2e-7
        ):
            raise ValueError(f"TRAIN prototype{number} source provenance differs")
        excluded = defaultdict(list)
        for prototype, ids in enumerate(buckets.values()):
            for group in sorted({row_groups[indices[index]] for index in ids}):
                excluded[group].append(prototype)
        exclusions[str(number)] = {
            group: np.asarray(ids, int) for group, ids in excluded.items()
        }
    return mapping, exclusions


def _font_paths(spec, key, count):
    records = spec[key]
    if len(records) != count:
        raise ValueError(f"Expected {count} pinned {key}")
    paths = []
    for record in records:
        if record.get("faceIndex", 0) != 0:
            raise ValueError("Only pinned face zero is supported")
        if _font_record(record["path"])["SHA256"] != record["SHA256"]:
            raise ValueError(f'Font asset hash differs: {record["path"]}')
        paths.append(str(record["path"]))
    return paths


def _validate_packet(packet):
    rgb = np.asarray(packet["rgb"])
    bbox = np.asarray(packet["bbox"], float)
    prior = float(packet["prior"])
    if rgb.dtype != np.uint8 or rgb.ndim != 3 or rgb.shape[2] != 3 or not rgb.size:
        raise ValueError("Expected nonempty RGB uint8 crop")
    if bbox.shape != (4,) or not np.isfinite(bbox).all() or min(bbox[2:]) <= 0:
        raise ValueError("Invalid bbox")
    if not np.isfinite(prior) or prior <= 0:
        raise ValueError("Invalid source prior")
    x, y, w, h = bbox
    # A one-pixel allowance is exclusively for integer crop-bound rounding.
    if x < 0 or y < 0 or x + w > rgb.shape[1] + 1 or y + h > rgb.shape[0] + 1:
        raise ValueError("Target bbox outside source crop")
    margins = np.array([x, rgb.shape[1] - x - w, y, rgb.shape[0] - y - h])
    if np.any(margins > np.array([w, w, h, h]) * 0.15 + 1):
        raise ValueError("Crop exceeds per-side 15% source context")
    own = np.asarray(packet["ownership"])
    if own.shape != rgb.shape[:2] or not np.isin(own, [0, 1, 255]).all():
        raise ValueError("Expected binary predicted ownership aligned to RGB")
    if packet.get("GTMaskUsed", False) or packet.get("inferenceUsesGT", False):
        raise ValueError("Only source-predicted observations are accepted")
    size = np.asarray(packet["pageSize"], float)
    if size.shape != (2,) or not np.isfinite(size).all() or min(size) <= 0:
        raise ValueError("Invalid pageSize")
    if not isinstance(packet.get("text", ""), str):
        raise ValueError("Source OCR text must be a string")
    return rgb, bbox, prior, own > 0


def _given_array(packet, name, width):
    value = packet.get(name)
    if value is None:
        return None
    value = np.asarray(value, float)
    if value.shape != (width,) or not np.isfinite(value).all():
        raise ValueError(f"Invalid source {name} measurements")
    return value.copy()


def _area169(paint, text, reference, fonts):
    chars = [c for c in unicodedata.normalize("NFC", text) if not c.isspace()]
    oldareas = np.array([glyph_area(reference, char) for char in chars])
    oldsum = oldareas.sum()
    values, coverage = [], []
    for font in fonts:
        areas = np.array([glyph_area(font, char) for char in chars])
        total = areas.sum()
        factor = np.sqrt(oldsum / total) if total > 0 and oldsum > 0 else 0.0
        values.extend(np.exp(paint[:4]) * factor)
        coverage.append(float((areas > 0).sum()) / max(1, len(chars)))
    return np.r_[values, coverage, float((oldareas > 0).sum()) / max(1, len(chars))]


def extract_source_measurements(packet, spec, *, font_paths=None):
    """Extract one new packet; never consult source IDs to select measurements."""
    rgb, bbox, prior, own = _validate_packet(packet)
    style = packet.get("style")
    if style is None:
        raise ValueError(
            "Fresh late measurements require source-predicted style; native app path is unsupported without it"
        )
    if style.get("inferenceUsesGT", False) or style.get("sourceOnly") is False:
        raise ValueError("Only source-predicted paint style is accepted")
    if spec.get("featureVersion", FEATURE_VERSION) != FEATURE_VERSION:
        raise ValueError("Unsupported source measurement version")
    fonts, extended, native_fonts = font_paths or (
        _font_paths(spec, "fonts", 4),
        _font_paths(spec, "extendedFonts", 8),
        _font_paths(spec, "nativeFonts", 4),
    )
    text = packet.get("text", "")
    native = _given_array(packet, "native", 156)
    if native is None:
        native = features(rgb, bbox, prior, version=4)
    templates = template_features(
        rgb,
        bbox,
        prior,
        text,
        fonts,
        refine=True,
        ownership=own,
        max_target_side=1600,
        glyph_limit=4,
    )
    evidence = _given_array(packet, "evidence", 291)
    if evidence is None:
        if (
            "cropOrigin" not in packet
            or packet.get("role") not in ROLES
            or "confidence" not in packet
        ):
            raise ValueError("Fresh CE requires cropOrigin, role and confidence")
        origin = np.asarray(packet["cropOrigin"], float)
        if origin.shape != (2,) or not np.isfinite(origin).all():
            raise ValueError("Invalid cropOrigin")
        center = (origin + bbox[:2] + bbox[2:] / 2) / packet["pageSize"]
        # 48 used the then-default 480-side/two-glyph physical template.
        original_template = template_features(
            rgb, bbox, prior, text, fonts, refine=True, ownership=own
        )
        evidence = np.r_[
            font_metric_features(text, native, fonts),
            technical_metrics(text, packet["confidence"], bbox[2:], prior),
            original_template,
            [float(packet["role"] == r) for r in ROLES],
            glyph_body_features(rgb, bbox, prior, own),
            center,
        ]
    result = {
        "native156": native,
        "CE291": evidence,
        "masked65": masked_features(rgb, bbox, prior, own),
        "cadence69": cadence_features(rgb, bbox, prior, own, np.expm1(evidence[146])),
        "colors100": color_bodies(rgb, bbox, prior, own),
        "templates103": templates,
        "templates115": script_templates(rgb, bbox, prior, text, fonts, own),
        "components75": extract_components(rgb, bbox, prior, own),
    }
    polygons = packet.get("memberPolygons")
    if not polygons:
        x, y, w, h = bbox
        polygons = [[[x, y], [x + w, y], [x + w, y + h], [x, y + h]]]
    geometry, physical = geometry_style_features(polygons, style, prior)
    oriented_prior = float(physical[3])
    if not np.isfinite(oriented_prior) or oriented_prior <= 0:
        raise ValueError("Invalid oriented source geometry")
    requested = prior / oriented_prior >= 1.1 and bool(packet.get("memberPolygons"))
    polygon = max(
        polygons,
        key=lambda p: np.max(cv2.minAreaRect(np.asarray(p, np.float32))[1]),
    )
    angle = pose_angle(polygon) if requested else 0.0
    deskewed = templates
    if requested:
        rotated_rgb, rotated_bbox = rotate(rgb, bbox, angle, border=(127, 127, 127))
        rotated_own, _ = rotate(own.astype(np.uint8), bbox, angle, nearest=True)
        deskewed = template_features(
            rotated_rgb,
            rotated_bbox,
            oriented_prior,
            text,
            fonts,
            refine=True,
            ownership=rotated_own > 0,
            max_target_side=1600,
            glyph_limit=4,
        )
    paint = paint_area(rgb, bbox, own, style, text, extended, prior)
    alpha = predicted_fill_alpha(rgb, bbox, own, style)
    local, unit, _ = prepare_alpha(alpha, bbox, oriented_prior)
    fill135 = fill_templates(
        local, unit, prior, oriented_prior, text, extended, fonts[0]
    )
    local, unit, _ = prepare_alpha(alpha, bbox, oriented_prior, angle=angle)
    fill143 = fill_templates(
        local, unit, prior, oriented_prior, text, extended, fonts[0], previous=fill135
    )
    joint147 = joint_templates(
        local, unit, prior, oriented_prior, text, extended, fill143
    )
    mass = float(alpha.sum())
    outside = (
        max(0.0, 1 - float(target_slice(alpha, bbox).sum()) / mass)
        if mass > 1e-6
        else 0.0
    )
    complete, complete_unit, _ = prepare_alpha(
        alpha, bbox, oriented_prior, angle=angle, complete=True
    )
    joint158 = (
        joint_templates(
            complete, complete_unit, prior, oriented_prior, text, extended, fill143
        )
        if outside >= 0.01 and mass > 10
        else joint147.copy()
    )
    native167 = fill_templates(
        complete, complete_unit, prior, oriented_prior, text, native_fonts, fonts[0]
    )
    result.update(
        geometry128={"X": geometry, "physical": physical},
        paint130=paint,
        templates131=deskewed,
        angles131=angle,
        priorRatio131=oriented_prior / prior if requested else 1.0,
        templates135=fill135,
        templates143=fill143,
        joint147=joint147,
        joint158=joint158,
        templates167=native167,
        areas169=_area169(paint, text, fonts[0], native_fonts),
        style187=style_residuals(
            alpha, bbox, angle, text, fonts[0], native_fonts, native167, prior
        ),
    )
    for name, width in SIGNAL_WIDTHS.items():
        value = result[name]
        if value.shape != (width,) or not np.isfinite(value).all():
            raise ValueError(f"Invalid extracted {name} layout")
    return result


def extract(rgb, bbox, prior, text, ownership, page_size, measurement_spec, **metadata):
    """Direct fresh-crop fallback; metadata supplies style and source observations.

    This single-row entrypoint measures pixels only. ``measure_packets`` adds
    TRAIN prototype queries and global component indices for the full graph.
    """
    packet = dict(
        metadata,
        rgb=rgb,
        bbox=bbox,
        prior=prior,
        text=text,
        ownership=ownership,
        pageSize=page_size,
    )
    return extract_source_measurements(packet, measurement_spec)


def _neighbors(
    descriptors, sizes, indices, bank, *, weighted=False, source_groups=None
):
    """Cosine query against packaged TRAIN prototypes, without fitting."""
    query = np.asarray(descriptors, np.float32).copy()
    if weighted and len(query):
        query[:, -5] *= 3
        query[:, -4:-1] *= 3
        query /= np.linalg.norm(query, axis=1)[:, None]
    features = np.asarray(bank["features"], np.float32)
    if features.ndim != 2 or features.shape[1] != 198 or len(features) < 8:
        raise ValueError("Invalid TRAIN prototype reference bank")
    distances = np.empty((len(query), 8), np.float32)
    nearest = np.empty((len(query), 8), int)
    # Bound temporary Qxbank allocation independently of page/component count.
    for start in range(0, len(query), 128):
        q = query[start : start + 128]
        qnorm = q / np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-30)
        fnorm = features / np.maximum(
            np.linalg.norm(features, axis=1, keepdims=True), 1e-30
        )
        distance = np.clip(1 - np.einsum("ik,jk->ij", qnorm, fnorm), 0.0, 2.0)
        if not np.isfinite(distance).all():
            raise ValueError("Invalid prototype cosine distance")
        if source_groups is not None:
            exclusions = bank.get("excludedBySourceGroup", {})
            for offset in range(len(q)):
                group = source_groups[indices[start + offset]]
                if not isinstance(group, str):
                    raise ValueError(
                        "Prototype query source group must be a stable string"
                    )
                excluded = exclusions.get(group, [])
                if len(features) - len(excluded) < 8:
                    raise ValueError("Insufficient independent TRAIN prototypes")
                distance[offset, excluded] = np.inf
        order = np.argsort(distance, axis=1, kind="stable")[:, :8]
        nearest[start : start + len(q)] = order
        distances[start : start + len(q)] = np.take_along_axis(distance, order, axis=1)
    return {
        "indices": np.asarray(indices, int),
        "sizes": np.asarray(sizes, float),
        "distances": distances,
        "ratios": np.asarray(bank["emPerComponentScale"])[nearest],
        "support": np.asarray(bank["support"])[nearest],
    }


def measure_packets(packets, measurement_spec):
    """Batch runtime entrypoint; per-row arrays plus globally indexed components.

    Accepts the direct ``optimizedGraph['measurementSpec']`` value. Fonts are
    hash-verified once per call. Component indices refer to input packet order.
    No feature/prediction/cohort cache is used, even for previously seen hashes.
    """
    spec = measurement_spec
    if not spec.get("prototypeExclusionAvailable", False):
        raise ValueError(
            "Reference banks lack source-exclusion provenance; rebuild measurementSpec"
        )
    packets = list(packets)
    identities = spec.get("sourceIdentityGroups", {})
    source_groups = []
    for packet in packets:
        source_hash = packet.get("sourceHash")
        group = identities.get(source_hash, packet.get("sourceGroup", source_hash))
        if not isinstance(group, str) or not group:
            raise ValueError("A stable string sourceHash/sourceGroup is required")
        source_groups.append(group)
    paths = (
        _font_paths(spec, "fonts", 4),
        _font_paths(spec, "extendedFonts", 8),
        _font_paths(spec, "nativeFonts", 4),
    )
    rows = [
        extract_source_measurements(packet, spec, font_paths=paths)
        for packet in packets
    ]
    result = {
        name: np.asarray([row[name] for row in rows], float).reshape(-1, width)
        for name, width in SIGNAL_WIDTHS.items()
    }
    result["geometry128"] = {
        key: np.asarray([row["geometry128"][key] for row in rows], float).reshape(
            -1, width
        )
        for key, width in [("X", 45), ("physical", 14)]
    }
    for name in ("angles131", "priorRatio131"):
        result[name] = np.asarray([row[name] for row in rows], float)
    descriptors, sizes, indices = [], [], []
    for index, row in enumerate(rows):
        for descriptor, size, _, _ in row["components75"]:
            descriptors.append(descriptor)
            sizes.append(size)
            indices.append(index)
    descriptors = np.asarray(descriptors, np.float32).reshape(-1, 198)
    result["components75"] = {
        "features": descriptors,
        "sizes": np.asarray(sizes, float),
        "indices": np.asarray(indices, int),
    }
    for number in (76, 84):
        result[f"neighbors{number}"] = _neighbors(
            descriptors,
            sizes,
            indices,
            spec["referenceBanks"][str(number)],
            weighted=number == 84,
            source_groups=source_groups,
        )
    result["measurementStatus"] = {
        "freshExtraction": True,
        "featureVersion": FEATURE_VERSION,
        "prototypeExclusionAvailable": bool(
            spec.get("prototypeExclusionAvailable", False)
        ),
        "nativeImplementation": False,
    }
    return result
