#!/usr/bin/env python3
"""Focused native row-clearance regression against a supplied saved-input corpus.

No corpus is bundled or fetched. With no --corpus, exits 77 (SKIP), not PASS.
Manifest schema: {"pages":[{"id":"NNNN","expectedAcceptedIDs":["..."],
"sealed":false,"baselineRecord":"optional/path/to/off-prepared-row.json"}]}.
Baseline records, when supplied, are exact --prepare-render-run JSON rows and
must be bound to the same input/payload hashes. No private build paths are used.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
IMMUTABLE = ('fontSize', 'tracking', 'foreground', 'outline', 'outlineWidth',
    'background', 'frame', 'textFrame', 'contentFrame', 'sourceOwner',
    'visibleUTF16Range', 'inputUTF16Length', 'paintUTF16Length',
    'shapedUTF16Length', 'horizontalScale', 'rotation', 'textRotation',
    'fits', 'lineCount', 'panelShape', 'sourceTopCohortAligned')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def check_page(row, spec, page_dir, manifest_dir):
    page = spec['id']
    problems = []
    def bad(code):
        problems.append([page, code])
    if row.get('status') != 'prepared':
        bad('not-prepared'); return problems
    payloads = list(page_dir.glob('*-render-payload.json'))
    if len(payloads) != 1 or not (page_dir / 'input.png').is_file() or \
       not (page_dir / 'final.json').is_file():
        bad('missing-frozen-input'); return problems
    if row.get('inputSHA256') != sha(page_dir / 'input.png') or \
       row.get('payloadSHA256') != sha(payloads[0]):
        bad('source-or-payload-drift')
    diag = row.get('diagnostics') or {}
    audit = diag.get('intraRowClearanceAudit')
    if not isinstance(audit, list):
        bad('missing-actual-main-row-audit'); return problems
    phase = (diag.get('phaseMilliseconds') or {}).get('rowClearance')
    if not isinstance(phase, (int, float)) or phase < 0:
        bad('missing-row-stage-time')
    expected = spec['expectedAcceptedIDs']
    accepted = {item['id']: item for item in audit if item.get('accepted') is True}
    if sorted(accepted) != sorted(expected): bad('accepted-inventory-drift')
    if spec.get('sealed'):
        if expected or audit != [{'status': 'sealed-artifact-abstention',
                'measuredClearance': None}]:
            bad('sealed-artifact-mutated-or-not-abstained')
    else:
        budgets = [item for item in audit if item.get('scope') == 'page-budget']
        if len(budgets) != 1: bad('missing-page-budget')
        else:
            budget = budgets[0]
            if budget.get('attemptLimit') != 24 or \
               budget.get('rawAlphaPixelLimit') != 8_000_000 or \
               not 0 <= budget.get('attemptsUsed', -1) <= 24 or \
               not 0 <= budget.get('rawAlphaPixelsCharged', -1) <= 8_000_000:
                bad('page-work-budget-exceeded-or-changed')
        cards = {card['id']: card for card in diag.get('cards') or []}
        for owner, receipt in accepted.items():
            if owner not in cards: bad(f'{owner}:missing-retained-card'); continue
            if receipt.get('fontUnchanged') is not True or \
               receipt.get('panelUnchanged') is not True or \
               receipt.get('finalPixelRowGap', 0) < 1 or \
               receipt.get('finalPDFSnappedPixelRowGap', 0) < 1 or \
               not 1 <= receipt.get('candidateEvaluations', 0) <= 8 or \
               not 0 < receipt.get('leadingDelta', 0) or \
               not receipt.get('finalLineHeight', 0) > receipt.get('originalLineHeight', 0):
                bad(f'{owner}:candidate-guard-or-scope')
            card = cards[owner]
            lines = card.get('horizontalRowMetrics') or []
            if len(lines) != card.get('lineCount') or len(lines) < 2 or \
               not all(isinstance(line.get('sourceUTF16Range'), list) and
                   isinstance(line.get('shapedUTF16Range'), list) and
                   isinstance(line.get('tokenCutAfterRowProxy'), bool) for line in lines):
                bad(f'{owner}:row-ledger-incomplete')
            clip = (diag.get('finalTextClipAudits') or {}).get(owner)
            if not clip or clip.get('status') != 'measured-within-allocation' or \
               len(clip.get('modes') or []) != 2 or \
               any(mode.get('clipLossPixels') != 0 for mode in clip['modes']):
                bad(f'{owner}:final-alpha-clip-loss-or-unmeasured')
    baseline = spec.get('baselineRecord')
    if baseline:
        baseline_path = (manifest_dir / baseline).resolve()
        before = json.loads(baseline_path.read_text())
        if before.get('status') != 'prepared' or \
           before.get('inputSHA256') != row.get('inputSHA256') or \
           before.get('payloadSHA256') != row.get('payloadSHA256'):
            bad('baseline-not-same-input'); return problems
        old_diag = before['diagnostics']
        old_cards = {card['id']: card for card in old_diag.get('cards') or []}
        new_cards = {card['id']: card for card in diag.get('cards') or []}
        if old_cards.keys() != new_cards.keys(): bad('baseline-card-inventory-drift')
        for owner in old_cards.keys() & new_cards.keys():
            old, new = old_cards[owner], new_cards[owner]
            if any(old.get(key) != new.get(key) for key in IMMUTABLE):
                bad(f'{owner}:immutable-style-panel-drift')
            left = old.get('horizontalRowMetrics') or []
            right = new.get('horizontalRowMetrics') or []
            if len(left) != len(right) or (left and
                    left[0].get('paintedBaseline') != right[0].get('paintedBaseline')):
                bad(f'{owner}:first-baseline-or-row-count-drift')
            for a, b in zip(left, right):
                if any(a.get(key) != b.get(key) for key in ('sourceUTF16Range',
                        'shapedUTF16Range', 'tokenCutAfterRowProxy',
                        'singleHangulLetterRow', 'graphemeCount')):
                    bad(f'{owner}:utf16-or-wrap-ledger-drift'); break
            if owner not in accepted and (old_diag.get('finalTextClipAudits') or {}).get(owner) != \
                    (diag.get('finalTextClipAudits') or {}).get(owner):
                bad(f'{owner}:peer-final-alpha-drift')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--corpus', type=Path)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--host-binary', type=Path)
    parser.add_argument('--root', type=Path, default=REPO)
    args = parser.parse_args()
    if args.corpus is None:
        print(json.dumps({'status': 'SKIP', 'reason': 'No --corpus supplied; no fixture or success claim'}))
        return 77
    if args.manifest is None or args.host_binary is None:
        parser.error('--corpus requires --manifest and --host-binary')
    corpus, manifest, binary = args.corpus.resolve(), args.manifest.resolve(), args.host_binary.resolve()
    specs = json.loads(manifest.read_text())['pages']
    ids = [item['id'] for item in specs]
    if not specs or len(ids) != len(set(ids)) or \
       any(len(page) != 4 or not page.isdigit() or
           not isinstance(item.get('expectedAcceptedIDs'), list) for page, item in zip(ids, specs)):
        parser.error('Manifest must list unique four-digit pages with expectedAcceptedIDs')
    available = sorted(p.name for p in corpus.iterdir() if p.is_dir())
    if available != sorted(ids):
        parser.error('Corpus pages must exactly match manifest; no cherry-picking')
    env = os.environ.copy()
    env['AIDOKU_PIPELINE_ROOT'] = str(args.root.resolve())
    fingerprint = binary.parent / 'fingerprint'
    if fingerprint.is_file():
        env['AIDOKU_PIPELINE_FINGERPRINT'] = fingerprint.read_text().strip()
    env.pop('AIDOKU_PRIVATE_INTRA_ROW_CLEARANCE', None)
    process = subprocess.run([str(binary), '--prepare-render-run', str(corpus)],
        env=env, capture_output=True, text=True)
    rows = [json.loads(line) for line in process.stdout.splitlines() if line.startswith('{')]
    by_id = {row['id']: row for row in rows}
    problems = []
    if process.returncode or len(rows) != len(specs) or by_id.keys() != set(ids):
        problems.append(['run', 'host-failure-or-page-inventory', process.stderr[-400:]])
    for spec in specs:
        if spec['id'] in by_id:
            problems.extend(check_page(by_id[spec['id']], spec,
                corpus / spec['id'], manifest.parent))
    result = {'status': 'PASS' if not problems else 'FAIL', 'pages': len(specs),
        'accepted': sum(len(spec['expectedAcceptedIDs']) for spec in specs),
        'problemCount': len(problems), 'problems': problems,
        'authority': 'native preparation regression; not actual serialized PDF or mobile performance proof'}
    print(json.dumps(result, ensure_ascii=False))
    return 0 if not problems else 1


if __name__ == '__main__':
    sys.exit(main())
