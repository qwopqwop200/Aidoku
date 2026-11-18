#!/usr/bin/env python3
"""Read publisher n-gram data and export its numeric tables for native use.

The publisher distributes the LM tables, not an arbiter implementation. This
module documents the sparse interpolated scoring contract and validates it.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

import numpy as np


class MangaNGram:
    def __init__(self, path):
        with np.load(path, allow_pickle=False) as data:
            self.characters = list(map(str, data['chars']))
            self.order, self.size = int(data['N']), int(data['V'])
            self.gkeys, self.gvalues = data['gk'].copy(), data['gv'].copy()
            self.ckeys, self.cvalues = data['ck'].copy(), data['cv'].copy()
        if self.order != 3 or len(self.characters) != self.size or self.size >= 4096:
            raise ValueError('Unexpected n-gram contract')
        if self.characters[:2] != ['\x02', '\x03']:
            raise ValueError('Unknown beginning/end markers')
        self.ids = {c:i + 1 for i,c in enumerate(self.characters)}
        self.grams = dict(zip(map(int, self.gkeys), map(float, self.gvalues)))
        self.contexts = dict(zip(map(int, self.ckeys), map(float, self.cvalues)))
        if not np.isfinite(self.gvalues).all() or not np.isfinite(self.cvalues).all():
            raise ValueError('Nonfinite n-gram probabilities')

    def log_probability(self, token, history):
        probability = 1 / self.size
        for order in range(1, min(self.order, len(history) + 1) + 1):
            context = history[-(order - 1):] if order > 1 else []
            packed = sum(int(value) << (12 * index) for index,value in enumerate(context))
            key = (order << 60) | packed | (int(token) << (12 * (order - 1)))
            context_key = ((order - 1) << 60) | packed
            seen = np.exp(self.grams[key]) if key in self.grams else 0
            backoff = np.exp(self.contexts.get(context_key, 0))
            probability = seen + backoff * probability
        return float(np.log(max(1e-30, probability)))

    def score(self, text):
        history = [1, 1]; result = 0.
        for character in text + '\x03':
            token = self.ids.get(character, 0)
            result += self.log_probability(token, history)
            history = (history + [token])[-2:]
        return result

    def export(self, path):
        gorder, corder = np.argsort(self.gkeys), np.argsort(self.ckeys)
        header = struct.pack('<8sIIIII', b'MNG3DATA', 1, self.order, self.size, len(gorder), len(corder))
        payload = [header, np.array([ord(c) for c in self.characters], '<u4').tobytes(),
                   self.gkeys[gorder].astype('<u8').tobytes(), self.gvalues[gorder].astype('<f2').tobytes(),
                   self.ckeys[corder].astype('<u8').tobytes(), self.cvalues[corder].astype('<f2').tobytes()]
        path.write_bytes(b''.join(payload))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, default=Path(__file__).resolve().parents[3] / 'model-refresh-20261106/ocr-v03')
    args = parser.parse_args(); directory = args.directory
    source = directory / 'manga_lm3.npz'; lm = MangaNGram(source)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != '2ebdc0a75861e0809a3940da3aa8fc049ff600d029ce4ec5594b518533e38580':
        raise ValueError('Publisher LM hash changed')
    destination = directory / 'manga_ngram_v03.bin'; lm.export(destination)
    symbols = (directory / 'dict.txt').read_text().splitlines() + [' ']
    if len(symbols) != 19054:
        raise ValueError('Unexpected recognition dictionary')
    (directory / 'ppocrv6_manga_rec_character_dict.txt').write_text(
        ''.join(json.dumps(c, ensure_ascii=False) + '\n' for c in symbols))
    # The observed discounted mass + interpolation mass should sum to one
    # within publisher float16 table rounding, including the padded BOS context.
    contexts = [[], [1], [1,1]]; checks = []
    for context in contexts:
        total = sum(np.exp(lm.log_probability(token, context)) for token in range(1,lm.size + 1))
        if abs(total - 1) > .003:
            raise ValueError(f'Invalid LM probability mass: {context}: {total}')
        checks.append(dict(context=context, probabilityMass=total))
    report = dict(sourceSHA256=digest, binarySHA256=hashlib.sha256(destination.read_bytes()).hexdigest(),
        binaryBytes=destination.stat().st_size, order=lm.order, vocabulary=lm.size,
        dictionaryCharacters=len(symbols), probabilityMassChecks=checks,
        contract='order in top4 bits,12-bit charIDs+1; oldest context in low bits; interpolated seen+backoff*lower',
        arbiterImplementation='local implementation using official numeric tables; not publisher demo parity',
        syntheticScores={text:lm.score(text) for text in ['こんにちは','こんにちわ','ありがとう','ありがとラ']})
    (directory / 'NGRAM-EXPORT.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
