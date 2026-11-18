#!/usr/bin/env python3
"""Compile production synopsis slicing/whitespace helpers; no app or provider calls."""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def block(path, marker):
    source = (ROOT / path).read_text()
    return source.split("// BEGIN " + marker, 1)[1].split("\n", 1)[1].split("// END " + marker, 1)[0]


helper = block("Aidoku/Core/Translation/MangaDescriptionTranslation.swift", "SYNOPSIS_CHUNK_HELPER")
checks = block("AidokuTests/Translation/MangaDescriptionTranslationTests.swift", "SYNOPSIS_CHUNK_CHECKS")
formatting = block("Aidoku/Core/Translation/TitleTranslation.swift", "METADATA PROMPT CONTRACT")
MAIN = r'''
import Foundation
@main struct Check {
    static func main() {
        let checks = SynopsisChunkingChecks.run()
        let failed = checks.filter { !$0.passed }
        if !failed.isEmpty {
            print("FAIL synopsis chunks: \(failed.map(\.name))")
            exit(1)
        }
        let source = "    " + String(repeating: "A word. ", count: 4_000) +
            "[a link](https://example.invalid/unchanged?q=1)  "
        let chunks = SynopsisChunking.chunks(source, maximumBytes: 16_384)
        precondition(chunks.count > 1)
        let joined = chunks.map {
            TitleTranslationKind.description.formattedTranslation($0.trimmingCharacters(in: .whitespacesAndNewlines), original: $0)
        }.joined()
        precondition(joined == source)
        print("PASS \(checks.count) synopsis slicing checks + production whitespace/chunk join; no OCR/provider calls")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="aidoku-synopsis-chunks-") as directory:
    folder = Path(directory)
    source = folder / "Check.swift"
    source.write_text(MAIN + "\n" + helper + "\n" + checks + "\n" + formatting)
    binary = folder / "check"
    started = time.monotonic()
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    print(f"Build seconds {time.monotonic() - started:.3f}", flush=True)
    started = time.monotonic()
    subprocess.run([str(binary)], check=True)
    print(f"Test seconds {time.monotonic() - started:.3f}", flush=True)
