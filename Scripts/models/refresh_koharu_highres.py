#!/usr/bin/env python3
"""Strict-load HighRes at its learned1920 lattice, lower inference input only."""
import argparse
import hashlib
import json
from pathlib import Path
import time

import coremltools as ct
import numpy as np
from PIL import Image
from rfdetr import RFDETRSeg2XLarge
from safetensors.torch import load_file
import torch
import torchvision.transforms.functional as TF

import convert_koharu_rfdetr as helpers

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--side', type=int, default=648)
    parser.add_argument('--precision', choices=['fp16', 'fp32'], default='fp16')
    args = parser.parse_args(); side = args.side
    if side % 24 or not 384 <= side <= 1920:
        parser.error('Side must be a multiple of24 within384…1920')
    root = ROOT / 'model-refresh-20261106/highres'
    target = root / (str(side) if args.precision == 'fp16' else f'{side}-fp32'); target.mkdir(exist_ok=True)
    weights = root / 'model.safetensors'
    expected = '03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255'
    if hashlib.sha256(weights.read_bytes()).hexdigest() != expected:
        raise ValueError('HighRes source checksum mismatch')
    torch.set_num_threads(4)
    report = dict(phase='strict-native1920-load', sourceRevision='53fef6f1301f4cbd8324ddc24f554b3767fc9e45',
                  sourceSHA256=expected, nativeTrainingSide=1920, inferenceSide=side,
                  originalImageResolutionPreserved=True, precision=args.precision, productionDeployed=False)
    started = time.monotonic()
    def save():
        (target / 'conversion.json').write_text(json.dumps(report, indent=2))
    save()
    detector = RFDETRSeg2XLarge(pretrain_weights=None, resolution=1920, positional_encoding_size=160,
                              num_select=160, num_classes=4, device='cpu')
    model = detector.model.model.cpu().eval()
    model.load_state_dict(load_file(str(weights), device='cpu'), strict=True)
    report['learnedPositionShape'] = list(model.backbone[0].encoder.encoder.embeddings.position_embeddings.shape)
    if report['learnedPositionShape'] != [1, 25601, 384]:
        raise ValueError('Native highres position lattice changed')
    model.backbone[0].encoder.shape = (side, side)
    detector.model.resolution = side; detector.model_config.resolution = side
    # Source pixels are numerical parity inputs only; no full-page visual review.
    sources = json.loads((ROOT / 'segmentation-accuracy-20261106/rf-full/sources.json').read_text())
    source = sources[0]
    original = Image.open(source['source']).convert('RGB')
    x = TF.normalize(TF.resize(TF.to_tensor(original), [side, side], antialias=True), helpers.MEAN, helpers.STD)[None]
    report.update(phase='stock-reference', sourceSize=list(original.size)); save()
    with torch.inference_mode():
        result = model(x)
        stock = {name:result[key].numpy() for name,key in zip(helpers.NAMES,['pred_boxes','pred_logits','pred_masks'])}
        del result
        np.savez_compressed(target / 'stock-parity.npz', **stock)
        model.export()
        report['rewrites'] = dict(depthwise=helpers.rewrite_depthwise(model),
                                  deformableAttention=helpers.rewrite_deformable_attention(model))
        helpers.specialize_proposal_grid()
        exported = dict(zip(helpers.NAMES, (value.numpy() for value in model(x))))
        report['stockExportParity'] = {name:helpers.metrics(stock[name], exported[name]) for name in helpers.NAMES}
        for name in helpers.NAMES:
            np.testing.assert_allclose(stock[name], exported[name], atol=.001, rtol=.001)
        report.update(phase='trace'); save()
        traced = torch.jit.trace(model, x, check_trace=False)
    report.update(phase='coreml-conversion'); save()
    package = target / f'KoharuHighres{side}{args.precision.upper()}.mlpackage'
    converted = ct.convert(traced, convert_to='mlprogram', minimum_deployment_target=ct.target.iOS18,
        inputs=[ct.TensorType(name='image', shape=(1,3,side,side), dtype=np.float32)],
        outputs=[ct.TensorType(name=name, dtype=np.float32) for name in helpers.NAMES],
        compute_precision=ct.precision.FLOAT16 if args.precision == 'fp16' else ct.precision.FLOAT32,
        skip_model_load=True)
    converted.user_defined_metadata.update({'source_revision':report['sourceRevision'], 'source_weights_sha256':expected,
        'weights_sha256':expected, 'fixed_resolution':str(side),
        'native_training_side':'1920', 'inference_side':str(side), 'original_resolution_preserved':'true'})
    converted.save(str(package)); del converted, detector, model, traced
    report.update(phase='coreml-parity', package=str(package)); save()
    engine = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    actual = engine.predict({'image':x.numpy()})
    np.savez_compressed(target / 'coreml-parity.npz', **actual)
    report['coremlRawParity'] = {name:helpers.metrics(stock[name], actual[name]) for name in helpers.NAMES}
    report.update(phase='converted-candidate', seconds=time.monotonic() - started)
    save(); print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
