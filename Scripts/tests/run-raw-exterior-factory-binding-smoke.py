#!/usr/bin/env python3
"""Focused R118 adapter regression; parent runs compilation after shared edits settle.

--source-only performs no build. Default compiles the production width helper
and real NativeTextSpacing in a private temporary directory. Synthetic geometry
only: no images, corpus, models, runtime flags, or production build caches.
This does not execute the complete painter or establish production parity.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Aidoku/Core/Translation/NativeEngine/Ensemble"


def function(source, name):
    start = source.index("    private static func " + name + "(")
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-only", action="store_true")
    args = parser.parse_args()
    source = (ENGINE / "NativeAOTRawTextPainter.swift").read_text()
    exterior_name = ("finalExteriorReadabilityAttempt" if "private static func finalExteriorReadabilityAttempt(" in source
                     else "finalExteriorReadability")
    exterior = function(source, exterior_name)
    raster = function(source, "renderPrimitives")
    wrapper = function(source, "renderAttempt")
    make = exterior.split("},make:{id,width,frame in", 1)[1].split("var metadata=layer.audit", 1)[0]
    assert "retainedExteriorContentWidth(outerWidth:b[2],font:fill.fontOutputPixels" in exterior
    assert "content[item.id]=width" in exterior
    assert "current:width" in exterior
    assert "let outer=width+2*inset" in make
    assert make.count("try renderPrimitives(") == 1 and "renderAttempt(" not in make
    assert "let row=attempt.audit.first" in make
    assert "var fill=old;fill.image=painted.image;fill.frame=painted.frame" in make
    assert "terminalExteriorContentWidth:width,terminalExteriorFont:old.fontOutputPixels" in make
    assert "retainedPitch:pitch" in make and "allowShrink:false" in make
    for forbidden in ("mandatoryStrokeLayer(", "paintAdmitted(", "NativeFinalTextPaintAdmission.place(",
                      "refineFinalReadability("):
        assert forbidden not in raster, forbidden
    assert raster.count("try Task.checkCancellation()") >= 2
    assert wrapper.count("try renderPrimitives(") == 1
    assert wrapper.count("mandatoryStrokeLayer(") == 1
    assert "admittedOverride:(reflow.fills,reflow.audit),forceRepaint:true" in exterior
    assert "exteriorFinalOutputPaletteVerified" in exterior
    assert "if error is CancellationError {throw error}" in exterior
    assert "retained-pre-exterior-layer" in exterior
    print("PASS source contracts: content binding, raw factory isolation, retained state, final paint/rollback/cancel")
    if args.source_only:
        print("NOT RUN: Swift compilation, numeric helper execution, production painter replay")
        return
    helper = function(source, "retainedExteriorContentWidth")
    harness = '''import Foundation
import CoreGraphics
import CoreText
struct Probe {
''' + helper + '''
    static func run() {
        let raw:[String:Any] = ["ensembleStrokeRatio":0.1]
        precondition(retainedExteriorContentWidth(outerWidth:143,font:50,raw:raw) == 111)
        // Compare the adapter's result to the actual shaping content rect,
        // including reservation from observed multilayer source outlines.
        let layered:[String:Any] = ["ensembleStrokeRatio":0.1,"sourceFontSize":25,
            "sourceAppearance":["outline":["present":true,"observedLayers":[["widthPx":2],["widthPx":1]]]]]
        for style in [raw,layered] {
            for font:CGFloat in [10,50,100] {
                for outer:CGFloat in [143,300,700] {
                    let inset=NativeTextSpacing.outwardExtent(raw:style,fontSize:font)+NativeTextSpacing.padding(fontSize:font)
                    let rect=NativeTextSpacing.contentRect(CGRect(x:0,y:0,width:outer,height:1000),
                        fontSize:font,outwardExtent:NativeTextSpacing.outwardExtent(raw:style,fontSize:font))!
                    let width=retainedExteriorContentWidth(outerWidth:outer,font:font,raw:style)!
                    precondition(abs(width-rect.width)<0.000001)
                    precondition(abs(width+2*inset-outer)<0.000001)
                }
            }
        }
        for outer:CGFloat in [0,32,-1,.infinity,.nan] {
            precondition(retainedExteriorContentWidth(outerWidth:outer,font:50,raw:raw) == nil)
        }
        for font:CGFloat in [0,-1,.infinity,.nan] {
            precondition(retainedExteriorContentWidth(outerWidth:143,font:font,raw:raw) == nil)
        }
        print("PASS real spacing/content width round trip, source outline reservations, invalid inputs")
    }
}
Probe.run()
'''
    with tempfile.TemporaryDirectory(prefix="r118-binding-") as tmp:
        tmp = Path(tmp)
        main_swift = tmp / "main.swift"
        main_swift.write_text(harness)
        binary = tmp / "smoke"
        subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(tmp / "modules"),
                        str(ENGINE / "NativeTextSpacing.swift"), str(main_swift), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
