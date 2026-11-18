"""Compile the actual contour vote selector and exercise all insertion orders."""
from pathlib import Path
import itertools, subprocess, json, time
root=Path(__file__).resolve().parents[2]
source=(root/'Aidoku/Core/Translation/ReaderTranslationChromaticBalloon.swift').read_text()
start=source.index('    static func dominantComponentVote(')
end=source.index('    static func interiors(',start)
work=root/'build/chromatic-vote-order-smoke';work.mkdir(exist_ok=True)
body=source[start:end].replace('static func','func',1)
checks=[]
for votes in [[(2,12),(9,12),(4,1)],[(2,11),(9,12),(4,1)],[(2,1)],[]]:
 for order in itertools.permutations(votes):
  entries=','.join(f'({k},{v})' for k,v in order)
  best=max((v for _,v in votes),default=0)
  winners=[p for p in votes if p[1]==best]
  expected=winners[0] if len(winners)==1 else None
  checks.append(f'let v{len(checks)}=dominantComponentVote(Dictionary(uniqueKeysWithValues:[{entries}] as [(Int,Int)])); precondition('+ (f'v{len(checks)}?.id == {expected[0]} && v{len(checks)}?.count == {expected[1]}' if expected else f'v{len(checks)} == nil')+')')
checks += ['precondition(dominantComponentVote([2:12,9:12],support:{ _ in [2:200,9:300] })?.id == 9)', 'precondition(dominantComponentVote([2:12,9:12],support:{ _ in [2:300,9:200] })?.id == 2)', 'precondition(dominantComponentVote([2:12,9:12],support:{ _ in [2:300,9:300] }) == nil)']
probe=work/'main.swift';probe.write_text('import Foundation\n'+body+'\n'+'\n'.join(checks)+'\nprint("vote checks passed: '+str(len(checks))+'")')
t=time.monotonic();subprocess.run(['xcrun','swiftc',str(probe),'-o',str(work/'smoke')],check=True);build=time.monotonic()-t
t=time.monotonic();subprocess.run([str(work/'smoke')],check=True)
print(json.dumps(dict(checks=len(checks),buildSeconds=build,testSeconds=time.monotonic()-t)))
