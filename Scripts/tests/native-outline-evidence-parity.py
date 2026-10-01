#!/usr/bin/env python3
"""Exact frozen source ring/core/surface and enclosed-filament evidence comparison."""
from __future__ import annotations
import argparse
import json
import math
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay"
FIXTURES = ROOT / "Scripts/tests/fixtures/native-outline-evidence"
REFERENCE = ROOT / "Scripts/native-render-parity/reference-source"


def fixtures():
    output=[]
    for index,(name,core,outline,background) in enumerate([
            ("black-on-paper",[12,12,12],[250,250,250],[250,250,250]),
            ("purple-outline",[250,250,250],[80,20,120],[190,185,170]),
            ("gold-outline",[250,210,90],[60,30,0],[230,220,200]),
            ("white-on-dark",[250,250,250],[10,10,10],[10,10,10]),
            ("black-white-halo",[12,12,12],[250,250,250],[12,12,12]),
            ("thin-neutral-ramp",[95,95,95],[250,250,250],[250,250,250]),
            ("enclosed-chromatic",[250,250,250],[80,20,120],[250,250,250]),
            ("enclosed-neutral",[250,250,250],[15,15,15],[250,250,250]),
            ("hollow-counter",[250,250,250],[90,15,130],[250,250,250]),
            ("gradient-art",[220,205,70],[10,10,10],[200,190,150]),
            ("connected-art",[12,12,12],[250,250,250],[150,150,150]),
            ("solid-no-letters",[250,250,250],[20,20,20],[250,250,250])]):
        w,h=94,72; rgba=(background+[255])*(w*h)
        def paint(x,y,width,height,rgb):
            for yy in range(max(0,y),min(h,y+height)):
                for xx in range(max(0,x),min(w,x+width)):
                    rgba[(yy*w+xx)*4:(yy*w+xx)*4+3]=rgb
        if name=="gradient-art":
            for y in range(h):
                for x in range(w): paint(x,y,1,1,[160+x//2,140+y//2,110+(x+y)//4])
        for glyph in range(4 if name.startswith("enclosed") else 3):
            x,y=14+glyph*19,25
            if name.startswith("enclosed"):
                paint(x-2,y-2,7,18,outline);paint(x,y,3,14,core)
            elif name=="hollow-counter":
                paint(x-2,y-2,12,15,outline);paint(x,y,8,11,core)
            elif name!="solid-no-letters":
                strokes=[(x,y,2,16),(x,y,12,2),(x,y+7,10,2),(x,y+14,12,2)]
                for sx,sy,sw,sh in strokes: paint(sx-2,sy-2,sw+4,sh+4,outline)
                for sx,sy,sw,sh in strokes: paint(sx,sy,sw,sh,core)
        if name=="connected-art": paint(5,5,30,27,core)
        output.append(dict(name=name,width=w,height=h,rgba=rgba,box=[10,20,86,46],glyph=20,candidates=[core,outline,background],ink=outline,neutral=name=="enclosed-neutral"))
    return output


def same(a,b):
    if isinstance(a,(float,int)) and isinstance(b,(float,int)):return math.isclose(a,b,rel_tol=0,abs_tol=1e-9)
    if isinstance(a,dict) and isinstance(b,dict):return a.keys()==b.keys() and all(same(a[k],b[k]) for k in a)
    if isinstance(a,list) and isinstance(b,list):return len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
    return a==b


def run(directory,reference):
    directory.mkdir(parents=True,exist_ok=True);inputs=directory/"input.json";inputs.write_text(json.dumps(fixtures()))
    source=directory/"main.swift";shutil.copyfile(FIXTURES/"main.swift",source);executable=directory/"native-outline"
    subprocess.run(["xcrun","swiftc",str(OVERLAY/"NativeSourceOutlineEvidence.swift"),str(source),"-o",str(executable)],check=True)
    native,browser=directory/"native.json",directory/"browser.json"
    subprocess.run([str(executable),str(inputs),str(native)],check=True)
    subprocess.run(["node",str(FIXTURES/"oracle.cjs"),str(inputs),str(reference),str(browser)],check=True)
    actual,expected=json.loads(native.read_text()),json.loads(browser.read_text());differences=[]
    for a,b in zip(actual,expected,strict=True):
        fields=[k for k in a if not same(a[k],b[k])];print(f"{a['name']}: {'DIFFERENT '+', '.join(fields) if fields else 'EXACT'}, ring={a['ring'] is not None}, enclosed={a['enclosed'] is not None}")
        if fields:differences.append(dict(name=a["name"],fields=fields))
    positive=any(a["ring"] for a in actual) and all(next(a for a in actual if a["name"]==n)["enclosed"] for n in ["enclosed-chromatic","enclosed-neutral"])
    report=dict(exact=not differences and positive,fixtures=len(actual),positive=positive,differences=differences)
    (directory/"report.json").write_text(json.dumps(report,indent=2)+"\n")
    if not report["exact"]:raise SystemExit("Outline evidence parity failed; inspect saved output.")


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--reference-overlay",type=pathlib.Path,default=REFERENCE);parser.add_argument("--output-dir",type=pathlib.Path);a=parser.parse_args()
    if a.output_dir:run(a.output_dir.resolve(),a.reference_overlay.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="aidoku-native-outline-") as d:run(pathlib.Path(d),a.reference_overlay.resolve())


if __name__=="__main__":main()
