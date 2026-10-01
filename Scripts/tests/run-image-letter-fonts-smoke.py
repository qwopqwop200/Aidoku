#!/usr/bin/env python3
"""Production overlay migration and native Core Text font registration."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = r'''
import Foundation
import CoreText

@main struct Check {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fonts = HostLetterFonts(root: root)
        precondition(fonts.appearanceValue == ["serif": true])
        precondition(fonts.availabilityKey == "native-letter-styles-v1:serif")
        let font = CTFontCreateWithName("AidokuSerifKR-Bold" as CFString, 12, nil)
        precondition(CTFontCopyPostScriptName(font) as String == "AidokuSerifKR-Bold")
        // Registration is process-wide; a second reader must still report the face.
        precondition(HostLetterFonts(root: root).appearanceValue == ["serif": true])
        let defaults = try HostOverlayAppearance.settings(saved: [:])
        precondition(defaults.opacity == 0.84 && !defaults.preserveSourceColors)
        let migrated = try HostOverlayAppearance.settings(saved: [
            "preserveSourceTextColor": true, "preserveSourceBackgroundColor": false,
            "inpaintingEnabled": false, "opacity": 0.3, "mode": "subtitle", "textPlacement": "expanded"
        ])
        precondition(migrated.preserveSourceColors && migrated.inpaintingEnabled)
        precondition(migrated.mode == .translateOnly && migrated.textPlacement == .replace)
        let payload = HostOverlayAppearance.value(settings: migrated, fonts: fonts)
        precondition(payload["opacity"] as? Double == 1)
        precondition(payload["sourceLetterFonts"] as? [String: Bool] == ["serif": true])
        let dark = try HostOverlayAppearance.settings(saved: ["colorMode": "dark", "opacity": 0.4])
        let darkPayload = HostOverlayAppearance.value(settings: dark, fonts: fonts)
        precondition(darkPayload["opacity"] as? Double == 0.4)
        precondition(darkPayload["inpaintingEnabled"] as? Bool == false)
        precondition(darkPayload["sourceLetterFonts"] as? Bool == false)
        precondition(HostLetterFonts(root: root.appendingPathComponent("missing-root")).appearanceValue.isEmpty)
        print("PASS: production overlay migration, partial defaults, native font availability and repeat Core Text registration")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="aidoku-letter-font-smoke-") as temporary:
    directory = Path(temporary)
    fixture = directory / "Check.swift"
    fixture.write_text(FIXTURE)
    binary = directory / "check"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library",
        str(ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay/IPhoneOverlaySettings.swift"),
        str(ROOT / "Scripts/image-translation/HostLetterFonts.swift"), str(fixture), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary), str(ROOT)], check=True)
