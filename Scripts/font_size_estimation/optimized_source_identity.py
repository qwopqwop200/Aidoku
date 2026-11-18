"""Offline source-exclusion aliases for encoded files and native RGB8 images.

No model, features, predictions, labels, or inference routing are consulted.
Packaging uses ImageIO + the actual NativeRFDETRSourceImage Swift decoder on
macOS. Pillow RGB conversion is deliberately not used as a native identity:
alpha compositing, embedded profiles and integer rounding can change bytes.
Only the returned metadata mapping belongs in the mobile/host model bundle.
"""

from collections.abc import Mapping
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

_SOURCE_SWIFT = (
    Path(__file__).resolve().parents[2]
    / 'Aidoku/Core/Translation/NativeEngine/Layout/NativeRFDETRLayoutModels.swift'
)


def _sha(value, name):
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(char not in '0123456789abcdef' for char in value)
    ):
        raise ValueError(f'{name} must be a lowercase SHA256')
    return value


def native_rgb_identity(width, height, rgb):
    """Hash already-decoded top-left RGB8, exactly like the Swift identity."""
    if (
        type(width) is not int
        or type(height) is not int
        or min(width, height) <= 0
        or max(width, height) > 16384
        or width * height > 16777216
    ):
        raise ValueError('Invalid native source dimensions')
    data = bytes(rgb)
    if len(data) != width * height * 3:
        raise ValueError('Invalid packed RGB8 length')
    return hashlib.sha256(f'rf648-rgb8-v1:{width}x{height}:'.encode() + data).hexdigest()


def _swift_source():
    """Compile the production struct verbatim, not an approximation of decode."""
    text = _SOURCE_SWIFT.read_text()
    start = text.index('struct NativeRFDETRSourceImage: Sendable {')
    end = text.index('\n/// Compact raw mask logits', start)
    return (
        '''import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

enum NativeRFDETRLayoutError: Error { case sourceImageTooLarge, invalidImage }
'''
        + text[start:end]
        + '''
let input = FileHandle.standardInput.readDataToEndOfFile()
let paths = try JSONDecoder().decode([String].self, from: input)
var results: [[String: Any]] = []
for path in paths {
    let row: [String: Any] = try autoreleasepool {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NativeRFDETRLayoutError.invalidImage
        }
        let decoded = try NativeRFDETRSourceImage.decode(image)
        var row: [String: Any] = ["identity": decoded.identity,
                                  "width": decoded.width, "height": decoded.height]
        if ProcessInfo.processInfo.environment["FONT_IDENTITY_TEST_RGB"] == "1" {
            row["rgbBase64"] = decoded.rgb.base64EncodedString()
        }
        return row
    }
    results.append(row)
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
'''
    )


def _native_decoded_identities(paths, *, include_rgb=False):
    if sys.platform != 'darwin' or shutil.which('swiftc') is None:
        raise RuntimeError(
            'Exact native source packaging requires macOS ImageIO/CoreGraphics and swiftc'
        )
    with tempfile.TemporaryDirectory(prefix='font-source-identities-') as temporary:
        directory = Path(temporary)
        source = directory / 'main.swift'
        binary = directory / 'source-identities'
        source.write_text(_swift_source())
        subprocess.run(
            ['swiftc', '-O', str(source), '-o', str(binary)],
            check=True,
            capture_output=True,
            text=True,
        )
        import os

        env = dict(os.environ)
        if include_rgb:
            env['FONT_IDENTITY_TEST_RGB'] = '1'
        else:
            env.pop('FONT_IDENTITY_TEST_RGB', None)
        result = subprocess.run(
            [str(binary)],
            input=json.dumps([str(path) for path in paths]),
            capture_output=True,
            text=True,
            check=True,
            env=env,
        )
        decoded = json.loads(result.stdout)
    if len(decoded) != len(paths):
        raise ValueError('Native identity result count differs')
    for row in decoded:
        _sha(row['identity'], 'native RGB identity')
    return decoded


def _resolve(root, value):
    path = Path(value)
    return path if path.is_absolute() else root / path


def _verified_sources(research_root):
    root = Path(research_root).resolve()
    if not (root / 'round35/SOURCE-ONLY-MANIFEST.json').is_file():
        root = root / 'font-size-estimation-20261110'
    document = json.loads((root / 'round35/SOURCE-ONLY-MANIFEST.json').read_text())
    packets, sources = {}, {}
    for row in document['items']:
        file_sha = _sha(row['sourceImageSHA256'], 'sourceImageSHA256')
        provenance = row['sourceOCR']
        packet_path = _resolve(root.parent, provenance['path'])
        packet_sha = _sha(provenance['SHA256'], 'sourceOCR SHA256')
        key = str(packet_path.resolve())
        if key not in packets:
            raw = packet_path.read_bytes()
            if hashlib.sha256(raw).hexdigest() != packet_sha:
                raise ValueError(f'Source OCR packet checksum differs: {packet_path}')
            packet = json.loads(raw)
            image_path = _resolve(packet_path.parent, packet['image']).resolve()
            packets[key] = (packet_sha, image_path)
        actual_packet_sha, image_path = packets[key]
        if actual_packet_sha != packet_sha:
            raise ValueError(f'Conflicting OCR packet checksums: {packet_path}')
        if image_path not in sources:
            actual = hashlib.sha256(image_path.read_bytes()).hexdigest()
            sources[image_path] = actual
        if sources[image_path] != file_sha:
            raise ValueError(f'Source image checksum differs: {image_path}')
        yield file_sha, image_path


def extend_source_identity_aliases(research_root, aliases):
    """Return a copy with canonical native RGB aliases for verified source files.

    ``aliases`` maps encoded-file SHA256 to an existing stable exclusion group
    such as ``g:<connected-source-SHA256>``. Existing keys/values never change.
    Missing original guards, bad provenance, and pixel aliases that disagree
    with any existing/new group all fail closed. This is OFFLINE packaging;
    no image paths or per-source outputs are retained in the returned mapping.
    """
    if not isinstance(aliases, Mapping):
        raise ValueError('aliases must be a mapping')
    result = dict(aliases)
    for key, group in result.items():
        _sha(key, 'source alias')
        if not isinstance(group, str) or not group:
            raise ValueError('Exclusion groups must be nonempty stable strings')
    sources = {}
    for file_sha, image_path in _verified_sources(research_root):
        if file_sha not in result:
            raise ValueError(f'Missing encoded-source exclusion alias: {file_sha}')
        sources[(file_sha, image_path)] = result[file_sha]
    ordered = sorted(sources, key=lambda key: (key[0], str(key[1])))
    identities = _native_decoded_identities([path for _, path in ordered])
    # Recheck source bytes after native decoding, closing the ordinary packaging
    # race with an edited source image. Inputs are trusted local source assets.
    for (file_sha, path), decoded in zip(ordered, identities):
        if hashlib.sha256(path.read_bytes()).hexdigest() != file_sha:
            raise ValueError(f'Source image changed during identity packaging: {path}')
        identity = decoded['identity']
        group = sources[(file_sha, path)]
        if identity in result and result[identity] != group:
            raise ValueError(
                f'Conflicting native RGB alias {identity}: {result[identity]} versus {group}'
            )
        result[identity] = group
    return result


def _self_test():
    """Isolated native-decoder/provenance checks; no actual source bank needed."""
    import base64
    from unittest.mock import patch
    from PIL import Image, ImageCms

    with tempfile.TemporaryDirectory(prefix='font-identity-fixture-') as temporary:
        root = Path(temporary)
        research = root / 'research'
        (research / 'round35').mkdir(parents=True)
        fixtures = []
        rgb = Image.new('RGB', (3, 2))
        rgb.putdata(
            [(255, 0, 0), (0, 255, 0), (0, 0, 255), (1, 2, 3), (60, 80, 100), (200, 210, 220)]
        )
        rgb.save(root / 'opaque.png')
        fixtures.append(root / 'opaque.png')
        rgba = Image.new('RGBA', (3, 2))
        rgba.putdata(
            [
                (255, 0, 0, 0),
                (0, 255, 0, 255),
                (0, 0, 255, 128),
                (1, 2, 3, 64),
                (60, 80, 100, 192),
                (200, 210, 220, 255),
            ]
        )
        rgba.save(root / 'alpha.png')
        fixtures.append(root / 'alpha.png')
        profile = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
        rgb.save(root / 'icc.png', icc_profile=profile)
        fixtures.append(root / 'icc.png')
        p3 = Path('/System/Library/ColorSync/Profiles/Display P3.icc').read_bytes()
        rgb.save(root / 'p3.png', icc_profile=p3)
        fixtures.append(root / 'p3.png')
        rgba.save(root / 'p3-alpha.png', icc_profile=p3)
        fixtures.append(root / 'p3-alpha.png')
        decoded = _native_decoded_identities(fixtures, include_rgb=True)
        pillow_comparison = {}
        for path, row in zip(fixtures, decoded):
            data = base64.b64decode(row['rgbBase64'])
            assert native_rgb_identity(row['width'], row['height'], data) == row['identity']
            with Image.open(path) as image:
                converted = image.convert('RGBA')
                white = Image.new('RGBA', image.size, (255, 255, 255, 255))
                pillow = Image.alpha_composite(white, converted).convert('RGB').tobytes()
                if image.info.get('icc_profile'):
                    converted = ImageCms.profileToProfile(
                        image.convert('RGB'),
                        ImageCms.ImageCmsProfile(
                            __import__('io').BytesIO(image.info['icc_profile'])
                        ),
                        ImageCms.createProfile('sRGB'),
                        outputMode='RGB',
                    )
                    converted = converted.convert('RGBA')
                    converted.putalpha(image.convert('RGBA').getchannel('A'))
                    pillow = Image.alpha_composite(white, converted).convert('RGB').tobytes()
            pillow_comparison[path.name] = dict(
                exact=pillow == data, differentBytes=sum(a != b for a, b in zip(pillow, data))
            )
        assert pillow_comparison['opaque.png']['exact']
        assert pillow_comparison['icc.png']['exact']
        assert base64.b64decode(decoded[1]['rgbBase64'])[:3] == bytes((255, 255, 255))
        rows, aliases = [], {}
        # Opaque and ICC encode the same RGB: put them in the same stable group.
        for index, path in enumerate(fixtures):
            file_sha = hashlib.sha256(path.read_bytes()).hexdigest()
            packet = root / f'ocr-{index}.json'
            packet.write_text(json.dumps({'image': str(path), 'regions': []}))
            rows.append(
                {
                    'sourceImageSHA256': file_sha,
                    'sourceOCR': {
                        'path': str(packet),
                        'SHA256': hashlib.sha256(packet.read_bytes()).hexdigest(),
                    },
                }
            )
            aliases[file_sha] = (
                'g:alpha' if index == 1 else 'g:opaque' if index < 3 else f'g:profile{index}'
            )
        manifest = research / 'round35/SOURCE-ONLY-MANIFEST.json'
        manifest.write_text(json.dumps({'items': rows}))
        native_result = [
            {key: row[key] for key in ('identity', 'width', 'height')} for row in decoded
        ]
        by_path = dict(zip([path.resolve() for path in fixtures], native_result))
        with patch(
            __name__ + '._native_decoded_identities',
            side_effect=lambda paths: [by_path[path] for path in paths],
        ):
            extended = extend_source_identity_aliases(research, aliases)
            assert all(extended[key] == value for key, value in aliases.items())
            assert extended[decoded[1]['identity']] == 'g:alpha'
            conflict = dict(aliases)
            conflict[rows[2]['sourceImageSHA256']] = 'g:conflict'
            try:
                extend_source_identity_aliases(research, conflict)
                raise AssertionError('RGB alias conflict was accepted')
            except ValueError as error:
                assert 'Conflicting native RGB alias' in str(error)
            (root / 'ocr-0.json').write_text('{}')
            try:
                extend_source_identity_aliases(research, aliases)
                raise AssertionError('Changed OCR provenance was accepted')
            except ValueError as error:
                assert 'checksum differs' in str(error)
        return dict(
            nativeProductionDecoderVerbatim=True,
            hashProtocolExact=True,
            fixturePillowComparison=pillow_comparison,
            alphaWhite=True,
            embeddedSRGBProfile=True,
            displayP3AndAlphaProfiles=True,
            originalAliasPreservation=True,
            conflictingPixelGroupRejected=True,
            changedOCRPacketRejected=True,
        )


if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--research-root', type=Path)
    parser.add_argument('--aliases', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.self_test:
        report = _self_test()
        print(json.dumps(report, indent=2))
    else:
        if any(value is None for value in (args.research_root, args.aliases, args.output)):
            parser.error('packaging requires --research-root, --aliases and --output')
        result = extend_source_identity_aliases(
            args.research_root, json.loads(args.aliases.read_text())
        )
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
        print(json.dumps({'aliases': len(result), 'output': str(args.output)}))
