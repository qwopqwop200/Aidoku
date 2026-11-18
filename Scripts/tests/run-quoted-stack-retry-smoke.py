"""Run the actual production copy-recovery predicate with small host-only carriers."""
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
source = (REPO / "Aidoku/Core/Translation/ReaderTranslationLanguageFilter.swift").read_text()
start = source.index("    static func requiresBalloonTranslation(")
opening = source.index("{", start)
depth, end = 1, opening + 1
while depth:
    if source[end] == "{": depth += 1
    elif source[end] == "}": depth -= 1
    end += 1
predicate = source[start:end]
carrier = '''import Foundation
import CoreGraphics
enum Orientation { case vertical, horizontal }
struct Interior { let contourVerified: Bool }
struct ReaderTranslationRegion {
    var source: String
    var sourceOrientation: Orientation = .vertical
    var unitMemberRects: [CGRect] = []
    var balloonInterior: Interior? = nil
}
enum ReaderTranslationLanguageFilter {
    static func canonical(_ value: String) -> String { value }
'''
checks = '''
var quote = ReaderTranslationRegion(source: "「はい…っ」")
precondition(!ReaderTranslationLanguageFilter.requiresBalloonTranslation(quote, translation: quote.source, target: "ko"))
quote.unitMemberRects = [CGRect(x: 0, y: 0, width: 20, height: 40), CGRect(x: 0, y: 50, width: 20, height: 40)]
precondition(ReaderTranslationLanguageFilter.requiresBalloonTranslation(quote, translation: quote.source, target: "ko"))
precondition(!ReaderTranslationLanguageFilter.requiresBalloonTranslation(quote, translation: "네…", target: "ko"))
precondition(!ReaderTranslationLanguageFilter.requiresBalloonTranslation(quote, translation: quote.source, target: "ja"))
quote.source = "どん"
precondition(!ReaderTranslationLanguageFilter.requiresBalloonTranslation(quote, translation: quote.source, target: "ko"))
quote.source = "「OK」"
precondition(!ReaderTranslationLanguageFilter.requiresBalloonTranslation(quote, translation: quote.source, target: "ko"))
print("PASS: 6 production predicate checks; recovered copy retries, real translation/English/free SFX remain unchanged")
'''
with tempfile.TemporaryDirectory(prefix="aidoku-quote-retry-") as directory:
    folder = Path(directory)
    (folder / "main.swift").write_text(carrier + predicate + "\n}\n" + checks)
    subprocess.run(["/usr/bin/xcrun", "swiftc", "-O", "-module-cache-path", str(REPO / "build/quoted-stack-tests/modules"),
                    str(REPO / "Aidoku/Core/Translation/ReaderTranslationQuotedStack.swift"),
                    str(folder / "main.swift"), "-o", str(folder / "test")], check=True)
    subprocess.run([str(folder / "test")], check=True)
