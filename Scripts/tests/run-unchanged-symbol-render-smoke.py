#!/usr/bin/env python3
"""Exercise production symbol-paint admission with explicit provider roles."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def declaration(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


service = (ROOT / 'Aidoku/Core/Translation/ReaderTranslationService.swift').read_text()
models = (ROOT / 'Aidoku/Core/Translation/NativeEngine/Translation/TranslationModels.swift').read_text()
language = (ROOT / 'Aidoku/Core/Translation/ReaderTranslationLanguageFilter.swift').read_text()
program = 'import Foundation\n'
for marker in ['enum RemoteTranslationTextRole:',
               'struct RemoteTranslatedSegment:']:
    program += declaration(models, marker) + '\n'
program += '''
struct Balloon { let contourVerified: Bool }
struct Evidence { let rfBalloonConfidence: Double?; let rfTextConfidence: Double?; let rfSFXConfidence: Double? }
struct Region {
    let source: String
    var translation: String?
    var balloonInterior: Balloon?
    var sourceRoleEvidence: Evidence?
    var keepsClassifiedSFXSource = false
    var rendersUnchangedSymbols = false
    var translationRecoveryFailure: String?
'''
program += declaration(service, 'var preservesOriginalText: Bool') + '\n'
program += '@discardableResult\n' + declaration(service, 'mutating func applyTranslation(') + '\n}\n'
program += 'enum LanguagePolicy {\n' + declaration(language, 'static func isLanguageNeutralSymbols(') + '\n}\n'
program += r'''
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message); checks += 1
}
for source in ["…?", "?!...", "♡…", "※"] {
    check(LanguagePolicy.isLanguageNeutralSymbols(source), "punctuation must not be rejected by source language")
    var region = Region(source: source)
    let dialogue = RemoteTranslatedSegment(id: "id", text: source, isSFX: false, textRole: .dialogue)
    check(region.applyTranslation(dialogue), "first admission changes state")
    check(region.rendersUnchangedSymbols && !region.preservesOriginalText, "admitted symbols must paint")
    check(!region.applyTranslation(dialogue), "same result is stable")
    for role in [RemoteTranslationTextRole.sfx, .background] {
        region.applyTranslation(.init(id: "id", text: source, isSFX: role == .sfx, textRole: role))
        check(!region.rendersUnchangedSymbols && region.preservesOriginalText, "filtered source stays preserved")
    }
    region.applyTranslation(dialogue)
    region.translationRecoveryFailure = "unresolved"
    check(region.preservesOriginalText, "unresolved recovery stays preserved")
}
for source in ["18000", "Alice", "SAMPLE", "１２"] {
    check(!LanguagePolicy.isLanguageNeutralSymbols(source), "lexical and numeric text keeps language policy")
    var region = Region(source: source)
    region.applyTranslation(.init(id: "id", text: source, isSFX: false, textRole: nil))
    check(!region.rendersUnchangedSymbols && region.preservesOriginalText, "unchanged lexical lettering keeps policy")
}
var punctuation = Region(source: "…?")
punctuation.applyTranslation(.init(id: "id", text: "…?"))
check(!punctuation.preservesOriginalText, "unfiltered admitted punctuation paints")
punctuation.applyTranslation(.init(id: "id", text: "…?", isSFX: true))
check(punctuation.preservesOriginalText, "explicit SFX wins without text_role")
var effect = Region(source: "ドン")
effect.applyTranslation(.init(id: "id", text: "쿵", isSFX: true, textRole: .sfx))
check(effect.keepsClassifiedSFXSource && effect.preservesOriginalText,
    "translated SFX stays in storage but its source lettering remains visible")
effect.applyTranslation(.init(id: "id", text: "쿵", isSFX: false, textRole: .dialogue))
check(!effect.keepsClassifiedSFXSource && !effect.preservesOriginalText,
    "reclassified dialogue paints the translation")
var label = Region(source: "飲料水")
label.applyTranslation(.init(id: "id", text: "음료수", isSFX: false, textRole: .background))
check(label.translation == label.source && label.preservesOriginalText,
    "translated in-scene lettering must not receive a dialogue overlay")
var voiced = Region(source: "っっ♡", balloonInterior: Balloon(contourVerified: true),
    sourceRoleEvidence: Evidence(rfBalloonConfidence: 0.8, rfTextConfidence: 0.8, rfSFXConfidence: nil))
voiced.applyTranslation(.init(id: "id", text: "윽♡", isSFX: true, textRole: .sfx))
check(voiced.keepsClassifiedSFXSource && voiced.preservesOriginalText,
    "SFX inside verified text balloon keeps source despite RF text support")
var outside = Region(source: "ドン")
outside.applyTranslation(.init(id: "id", text: "쿵", isSFX: true, textRole: .sfx))
check(outside.keepsClassifiedSFXSource && outside.preservesOriginalText,
    "unboxed sound-effect lettering stays printed")
check(!LanguagePolicy.isLanguageNeutralSymbols(" \n "), "empty input is not admitted")
print("PASS: \(checks) production unchanged-symbol admission checks")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-symbol-admission-') as directory:
    source = Path(directory) / 'main.swift'
    executable = Path(directory) / 'check'
    source.write_text(program)
    subprocess.run(['swiftc', '-O', str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
