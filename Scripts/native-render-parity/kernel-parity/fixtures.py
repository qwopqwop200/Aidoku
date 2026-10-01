"""Deterministic ABI fixtures; every exported algorithm has an active nonempty case."""
import base64
import re
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'Scripts/overlay-kernels/kernels.rs'


def signatures():
    result = {}
    for match in re.finditer(r'pub unsafe extern "C" fn (\w+)\((.*?)\)(\s*->[^\{]+)?\s*\{', SOURCE.read_text(), re.S):
        result[match[1]] = {'parameters': [tuple(value.strip().split(': ', 1)) for value in match[2].split(',')],
                           'returns': bool(match[3])}
    return result


class Arena:
    def __init__(self):
        self.data = bytearray()
        self.buffers = {}

    def allocate(self, name, kind, count, values=None):
        size = {'u8': 1, 'i32': 4, 'f32': 4, 'f64': 8}[kind]
        self.data.extend(b'\0' * ((-len(self.data)) % 16))
        at = len(self.data)
        self.data.extend(b'\0' * (size * count))
        self.buffers[name] = {'offset': at, 'kind': kind, 'count': count, 'guardOffset': at + size * count}
        self.data.extend(bytes([165]) * 32)
        if values is not None:
            self.write(name, values)
        return {'pointer': at}

    def write(self, name, values):
        buffer = self.buffers[name]
        code = {'u8': 'B', 'i32': 'i', 'f32': 'f', 'f64': 'd'}[buffer['kind']]
        values = list(values)
        encoded = struct.pack('<' + code * len(values), *values)
        assert len(values) <= buffer['count'], name
        at = buffer['offset']
        self.data[at:at + len(encoded)] = encoded


def polygon_mask(w, h):
    # Triangle with fractional edges, rasterized before the kernels' mask ABI.
    return [int(12.25 < y < 47.75 and 8.5 + (y - 12.25) * .45 < x < 51.5 - (y - 12.25) * .35)
            for y in range(h) for x in range(w)]


def fixture(name, signature, seed, variant):
    w = h = 64
    n = w * h
    state = seed
    def random_byte():
        nonlocal state
        state = (1664525 * state + 1013904223) & 0xffffffff
        return state >> 24
    rgba = [value for y in range(h) for x in range(w) for value in (240 + ((x + y + seed) % 2),) * 3 + (255,)]
    glyph = []
    def pixel(x, y, color):
        rgba[(y * w + x) * 4:(y * w + x + 1) * 4] = list(color) + [255]
    for x0, y0 in [(20, 22), (36, 32)]:
        for y in range(y0, y0 + 8):
            for x in range(x0, x0 + 8):
                if x in (x0, x0 + 7) or y in (y0, y0 + 7):
                    pixel(x, y, (24, 52, 80))
                    glyph.append(y * w + x)
    if variant.startswith('half-even'):
        # A 50/50 checker ring samples exactly .5; ECMAScript rounds to an even byte.
        lower = 240 if variant == 'half-even-low' else 241
        rgba = [value for y in range(h) for x in range(w)
                for value in (lower + ((x + y) % 2),) * 3 + (255,)]
        glyph = []
        for y in range(22, 30):
            for x in range(20, 28):
                if x in (20, 27) or y in (22, 29):
                    pixel(x, y, (24, 52, 80))
                    glyph.append(y * w + x)
    # Small enclosed hole produces a real positive ray event.
    for y in range(46, 46 if variant.startswith('half-even') else 49):
        for x in range(28, 31):
            if (x, y) != (29, 47):
                pixel(x, y, (24, 52, 80))
                glyph.append(y * w + x)
    if name == 'stroke_seed':
        rgba = [value for y in range(h) for x in range(w) for value in (192, 212, 246, 255)]
        for y in range(27, 38):
            for x in range(27, 38):
                pixel(x, y, (128, 128, 128))
        for y in range(31, 34):
            for x in range(31, 34):
                pixel(x, y, (24, 52, 80))
    if name == 'exemplar_fill':
        rgba = []
        for y in range(h):
            for x in range(w):
                delta = 7 if (x + y) % 2 else -7
                # Fractional plane coefficients exercise Float32 residual stores.
                rgba.extend([225 + delta, 228 + delta, 231 + delta, 255])
    if name == 'pixel_classes':
        for x, color in enumerate([(130, 30, 220), (0, 22, 255), (24, 52, 80), (128, 128, 128), (240, 240, 240)], 4):
            pixel(x, 4, color)
    if variant == 'alpha-rejection':
        rgba[3] = 249
    arena = Arena()
    args = []
    scalar = {'w': w, 'h': h, 'n': n, 'x0': 1, 'x1': w - 1, 'y0': 1, 'y1': h - 1,
              'l': 12, 'r': 52, 't': 12, 'b': 52, 'bottom': 52, 'left': 12.25, 'right': 51.75,
              'top': 12.25, 'ir': 24, 'ig': 52, 'ib': 80, 'cr': 24, 'cg': 52, 'cb': 80,
              'fr': 24, 'fg': 52, 'fb': 80, 'or': 240, 'og': 240, 'ob': 240,
              'len': len(glyph), 'stride': 2 if variant == 'fractional-negative' else 1,
              'min_total': 8, 'vertical': seed % 2, 'origin': -.75 if variant == 'fractional-negative' else 12.25,
              'span': 37.5, 'reach': 12, 'samples': 3, 'sr': 128, 'sg': 128, 'sb': 128, 'rejoins': seed % 2,
              'check_alpha': 1, 'allow_dark': seed % 2, 'tolerance': 24, 'radius': 2,
              'il': 12.25, 'it': 12.25, 'iright': 51.75, 'ibottom': 51.75,
              'dark_ink': seed % 2, 'interior_min': 8, 'axis': seed % 2, 'textured': seed % 2,
              'start': 32.75 if variant == 'fractional-negative' else 1.25, 'length': 45.5,
              'count': n, 'm0': 100.5, 'm1': 100.5, 'm2': 100.5, 'from': 2, 'to': n - 3,
              'tail': 16, 'accelerated': seed % 2, 'erased': 9, 'aux_n': 1, 'exc_n': int(variant == 'polygon-protected'),
              'bmax': 40.5, 'part_capacity': n, 'flags': 15 if variant == 'active' else 8 if variant == 'fractional-negative' else 0, 'ink_tolerance': 28.25, 'halo_separation': 44.75}
    if variant == 'below-threshold': scalar['min_total'] = n
    if name == 'enclosed_paper':
        scalar.update(l=12, t=12, r=52, bottom=52)
    if variant == 'fractional-negative':
        scalar.update(left=-.75, top=-.25)
    for parameter, kind in signature['parameters']:
        if not kind.startswith('*'):
            value = scalar.get(parameter, 0)
            args.append(float(value) if kind == 'f64' else int(value))
            continue
        element = kind.split()[-1]
        count = {'u8': n * 4, 'i32': max(n, 4097), 'f32': n * 3, 'f64': 64}[element]
        if parameter in ('sums',): count = 4096 * 3
        if parameter in ('out',): count = n * 9 if name == 'outlined_components' else n * 4
        if parameter in ('parts', 'first', 'meta'): count = n * 8
        if parameter == 'integral': count = (w + 1) * (h + 1)
        if parameter == 'cell': count = n
        values = None
        if parameter in ('rgba', 'src', 'p'): values = rgba
        elif kind.startswith('*const') and element == 'u8':
            values = [0] * count
            if parameter in ('r', 'g', 'b'):
                values[:n] = [random_byte() for _ in range(n)]
                # Uniformly brighter samples and near-mode support both present.
                values[:80] = [100] * 40 + [160] * 40
            elif parameter == 'band': values[:n] = [i % 8 for i in range(n)]
            elif parameter == 'dots': values[:n] = [int(x % 3 == 0 and y % 3 == 0) for y in range(h) for x in range(w)]
            elif parameter in ('mask', 'paint'):
                target = [(31 + yy) * w + 31 + xx for yy in range(3) for xx in range(3)]
                for i in target: values[i] = 1
            elif parameter in ('excluded', 'forbidden') and variant == 'polygon-protected': values[:n] = polygon_mask(w, h)
            elif parameter == 'blocked':
                values[:n] = [int(x == 0 or y == 0 or x == w - 1 or y == h - 1) for y in range(h) for x in range(w)]
        elif kind.startswith('*const') and element == 'i32':
            if parameter == 'core': values = glyph
            elif parameter == 'queue': values = [(30 + yy) * w + 30 + xx for yy in range(4) for xx in range(4)]
            elif parameter in ('sx', 'sy'): values = [32, 31, 33]
            elif parameter == 'first': values = [1] * 24
        elif kind.startswith('*const') and element == 'f64':
            if parameter == 'fg': values = [24.25, 52.5, 80.75]
            elif parameter == 'bg': values = [240.5, 240.5, 240.5]
            elif parameter == 'coeff': values = [225.5, .5, -.5, 228.5, -.5, .5, 231.5, .25, -.25]
            elif parameter == 'rects': values = [-1.25, 20.5, 4.75, 4.5, 20.25, 22.25, 9.5, 9.5]
            elif parameter == 'colors': values = [24.25, 52.5, 80.75, 240.5, 240.5, 240.5, -12.5, 22.25, 260.5, 128.5, 128.5, 128.5]
        args.append(arena.allocate(parameter, element, count, values))
    calls = []
    if name == 'glyph_seed':
        def pointer(parameter): return {'pointer': arena.buffers[parameter]['offset']}
        calls.append({'name': 'glyph_index', 'args': [pointer('rgba'), n, pointer('start'), pointer('order'),
                                                    arena.allocate('cursor', 'i32', 4096)]})
    aliases = []
    if variant == 'alias':
        parameters = [parameter for parameter, _ in signature['parameters']]
        if name == 'harmonic_fill':
            start = arena.buffers['work']['offset'] + n * 8
            arena.data[start:start + n * 4] = bytes(rgba)
            args[parameters.index('p')] = {'pointer': start}
            aliases.append('p aliases last third of Float32 work')
        if name == 'exemplar_fill':
            args[parameters.index('work')] = {'pointer': arena.buffers['rgba']['offset']}
            aliases.append('work aliases rgba')
        if name == 'local_components':
            args[parameters.index('member')] = {'pointer': arena.buffers['seen']['offset']}
            aliases.append('member aliases seen after component walk')
    calls.append({'name': name, 'args': args})
    return {'id': f'{name}-{seed}-{variant}', 'name': name, 'seed': seed, 'variant': variant,
            'buffers': arena.buffers, 'aliases': aliases, 'calls': calls, 'data': base64.b64encode(arena.data).decode()}


def fixtures():
    abi = signatures()
    cases = [fixture(name, signature, seed, variant) for name, signature in abi.items()
             for seed, variant in [(17, 'active'), (42, 'fractional-negative'), (91, 'polygon-protected')]]
    for name in ['bins_inside', 'caption_mask']:
        cases.append(fixture(name, abi[name], 17, 'alpha-rejection'))
    cases.append(fixture('glyph_seed', abi['glyph_seed'], 17, 'below-threshold'))
    for name in ['harmonic_fill', 'exemplar_fill', 'local_components']:
        cases.append(fixture(name, abi[name], 17, 'alias'))
    for variant in ['half-even-low', 'half-even-high']:
        cases.append(fixture('local_components', abi['local_components'], 17, variant))
    return abi, cases
