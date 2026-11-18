#!/usr/bin/env python3
"""Focused production source-bootstrap regression; no bundled/fetched corpus.

No --corpus: SKIP, exit77, never PASS. Required with a corpus: --manifest and
--host-binary (already built; this runner never builds or reads an object map).
Only --prepare-render-run is invoked, before provider/environment loading.

Manifest v1: {"schemaVersion":1,"pages":[...]} with five declared page specs.
Each spec requires id, sourceSHA256, payloadSHA256, expectedInputIDs,
expectedCardIDs, expectedRestoredIDs, expectedOmittedIDs, expectedCheckedIDs,
transaction (commit/rollback/abstain), expectedContainment (birth ID -> true or
false or null), expectedUTF16Lengths (checked final ID -> length), and
expectedSourceOwners (checked final ID -> [x,y,w,h]). Commit specs describe
three restored owners in total; all specs retain four raw omissions in total
by default. Optional root expectedTotals={"restored":4,"rawRemaining":3} and
expectedTransactionInventory={"commit":4,"rollback":0,"abstain":1} declare
the paragraph-shift contract. Each object requires exactly the shown keys and
nonnegative integer counts (not booleans), matching all five page specs.
Omitted objects independently default to totals 3/4 and inventory 3/1/1.
Rollback specs may declare expectedRejectedReasons (ID -> native reason).

Optional baselineRecord, baselineRecordSHA256 and baselineFields bind a saved
prepared row to identical source/payload bytes. baselineFields=["*"] compares
all final Card fields (except ordering of the two keyed BG histograms).
Otherwise only explicitly listed fields are compared. A pre-bootstrap baseline
may lack expectedRestoredIDs; no other baseline Card may disappear.
Optional hostBinarySHA256 at manifest root pins the executable itself.

The supplied corpus may be larger: only the predeclared five-page selection is
symlinked into a temporary read-only-input run. Source/payload hashes are checked
before AND after execution. No original, cache, label, PDF or image is written.
Native admission is bitmap + PDF-snapped bitmap, NOT serialized-PDF proof.
Actual source-free finalizer/PDF parity remains a separate offline validation.
"""
import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[2]
TRANSACTION = 'sourceBootstrapTransaction'
REUSE = 'sourceBootstrapSourceReuse'
MODES = ['bitmap', 'PDF-snapped-bitmap']
LEGACY_TOTALS = {'restored': 3, 'rawRemaining': 4}
LEGACY_TRANSACTION_INVENTORY = {'commit': 3, 'rollback': 1, 'abstain': 1}


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def integer(value, low=0, high=None):
    return type(value) is int and value >= low and (high is None or value <= high)


def ids(value):
    return isinstance(value, list) and all(isinstance(x, str) and x for x in value) and len(value) == len(set(value))


def normalized(card):
    result = copy.deepcopy(card)
    bg = result.get('initialBGHostObservation')
    if isinstance(bg, dict):
        for name in ('fitBodyHistogram', 'heldBodyHistogram'):
            values = bg.get(name)
            if isinstance(values, list):
                if not all(isinstance(x, dict) and set(x) == {'key', 'count'} for x in values):
                    raise ValueError('invalid keyed histogram')
                if len({x['key'] for x in values}) != len(values):
                    raise ValueError('duplicate histogram key')
                bg[name] = sorted(values, key=lambda x: x['key'])
    return result


def expected_contract(manifest):
    """Resolve declarations without letting malformed values fall back silently."""
    result = []
    for key, default in (('expectedTotals', LEGACY_TOTALS),
                         ('expectedTransactionInventory', LEGACY_TRANSACTION_INVENTORY)):
        counts = manifest.get(key, default)
        if not isinstance(counts, dict) or set(counts) != set(default) or any(
                not integer(n) for n in counts.values()):
            raise ValueError(key + ' requires exact count keys and nonnegative integers')
        result.append(dict(counts))
    if sum(result[1].values()) != 5:
        raise ValueError('expectedTransactionInventory must account for all five pages')
    return tuple(result)


def validate_manifest(manifest):
    if not isinstance(manifest, dict) or type(manifest.get('schemaVersion')) is not int or manifest['schemaVersion'] != 1:
        raise ValueError('schemaVersion must be1')
    totals, inventory = expected_contract(manifest)
    pages = manifest.get('pages')
    if not isinstance(pages, list) or len(pages) != 5 or not all(isinstance(p, dict) for p in pages):
        raise ValueError('Declare all five focused pages, not a successful subset')
    names = [p.get('id') for p in pages]
    if any(not isinstance(p, str) or len(p) != 4 or not p.isascii() or not p.isdigit() for p in names) or len(set(names)) != len(names):
        raise ValueError('Unique four-digit page IDs required')
    for spec in pages:
        for key in ('sourceSHA256', 'payloadSHA256'):
            digest = spec.get(key)
            if not isinstance(digest, str) or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
                raise ValueError('Explicit source/payload SHA256 required')
        for key in ('expectedInputIDs', 'expectedCardIDs', 'expectedRestoredIDs', 'expectedOmittedIDs', 'expectedCheckedIDs'):
            if not ids(spec.get(key)):
                raise ValueError('Unique string ID lists required: ' + key)
        inputs, cards, restored, omitted, checked = [set(spec[k]) for k in
            ('expectedInputIDs', 'expectedCardIDs', 'expectedRestoredIDs', 'expectedOmittedIDs', 'expectedCheckedIDs')]
        if cards & omitted or cards | omitted != inputs or not restored <= checked <= cards:
            raise ValueError('Input/Card/omission/checked inventory is inconsistent')
        mode = spec.get('transaction')
        if mode not in ('commit', 'rollback', 'abstain') or bool(restored) != (mode == 'commit'):
            raise ValueError('Explicit commit/rollback/abstain outcome required')
        if mode == 'rollback' and (not isinstance(spec.get('expectedRejectedReasons'), dict) or not spec['expectedRejectedReasons']):
            raise ValueError('Rollback requires explicit native rejection reasons')
        containment = spec.get('expectedContainment')
        if not isinstance(containment, dict) or set(containment) != restored or any(v is not None and type(v) is not bool for v in containment.values()):
            raise ValueError('Every restored owner needs typed boolean/null containment')
        lengths, owners = spec.get('expectedUTF16Lengths'), spec.get('expectedSourceOwners')
        if not isinstance(lengths, dict) or set(lengths) != checked or any(not integer(n, 1) for n in lengths.values()):
            raise ValueError('Every checked final owner needs a positive input UTF16 length')
        if not isinstance(owners, dict) or set(owners) != checked or any(not isinstance(r, list) or len(r) != 4 or
                any(type(v) not in (int, float) or not math.isfinite(v) for v in r) or r[2] <= 0 or r[3] <= 0 for r in owners.values()):
            raise ValueError('Every checked final owner needs its bound source owner rectangle')
        if spec.get('baselineRecord') and (not spec.get('baselineRecordSHA256') or not ids(spec.get('baselineFields')) or not spec['baselineFields']):
            raise ValueError('Optional baseline requires record SHA256 and explicit fields')
    if (sum(len(p['expectedRestoredIDs']) for p in pages) != totals['restored'] or
            sum(len(p['expectedOmittedIDs']) for p in pages) != totals['rawRemaining']):
        raise ValueError('Page owner totals must match expectedTotals (legacy default:3 restored,4 raw)')
    if {mode: sum(p['transaction'] == mode for p in pages) for mode in inventory} != inventory:
        raise ValueError('Page transactions must match expectedTransactionInventory (legacy default:3/1/1)')
    return pages


def check_diagnostics(row, spec):
    """Pure validator, also usable by small adversarial tests without a corpus."""
    problems = []
    def bad(code):
        problems.append([spec['id'], code])
    if row.get('status') != 'prepared':
        bad('not-prepared'); return problems
    if not ids(row.get('expectedRenderCardIDs')) or set(row['expectedRenderCardIDs']) != set(spec['expectedInputIDs']):
        bad('input-owner-ID-drift')
    diag = row.get('diagnostics') or {}
    records = diag.get('cards') or []
    cards = {c['id']: c for c in records}
    if len(cards) != len(records) or set(cards) != set(spec['expectedCardIDs']):
        bad('final-card-inventory')
    omissions = diag.get('omittedInputs') or []
    if len({o['id'] for o in omissions}) != len(omissions) or {o['id'] for o in omissions} != set(spec['expectedOmittedIDs']):
        bad('raw-omission-inventory')
    if any(o.get('stage') != 'text-space' for o in omissions):
        bad('omission-cause-changed')
    for cid in spec['expectedCheckedIDs']:
        card = cards.get(cid, {})
        n = spec['expectedUTF16Lengths'][cid]
        if card.get('inputUTF16Length') != n or card.get('visibleUTF16Range') != [0, n]:
            bad(cid + ':incomplete-input-UTF16')
        if card.get('sourceOwner') != spec['expectedSourceOwners'][cid]:
            bad(cid + ':source-owner-changed')
    tx = diag.get(TRANSACTION)
    if spec['transaction'] == 'abstain':
        if tx is not None or spec['expectedCheckedIDs']:
            bad('abstention-mutated-or-admitted')
        return problems
    if not isinstance(tx, dict):
        bad('missing-production-bootstrap-transaction'); return problems
    committed = spec['transaction'] == 'commit'
    if tx.get('committed') is not committed:
        bad('commit-or-rollback-drift')
    if tx.get('maximumBirths') != 2 or tx.get('maximumAlphaPixels') != 8_000_000 or not integer(tx.get('alphaPixelsCharged'), 1, 8_000_000):
        bad('birth-or-alpha-work-budget')
    if not ids(tx.get('bornIDs')) or not 1 <= len(tx['bornIDs']) <= 2 or not ids(tx.get('proposedIDs')) or len(tx['proposedIDs']) > 2:
        bad('unbounded-or-missing-births')
    if tx.get('serializedPDFMeasured') is not False:
        bad('wrong-native-authority')
    admission = tx.get('birthAdmission') or {}
    if committed:
        if set(tx.get('bornIDs', [])) != set(spec['expectedRestoredIDs']) or not ids(tx.get('runtimeCheckedIDs')) or set(tx['runtimeCheckedIDs']) != set(spec['expectedCheckedIDs']) or set(admission) != set(spec['expectedCheckedIDs']):
            bad('birth-or-changed-owner-admission-coverage')
        for cid in spec['expectedCheckedIDs']:
            receipt = admission.get(cid, {})
            alpha = receipt.get('admission') or {}
            if alpha.get('accepted') is not True or not integer(alpha.get('clipPixels'), 0, 0) or not integer(alpha.get('peerPixels'), 0, 0) or alpha.get('modes') != MODES or alpha.get('serializedPDFMeasured') is not False or not integer(alpha.get('occupiedAcrossModes'), 1):
                bad(cid + ':native-clip-peer-or-unmeasured')
            if cid in spec['expectedRestoredIDs']:
                if 'balloonContainment' not in receipt or receipt['balloonContainment'] is not spec['expectedContainment'][cid]:
                    bad(cid + ':containment-unknown-became-pass-or-type-drift')
                if receipt.get('nilSurfaceMeansNoBalloon') is not False or receipt.get('incumbentTextAlpha') != 'known-empty':
                    bad(cid + ':birth-incumbent-or-nil-surface-authority')
            elif receipt.get('existingChanged') is not True:
                bad(cid + ':missing-changed-incumbent-receipt')
    else:
        if set(tx.get('bornIDs', [])) & set(cards) or not any((a.get('admission') or {}).get('accepted') is False for a in admission.values()):
            bad('unsafe-trial-not-rolled-back')
        for cid, reason in spec.get('expectedRejectedReasons', {}).items():
            alpha = admission.get(cid, {}).get('admission') or {}
            if alpha.get('accepted') is not False or alpha.get('reason') != reason:
                bad(cid + ':expected-native-rejection-missing')
    reuse = diag.get(REUSE)
    if not isinstance(reuse, dict):
        bad('missing-source-reuse-budget'); return problems
    if reuse.get('metadataLogicalByteLimit') != 4_194_304 or any(not integer(reuse.get(k), 0, 4_194_304) for k in
            ('retainedMetadataLogicalBytes', 'peakRetainedMetadataLogicalBytes')) or reuse.get('sourcePrefixOwnerLimit') != 64:
        bad('retained-metadata-budget')
    if reuse.get('readerCacheLogicalByteLimit') != 16_777_216 or not integer(reuse.get('readerCacheLiveUpperBound'), 0, 16_777_216):
        bad('reader-cache-budget')
    if reuse.get('persistentCacheAdded') is not False or reuse.get('sourceFilterResolutionAndColorPolicyChanged') is not False:
        bad('source-filter-color-or-cache-policy')
    return problems


def check_baseline(row, spec, manifest_dir):
    if not spec.get('baselineRecord'):
        return []
    path = (manifest_dir / spec['baselineRecord']).resolve()
    if sha(path) != spec['baselineRecordSHA256']:
        return [[spec['id'], 'baseline-record-SHA-drift']]
    before = json.loads(path.read_text())
    if before.get('status') != 'prepared' or any(before.get(k) != row.get(k) for k in ('inputSHA256', 'payloadSHA256')):
        return [[spec['id'], 'baseline-not-bound-to-identical-input']]
    old = {c['id']: c for c in before['diagnostics']['cards']}
    new = {c['id']: c for c in row['diagnostics']['cards']}
    result = []
    if old.keys() - new.keys():
        result.append([spec['id'], 'baseline-owner-removed'])
    for cid in old.keys() & new.keys():
        a, b = normalized(old[cid]), normalized(new[cid])
        fields = a.keys() | b.keys() if spec['baselineFields'] == ['*'] else spec['baselineFields']
        different = sorted(k for k in fields if a.get(k) != b.get(k))
        if different:
            result.append([spec['id'], cid, 'bound-baseline-field-drift', different])
    return result


def observed_inventory(rows):
    """Inventory is diagnostic evidence, not proof that an admission passed."""
    born, omitted = 0, 0
    for row in rows:
        diagnostics = row.get('diagnostics') or {}
        cards = {card.get('id') for card in diagnostics.get('cards', [])}
        transaction = diagnostics.get(TRANSACTION) or {}
        if transaction.get('committed') is True:
            born += len(set(transaction.get('bornIDs', [])) & cards)
        omitted += len(diagnostics.get('omittedInputs', []))
    return born, omitted


def inventory_report(rows, manifest, problems):
    """Keep observed evidence visible, but certify totals only on a clean run."""
    totals, _ = expected_contract(manifest)
    born, omitted = observed_inventory(rows)
    if (born, omitted) != (totals['restored'], totals['rawRemaining']):
        problems.append(['run', 'observed-owner-totals-mismatch'])
    return {'restored': born if not problems else None,
        'rawRemaining': omitted if not problems else None,
        'expectedRestored': totals['restored'], 'expectedRawRemaining': totals['rawRemaining'],
        'observedCommittedBirths': born, 'observedRawOmissions': omitted}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--corpus', type=Path)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--host-binary', type=Path)
    parser.add_argument('--root', type=Path, default=REPO)
    args = parser.parse_args()
    if args.corpus is None:
        print(json.dumps({'status': 'SKIP', 'reason': 'No external corpus supplied; no native regression executed'}))
        return 77
    if args.manifest is None or args.host_binary is None:
        parser.error('--corpus requires --manifest and --host-binary')
    try:
        manifest = json.loads(args.manifest.read_text())
        specs = validate_manifest(manifest)
        binary = args.host_binary.resolve(strict=True)
        binary_sha = sha(binary)
        if manifest.get('hostBinarySHA256', binary_sha) != binary_sha:
            raise ValueError('hostBinarySHA256 mismatch')
        inputs = {}
        for spec in specs:
            directory = (args.corpus / spec['id']).resolve(strict=True)
            payloads = list(directory.glob('*-render-payload.json'))
            if len(payloads) != 1 or not (directory / 'input.png').is_file() or not (directory / 'final.json').is_file():
                raise ValueError('Missing or ambiguous frozen source/payload/final inputs')
            files = {'input.png': directory / 'input.png', payloads[0].name: payloads[0], 'final.json': directory / 'final.json'}
            if sha(files['input.png']) != spec['sourceSHA256'] or sha(payloads[0]) != spec['payloadSHA256']:
                raise ValueError('Manifest source/payload binding mismatch')
            inputs[spec['id']] = (files, {name: sha(path) for name, path in files.items()})
        env = {k: v for k, v in os.environ.items() if not k.startswith('AIDOKU_PRIVATE_') and k != 'AIDOKU_TRACE_PANEL_STAGES'}
        env.update(AIDOKU_PIPELINE_ROOT=str(args.root.resolve()), AIDOKU_PIPELINE_FINGERPRINT=binary_sha)
        with tempfile.TemporaryDirectory(prefix='aidoku-source-bootstrap-smoke-') as temporary:
            folder = Path(temporary)
            for pid, (files, _) in inputs.items():
                target = folder / pid; target.mkdir()
                for name, path in files.items():
                    (target / name).symlink_to(path)
            process = subprocess.run([str(binary), '--prepare-render-run', str(folder)], env=env, capture_output=True, text=True)
        rows = [json.loads(line) for line in process.stdout.splitlines() if line.startswith('{')]
        by_id = {row['id']: row for row in rows}
        problems = []
        if process.returncode or len(rows) != len(specs) or set(by_id) != set(inputs):
            problems.append(['run', 'host-failure-or-page-inventory', process.returncode])
        for spec in specs:
            pid = spec['id']; row = by_id.get(pid)
            files, hashes = inputs[pid]
            if any(sha(path) != hashes[name] for name, path in files.items()):
                problems.append([pid, 'input-mutated-during-run'])
            if row is None:
                continue
            if row.get('inputSHA256') != spec['sourceSHA256'] or row.get('payloadSHA256') != spec['payloadSHA256'] or row.get('nativeBuildFingerprint') != binary_sha:
                problems.append([pid, 'actual-host-source-payload-binding'])
            problems.extend(check_diagnostics(row, spec))
            problems.extend(check_baseline(row, spec, args.manifest.resolve().parent))
        if sha(binary) != binary_sha:
            problems.append(['run', 'binary-mutated-during-run'])
        inventory = inventory_report(rows, manifest, problems)
        result = {'status': 'PASS' if not problems else 'FAIL', 'pages': len(rows),
            **inventory,
            'problemCount': len(problems), 'problems': problems, 'hostBinarySHA256': binary_sha,
            'manifestSHA256': sha(args.manifest), 'scope': 'five declared external pages, not full corpus',
            'authority': 'production native dual-bitmap admission and UTF16 diagnostics; not serialized PDF/artwork GT',
            'serializedPDFMeasured': False, 'sourceCompositesCreated': False, 'hostBuildPerformed': False}
        print(json.dumps(result, ensure_ascii=False))
        return 0 if not problems else 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({'status': 'FAIL', 'reason': type(error).__name__, 'detail': str(error)[:240]}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
