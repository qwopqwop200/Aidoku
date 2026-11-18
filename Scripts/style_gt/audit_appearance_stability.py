"""Flag substantial returned changes and cross-round reversals for crop adjudication."""
import argparse
from collections import Counter
import json
from pathlib import Path
from merge_appearance_recheck import FIELDS, semantic


def load(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--older', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    before = {r['itemID']: r for r in load(root / 'before-appearance-gt.json')['items']}
    older = {r['itemID']: r for r in load(args.older)['items']}
    flags, errors = [], []
    seen = 0
    for path in sorted((root / 'shards').glob('*/review-items/*.json')):
        try:
            new = load(path)
            item = new['itemID']
            old = before[item]
            reasons = []
            for field in FIELDS:
                if semantic(new.get(field)) == semantic(old.get(field)):
                    continue
                if item in older and semantic(new.get(field)) == semantic(older[item].get(field)):
                    reasons.append('cross-round reversal: ' + field)
            for field in ['outline', 'shadow']:
                a, b = old[field].get('present'), new[field].get('present')
                if a != b:
                    reasons.append(f'{field} presence {a} -> {b}')
            for field in ['fill', 'outline', 'background']:
                a, b = old[field].get('rgb'), new[field].get('rgb')
                if a is not None and b is not None and max(abs(x-y) for x, y in zip(a, b)) > 45:
                    reasons.append(field + ' substantial color change')
            a, b = old['outline'].get('widthPx'), new['outline'].get('widthPx')
            if a is not None and b is not None and abs(a-b) > max(1.5, a*.3):
                reasons.append('substantial outline width change')
            if semantic(new.get('substyles', [])) != semantic(old.get('substyles', [])):
                reasons.append('substyle change')
            if reasons:
                flags.append(dict(itemID=item, shard=int(path.parts[-3]), reasons=reasons,
                    crop=old['crop'], reviewFile=str(path), recheck=new.get('recheck')))
            seen += 1
        except Exception as error:
            errors.append(dict(path=str(path), error=str(error)))
    output = dict(reviewedRecords=seen, flaggedItems=len(flags),
                  reasons=dict(Counter(reason for r in flags for reason in r['reasons'])),
                  note='Flags request returned-result review, not automatic rejection. Older labels are not ground truth.',
                  items=flags, errors=errors)
    (root / 'STABILITY-AUDIT.json').write_text(json.dumps(output, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({k:v for k,v in output.items() if k not in ['items', 'errors']}))


if __name__ == '__main__':
    main()
