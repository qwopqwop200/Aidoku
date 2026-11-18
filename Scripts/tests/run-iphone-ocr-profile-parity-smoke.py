#!/usr/bin/env python3
"""Compare synthetic phone OCR imports with the actual shared Swift reader profile."""
import json
from pathlib import Path
import runpy
import subprocess


ROOT = Path(__file__).resolve().parents[2]
profile = runpy.run_path(str(ROOT / 'Scripts/image-translation/sync-iphone-settings.py'))['profile']
source = (ROOT / 'Aidoku/Core/Translation/ReaderTranslationSettings.swift').read_text()
configuration = source[:source.index('    @available(iOS 18.0, *)\n    var detectorPostprocessConfiguration')]
reader = configuration + '''
}
let entries = try JSONDecoder().decode([ReaderOCRConfiguration].self, from: Data(CommandLine.arguments[1].utf8))
let effective = entries.map { entry in
    var value = entry.boundedReaderResolution
    value.confidenceThreshold = IPhoneOCRSettings.migratedConfidenceThreshold(value.confidenceThreshold, for: value.modelTier)
    return value
}
print(String(decoding: try JSONEncoder().encode(effective), as: UTF8.self))
'''

profiles = []
for tier in ['manga', 'medium', 'small', 'tiny']:
    for detector, recognizer in [(1, 1), (1120, 2400), (1184, 1500), (1500, 2600), (960, 800)]:
        for confidence in [.75, .45, .50, .81]:
            options = {
                'modelTier': tier, 'confidenceThreshold': confidence,
                'detectorMaximumSide': detector, 'recognizerMaximumWidth': recognizer,
            }
            # Legacy snapshots omit detector fields; saved zero overrides must not become defaults.
            profiles.extend([options, {
                **options, 'detectorPixelThreshold': 0, 'detectorConfidenceThreshold': .37,
                'detectorMinimumBoxSide': 0,
            }])
swift = subprocess.run(['xcrun', 'swift', '-', json.dumps(profiles)], input=reader,
                       encoding='utf-8', check=True, capture_output=True)
effective = json.loads(swift.stdout)
keys = {
    'modelTier': 'AIDOKU_OCR_TIER',
    'confidenceThreshold': 'AIDOKU_OCR_CONFIDENCE',
    'detectorMaximumSide': 'AIDOKU_OCR_DETECTOR_SIDE',
    'recognizerMaximumWidth': 'AIDOKU_OCR_RECOGNIZER_WIDTH',
    'detectorPixelThreshold': 'AIDOKU_OCR_DETECTOR_PIXEL_THRESHOLD',
    'detectorConfidenceThreshold': 'AIDOKU_OCR_DETECTOR_CONFIDENCE_THRESHOLD',
    'detectorMinimumBoxSide': 'AIDOKU_OCR_DETECTOR_MINIMUM_BOX_SIDE',
}
assert len(effective) == len(profiles)
for entry, expected in zip(profiles, effective):
    imported = profile({
        'Reader.translation.provider': 'custom',
        'Reader.translation.custom': {'baseURL': 'https://example.test/v1', 'model': 'fixture', 'apiProtocol': 'responses'},
        'Reader.translation.overlay': {},
        'Reader.translation.ocr': json.dumps(entry).encode(),
    })
    actual = {name: imported[key] for name, key in keys.items()}
    assert actual == expected, (entry, actual, expected)
print(f'PASS: {len(effective)} synthetic phone profiles match shared Swift reader OCR settings')

host = (ROOT / 'Scripts/image-translation/PipelineMain.swift').read_text()
start = host.index('        for key in ["AIDOKU_OCR_DETECTOR_PIXEL_THRESHOLD"')
end = host.index('        if let value = setting("AIDOKU_TRANSLATION_REASONING")', start)
# Exercise this production parsing block without linking the translation provider.
parser = '''
import Foundation
enum HostError: Error { case message(String) }
func inspect(_ fields: [String:String]) throws -> [Double] {
    func setting(_ key: String) -> String? { fields[key] }
    var detectorPixelThreshold = -1.0
    var detectorConfidenceThreshold = -1.0
    var detectorMinimumBoxSide = -1.0
    var timeout = 60.0
''' + host[start:end] + '''
    return [detectorPixelThreshold, detectorConfidenceThreshold, detectorMinimumBoxSide, timeout]
}
let values = try inspect(["AIDOKU_OCR_DETECTOR_PIXEL_THRESHOLD":"0",
                          "AIDOKU_OCR_DETECTOR_CONFIDENCE_THRESHOLD":"0",
                          "AIDOKU_OCR_DETECTOR_MINIMUM_BOX_SIDE":"0"])
precondition(values == [0, 0, 0, 60])
for (key, value) in [("AIDOKU_TRANSLATION_TIMEOUT", "0"), ("AIDOKU_OCR_DETECTOR_MINIMUM_BOX_SIDE", "-1"),
                     ("AIDOKU_OCR_DETECTOR_PIXEL_THRESHOLD", "nan"), ("AIDOKU_OCR_DETECTOR_CONFIDENCE_THRESHOLD", "1.001")] {
    do { _ = try inspect([key:value]); fatalError("accepted invalid field") }
    catch HostError.message(let reason) { precondition(reason.hasSuffix(key)) }
}
'''
subprocess.run(['xcrun', 'swift', '-'], input=parser, encoding='utf-8', check=True)
print('PASS: host accepts valid zero OCR settings without accepting zero timeout or invalid OCR settings')
