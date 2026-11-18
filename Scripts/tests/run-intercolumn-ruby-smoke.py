#!/usr/bin/env python3
"""Exercise default original-column ruby recovery without images, OCR or labels."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts'))
from swift_replay_cache import compile_replay

carrier = ROOT / 'Scripts/tests/run-paragraph-fragment-pipeline-smoke.py'
ns = {'__file__': str(carrier)}
exec(carrier.read_text().split('tests =')[0], ns)
support = ns['support'].replace('    var translation: String?',
    '    var sourceRoleEvidence: NativeTranslationRoleEvidence?\n    var translation: String?')
translation = ROOT / 'Aidoku/Core/Translation'
ocr = translation / 'NativeEngine/OCR'
sources = [ocr / (name + '.swift') for name in ('BrowserOCRSourceOrientation',
    'NativeOCRDetectorSeedEvidence', 'NativeOCRSourceROIProbabilityEvidence', 'NativeOCRAcceptedSource')]
sources += [translation / 'NativeParagraphFragmentGrouping.swift',
    translation / 'NativeParagraphFragmentGrouping+Pipeline.swift',
    translation / 'NativeEngine/Translation/TranslationBackgroundRolePolicy.swift']
main = support + r'''
typealias G = NativeParagraphFragmentGrouping
typealias E = NativeOCRDetectorSeedEvidence
typealias A = G.Atom
for scale: CGFloat in [0.5, 1, 2] {
    func atom(_ id: Int, _ text: String, _ rect: CGRect,
              _ orientation: BrowserOCRSourceOrientation = .vertical) -> A {
        .init(index: id, source: text, box: rect.applying(.init(scaleX: scale, y: scale)),
              orientation: orientation, owner: nil)
    }
    let host = atom(10, "漢字", CGRect(x: 100, y: 100, width: 30, height: 200))
    let other = atom(20, "次の列", CGRect(x: 170, y: 100, width: 30, height: 200))
    let ruby = atom(30, "かんじ", CGRect(x: 135, y: 110, width: 10, height: 60))
    precondition(G.intercolumnRubyHost(ruby, columns: [host, other]) == 10)
    // A paragraph envelope is intentionally NOT a host-column observation.
    let envelope = atom(40, "漢字次の列", CGRect(x: 100, y: 100, width: 100, height: 200))
    precondition(G.intercolumnRubyHost(ruby, columns: [envelope]) == nil)
    precondition(G.intercolumnRubyHost(ruby, columns: [host, atom(11, "別字", CGRect(x: 101, y: 100, width: 30, height: 200))]) == nil)
    precondition(G.intercolumnRubyHost(atom(30, "カンジ", CGRect(x: 135, y: 110, width: 10, height: 60)), columns: [host]) == 10)
    for candidate in [atom(30, "abc", CGRect(x: 135, y: 110, width: 10, height: 60)),
                      atom(30, "かんじ", CGRect(x: 135, y: 110, width: 25, height: 60)),
                      atom(30, "かんじ", CGRect(x: 80, y: 110, width: 10, height: 60)),
                      atom(30, "かんじ", CGRect(x: 135, y: 400, width: 10, height: 60)),
                      atom(30, "かんじ", CGRect(x: 135, y: 110, width: 10, height: 60), .horizontal)] {
        precondition(G.intercolumnRubyHost(candidate, columns: [host]) == nil)
    }
}
func packet(_ id: Int, _ text: String, _ box: CGRect) -> NativeOCRAcceptedSource.Packet {
    let x = Int(box.minX), y = Int(box.minY), width = Int(box.width), height = Int(box.height)
    let component = E.Component(seed: y * 1000 + x, pixelCount: width * height, meanProbability: 1,
        runs: (y..<(y + height)).map { E.Run(y: $0, x: x, count: width) })
    let seed = E(ownerID: "ruby-test:\(id)", parentBoxIndex: id, provenance: "db-complete-cc-candidates-v2",
        threshold: 0.9, mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
        sourceWidth: 1000, sourceHeight: 1000, components: [component], ownershipVersion: 2,
        completeCCScan: true, ambiguousComponents: [], candidateComponents: [])
    return .init(polygon: [.init(x: box.minX, y: box.minY), .init(x: box.maxX, y: box.minY),
        .init(x: box.maxX, y: box.maxY), .init(x: box.minX, y: box.maxY)], text: text, score: 0.99,
        orientation: .vertical, orientationIsEstimated: false, sourceTileBounds: nil,
        erasurePolygons: [], detectorSeedEvidence: [seed])
}
let boxes = [CGRect(x: 100, y: 100, width: 30, height: 200),
             CGRect(x: 170, y: 100, width: 30, height: 200),
             CGRect(x: 135, y: 110, width: 10, height: 60)]
let packets = zip(["漢字", "次の列", "かんじ"], boxes).enumerated().map { packet($0.offset, $0.element.0, $0.element.1) }
let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
func region(_ id: String, _ source: String, _ rect: CGRect, _ body: Set<Int>) -> ReaderTranslationRegion {
    var r = ReaderTranslationRegion(id: id, rect: rect.applying(.init(scaleX: 0.001, y: 0.001)), source: source)
    r.sourceOrientation = .vertical; r.sourceImageAspectRatio = 1
    r.acceptedSource = .init(.init(table: table, body: body, readings: [], unknownDedup: [], hasUntrackedInputs: false))
    return r
}
let input = [region("host", "次の列漢字", boxes[0].union(boxes[1]), [0, 1]), region("ruby", "かんじ", boxes[2], [2])]
unsetenv("AIDOKU_COLUMN_RUBY_RECOVERY")
precondition(G.columnRubyRecoveryEnabled)
setenv("AIDOKU_COLUMN_RUBY_RECOVERY", "0", 1)
precondition(!G.columnRubyRecoveryEnabled)
let baseline = G.reconcilingObservations(input, scopes: [])
precondition(baseline.count == 2)
setenv("AIDOKU_COLUMN_RUBY_RECOVERY", "1", 1)
let recovered = G.reconcilingObservations(input, scopes: [])
precondition(recovered.count == 1 && recovered[0].source == input[0].source)
let m = recovered[0].acceptedSource.membership!
precondition(m.table === table && m.body == [0, 1] && m.readings == [2])
precondition(recovered[0].rect == input[0].rect && recovered[0].auxiliaryInkRects.contains(input[1].rect))
let twice = G.reconcilingObservations(recovered, scopes: [])
precondition(twice.count == 1 && twice[0].acceptedSource.membership!.readings == [2])
precondition(twice[0].auxiliaryInkRects == recovered[0].auxiliaryInkRects)
precondition(input[1].acceptedSource.membership!.body == [2] && table.packets[2].text == "かんじ")
// OCR text embedded inside an existing body packet is not guessed or sliced.
let embedded = G.reconcilingObservations([input[0]], scopes: [])
precondition(embedded[0].source == input[0].source)
print("Ruby: original-column hosts, scale invariance, ambiguity abstention, packet conservation, idempotence and default enablement passed")
'''
cache = ROOT / 'build/intercolumn-ruby-smoke'
cache.mkdir(parents=True, exist_ok=True)
binary = cache / 'smoke'
compile_replay(cache, sources, main, binary)
subprocess.run([str(binary)], check=True)
