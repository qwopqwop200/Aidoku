#!/usr/bin/env python3
"""Check production replay identity against same-path edits; no OCR/API or app build."""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
replay = (ROOT / "Scripts/image-translation/HostSavedOCRReplay.swift").read_text()
helper = replay.split("// BEGIN SAVED OCR CONTENT IDENTITY\n", 1)[1].split(
    "// END SAVED OCR CONTENT IDENTITY", 1)[0]
pipeline = (ROOT / "Scripts/image-translation/PipelineMain.swift").read_text()
assert "HostSavedOCRIdentity.digest(directory: $0.appendingPathComponent(pageDirectoryName))" in pipeline
assert '"savedOCRContentSHA256": savedOCRHash' in pipeline
assert pipeline.index("let expectedResumeIdentity = try resumeIdentity") < pipeline.index('guard saved["resumeIdentity"]')
assert "modelEstimated: modelEstimated" in replay
assert '"savedOCRGrouping"' in pipeline
assert pipeline.index("HostSavedOCRReplay.loadGrouped") < pipeline.index("ReaderTranslationService.plans(regions:")
assert '"merged": grouped.merged' in pipeline and '"split": grouped.split' in pipeline
assert 'linkItem(at: savedOCR.appendingPathComponent("ocr-boxes.png")' not in pipeline
analysis = (ROOT / "Scripts/image-translation/HostAnalysis.swift").read_text()
retained = analysis.split('let retainedStages: Set<String> = ', 1)[1].split('let entries =', 1)[0]
assert '"saved-ocr-replay"' in retained

HARNESS = r'''
import Foundation
import CryptoKit
@main struct Check {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        let a = root.appendingPathComponent("0001"), b = root.appendingPathComponent("0002")
        let original = Data(#"{"source":"原文","bbox":[0.1,0.2,0.3,0.4],"role_evidence":{}}"#.utf8)
        // Cross the hashing chunk boundary; no actual image decoding is needed for a byte identity test.
        let pixels = Data(repeating: 42, count: 1_048_600)
        for page in [a, b] {
            try fm.createDirectory(at: page, withIntermediateDirectories: true)
            try original.write(to: page.appendingPathComponent("final.json"))
            try pixels.write(to: page.appendingPathComponent("input.png"))
        }
        let baseline = try HostSavedOCRIdentity.digest(directory: a)
        precondition(baseline.count == 64)
        precondition(tryEqual(baseline, try HostSavedOCRIdentity.digest(directory: b)))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: a.appendingPathComponent("final.json").path)
        precondition(tryEqual(baseline, try HostSavedOCRIdentity.digest(directory: a)))
        for changed in [
            #"{"source":"修正","bbox":[0.1,0.2,0.3,0.4],"role_evidence":{}}"#,
            #"{"source":"原文","bbox":[0.2,0.2,0.3,0.4],"role_evidence":{}}"#,
            #"{"source":"原文","bbox":[0.1,0.2,0.3,0.4],"role_evidence":{"verified":false}}"#
        ] {
            try Data(changed.utf8).write(to: a.appendingPathComponent("final.json"))
            let modified = try HostSavedOCRIdentity.digest(directory: a)
            precondition(modified != baseline)
            precondition(tryEqual(baseline, try HostSavedOCRIdentity.digest(directory: b)))
        }
        try original.write(to: a.appendingPathComponent("final.json"))
        precondition(tryEqual(baseline, try HostSavedOCRIdentity.digest(directory: a)))
        var changedPixels = pixels
        changedPixels[changedPixels.count - 1] = 43
        try changedPixels.write(to: a.appendingPathComponent("input.png"))
        let newImageHash = try HostSavedOCRIdentity.digest(directory: a)
        precondition(newImageHash != baseline)
        for missing in ["final.json", "input.png"] {
            try fm.removeItem(at: a.appendingPathComponent(missing))
            do {
                _ = try HostSavedOCRIdentity.digest(directory: a)
                preconditionFailure("Missing snapshot accepted")
            } catch { }
            try (missing == "final.json" ? original : pixels).write(to: a.appendingPathComponent(missing))
        }
        print("PASS saved OCR identity: text/geometry/evidence/image edits, chunk boundary, page isolation, timestamps and missing files")
    }
    static func tryEqual(_ expected: String, _ actual: @autoclosure () throws -> String) -> Bool {
        (try? actual()) == expected
    }
}
'''

with tempfile.TemporaryDirectory(prefix="aidoku-saved-ocr-identity-") as directory:
    folder = Path(directory)
    source = folder / "Check.swift"
    source.write_text(HARNESS + "\n" + helper)
    binary = folder / "check"
    started = time.monotonic()
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    print(f"Build seconds {time.monotonic() - started:.3f}", flush=True)
    started = time.monotonic()
    subprocess.run([str(binary), str(folder)], check=True)
    print(f"Test seconds {time.monotonic() - started:.3f}", flush=True)
