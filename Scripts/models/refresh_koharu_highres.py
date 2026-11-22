#!/usr/bin/env python3
"""Strict-load HighRes at its learned1920 lattice, lower inference input only."""
import argparse
import hashlib
import json
from pathlib import Path
import time
import types

import coremltools as ct
import numpy as np
from PIL import Image
from rfdetr import RFDETRSeg2XLarge
from safetensors.torch import load_file
import torch
import torchvision.transforms.functional as TF

ROOT = Path(__file__).resolve().parents[3]
MEAN = [0.485, 0.456, 0.406]
STD = [0.229, 0.224, 0.225]
NAMES = ["boxes", "logits", "instance_masks"]


def metrics(a, b):
    a, b = np.asarray(a), np.asarray(b)
    if a.shape != b.shape:
        raise ValueError(f"Output shape mismatch: {a.shape} != {b.shape}")
    delta = np.abs(a.astype(np.float64) - b.astype(np.float64))
    return {"shape": list(a.shape), "finite": bool(np.isfinite(b).all()),
            "max_abs": float(delta.max()), "mean_abs": float(delta.mean()),
            "rmse": float(np.sqrt(np.mean(delta * delta))),
            "reference_abs_max": float(np.abs(a).max())}


def rewrite_depthwise(model):
    """Inference-equivalent removal of upstream training-only PythonOp.

    _DepthwiseConvWithoutCuDNN.forward is exactly F.conv2d with these
    parameters; its custom backward and CUDA backend flag do not affect
    CPU inference. Patch only this model instance, never installed sources.
    """
    from rfdetr.models.heads.segmentation import DepthwiseConvBlock

    def plain_depthwise(self, x):
        return self.dwconv(x)

    names = []
    for name, child in model.named_modules():
        if isinstance(child, DepthwiseConvBlock):
            child._depthwise_conv = types.MethodType(plain_depthwise, child)
            names.append(name)
    return names


def specialize_proposal_grid():
    """Freeze only spatial dimensions for this explicitly fixed input ABI.

    JIT traces shape-derived linspace steps as scalar tensors. coremltools
    8.3 then builds rank-two linspace outputs and rejects the meshgrid.
    Constant integer H/W produces the same grid and avoids that frontend bug.
    """
    import rfdetr.models.transformer as transformer
    original = transformer.gen_encoder_output_proposals

    def fixed_grid(memory, memory_padding_mask=None, spatial_shapes=None, unsigmoid=True):
        shapes = [(int(h), int(w)) for h, w in spatial_shapes]
        return original(memory, memory_padding_mask, shapes, unsigmoid)

    transformer.gen_encoder_output_proposals = fixed_grid


def rewrite_deformable_attention(model):
    """Keep the same sampling arithmetic while avoiding rank-six tensors.

    Combine level*point in the offset tensor, then sample each feature level
    using the original bilinear zero-padding/align_corners=False operation.
    No learned parameters, sampling points, attention weights, or levels change.
    """
    import torch.nn.functional as F
    from rfdetr.models.ops.modules.ms_deform_attn import MSDeformAttn

    def rank_five_forward(self, query, reference_points, input_flatten,
                          input_spatial_shapes, input_level_start_index,
                          input_padding_mask=None, input_spatial_shapes_hw=None):
        batch, queries, _ = query.shape
        length = input_flatten.shape[1]
        shapes = [(int(h), int(w)) for h, w in input_spatial_shapes_hw]
        value = self.value_proj(input_flatten)
        if input_padding_mask is not None:
            value = value.masked_fill(input_padding_mask[..., None], 0.0)
        offsets = self.sampling_offsets(query).view(batch, queries, self.n_heads, self.n_levels * self.n_points, 2)
        weights = F.softmax(self.attention_weights(query).view(
            batch, queries, self.n_heads, self.n_levels * self.n_points), -1)
        value = value.transpose(1, 2).contiguous().view(batch, self.n_heads, self.d_model // self.n_heads, length)
        chunks = value.split([h * w for h, w in shapes], dim=3)
        samples = []
        for level, (height, width) in enumerate(shapes):
            offset = offsets[:, :, :, level * self.n_points:(level + 1) * self.n_points, :]
            center = reference_points[:, :, level, :2].unsqueeze(2).unsqueeze(3)
            if reference_points.shape[-1] == 4:
                size = reference_points[:, :, level, 2:].unsqueeze(2).unsqueeze(3)
                location = center + offset / self.n_points * size * 0.5
            else:
                normalizer = offset.new_tensor([width, height])
                location = center + offset / normalizer
            grid = (2 * location - 1).transpose(1, 2).flatten(0, 1)
            feature = chunks[level].view(batch * self.n_heads, self.d_model // self.n_heads, height, width)
            samples.append(F.grid_sample(feature, grid, mode="bilinear", padding_mode="zeros", align_corners=False))
        weights = weights.transpose(1, 2).reshape(batch * self.n_heads, 1, queries, self.n_levels * self.n_points)
        sampled = torch.stack(samples, dim=-2).flatten(-2)
        output = (sampled * weights).sum(-1).view(batch, self.d_model, queries).transpose(1, 2).contiguous()
        return self.output_proj(output)

    names = []
    for name, child in model.named_modules():
        if isinstance(child, MSDeformAttn):
            child.forward = types.MethodType(rank_five_forward, child)
            names.append(name)
    return names


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
    x = TF.normalize(TF.resize(TF.to_tensor(original), [side, side], antialias=True), MEAN, STD)[None]
    report.update(phase='stock-reference', sourceSize=list(original.size)); save()
    with torch.inference_mode():
        result = model(x)
        stock = {name:result[key].numpy() for name,key in zip(NAMES,['pred_boxes','pred_logits','pred_masks'])}
        del result
        np.savez_compressed(target / 'stock-parity.npz', **stock)
        model.export()
        report['rewrites'] = dict(depthwise=rewrite_depthwise(model),
                                  deformableAttention=rewrite_deformable_attention(model))
        specialize_proposal_grid()
        exported = dict(zip(NAMES, (value.numpy() for value in model(x))))
        report['stockExportParity'] = {name:metrics(stock[name], exported[name]) for name in NAMES}
        for name in NAMES:
            np.testing.assert_allclose(stock[name], exported[name], atol=.001, rtol=.001)
        report.update(phase='trace'); save()
        traced = torch.jit.trace(model, x, check_trace=False)
    report.update(phase='coreml-conversion'); save()
    package = target / f'KoharuHighres{side}{args.precision.upper()}.mlpackage'
    converted = ct.convert(traced, convert_to='mlprogram', minimum_deployment_target=ct.target.iOS18,
        inputs=[ct.TensorType(name='image', shape=(1,3,side,side), dtype=np.float32)],
        outputs=[ct.TensorType(name=name, dtype=np.float32) for name in NAMES],
        compute_precision=ct.precision.FLOAT16 if args.precision == 'fp16' else ct.precision.FLOAT32,
        skip_model_load=True)
    converted.user_defined_metadata.update({'source_revision':report['sourceRevision'], 'source_weights_sha256':expected,
        'weights_sha256':expected, 'fixed_resolution':str(side),
        'native_training_side':'1920', 'inference_side':str(side), 'original_resolution_preserved':'true'})
    converted.save(str(package)); del converted, detector, model, traced
    # The app reads only boxes and logits: drop the unused per-query masks (~400 MB of GPU buffers per call).
    model_file = package / 'Data/com.apple.CoreML/model.mlmodel'
    spec = ct.utils.load_spec(str(model_file))
    for block in spec.mlProgram.functions['main'].block_specializations.values():
        del block.outputs[NAMES.index('instance_masks')]
    del spec.description.output[NAMES.index('instance_masks')]
    model_file.write_bytes(spec.SerializeToString())
    report.update(phase='coreml-parity', package=str(package)); save()
    engine = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    actual = engine.predict({'image':x.numpy()})
    np.savez_compressed(target / 'coreml-parity.npz', **actual)
    report['coremlRawParity'] = {name:metrics(stock[name], actual[name]) for name in NAMES if name in actual}
    report.update(phase='converted-candidate', seconds=time.monotonic() - started)
    save(); print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
