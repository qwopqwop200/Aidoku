#!/usr/bin/env python3
"""Exercise the production final-owner resolver without models or an app build.

An optional --baseline source checks exact default decisions on generated
constituent/overlap cases. No labels, pages, pixels, or provider calls are used.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'Aidoku/Core/Translation'
CHECK = r'''
import Foundation
typealias D = NativeFinalOutputDuplicateResolver
typealias P = NativeOCRPremergeCandidateFeatures.Point
func rect(_ x: Double, _ y: Double = 0, _ w: Double = 10, _ h: Double = 10) -> [P] {
    [.init(x:x,y:y), .init(x:x+w,y:y), .init(x:x+w,y:y+h), .init(x:x,y:y+h)]
}
func owner(_ body: [Int], _ q: [P] = rect(0), _ confidence: Double = 0.9,
           _ table: Int = 0, readings: [Int] = [], eligible: Bool = true) -> D.Observation {
    .init(polygon:q,confidence:confidence,body:body,readings:readings,table:table,eligible:eligible)
}
func select(_ rows: [D.Observation], _ sources: [[P]], _ scores: [Double]? = nil) -> D.Result {
    D.select(rows,sourceTables:[0:sources],sourceAgreement:[0:scores ?? sources.map {_ in 1}])
}
@main struct Check {
    static func main() throws {
        let p = rect(0), other = rect(30), wide = rect(0,0,40)
        let duplicate = select([owner([0]),owner([0],p,0.8)], [p])
        precondition(duplicate.keep == [true,false] && duplicate.aliases.count == 1)
        precondition(duplicate.aliases[0].removedOriginalBody == [0])
        precondition(select([owner([0],wide),owner([1])], [other,p]).keep == [true,true],
            "An enclosing output must not erase independent source constituents")
        precondition(select([owner([0,1],wide),owner([0])], [p,other]).keep == [true,false])
        precondition(select([owner([0],wide),owner([1],p,0.8)], [p,p], [0.5,1]).keep == [true,true],
            "A weaker original-source agreement must not dominate the independent owner")
        precondition(select([owner([0]),owner([0],p,0.8,1)], [p]).keep == [true,true])
        precondition(select([owner([0]),owner([0],p,0.8,eligible:false)], [p]).keep == [true,true])
        precondition(select([owner([0]),owner([9])], [p]).keep == [true,true])
        precondition(select([owner([0],p,.nan),owner([0])], [p]).keep == [true,true])
        precondition(select([owner([0]),owner([0])], [[]]).keep == [true,true])
        precondition(select([owner([0]),owner([0])], [p], [.nan]).keep == [true,true])
        // Overlap is deliberately non-transitive: A witnesses B, B witnesses C,
        // A does not witness C. An absorbed alias must not acquire new witnesses.
        let chain = select([owner([0],p),owner([1],rect(0.6)),owner([2],rect(1.2))],
            [p,rect(0.6),rect(1.2)])
        precondition(chain.keep == [true,false,true])
        var rng: UInt64 = 0xD3D0_2026
        func next(_ n: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 32) % UInt64(n))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var removals = 0
        for _ in 0..<600 {
            let packets = (0..<12).map { i in rect(Double(i / 3) * 25 + Double(next(4)) * 0.4,
                Double(next(3)) * 0.1, 10 + Double(next(3)), 10) }
            let scores = packets.map {_ in [0.8,0.9,1.0][next(3)]}
            let rows = (0..<24).map { _ -> D.Observation in
                let source = next(packets.count)
                let body = next(5) == 0 ? [source,source] : [source]
                let readings = next(4) == 0 ? [(source / 3) * 3 + next(3)] : []
                return owner(body,packets[source],Double(7 + next(4)) / 10,readings:readings)
            }
            let result = select(rows,packets,scores)
            removals += result.aliases.count
            for alias in result.aliases {
                precondition(result.keep[alias.anchor] && !result.keep[alias.removed])
                precondition(alias.anchorOriginalBody == rows[alias.anchor].body)
                precondition(alias.removedOriginalReadings == rows[alias.removed].readings)
            }
            BASELINE_CHECK
        }
        print("PASS final-owner contracts + 600 generated cases; removals=\(removals)")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='aidoku-final-duplicate-') as directory:
        work = Path(directory)
        check = CHECK
        sources = [BASE / 'NativeEngine/OCR/NativeOCRPremergeCandidateFeatures.swift',
                   BASE / 'NativeFinalOutputDuplicateResolver.swift']
        if args.baseline:
            baseline = work / 'Baseline.swift'
            baseline.write_text(args.baseline.read_text().replace(
                'NativeFinalOutputDuplicateResolver', 'BaselineFinalOutputDuplicateResolver'))
            sources.append(baseline)
            check = check.replace('BASELINE_CHECK', r'''
            let oldRows = try JSONDecoder().decode([BaselineFinalOutputDuplicateResolver.Observation].self,
                from: encoder.encode(rows))
            let old = BaselineFinalOutputDuplicateResolver.select(oldRows,
                sourceTables:[0:packets],sourceAgreement:[0:scores])
            precondition(result.keep == old.keep)
            let newAliases = try encoder.encode(result.aliases)
            let oldAliases = try encoder.encode(old.aliases)
            precondition(newAliases == oldAliases)
            ''')
        else:
            check = check.replace('BASELINE_CHECK', '')
        main_source = work / 'Check.swift'
        main_source.write_text(check)
        binary = work / 'check'
        subprocess.run(['swiftc', '-O', *map(str, sources), str(main_source), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
