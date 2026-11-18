#!/usr/bin/env python3
"""Pinned Manga v0.3 conversion with dynamic shapes and compact LM alternatives.

Converts only reviewed ONNX operators. Never imports publisher demo code.
Candidates stay isolated until native parity and corpus checks pass.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import time

import coremltools as ct
import numpy as np
import onnx
import onnx2torch
import onnxruntime as ort
import torch
from torch import nn
import torch.nn.functional as F

ROOT = Path(__file__).resolve().parents[3]
REVISION = '6dabccae4be17cbe362028eed1572546a0a987f2'


class SameUpperConv(nn.Module):
    def __init__(self, conv):
        super().__init__(); self.conv = conv
        pair = lambda value:(value, value) if isinstance(value, int) else tuple(value)
        self.kh, self.kw = pair(conv.kernel_size)
        self.sh, self.sw = pair(conv.stride)
        self.dh, self.dw = pair(conv.dilation)
        self.padValue = float('-inf') if isinstance(conv, nn.MaxPool2d) else 0.

    def forward(self, x):
        h, w = x.size(-2), x.size(-1)
        ph = max(0, ((h + self.sh - 1) // self.sh - 1) * self.sh + (self.kh - 1) * self.dh + 1 - h)
        pw = max(0, ((w + self.sw - 1) // self.sw - 1) * self.sw + (self.kw - 1) * self.dw + 1 - w)
        return self.conv(F.pad(x, [pw // 2, pw - pw // 2, ph // 2, ph - ph // 2], value=self.padValue))


def install_same_padding():
    from onnx2torch.node_converters.registry import _CONVERTER_REGISTRY
    from onnx2torch.utils.common import OperationConverterResult
    for key, original in list(_CONVERTER_REGISTRY.items()):
        if key.operation_type not in ['Conv', 'MaxPool']:
            continue

        def convert(node, graph, original=original):
            attributes = node.attributes
            if attributes.get('auto_pad', 'NOTSET') != 'SAME_UPPER':
                return original(node, graph)
            local = copy.copy(node)
            local._proto_attributes = dict(attributes, auto_pad='NOTSET')
            result = original(local, graph)
            if not isinstance(result.torch_module, (nn.Conv2d, nn.MaxPool2d)):
                raise ValueError('Unexpected SAME_UPPER operator')
            return OperationConverterResult(torch_module=torch.jit.script(SameUpperConv(result.torch_module)),
                                            onnx_mapping=result.onnx_mapping)
        _CONVERTER_REGISTRY[key] = convert


def fold_constant_identity(model):
    initializers = {value.name for value in model.graph.initializer}
    aliases = {}
    retained = []
    outputs = {value.name for value in model.graph.output}
    for node in model.graph.node:
        for i, name in enumerate(node.input):
            node.input[i] = aliases.get(name, name)
        if node.op_type == 'Identity' and node.input[0] in initializers and node.output[0] not in outputs:
            aliases[node.output[0]] = node.input[0]
        else:
            retained.append(node)
    del model.graph.node[:]
    model.graph.node.extend(retained)
    return model


def install_dynamic_pad():
    from coremltools.converters.mil.frontend.torch import ops
    from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
    from coremltools.converters.mil.mil import Builder as mb, Var
    original = ops.pad

    @register_torch_op(torch_alias=['constant_pad_nd'], override=True)
    def pad(context, node):
        inputs = ops._get_inputs(context, node, expected=(3, 4))
        x, pads = inputs[:2]
        if not isinstance(pads, (list, tuple)):
            return original(context, node)
        if node.kind == 'pad':
            mode, value = inputs[2], inputs[3]
        else:
            mode, value = 'constant', inputs[2]
        mode = mode.val if isinstance(mode, Var) else mode
        value = value.val if isinstance(value, Var) else value
        if mode != 'constant':
            raise ValueError('Unexpected dynamic padding mode')
        ordered = [0, 0] * (x.rank - len(pads) // 2)
        for i in range(len(pads) - 2, -1, -2):
            ordered.extend(pads[i:i + 2])
        pieces = []
        for item in ordered:
            item = mb.const(val=np.int32(item)) if not isinstance(item, Var) else item
            item = mb.cast(x=item, dtype='int32')
            pieces.append(mb.expand_dims(x=item, axes=[0]))
        vector = mb.concat(values=pieces, axis=0)
        context.add(mb.pad(x=x, pad=vector, mode='constant', constant_val=float(value or 0), name=node.name))


class CompactRecognizer(nn.Module):
    def __init__(self, model):
        super().__init__(); self.model = model

    def forward(self, x):
        probability = self.model(x)
        scores, indices = torch.topk(probability, 4, dim=-1, sorted=True)
        return indices[:, :, 0].to(torch.int32), scores[:, :, 0], indices.to(torch.int32), scores


class DynamicShape(nn.Module):
    def __init__(self, start=0, end=None):
        super().__init__(); self.start = start; self.end = end

    def forward(self, x):
        return torch._shape_as_tensor(x)[self.start:self.end]


def preserve_dynamic_shape(core):
    from onnx2torch.node_converters.shape import OnnxShape
    for name, module in list(core.named_modules()):
        if isinstance(module, OnnxShape):
            parent_name, _, leaf = name.rpartition('.')
            parent = core.get_submodule(parent_name) if parent_name else core
            setattr(parent, leaf, DynamicShape(module._start, module._end))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('component', choices=['det', 'rec'])
    parser.add_argument('--out', type=Path, default=ROOT / 'model-refresh-20261106/ocr-v03')
    args = parser.parse_args(); out = args.out.resolve(); out.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(4); install_same_padding(); install_dynamic_pad()
    path = out / f'{args.component}.onnx'
    expected = {'det': '97c434ae8deaad83513fb132b605d5085a3af8ffac2cb15e2aa096815c206172',
                'rec': '5288bd221a9a047c6b7d1ff56bb98de8c875fb613df98ebe8754946448bda540'}
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected[args.component]:
        raise ValueError('Pinned ONNX source hash mismatch')
    start = time.monotonic(); report = dict(component=args.component, revision=REVISION, phase='onnx-to-torch')
    receipt = out / f'{args.component}-conversion.json'
    def save():
        receipt.write_text(json.dumps(report, indent=2))
    save()
    core = onnx2torch.convert(fold_constant_identity(onnx.load(path))).eval()
    preserve_dynamic_shape(core)
    options = ort.SessionOptions(); options.intra_op_num_threads = 4; options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(path), sess_options=options, providers=['CPUExecutionProvider'])
    shapes = [(1, 3, 64, 96), (1, 3, 96, 128)] if args.component == 'det' else [(1, 3, 48, 320), (1, 3, 48, 127), (2, 3, 48, 641)]
    rng = np.random.default_rng(20261106); inputs = [rng.normal(0, .4, s).astype(np.float32) for s in shapes]
    comparisons = []
    with torch.inference_mode():
        for x in inputs:
            reference = session.run(None, {'x': x})[0]; actual = core(torch.from_numpy(x)).numpy()
            np.testing.assert_allclose(reference, actual, atol=2e-4, rtol=2e-3)
            comparisons.append(dict(shape=list(x.shape), maxAbs=float(np.max(np.abs(reference - actual)))))
    report.update(phase='trace', onnxTorchParity=comparisons); save()
    model = CompactRecognizer(core).eval() if args.component == 'rec' else core
    with torch.inference_mode():
        traced = torch.jit.trace(model, torch.from_numpy(inputs[0]), check_trace=False)
        traced = torch.jit.freeze(traced.eval())
        for x in inputs:
            a, b = model(torch.from_numpy(x)), traced(torch.from_numpy(x))
            for expected_output, actual_output in zip(a if isinstance(a, tuple) else (a,), b if isinstance(b, tuple) else (b,)):
                torch.testing.assert_close(actual_output, expected_output, atol=2e-4, rtol=2e-3)
    report.update(phase='coreml-conversion'); save()
    if args.component == 'det':
        shape = (1, 3, ct.RangeDim(32, 1184, default=64), ct.RangeDim(32, 1184, default=96))
        outputs = [ct.TensorType(name='fetch_name_0', dtype=np.float32)]
        precision = ct.precision.FLOAT16
        name = 'PP-OCRv6-Manga-DetShapes.mlpackage'
    else:
        shape = (ct.RangeDim(1, 8, default=1), 3, 48, ct.RangeDim(32, 2400, default=320))
        outputs = [ct.TensorType(name='ctc_indices', dtype=np.int32), ct.TensorType(name='ctc_scores', dtype=np.float32),
                   ct.TensorType(name='ctc_topk_indices', dtype=np.int32), ct.TensorType(name='ctc_topk_scores', dtype=np.float32)]
        precision = ct.precision.FLOAT16
        name = 'PP-OCRv6-Manga-RecWidths.mlpackage'
    converted = ct.convert(traced, convert_to='mlprogram', inputs=[ct.TensorType(name='x', shape=shape, dtype=np.float32)],
                           outputs=outputs, minimum_deployment_target=ct.target.iOS18, compute_precision=precision,
                           skip_model_load=True)
    converted.user_defined_metadata.update({'source_revision': REVISION, 'source_model_version': 'v0.3',
        'source_onnx_sha256': expected[args.component], 'ngram_alternatives': '4' if args.component == 'rec' else 'none'})
    converted.save(str(out / name))
    report.update(phase='converted-candidate', package=str(out / name), seconds=time.monotonic() - start,
                  productionDeployed=False, dynamicTraceParity=True)
    save(); print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
