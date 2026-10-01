"""Read-only analysis of an immutable actual-iOS Han capture.

Translations here are diagnostic controls, never replacement gate artifacts or
production corrections. Run with the bundled Python containing pypdf and Pillow.
"""
from pathlib import Path
import argparse
import hashlib
import json
from PIL import Image, ImageChops
from pypdf import PdfReader
from pypdf.generic import ContentStream

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument("--snapshot", type=Path, default=ROOT / "build/native-render-parity/verify-han-build41-snapshot")
parser.add_argument("--output", type=Path, default=ROOT / "build/native-render-parity/han-ios-position-proof")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def multiply(left, right):
    a, b, c, d, e, f = left
    A, B, C, D, E, F = right
    return [a*A+c*B, b*A+d*B, a*C+c*D, b*C+d*D, a*E+c*F+e, b*E+d*F+f]

IDENTITY = [1, 0, 0, 1, 0, 0]

def pdf(path):
    reader = PdfReader(path)
    page = reader.pages[0]
    resources = page["/Resources"]["/Font"]
    fonts = {}
    for key, ref in resources.items():
        font = ref.get_object()
        desc = font["/FontDescriptor"]
        payload_key = next(key for key in ("/FontFile", "/FontFile2", "/FontFile3") if key in desc)
        payload = desc[payload_key].get_data()
        cmap = font["/ToUnicode"].get_data()
        fonts[str(key)] = dict(name=str(font["/BaseFont"]), subtype=str(font["/Subtype"]),
            payloadKey=payload_key, payloadBytes=len(payload), payloadSHA256=sha(payload),
            toUnicodeSHA256=sha(cmap), toUnicode=cmap.decode())
    ctm = IDENTITY[:]
    stack = []
    tm = IDENTITY[:]
    font_key = None
    size = None
    glyphs = []
    for operands, operator in ContentStream(page["/Contents"], reader).operations:
        if operator == b"q":
            stack.append(ctm[:])
        elif operator == b"Q":
            ctm = stack.pop()
        elif operator == b"cm":
            ctm = multiply(ctm, list(map(float, operands)))
        elif operator == b"BT":
            tm = IDENTITY[:]
        elif operator == b"Tm":
            tm = list(map(float, operands))
        elif operator == b"Td":
            tm = multiply(tm, [1, 0, 0, 1, *map(float, operands)])
        elif operator == b"Tf":
            font_key, size = str(operands[0]), float(operands[1])
        elif operator == b"Tj":
            value = operands[0]
            data = value.get_original_bytes() if hasattr(value, "get_original_bytes") else bytes(value)
            # The captured Quartz streams use one Type1 glyph per Tj, with
            # explicit Td before the next glyph. Refuse other text-state flows.
            assert len(data) == 1 and fonts[font_key]["subtype"] == "/Type1"
            glyphs.append(dict(code=data[0], font=font_key, size=size, ctm=ctm[:],
                textMatrix=tm[:], finalMatrix=multiply(ctm, tm)))
        elif operator in (b"TJ", b"T*", b"TD", b"'", b'"'):
            raise AssertionError("Unsupported text-state operator: " + repr(operator))
    return dict(pdfSHA256=sha(path.read_bytes()), fonts=fonts, glyphs=glyphs)

def comparison(web, native):
    diff = ImageChops.difference(web, native)
    channels = diff.split()
    maximum = channels[0]
    for channel in channels[1:]:
        maximum = ImageChops.lighter(maximum, channel)
    hist = maximum.histogram()
    return dict(changedPixels=sum(hist[1:]), maxDelta=max(i for i, count in enumerate(hist) if count))

capture = json.loads((args.snapshot / "report.json").read_text())
assert capture["scope"].startswith("actual-iOS")
report = dict(scope="Actual-iOS immutable PDF matrices/font payloads and full RGBA diagnostic translations; no gate artifact is changed and no translation is a production policy.",
    capture=capture, scriptSHA256=sha(Path(__file__).read_bytes()), cases=[])
for source in capture["reports"]:
    tracking = source["tracking"]
    directory = args.snapshot / str(tracking)
    web, native = pdf(directory / "web.pdf"), pdf(directory / "native.pdf")
    assert len(web["glyphs"]) == len(native["glyphs"]) == len(capture["rawText"])
    origins = []
    for literal, w, n in zip(capture["rawText"], web["glyphs"], native["glyphs"]):
        assert w["code"] == n["code"] and w["size"] == n["size"]
        assert w["finalMatrix"][:4] == n["finalMatrix"][:4]
        origins.append(dict(literal=literal, code=w["code"], web=w["finalMatrix"], native=n["finalMatrix"],
            nativeMinusWeb=[round(n["finalMatrix"][i]-w["finalMatrix"][i], 9) for i in (4, 5)]))
    wfonts, nfonts = list(web["fonts"].values()), list(native["fonts"].values())
    assert len(wfonts) == len(nfonts) == 1
    font_equal = wfonts[0]["payloadSHA256"] == nfonts[0]["payloadSHA256"]
    cmap_equal = wfonts[0]["toUnicodeSHA256"] == nfonts[0]["toUnicodeSHA256"]
    # Pixel dimensions are explicitly captured by the iOS test's raster contract.
    width, height = 780, 1400
    wbytes, nbytes = (directory / "web.rgba").read_bytes(), (directory / "native.rgba").read_bytes()
    assert len(wbytes) == len(nbytes) == width*height*4 == source["pixels"]*4
    wimage, nimage = Image.frombytes("RGBA", (width, height), wbytes), Image.frombytes("RGBA", (width, height), nbytes)
    translations = []
    for dx, dy in ((0, 0), (1, 0), (1, 1), (1, -1)):
        shifted = Image.new("RGBA", (width, height), (255, 255, 255, 255))
        shifted.paste(nimage, (dx, dy))
        translations.append(dict(dxPixels=dx, dyPixels=dy, **comparison(wimage, shifted)))
    assert translations[0]["changedPixels"] == source["changedPixels"]
    report["cases"].append(dict(tracking=tracking, fontsEqual=font_equal, unicodeEqual=cmap_equal,
        webPDF=web, nativePDF=native, glyphOrigins=origins, diagnosticTranslations=translations,
        sourceSHA256={path.name: sha(path.read_bytes()) for path in directory.iterdir() if path.is_file()}))
(args.output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps([dict(tracking=case["tracking"], fontsEqual=case["fontsEqual"],
    glyphOriginDeltas=[row["nativeMinusWeb"] for row in case["glyphOrigins"]],
    diagnosticTranslations=case["diagnosticTranslations"]) for case in report["cases"]], indent=2))
