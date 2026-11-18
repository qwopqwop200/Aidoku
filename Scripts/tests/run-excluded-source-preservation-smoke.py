#!/usr/bin/env python3
"""Compile the production excluded-source ownership function with neutral regions."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
source = (root / "Aidoku/Core/Translation/ReaderTranslationLanguageFilter.swift").read_text()
start = source.index("    static func preservingExcludedSource(")
end = source.index("    /// NaturalLanguage classification", start)
fixture = r'''
import Foundation
struct ReaderTranslationRegion: Equatable {
    var id: String
    var source: String
    var translation: String?
    var translationReuseIdentity: String?
}
enum Policy {
''' + source[start:end] + r'''
}
let original = [
    ReaderTranslationRegion(id: "narration", source: "As you light a candle, another candle is lit.", translation: nil, translationReuseIdentity: "stale"),
    ReaderTranslationRegion(id: "menu", source: "Back History Skip Auto Save Load Settings", translation: nil, translationReuseIdentity: nil)
]
let kept = Policy.preservingExcludedSource(original: original, translated: [], eligibleIDs: [])
precondition(kept.count == 2)
precondition(kept.map(\.id) == original.map(\.id))
precondition(kept.allSatisfy { $0.translation == $0.source && $0.translationReuseIdentity == nil })
var translated = original[0]
translated.translation = "촛불을 켜자 다른 촛불도 켜졌다."
let mixed = Policy.preservingExcludedSource(original: original, translated: [translated], eligibleIDs: ["narration"])
precondition(mixed[0] == translated && mixed[1].translation == original[1].source)
let failed = Policy.preservingExcludedSource(original: original, translated: [], eligibleIDs: ["narration"])
precondition(failed[0] == original[0] && failed[1].translation == original[1].source)
print("PASS: excluded narration/menu retain source ownership; mixed and missing-provider controls")
'''
with tempfile.TemporaryDirectory(prefix="aidoku-excluded-reading-") as directory:
    path = Path(directory)
    (path / "main.swift").write_text(fixture)
    subprocess.run(["swiftc", str(path / "main.swift"), "-o", str(path / "check")], check=True)
    subprocess.run([str(path / "check")], check=True)
