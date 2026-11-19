#!/usr/bin/env python3
"""21 production provenance contracts + actual iOS15 SDK availability boundaries.

Run on a macOS Xcode host. Missing SDK/compiler is a failure, never a silent pass.
No private replay snapshots, corpus/model/API work, or full-app build. Extracted
Region storage retains synthesized equality/memberwise init; UI methods are out
of scope. The unused (nil) translation cache key alone is a fixture type, not a
test of translation cache identity. Disk codec and all tested algorithms are real.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
TRANS = ROOT / 'Aidoku/Core/Translation'
OCR = TRANS / 'NativeEngine/OCR'
OUT = ROOT / 'build/native-accepted-source-lineage-smoke'
FIXTURE = Path(__file__).with_name('NativeAcceptedSourceLineageSmoke.swift')


def declaration(text, marker):
    """Extract a balanced production declaration; fail on missing/drifted anchors."""
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if text[end] == '{':
            depth += 1
        elif text[end] == '}':
            depth -= 1
        end += 1
    return text[start:end] + '\n'


def line(text, marker):
    """Extract one production line; fail on a missing/drifted anchor."""
    start = text.index(marker)
    return text[start:text.index('\n', start)] + '\n'


def before(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


def write_if_changed(path, text):
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def execute(command):
    return subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True)


def checked(command):
    result = execute(command)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout.strip()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    pipeline = (OCR / 'NativeCoreMLOCRPipeline.swift').read_text()
    region = (TRANS / 'ReaderTranslationService.swift').read_text()
    # Include the source availability annotation, rather than hardcoding one
    # which could hide a production regression. Region must remain unannotated.
    native = before(pipeline, '@available(iOS 18.0, *)\nstruct NativeCoreMLOCRLine:',
                    '@available(iOS 18.0, *)\nstruct NativeCoreMLOCRPipelineDiagnostics')
    storage = before(region, 'struct ReaderTranslationRegion:',
                     '    /// If translation adds no information') + '}\n'
    reuse = (TRANS / 'NativeEngine/Translation/NativeTranslationReuseIdentity.swift').read_text()
    support = 'import Foundation\nimport CoreGraphics\n'
    support += native + storage
    support += declaration((OCR / 'NativeOCRMixedScriptColumnRecovery.swift').read_text(),
                           'struct ReaderTranslationSourceOCRAlternative:')
    support += declaration((TRANS / 'ReaderTranslationEnclosedBackground.swift').read_text(),
                           'struct ReaderTranslationBalloonInterior:')
    support += before(reuse, 'struct NativeTranslationReuseIdentity:',
                      '    static func identitiesBySegmentID(') + '}\n'
    support += '// Only an unused nil cache-key dependency; no cache identity claim.\n'
    support += 'struct TranslationCacheKey: Codable, Hashable, Sendable {}\n'
    # Source reread receipts are nil-defaulted, never stored on disk and not
    # exercised here; fixture types only, no recognition claim.
    support += 'enum NativeCausalPacketColumnRecognition { struct Correction: Equatable, Sendable {} }\n'
    support += 'enum NativeCausalRFParagraphRecognition { struct Correction: Equatable, Sendable {} }\n'
    # Disk-stored evidence keeps its real Codable shape and validation helpers.
    role = (TRANS / 'NativeEngine/Translation/TranslationBackgroundRolePolicy.swift').read_text()
    support += 'import CryptoKit\n' + line(role, 'typealias NativeTranslationRoleEvidence')
    support += 'enum TranslationBackgroundRolePolicy {\n' + line(role, '    static let version =')
    support += declaration(role, '    struct Evidence:')
    support += declaration(role, '    private static func digest(')
    support += declaration(role, '    private static func validBounds(') + '}\n'
    post = (TRANS / 'NativePostLLMContentReclassifier.swift').read_text()
    final = (TRANS / 'NativeFinalOutputContentFilter.swift').read_text()
    support += 'enum NativeFinalOutputContentFilter {\n' + line(final, '    static let policyVersion =') + '}\n'
    support += 'enum NativePostLLMContentReclassifier {\n' + line(post, '    static let evidenceVersion =')
    support += '    // Fixture schema count only: this smoke never constructs post-LLM evidence.\n'
    support += '    fileprivate static let expectedFeatureCount = 0\n'
    support += declaration(post, '    struct Evidence:')
    support += declaration(post, '    private static func validDetectorVector(') + '}\n'
    support += declaration((TRANS / 'ReaderTranslationDiskCache.swift').read_text(),
                           'struct ReaderTranslationStoredRegion:')
    boundary = OUT / 'ProductionStorage.swift'
    write_if_changed(boundary, support)

    algorithms = 'import Foundation\nimport CoreGraphics\n'
    algorithms += '@available(iOS 18.0, *)\n' + declaration(pipeline, 'enum NativeOCRScopeGeometry {')
    algorithms += '@available(iOS 18.0, *)\n' + declaration(pipeline, 'struct NativeCoreMLOCRGapLine:')
    recovery = declaration(pipeline, 'enum NativeOCRAdjacentLineRecovery {')
    algorithms += '@available(iOS 18.0, *)\nenum NativeOCRAdjacentLineRecovery {\n'
    algorithms += declaration(recovery, '    static func extending(')
    algorithms += declaration(recovery, '    private static func contains(_ polygon:') + '}\n'
    algorithms += 'enum ReaderTranslationBalloonMerger {\n'
    algorithms += declaration((TRANS / 'ReaderTranslationBalloonMerger.swift').read_text(),
                              '    static func separatesVerticalUtterances(') + '}\n'
    extracted = OUT / 'ProductionAlgorithms.swift'
    write_if_changed(extracted, algorithms)

    neutral = [OCR / (name + '.swift') for name in (
        'NativeOCRAcceptedSource', 'BrowserOCRSourceOrientation',
        'NativeOCRDetectorSeedEvidence', 'NativeOCRSourceROIProbabilityEvidence')]
    host = neutral + [OCR / (name + '.swift') for name in (
        'PaddleOCRTypes', 'NativeOCRSpatialIndex', 'NativeOCRAuxiliaryOwnership',
        'NativeOCRSlantedDependentColumns', 'NativeOCRTextLineMerger', 'NativeOCRLocalCoordinates')]
    host += [boundary, extracted, FIXTURE]
    version = checked(['xcrun', 'swiftc', '--version'])
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-O',
               '-module-cache-path', OUT / 'host-module-cache', *host, '-o', OUT / 'smoke']
    digest = hashlib.sha256(version.encode() + repr(list(map(str, command))).encode())
    for path in host:
        digest.update(path.read_bytes())
    fingerprint = digest.hexdigest()
    stamp = OUT / 'fingerprint.txt'
    build_start = time.monotonic()
    reused = (OUT / 'smoke').exists() and stamp.exists() and stamp.read_text() == fingerprint
    if not reused:
        checked(command)
        stamp.write_text(fingerprint)
    build_seconds = time.monotonic() - build_start
    test_start = time.monotonic()
    contracts = json.loads(checked([OUT / 'smoke']))
    assert contracts['passed'] and contracts['count'] == 21
    assert len(set(contracts['contracts'])) == 21
    assert contracts['modelCalls'] == 0 and contracts['APICalls'] == 0
    test_seconds = time.monotonic() - test_start
    print(json.dumps(dict(phase='host', buildSeconds=build_seconds,
                          testSeconds=test_seconds, reusedBuild=reused, **contracts)), flush=True)

    baseline = OUT / 'BaselineOperations.swift'
    write_if_changed(baseline, '''import Foundation
func exerciseBaseline() {
    let packet = NativeOCRAcceptedSource.Packet(polygon: [], text: "甲", score: 0.9, orientation: .vertical,
        orientationIsEstimated: false, sourceTileBounds: nil, erasurePolygons: [], detectorSeedEvidence: nil)
    let table = NativeOCRAcceptedSource.PacketTable(packets: [packet], width: 1000, height: 1000)
    let member = NativeOCRAcceptedSource.Membership(table: table, body: [0], readings: [], unknownDedup: [], hasUntrackedInputs: false)
    var region = ReaderTranslationRegion(id: "baseline", rect: .zero, source: "甲")
    region.acceptedSource = NativeOCRSourceMetadata.union([.init(member)])
    _ = region.acceptedSource.retainingReading(.init(member))
    _ = region.acceptedSource.retainingDuplicate(.init(member), exactContentWitness: true)
    if #available(iOS 18.0, *) {
        let line = NativeCoreMLOCRLine(polygon: [], text: "甲", score: 0.9, orientation: .vertical)
        _ = NativeOCRAcceptedSource.Packet(line)
        _ = NativeOCRAcceptedSource.bindingPrimary([line], width: 1000, height: 1000)
    }
}
''')
    unguarded = OUT / 'UnguardedIngress.swift'
    write_if_changed(unguarded, '''func mustRejectOnIOS15() {
    _ = NativeOCRAcceptedSource.bindingPrimary([], width: 1, height: 1)
}
''')
    actual = neutral[0].read_text()
    marker = 'struct NativeOCRSourceMetadata:'
    assert actual.count(marker) == 1
    mutated = OUT / 'UnavailableMetadataNegativeControl.swift'
    write_if_changed(mutated, actual.replace(marker, '@available(iOS 18.0, *)\n' + marker, 1))
    checks = []
    availability_start = time.monotonic()
    for sdk_name, target in [('iphonesimulator', 'arm64-apple-ios15.0-simulator'),
                             ('iphoneos', 'arm64-apple-ios15.0')]:
        sdk = checked(['xcrun', '--sdk', sdk_name, '--show-sdk-path'])
        for name, source, extras, diagnostic in [
            ('neutral-storage-guarded-ingress', neutral[0], [baseline], None),
            ('annotated-metadata-negative-control', mutated, [], "'NativeOCRSourceMetadata' is only available in iOS 18.0"),
            ('unguarded-ingress-negative-control', neutral[0], [unguarded], "'bindingPrimary(_:width:height:)' is only available in iOS 18.0"),
        ]:
            start = time.monotonic()
            result = execute(['xcrun', 'swiftc', '-typecheck', '-swift-version', '5',
                              '-target', target, '-sdk', sdk, '-module-cache-path', OUT / 'sdk-module-cache',
                              source, *neutral[1:], boundary, *extras])
            log = OUT / (sdk_name + '-' + name + '.log')
            log.write_text(result.stdout + result.stderr)
            passed = result.returncode == 0 if diagnostic is None else (
                result.returncode != 0 and diagnostic in result.stderr)
            check = dict(name=name, sdk=sdk_name, sdkPath=sdk, target=target,
                         passed=passed, seconds=time.monotonic() - start, log=str(log))
            checks.append(check)
            print(json.dumps(check), flush=True)
            assert passed, log.read_text()
    report = dict(passed=True, contracts=contracts, availabilityChecks=checks,
                  buildSeconds=build_seconds, testSeconds=test_seconds, reusedBuild=reused,
                  availabilitySeconds=time.monotonic() - availability_start,
                  sourceHashes={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in host if OUT not in p.parents},
                  scope='Host production algorithms and extracted storage; actual iOS15 SDK typechecks only, not full app or device execution')
    (OUT / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(passed=True, contracts=21, availabilityChecks=len(checks),
                          report=str(OUT / 'result.json'))))


if __name__ == '__main__':
    main()
