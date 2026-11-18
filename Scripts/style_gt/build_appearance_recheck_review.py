"""Crop-only reinspection viewer with actual before/after differences."""
import argparse
import json
import subprocess
import sys
from pathlib import Path
from build_appearance_review import HTML


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    subprocess.run([sys.executable, str(Path(__file__).with_name('build_appearance_review.py')), '--root', str(root)], check=True)
    data_path = root / 'review/data.js'
    payload = json.loads(data_path.read_text().removeprefix('window.APPEARANCE_GT=').strip().removesuffix(';'))
    changes = json.loads((root / 'CHANGES.json').read_text())
    index = {r['itemID']: r for r in changes['items']}
    for row in payload['items']:
        row['change'] = index.get(row['itemID'])
    data_path.write_text('window.APPEARANCE_GT=' + json.dumps(payload, ensure_ascii=False, separators=(',', ':')) + ';\n')
    html = HTML.replace('<option value="all">전체</option>', '<option value="all">전체</option><option value="changed">스타일 수정</option><option value="confidence">신뢰도만 수정</option>')
    html = html.replace("f==='all'||f==='uncertain'", "f==='all'||f==='changed'&&r.change&&!r.change.confidenceOnly||f==='confidence'&&r.change?.confidenceOnly||f==='uncertain'")
    html = html.replace("$('details').replaceChildren();\npanel", "$('details').replaceChildren();if(r.change){let c=element('section');c.append(element('h2',r.change.confidenceOnly?'신뢰도만 수정':'스타일 수정 전후'));c.append(element('pre',JSON.stringify(r.change,null,2)));$('details').append(c)}\npanel")
    round_number = json.loads((root / 'input-manifest.json').read_text())['reviewRound']
    html = html.replace('appearance-gt-merged830-20261109.json', f'appearance-gt-merged830-20261109-review{round_number}-final.json')
    (root / 'review/index.html').write_text(html)


if __name__ == '__main__':
    main()
