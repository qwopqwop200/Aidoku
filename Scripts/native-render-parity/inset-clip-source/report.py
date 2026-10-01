#!/usr/bin/env python3
"""Read-only pinned source provenance; no renderer or pixel-equivalence assertion."""
from pathlib import Path
import hashlib, json
ROOT = Path(__file__).resolve().parents[3]
COMMIT = "dd5fe1011df7e3438ac4889356abcab7681df46d"
CACHE = ROOT / "build/native-render-parity/inset-clip-source/primary-source"
FILES = {
    "StyleInsetFunction.cpp": "style/values/shapes/StyleInsetFunction.cpp",
    "StylePrimitiveNumeric.h": "style/values/primitives/StylePrimitiveNumeric.h",
    "StylePrimitiveNumericTypes+Evaluation.h": "style/values/primitives/StylePrimitiveNumericTypes+Evaluation.h",
    "StylePrimitiveNumericTypes+Conversions.cpp": "style/values/primitives/StylePrimitiveNumericTypes+Conversions.cpp",
    "StylePrimitiveNumericTypes+Conversions.h": "style/values/primitives/StylePrimitiveNumericTypes+Conversions.h",
    "CSSPropertyParserConsumer+Shapes.cpp": "css/parser/CSSPropertyParserConsumer+Shapes.cpp",
    "RenderLayerModelObject.cpp": "rendering/RenderLayerModelObject.cpp",
    "RenderLayer.cpp": "rendering/RenderLayer.cpp",
    "LayoutRect.h": "platform/graphics/LayoutRect.h",
    "LayoutPoint.h": "platform/graphics/LayoutPoint.h",
    "LayoutUnit.h": "platform/LayoutUnit.h",
    "PathImpl.cpp": "platform/graphics/PathImpl.cpp",
}
def digest(path):
    data = path.read_bytes()
    return {"file": str(path.relative_to(ROOT)), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
checks = {
    "painting_offset_snapped_before_reference": ("RenderLayer.cpp", "LayoutSize paintingOffsetFromRoot = LayoutSize(snapSizeToDevicePixel(offsetFromRoot + paintingInfo.subpixelOffset, LayoutPoint(), renderer().document().deviceScaleFactor()))"),
    "local_reference_moved_by_snapped_offset": ("RenderLayer.cpp", "referenceBoxRect.move(offsetFromRoot)"),
    "percentage_double_literal": ("StylePrimitiveNumericTypes+Evaluation.h", "static_cast<Reference>(percentage.value) / 100.0 * referenceLength"),
    "rect_left_associative_width": ("StyleInsetFunction.cpp", "boundingSize.width() - left - evaluate(value.insets.right(), boundingSize.width())"),
    "prefer_bezier": ("StyleInsetFunction.cpp", "PathRoundedRect::Strategy::PreferBezier"),
    "float_box_to_layout_box": ("RenderLayerModelObject.cpp", "snapRectToDevicePixels(LayoutRect { rect }, renderer.document().deviceScaleFactor())"),
    "fractional_size_rounding": ("LayoutPoint.h", "roundToDevicePixel(fraction + a, pixelSnappingFactor) - roundToDevicePixel(fraction, pixelSnappingFactor)"),
    "negative_halfway_translation": ("LayoutUnit.h", "unsigned translateOrigin = WTF::negate(value.rawValue())"),
    "float_path_corner": ("PathImpl.cpp", "PathLineTo { FloatPoint(rect.maxX() - topRightRadius.width(), rect.y()) }"),
}
for name, (filename, needle) in checks.items():
    if needle not in (CACHE / filename).read_text():
        raise SystemExit("Pinned source check failed: " + name)
sources = []
for filename, path in FILES.items():
    sources.append({**digest(CACHE / filename), "url": f"https://github.com/WebKit/WebKit/blob/{COMMIT}/Source/WebCore/{path}"})
report = {
    "commit": COMMIT,
    "status": "source-equations-only; external helper parsed; no pixel-equivalence claim",
    "source_checks": {key: True for key in checks},
    "sources": sources,
    "external_artifacts": [digest(Path(__file__).resolve().parent / name) for name in ("README.md", "NativeInsetClip.staged.swift")],
    "supported": ["simple canonical px at zoom 1", "simple percent with Float reference dimensions", "zero-radius PreferBezier path", "ordinary HTML already-snapped reference box supplied by caller (snapped paint offset then local-box move then reference snapping)"],
    "unsupported": ["calc", "font-relative units", "non-default zoom", "round radii", "SVG snapping exceptions", "extreme saturated values", "vertical writing/reference-box changes", "unobserved live compositor behavior"],
    "equations": {
        "percent": "Float((Double(Float(p)) / 100.0) * Double(referenceFloat))",
        "x": "Float(left + snappedX)", "y": "Float(top + snappedY)",
        "width": "max(Float(Float(snappedWidth - left) - right), 0)",
        "height": "max(Float(Float(snappedHeight - top) - bottom), 0)",
        "zero_radius_path": "Float M(x,y), L(x+w,y), L(x+w,y+h), L(x,y+h), L(x,y), close",
    },
}
output = ROOT / "build/native-render-parity/inset-clip-source/source-report.json"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"report": str(output.relative_to(ROOT)), "source_checks": len(checks), "pinned_source_files": len(sources), "status": report["status"]}))
