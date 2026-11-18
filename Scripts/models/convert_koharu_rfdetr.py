#!/usr/bin/env python3
"""Faithful, fixed 1152 Koharu RF-DETR Core ML feasibility and host parity.

Run from the repository root (all caches and outputs are isolated):
  uv venv --python 3.11 build/koharu-mobile/rfdetr-env
  UV_CACHE_DIR=build/koharu-mobile/rfdetr/uv-cache uv pip install \
    --python build/koharu-mobile/rfdetr-env/bin/python rfdetr==1.7.0 \
    torch==2.7.0 torchvision==0.22.0 transformers==5.1.0 \
    coremltools==8.3.0 numpy==1.26.4 protobuf==5.29.5 safetensors==0.8.0
  build/koharu-mobile/rfdetr-env/bin/python Scripts/models/convert_koharu_rfdetr.py

No remote Python is executed. No app sources or Swift hosts are modified.
Tensor ABI uses pre-normalized RGB float32 NCHW; resizing belongs to the host.
The legacy comparison defaults to native 1152. --stage resolution creates
isolated fixed-shape FP16 candidates under rf-resolution, including parity.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import resource
import time
import traceback
import types
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/koharu-mobile/rfdetr"
REVISION = "aed55fdb8ca953c6bec33cf6ed6dd52a9b72bfa2"
REPO = "mayocream/koharu-layout-rfdetr-seg-2xl-1152"
WEIGHTS_SHA256 = "9bf6d2cbd7793c956d8c857bb1672a396eb7f100eb0682f86830d05e31168efb"
MEAN = [0.485, 0.456, 0.406]
STD = [0.229, 0.224, 0.225]
NAMES = ["boxes", "logits", "instance_masks"]


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def save_json(path, data):
    path.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")


def download(name):
    path = OUT / name
    if not path.exists():
        temporary = path.with_suffix(path.suffix + ".partial")
        with urllib.request.urlopen(f"https://huggingface.co/{REPO}/resolve/{REVISION}/{name}") as source:
            with temporary.open("wb") as target:
                while block := source.read(1024 * 1024):
                    target.write(block)
        temporary.replace(path)
    return path


def timed(fn):
    start = time.perf_counter()
    value = fn()
    return value, time.perf_counter() - start


def metrics(a, b):
    import numpy as np
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
    import torch
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


def chunk_global_attention(model, chunk_size=256):
    """Independent query chunks retain all keys/values and exact SDPA semantics.

    No local-attention approximation: every query still attends every key.
    Only global (more than 4096 keys) attention is split, bounding a logical
    score buffer to B*heads*256*keys rather than B*heads*queries*keys.
    """
    import torch
    import torch.nn.functional as F
    from rfdetr.models.backbone.dinov2_with_windowed_attn import Dinov2WithRegistersSdpaSelfAttention

    def chunked(self, hidden_states, output_attentions=False):
        if output_attentions or self.training:
            raise ValueError("Chunked export is strictly eval with output_attentions=False")
        q = self.transpose_for_scores(self.query(hidden_states))
        k = self.transpose_for_scores(self.key(hidden_states))
        v = self.transpose_for_scores(self.value(hidden_states))
        if k.shape[-2] > 4096:
            output = torch.cat([F.scaled_dot_product_attention(q[:, :, start:start + chunk_size], k, v,
                attn_mask=None, dropout_p=0.0, is_causal=False)
                for start in range(0, int(q.shape[-2]), chunk_size)], dim=2)
        else:
            output = F.scaled_dot_product_attention(q, k, v, attn_mask=None, dropout_p=0.0, is_causal=False)
        output = output.permute(0, 2, 1, 3).contiguous()
        return (output.view(output.shape[0], output.shape[1], self.all_head_size),)

    names = []
    for name, child in model.named_modules():
        if isinstance(child, Dinov2WithRegistersSdpaSelfAttention):
            child._unchunked_forward = child.forward
            child.forward = types.MethodType(chunked, child)
            names.append(name)
    return names


def probe_wrapper(model):
    """Expose encoder features/scores/topk without changing inference values."""
    import torch

    class Probes(torch.nn.Module):
        def __init__(self, core):
            super().__init__()
            self.core = core
            self.values = {}
            core.backbone.register_forward_hook(self.backbone_hook)
            core.transformer.enc_out_class_embed[0].register_forward_hook(self.logits_hook)
            core.transformer.register_forward_hook(self.transformer_hook)

        def backbone_hook(self, module, inputs, output):
            self.values["features"] = output[0][0]

        def logits_hook(self, module, inputs, output):
            self.values["logits"] = output

        def transformer_hook(self, module, inputs, output):
            self.values["ref_enc"] = output[3]

        def forward(self, image):
            outputs = self.core(image)
            scores = self.values["logits"]
            indices = torch.topk(scores.max(-1)[0], self.core.num_queries, dim=1)[1].to(torch.int32)
            return outputs + (self.values["features"], scores, indices, self.values["ref_enc"])

    return Probes(model).eval()


def compute_plan(model, units):
    """Record predicted host placement, never claim iPhone placement."""
    from coremltools.models.compute_plan import MLComputePlan
    plan = MLComputePlan.load_from_path(model.get_compiled_model_path(), compute_units=units)
    rows = []
    for op in plan.model_structure.program.functions["main"].block.operations:
        usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
        rows.append({"op": op.operator_name, "outputs": [o.name for o in op.outputs],
                     "preferred": type(usage.preferred_compute_device).__name__ if usage else None,
                     "supported": [type(d).__name__ for d in usage.supported_compute_devices] if usage else []})
    return {"scope": "host estimated placement only; not measured per-op execution or mobile placement",
            "counts": dict(Counter(f"{r['op']}:{r['preferred']}" for r in rows)), "operations": rows}


def attention_memory(package):
    """Inspect serialized MIL types, avoiding assumptions about hidden tokens."""
    import coremltools as ct
    spec = ct.models.utils.load_spec(str(package / "Data/com.apple.CoreML/model.mlmodel"))
    block = next(iter(spec.mlProgram.functions["main"].block_specializations.values()))
    types_by_name = {value.name: value.type for op in block.operations for value in op.outputs}
    rows = []
    for op in block.operations:
        if op.type != "scaled_dot_product_attention":
            continue
        q = types_by_name[op.inputs["query"].arguments[0].name].tensorType
        k = types_by_name[op.inputs["key"].arguments[0].name].tensorType
        shape = [int(d.constant.size) for d in q.dimensions]
        key_shape = [int(d.constant.size) for d in k.dimensions]
        count = shape[-2] * key_shape[-2]
        for dim in shape[:-2]:
            count *= dim
        rows.append({"query_shape": shape, "key_shape": key_shape,
                     "hypothetical_materialized_score_fp16_bytes": count * 2,
                     "hypothetical_materialized_score_fp32_bytes": count * 4,
                     "note": "fused SDPA: logical matrix sizes only, not measured allocation"})
    return rows


def half_constant_storage():
    """FP16 tensor constants with FP32 arithmetic: a distinct mixed variant.

    Explicit constexpr_cast remains in MIL; no custom operation is used.
    This isolates weight/constant rounding from FP16 activation/accumulation.
    """
    import numpy as np
    import coremltools as ct
    from coremltools.converters.mil.frontend.milproto.load import load
    from coremltools.converters.mil.mil import Builder as mb, Block
    source = OUT / "KoharuRFDETRSeg2XLarge1152FP32DiagnosticChunked.mlpackage"
    destination = OUT / "KoharuRFDETRSeg2XLarge1152FP32ChunkedHalfStorage.mlpackage"
    spec = ct.models.utils.load_spec(str(source / "Data/com.apple.CoreML/model.mlmodel"))
    program = load(spec, spec.specificationVersion, file_weights_dir=str(source / "Data/com.apple.CoreML/weights"))
    function = program.functions["main"]
    rows = []
    with function:
        for op in list(function.operations):
            if op.op_type != "const":
                continue
            original = op.outputs[0]
            value = original.val
            if not isinstance(value, np.ndarray) or value.dtype != np.float32 or value.ndim == 0 or value.size < 32:
                continue
            half_value = value.astype(np.float16)
            if not np.isfinite(half_value).all():
                continue
            half = mb.const(val=half_value, name=op.name + "_storage_fp16", before_op=op)
            restored = mb.constexpr_cast(source_val=half, output_dtype="fp32",
                                         name=op.name + "_arithmetic_fp32", before_op=op)
            Block._copy_metadata(original, restored)
            function.replace_uses_of_var_after_op(anchor_op=op, old_var=original, new_var=restored, force_replace=True)
            function.remove_ops([op])
            rows.append({"name": op.name, "shape": list(value.shape), "elements": int(value.size),
                         "max_rounding_abs": float(np.abs(value - half_value.astype(np.float32)).max())})
    model = ct.convert(program, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32, skip_model_load=True, pass_pipeline=ct.PassPipeline.EMPTY)
    model.user_defined_metadata.update({"source_revision": REVISION, "weights_sha256": WEIGHTS_SHA256,
        "precision": "FP16 tensor-constant storage; FP32 arithmetic; query-chunked full attention"})
    model.save(str(destination))
    save_json(OUT / "report-half-storage.json", {"source": str(source), "package": str(destination),
        "precision": "FP16 tensor-constant storage via constexpr_cast with FP32 arithmetic; not all-FP16 computation",
        "constants": rows, "package_bytes": sum(p.stat().st_size for p in destination.rglob("*") if p.is_file()),
        "attention_memory": attention_memory(destination), "quality_gate": "pending real selected-mask parity",
        "peak_host_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})


def summarize():
    """Generate a machine-readable handoff and a brief host-only comparison."""
    import numpy as np
    summary = {"source": {"repo": REPO, "revision": REVISION, "sha256": WEIGHTS_SHA256},
               "mobile_measurements": "owned by main; none performed here", "integration_approved": False,
               "classes": ["text", "sfx", "bubble", "panel"], "thresholds": [0.25, 0.20, 0.50, 0.50],
               "variants": [], "comparison": []}
    for name in ["report.json", "report-fp32-diagnostic.json", "report-mixed-attention-norm.json", "report-probe.json"]:
        path = OUT / name
        if not path.exists():
            continue
        report = json.loads(path.read_text())
        package = Path(report["package_path"])
        report["attention_memory"] = attention_memory(package)
        if name == "report.json":
            report["ane_compiler_diagnostic"] = {
                "message": "MILCompilerForANE error: failed to compile ANE model using ANEF; ANECCompile() FAILED",
                "logs": ["host-cpu-ane.log", "host-compute-plan.log"],
                "exact_failing_ane_op": None,
                "note": "compiler did not identify one op; host prediction completed despite compilation diagnostic"}
        save_json(path, report)
        row = {"report": name, "package": str(package), "package_bytes": report["package_bytes"],
               "export_status": report.get("export_status"), "raw_parity_pass": report.get("host_parity_pass"),
               "host_timings": {unit: {"load_compile_seconds": run["load_compile_seconds"],
                    "inputs": {key: {"first_seconds": value["first_seconds"],
                                     "warm_seconds": value["warm_seconds"], "raw_parity_pass": value["raw_parity_pass"]}
                               for key, value in run["inputs"].items()}}
                    for unit, run in report.get("host_coreml", {}).items()}}
        summary["variants"].append(row)
    # Existing YOLO artifacts are read only; resolutions/preprocessing differ.
    yolo_path = ROOT / "build/koharu-mobile/yolo/summary.json"
    if yolo_path.exists():
        for report in json.loads(yolo_path.read_text()):
            summary["comparison"].append({"family": "YOLO", "side": report["size"],
                "package_bytes": report["package_bytes"], "raw_parity_pass": report.get("parity_pass"),
                "host_cpu_seconds": report.get("host_timings", {}).get("cpu_only", {}).get("median_ms", 0) / 1000,
                "source_report": str(yolo_path)})
    baseline = json.loads((OUT / "report.json").read_text())
    summary["comparison"].append({"family": "RF-DETR", "side": 1152,
        "package_bytes": baseline["package_bytes"], "raw_parity_pass": baseline["host_parity_pass"],
        "host_cpu_seconds": baseline["host_coreml"]["CPU_ONLY"]["inputs"]["neutral"]["warm_seconds"][0],
        "source_report": str(OUT / "report.json")})
    summary["comparison_limits"] = "HOST ONLY; different resolutions/fixtures/warmup counts; not equal-quality accuracy or iPhone performance evidence"
    summary["class_mapping_yolo_to_rfdetr"] = {"0": 3, "1": 0, "2": 2, "3": 1}
    summary["device_candidate"] = str(OUT / "KoharuRFDETRSeg2XLarge1152FP16.mlpackage")
    summary["device_contract"] = str(OUT / "contract.json")
    summary["device_input"] = str(OUT / "neutral_input.f32")
    summary["device_input_bytes"] = (OUT / "neutral_input.f32").stat().st_size
    summary["device_gate"] = "Benchmark candidate only: exported, but FP16 raw host parity failed; do not treat as approved for integration"
    references = {}
    for key in ["neutral", "random"]:
        with np.load(OUT / f"{key}_reference.npz") as values:
            references[key] = {name: {"shape": list(values[name].shape), "first32": values[name].reshape(-1)[:32].tolist(),
                "mean": float(values[name].mean(dtype=np.float64)), "min": float(values[name].min()),
                "max": float(values[name].max())} for name in NAMES}
    save_json(OUT / "reference-summary.json", references)
    save_json(OUT / "handoff.json", summary)


def bounded_diagnostics(model, inputs, report, attention_only=False):
    """Counterfactual module exports fed identical, known PyTorch inputs.

    Each stage is isolated; input errors cannot cascade from a preceding
    converted module. Both inputs are neutral/generated RGB only.
    """
    import copy
    import numpy as np
    import torch
    import coremltools as ct
    directory = OUT / "bounded"
    directory.mkdir(exist_ok=True)
    model.export()
    dino = model.backbone[0].encoder.encoder
    first = dino.encoder.layer[0]
    report["eval_audit"] = {"any_training": any(m.training for m in model.modules()),
        "dropout": [{"name": name, "p": m.p, "training": m.training}
                    for name, m in model.named_modules() if isinstance(m, torch.nn.Dropout)],
        "sdpa": "attn_mask=None, dropout_p=0.0 in eval, is_causal=False, default 1/sqrt(64) scale"}

    class Single(torch.nn.Module):
        def __init__(self, core):
            super().__init__()
            self.core = core

        def forward(self, x):
            y = self.core(x)
            return y[0] if isinstance(y, tuple) else y

    stages = [("patch_projection", dino.embeddings.patch_embeddings.projection, "image"),
              ("embeddings", dino.embeddings, "image"),
              ("norm1", first.norm1, "embedding"),
              ("self_attention", first.attention.attention, "normalized"),
              ("layer0", first, "embedding")]
    if attention_only:
        stages = [("q_projection", first.attention.attention.query, "normalized"),
                  ("k_projection", first.attention.attention.key, "normalized"),
                  ("v_projection", first.attention.attention.value, "normalized")]
    stage_inputs = {}
    with torch.inference_mode():
        for key, x in inputs.items():
            image = torch.from_numpy(x)
            embedding = dino.embeddings(image)
            stage_inputs[key] = {"image": image, "embedding": embedding, "normalized": first.norm1(embedding)}
        report["bounded_modules"] = {}
        for name, core, input_key in stages:
            print(f"Bounded counterfactual: {name}", flush=True)
            wrapper = Single(core).eval()
            x = stage_inputs["neutral"][input_key]
            traced = torch.jit.trace(wrapper, x, check_trace=False)
            entry = {"input_shape": list(x.shape), "trace_ops": dict(Counter(n.kind() for n in traced.inlined_graph.nodes())),
                     "precision": {}}
            expected = {key: wrapper(values[input_key]).numpy() for key, values in stage_inputs.items()}
            try:
                half = Single(copy.deepcopy(core).half()).eval()
                entry["pytorch_half_vs_fp32"] = {key: metrics(expected[key], half(values[input_key].half()).float().numpy())
                                                 for key, values in stage_inputs.items()}
                del half
            except Exception as error:
                entry["pytorch_half_error"] = str(error)
            for precision in ["fp32", "fp16"]:
                converted = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
                    inputs=[ct.TensorType(name="x", shape=tuple(x.shape), dtype=np.float32)],
                    outputs=[ct.TensorType(name="y", dtype=np.float32)],
                    compute_precision=ct.precision.FLOAT32 if precision == "fp32" else ct.precision.FLOAT16,
                    compute_units=ct.ComputeUnit.CPU_ONLY)
                converted.save(str(directory / f"{name}_{precision}.mlpackage"))
                entry["precision"][precision] = {}
                for key, values in stage_inputs.items():
                    actual = converted.predict({"x": values[input_key].numpy()})["y"]
                    entry["precision"][precision][key] = metrics(expected[key], actual)
                    np.savez(directory / f"{name}_{precision}_{key}.npz", reference=expected[key], actual=actual)
                del converted
            report["bounded_modules"][name] = entry
            save_json(OUT / ("report-bounded-attention.json" if attention_only else "report-bounded.json"), report)
        if not attention_only:
            return

        class BareSDPA(torch.nn.Module):
            def __init__(self, manual=False):
                super().__init__()
                self.manual = manual

            def forward(self, q, k, v):
                if not self.manual:
                    return torch.nn.functional.scaled_dot_product_attention(q, k, v,
                        attn_mask=None, dropout_p=0.0, is_causal=False)
                chunks = []
                for start in range(0, int(q.shape[-2]), 128):
                    scores = torch.matmul(q[:, :, start:start + 128], k.transpose(-1, -2)) / (q.shape[-1] ** 0.5)
                    chunks.append(torch.matmul(torch.softmax(scores, dim=-1), v))
                return torch.cat(chunks, dim=2)

        attn = first.attention.attention
        triples = {key: tuple(attn.transpose_for_scores(proj(values["normalized"]))
                             for proj in [attn.query, attn.key, attn.value]) for key, values in stage_inputs.items()}
        for key, triple in triples.items():
            np.savez(directory / f"bare_sdpa_inputs_{key}.npz", **dict(zip(["q", "k", "v"], [t.numpy() for t in triple])))
        oracle = BareSDPA().eval()
        expected = {key: oracle(*triple).numpy() for key, triple in triples.items()}
        for manual in [False, True]:
            name = "manual_sdpa_chunks128" if manual else "bare_sdpa"
            wrapper = BareSDPA(manual).eval()
            traced = torch.jit.trace(wrapper, triples["neutral"], check_trace=False)
            entry = {"input_shapes": [list(t.shape) for t in triples["neutral"]],
                     "trace_ops": dict(Counter(n.kind() for n in traced.inlined_graph.nodes())), "precision": {},
                     "torch_fp32_vs_sdpa": {key: metrics(expected[key], wrapper(*triple).numpy()) for key, triple in triples.items()},
                     "torch_fp16_vs_sdpa": {key: metrics(expected[key], wrapper(*(t.half() for t in triple)).float().numpy()) for key, triple in triples.items()}}
            for precision in ["fp32", "fp16"]:
                converted = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
                    inputs=[ct.TensorType(name=key, shape=tuple(t.shape), dtype=np.float32)
                            for key, t in zip(["q", "k", "v"], triples["neutral"])],
                    outputs=[ct.TensorType(name="y", dtype=np.float32)],
                    compute_precision=ct.precision.FLOAT32 if precision == "fp32" else ct.precision.FLOAT16,
                    compute_units=ct.ComputeUnit.CPU_ONLY)
                converted.save(str(directory / f"{name}_{precision}.mlpackage"))
                entry["precision"][precision] = {}
                for key, triple in triples.items():
                    actual = converted.predict(dict(zip(["q", "k", "v"], [t.numpy() for t in triple])))["y"]
                    entry["precision"][precision][key] = metrics(expected[key], actual)
                    np.savez(directory / f"{name}_{precision}_{key}.npz", reference=expected[key], actual=actual)
                del converted
            report["bounded_modules"][name] = entry
            save_json(OUT / "report-bounded-attention.json", report)


def real_parity(model, report, fixture="xkcd"):
    """Selected detections/masks on an explicitly nonsexual real comic.

    This measures conversion parity against pinned PyTorch, not human-label
    accuracy. Matching uses class and box IoU rather than query position.
    """
    import numpy as np
    import torch
    import torchvision.transforms.functional as TF
    import coremltools as ct
    from PIL import Image
    from scipy.optimize import linear_sum_assignment
    fixture_hashes = {"xkcd": "1489aef471a4ed7cda5e1c69bf9ce9d51395bd2e781346216f025e208c95756b",
        "peppercarrot_01": "f1de30872ce216b4ea57f6d99110867ba44396211119ffd20bce6277332f64d3",
        "peppercarrot_02": "7696832a48b3cd75a2c8faef7827e0abe69cce987b28aea6a60865955f0ed803",
        "peppercarrot_03": "2555dff43af17bf07e2c01758c5f3ef0c03d5588c7a9d1e0f08d2d63d5c4b278"}
    fixture_hashes["peppercarrot_ja01"] = "3bef9922e09cea66ab12271da0070025768ae9bc5d286f41ced617468131267e"
    stem = "xkcd_compiling" if fixture == "xkcd" else fixture
    path = OUT / (stem + (".png" if fixture == "xkcd" else ".jpg"))
    url = "https://imgs.xkcd.com/comics/compiling.png" if fixture == "xkcd" else (
        "https://www.peppercarrot.com/0_sources/ep01_Potion-of-Flight/low-res/"
        f"{'ja' if 'ja' in fixture else 'en'}_Pepper-and-Carrot_by-David-Revoy_E01P{fixture[-2:]}.jpg")
    if not path.exists():
        with urllib.request.urlopen(url) as response:
            path.write_bytes(response.read())
    if digest(path) != fixture_hashes[fixture]:
        raise ValueError("Nonsexual fixture checksum changed")
    image = Image.open(path).convert("RGB")
    width, height = image.size
    x = TF.normalize(TF.resize(TF.to_tensor(image), [1152, 1152], antialias=True), MEAN, STD).unsqueeze(0)
    x.numpy().tofile(OUT / f"{stem}_input.f32")
    with torch.inference_mode():
        y = model(x)
        reference = {name: y[key].numpy() for name, key in zip(NAMES, ["pred_boxes", "pred_logits", "pred_masks"])}
        np.savez(OUT / f"{stem}_reference.npz", **reference)
        del y

    def select(values):
        logits = values["logits"][0]
        scores = 1 / (1 + np.exp(-logits))
        indices = np.argsort(-scores.reshape(-1), kind="stable")[:160]
        queries, classes = indices // logits.shape[-1], indices % logits.shape[-1]
        kept = np.array([c < 4 and scores[q, c] >= [0.25, 0.20, 0.50, 0.50][c] for q, c in zip(queries, classes)])
        queries, classes = queries[kept], classes[kept]
        cxcywh = values["boxes"][0, queries]
        boxes = np.concatenate([cxcywh[:, :2] - cxcywh[:, 2:] / 2,
                                cxcywh[:, :2] + cxcywh[:, 2:] / 2], axis=-1)
        masks = torch.from_numpy(values["instance_masks"][0, queries]).unsqueeze(1)
        masks = (torch.nn.functional.interpolate(masks, size=(height, width), mode="bilinear", align_corners=False)[:, 0] > 0).numpy() if len(queries) else np.zeros((0, height, width), bool)
        return {"queries": queries, "classes": classes, "scores": scores[queries, classes], "boxes": boxes, "masks": masks}

    expected = select(reference)
    result = {"fixture": str(path), "fixture_sha256": digest(path), "original_size": [height, width],
              "source": url, "title": "Compiling" if fixture == "xkcd" else "Pepper&Carrot: The Potion of Flight",
              "license": "CC BY-NC 2.5" if fixture == "xkcd" else "CC BY 4.0, David Revoy",
              "scope": "nonsexual real comic, selected-mask parity to PyTorch; no human ground-truth accuracy claim",
              "reference_count": len(expected["queries"]), "variants": {}}
    np.savez(OUT / f"{fixture}_selected_reference.npz", **expected)
    result_path = OUT / ("real-selected-parity.json" if fixture == "xkcd" else f"{fixture}_selected_parity.json")
    for precision, suffix in [("fp16", "FP16"), ("fp32", "FP32Diagnostic"),
                              ("mixed_attention_norm", "FP16MixedAttentionNorm"),
                              ("fp32_chunked", "FP32DiagnosticChunked"),
                              ("fp16_storage_fp32_chunked", "FP32ChunkedHalfStorage")]:
        package = OUT / f"KoharuRFDETRSeg2XLarge1152{suffix}.mlpackage"
        if not package.exists():
            continue
        print(f"Real selected-mask parity: {precision}", flush=True)
        try:
            mlmodel = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
        except Exception as error:
            result["variants"][precision] = {"package": str(package), "selected_parity_pass": False,
                                            "compile_error": str(error)}
            save_json(result_path, result)
            continue
        actual, seconds = timed(lambda: mlmodel.predict({"image": x.numpy()}))
        selected = select(actual)
        np.savez(OUT / f"{fixture}_selected_{precision}.npz", **selected)
        pairs = []
        for cls in range(4):
            a_idx = np.flatnonzero(expected["classes"] == cls)
            b_idx = np.flatnonzero(selected["classes"] == cls)
            if not len(a_idx) or not len(b_idx):
                continue
            a, b = expected["boxes"][a_idx], selected["boxes"][b_idx]
            lo = np.maximum(a[:, None, :2], b[None, :, :2])
            hi = np.minimum(a[:, None, 2:], b[None, :, 2:])
            intersection = np.prod(np.maximum(hi - lo, 0), axis=-1)
            area_a = np.prod(np.maximum(a[:, 2:] - a[:, :2], 0), axis=-1)
            area_b = np.prod(np.maximum(b[:, 2:] - b[:, :2], 0), axis=-1)
            iou = intersection / np.maximum(area_a[:, None] + area_b[None, :] - intersection, 1e-12)
            rows, columns = linear_sum_assignment(-iou)
            for row, col in zip(rows, columns):
                ai, bi = int(a_idx[row]), int(b_idx[col])
                ma, mb = expected["masks"][ai], selected["masks"][bi]
                union = np.count_nonzero(ma | mb)
                pairs.append({"class": cls, "reference_query": int(expected["queries"][ai]),
                    "actual_query": int(selected["queries"][bi]), "box_iou": float(iou[row, col]),
                    "mask_iou": float(np.count_nonzero(ma & mb) / union) if union else 1.0,
                    "score_abs_delta": float(abs(expected["scores"][ai] - selected["scores"][bi]))})
        counts_equal = all(np.count_nonzero(expected["classes"] == c) == np.count_nonzero(selected["classes"] == c) for c in range(4))
        passed = bool(len(pairs) > 0 and counts_equal and len(pairs) == len(expected["queries"]) and
                      all(p["box_iou"] >= 0.99 and p["mask_iou"] >= 0.99 and p["score_abs_delta"] <= 0.005 for p in pairs))
        result["variants"][precision] = {"package": str(package), "host_cpu_first_seconds": seconds,
            "actual_count": len(selected["queries"]), "reference_classes": expected["classes"].tolist(),
            "actual_classes": selected["classes"].tolist(), "matches": pairs, "selected_parity_pass": passed,
            "raw_metrics": {name: metrics(reference[name], actual[name]) for name in NAMES}}
        save_json(result_path, result)
        del actual, selected, mlmodel
    report.setdefault("real_selected_parity", {})[fixture] = result


def host_benchmark(args):
    """Core ML-only process: keep PyTorch reference/tracing memory separate."""
    import numpy as np
    import coremltools as ct
    suffix = "FP16" if args.precision == "fp16" else "FP32Diagnostic"
    if args.fp32_attention_norm:
        suffix += "MixedAttentionNorm"
    if args.chunk_attention:
        suffix += "Chunked"
    if args.half_storage_model:
        suffix = "FP32ChunkedHalfStorage"
    package = OUT / f"KoharuRFDETRSeg2XLarge1152{suffix}.mlpackage"
    fixture = OUT / ("xkcd_compiling_input.f32" if args.fixture == "xkcd" else f"{args.fixture}_input.f32")
    x = np.fromfile(fixture, dtype="<f4").reshape(1, 3, 1152, 1152)
    model, load_seconds = timed(lambda: ct.models.MLModel(str(package), compute_units=getattr(ct.ComputeUnit, args.compute_units)))
    first, first_seconds = timed(lambda: model.predict({"image": x}))
    del first
    times = []
    for _ in range(args.runs):
        actual, seconds = timed(lambda: model.predict({"image": x}))
        times.append(seconds)
        del actual
    save_json(OUT / f"host-{suffix}-{args.compute_units}-{args.fixture}.json", {
        "scope": "Core ML-only macOS host process; not mobile performance/memory or accuracy proof",
        "package": str(package), "fixture": str(fixture), "load_compile_seconds": load_seconds,
        "first_seconds": first_seconds, "warm_seconds": times, "warm_median_seconds": float(np.median(times)),
        "peak_host_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "device_memory_budget_bytes": 2 * 1024 ** 3, "device_budget_measured": False})


def device_fixture():
    """Package stock outputs, not converted outputs, for main's device dump."""
    import numpy as np
    fixture = OUT / "peppercarrot_ja01_input.f32"
    with np.load(OUT / "peppercarrot_ja01_selected_reference.npz") as selected:
        values = {key: selected[key] for key in selected.files}
    with np.load(OUT / "peppercarrot_ja01_reference.npz") as stock:
        query_ids = values["queries"].astype(np.int32)
        native_boxes = stock["boxes"][0, query_ids]
        mask_logits = stock["instance_masks"][0, query_ids]
    height, width = values["masks"].shape[-2:]
    normalized = values["boxes"]
    pixels = normalized * np.array([width, height, width, height], np.float32)
    compact = OUT / "peppercarrot_ja01_stock_selected.npz"
    np.savez_compressed(compact, query_ids=query_ids, class_ids=values["classes"].astype(np.int32),
        scores=values["scores"].astype(np.float32), boxes_cxcywh_normalized=native_boxes,
        boxes_xyxy_normalized=normalized, boxes_xyxy_pixels=pixels,
        mask_logits_native=mask_logits, masks_original=values["masks"],
        original_size_hw=np.array([height, width], np.int32))
    manifest = {"input": {"path": str(fixture), "sha256": digest(fixture), "bytes": fixture.stat().st_size,
                "dtype": "little-endian float32", "shape": [1, 3, 1152, 1152], "layout": "NCHW RGB",
                "preprocessing": "stock torchvision RGB to_tensor, bilinear antialias resize 1152x1152, then normalize",
                "mean": MEAN, "std": STD, "already_normalized": True},
        "stock_selected_npz": str(compact), "stock_selected_npz_sha256": digest(compact),
        "stock_selected_npz_bytes": compact.stat().st_size,
        "source": "strict pinned SafeTensors stock PyTorch forward; not any Core ML candidate",
        "revision": REVISION, "weights_sha256": WEIGHTS_SHA256, "original_size_hw": [height, width],
        "num_select": 160, "thresholds": [0.25, 0.20, 0.50, 0.50],
        "class_names": ["text", "sfx", "bubble", "panel"],
        "selection": "top160 flattened sigmoid over all 300x5 logits, then class0..3 and >= class threshold",
        "mask_decode": "select query logits; bilinear resize 288x288 to original H,W align_corners=False, threshold >0; no box crop",
        "device_raw_outputs": {"boxes": [1, 300, 4], "logits": [1, 300, 5], "instance_masks": [1, 300, 288, 288]},
        "selected": [{"query_id": int(q), "class_id": int(c), "class": ["text", "sfx", "bubble", "panel"][int(c)],
                     "score": float(s), "box_cxcywh_normalized": b.tolist(), "box_xyxy_pixels": p.tolist()}
                    for q, c, s, b, p in zip(query_ids, values["classes"], values["scores"], native_boxes, pixels)]}
    save_json(OUT / "peppercarrot_ja01_device_fixture.json", manifest)
    print(json.dumps({"input": str(fixture), "stock": str(compact),
                      "manifest": str(OUT / "peppercarrot_ja01_device_fixture.json")}), flush=True)


def load_resolution_model(side):
    """Strict native checkpoint load; retain its learned PE lattice at every size.

    Constructing a differently sized learned PE parameter before strict load
    would change checkpoint semantics. Stock inference interpolates the native
    lattice dynamically; upstream export freezes that same interpolation.
    """
    import torch
    from rfdetr import RFDETRSeg2XLarge
    from safetensors.torch import load_file
    if importlib.metadata.version("rfdetr") != "1.7.0":
        raise RuntimeError("rfdetr==1.7.0 required")
    weights = OUT / "model.safetensors"
    if digest(weights) != WEIGHTS_SHA256:
        raise ValueError("Pinned checkpoint checksum mismatch")
    detector = RFDETRSeg2XLarge(pretrain_weights=None, resolution=1152,
                              num_select=160, num_classes=4, device="cpu")
    model = detector.model.model.cpu().eval()
    model.load_state_dict(load_file(str(weights), device="cpu"), strict=True)
    backbone = model.backbone[0].encoder
    divisor = backbone.patch_size * backbone.num_windows
    if side <= 0 or side % divisor:
        raise ValueError(f"{side} unsupported: patch_size * num_windows = {divisor}")
    backbone.shape = (side, side)
    detector.model.resolution = side
    detector.model_config.resolution = side
    return detector, model, {
        "patch_size": backbone.patch_size, "num_windows": backbone.num_windows,
        "divisor": divisor, "fixed_shape": [1, 3, side, side],
        "learned_position_shape": list(backbone.encoder.embeddings.position_embeddings.shape),
        "patch_grid": [side // backbone.patch_size] * 2,
        "position_interpolation": "stock FP32 bicubic, align_corners=False, CPU antialias=True; class token preserved",
        "checkpoint_load": "native architecture strict=True before changing inference shape",
    }


def resolution_export(args):
    """Fixed-shape export, real stock parity and a parent-only device handoff."""
    import shutil
    import numpy as np
    import torch
    import torchvision.transforms.functional as TF
    import coremltools as ct
    from PIL import Image
    from evaluate_koharu_rfdetr_resolution import selected_parity
    side = args.resolution
    target = args.resolution_output.resolve() / str(side)
    target.mkdir(parents=True, exist_ok=True)
    report_path = target / "conversion.json"
    if report_path.exists():
        prior = json.loads(report_path.read_text())
        if prior.get("status") == "complete":
            raise ValueError("Completed conversion exists; preserve it and use evaluator --resume")
    os.environ["TMPDIR"] = str(target / "tmp")
    Path(os.environ["TMPDIR"]).mkdir(exist_ok=True)
    torch.set_num_threads(args.threads)
    report = {"status": "running", "side": side, "source_revision": REVISION,
              "weights_sha256": WEIGHTS_SHA256, "precision": "FP16 compute, FP32 tensor IO",
              "phone_measured": False, "production_integration": False,
              "versions": {p: importlib.metadata.version(p) for p in
                           ("rfdetr", "torch", "coremltools", "numpy")}}
    phase = "strict_load"
    save_json(report_path, report)
    try:
        detector, model, structure = load_resolution_model(side)
        report["structure"] = structure
        fixture = OUT / "peppercarrot_ja01.jpg"
        if digest(fixture) != "3bef9922e09cea66ab12271da0070025768ae9bc5d286f41ced617468131267e":
            raise ValueError("Public parity fixture checksum changed")
        with Image.open(fixture) as image:
            rgb = image.convert("RGB")
            width, height = rgb.size
            x = TF.normalize(TF.resize(TF.to_tensor(rgb), [side, side], antialias=True), MEAN, STD)[None]
        x.numpy().astype("<f4").tofile(target / "public-input.f32")
        phase = "stock_reference"
        with torch.inference_mode():
            y, seconds = timed(lambda: model(x))
            stock = {name: y[key].numpy() for name, key in zip(NAMES, ("pred_boxes", "pred_logits", "pred_masks"))}
            del y
            np.savez(target / "public-stock.npz", **stock)
            report["stock_cpu_model_seconds"] = seconds
            model.export()
            report["structure"]["export_position_shape"] = list(
                model.backbone[0].encoder.encoder.embeddings.position_embeddings.shape)
            report["rewrites"] = {"depthwise": rewrite_depthwise(model),
                                  "deformable_attention": rewrite_deformable_attention(model)}
            specialize_proposal_grid()
            exported = dict(zip(NAMES, (v.numpy() for v in model(x))))
            report["stock_export_raw"] = {n: metrics(stock[n], exported[n]) for n in NAMES}
            for name in NAMES:
                np.testing.assert_allclose(stock[name], exported[name], atol=0.001, rtol=0.001)
            phase = "trace"
            traced, report["trace_seconds"] = timed(lambda: torch.jit.trace(model, x, check_trace=False))
            for name, value in zip(NAMES, traced(x)):
                np.testing.assert_allclose(exported[name], value.numpy(), atol=0.001, rtol=0.001)
        phase = "conversion"
        package = target / f"KoharuRFDETRSeg2XLarge{side}FP16.mlpackage"
        converted, report["conversion_seconds"] = timed(lambda: ct.convert(
            traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
            inputs=[ct.TensorType(name="image", shape=(1, 3, side, side), dtype=np.float32)],
            outputs=[ct.TensorType(name=n, dtype=np.float32) for n in NAMES],
            compute_precision=ct.precision.FLOAT16, skip_model_load=True))
        converted.user_defined_metadata.update({"weights_sha256": WEIGHTS_SHA256,
            "source_revision": REVISION, "fixed_resolution": str(side)})
        converted.save(str(package))
        report["package"] = str(package)
        report["package_sha256_files"] = {str(p.relative_to(package)): digest(p)
                                           for p in package.rglob("*") if p.is_file()}
        report["package_bytes"] = sum(p.stat().st_size for p in package.rglob("*") if p.is_file())
        report["attention_memory"] = attention_memory(package)
        del detector, model, traced, converted, exported
        import gc
        gc.collect()
        phase = "coreml_parity"
        engine, report["host_load_compile_seconds"] = timed(lambda: ct.models.MLModel(
            str(package), compute_units=getattr(ct.ComputeUnit, args.compute_units)))
        actual, report["host_first_model_seconds"] = timed(lambda: engine.predict({"image": x.numpy()}))
        report["raw_stock_coreml"] = {n: metrics(stock[n], actual[n]) for n in NAMES}
        report["raw_parity_pass"] = all(v["finite"] and v["mean_abs"] <= (0.002 if n == "boxes" else 0.05)
            and v["max_abs"] <= (0.02 if n == "boxes" else 1.0) for n, v in report["raw_stock_coreml"].items())
        report["selected_stock_coreml"] = selected_parity(stock, actual, width, height)
        np.savez(target / "public-coreml.npz", **actual)
        compiled = target / f"KoharuRFDETRSeg2XLarge{side}FP16.mlmodelc"
        if not compiled.exists():
            shutil.copytree(engine.get_compiled_model_path(), compiled)
        contract = {"resolution": side, "input": {"name": "image", "shape": [1, 3, side, side],
            "dtype": "float32", "layout": "NCHW", "channels": "RGB", "mean": MEAN, "std": STD,
            "resize": f"stretch directly to {side}x{side}; tensor bilinear antialias=True; no letterbox",
            "binary_dtype": "little-endian float32, already normalized"},
            "outputs": {n: list(actual[n].shape) for n in NAMES}, "classes": ["text", "sfx", "bubble", "panel"],
            "thresholds": [0.25, 0.20, 0.50, 0.50], "num_select": 160,
            "mask_decode": "gather selected query logits; resize to source H,W bilinear align_corners=False, >0; no box crop",
            "stock_fixture": str(fixture), "source_size_wh": [width, height], "structure": structure,
            "input_sha256": digest(target / "public-input.f32"), "weights_sha256": WEIGHTS_SHA256}
        save_json(target / "contract.json", contract)
        # Only write requests. Parent owns copying, installation, launch and phone results.
        for units in ("cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine", "all"):
            save_json(target / f"request-rf-{side}-fp16-{units}.json", {
                "modelPath": compiled.name, "computeUnits": units, "warmup": 1, "iterations": 3,
                "reportName": f"rf-resolution-{side}-fp16-{units}.json",
                "inputFiles": {"image": f"rf-resolution-{side}-public-input.f32"}, "dumpOutputs": True})
        save_json(target / "parent-handoff.json", {"compiled_model": str(compiled),
            "compiled_sha256_files": {str(p.relative_to(compiled)): digest(p) for p in compiled.rglob("*") if p.is_file()},
            "input_source": str(target / "public-input.f32"), "input_phone_name": f"rf-resolution-{side}-public-input.f32",
            "requests": [str(p) for p in target.glob("request-*.json")],
            "stock_outputs": str(target / "public-stock.npz"), "contract": str(target / "contract.json"),
            "parity_pass": report["raw_parity_pass"] and report["selected_stock_coreml"]["pass"],
            "phone_gate": {"peak_memory_bytes_max": 2 * 1024**3, "full_pipeline_seconds_max": 1.0,
                           "measured": False}, "phone_owner": "parent exclusively", "integration_approved": False})
        report["status"] = "complete"
        report["compute_units"] = args.compute_units
        print(f"RESOLUTION {side}: exported; raw parity={report['raw_parity_pass']}, selected parity={report['selected_stock_coreml']['pass']}", flush=True)
    except Exception as error:
        report.update(status="failed", failure={"phase": phase, "message": str(error), "traceback": traceback.format_exc()})
        raise
    finally:
        report["conversion_process_peak_rss_bytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        report["memory_scope"] = "export plus Torch and CoreML process; not model-only mobile memory"
        save_json(report_path, report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=["all", "export", "parity", "summary", "diagnose", "real-parity", "host-benchmark", "half-storage", "device-fixture", "resolution"], default="all")
    parser.add_argument("--resolution", type=int, default=1152,
                        help="Fixed input side for --stage resolution only; must be a multiple of24")
    parser.add_argument("--resolution-output", type=Path, default=ROOT / "build/koharu-mobile/rf-resolution")
    parser.add_argument("--compute-units", choices=["CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE", "ALL"], default="CPU_ONLY")
    parser.add_argument("--precision", choices=["fp16", "fp32"], default="fp16",
                        help="FP32 is a diagnostic control, not the requested mobile candidate")
    parser.add_argument("--probe", action="store_true", help="Export intermediate encoder probes to a separate diagnostic package")
    parser.add_argument("--fp32-attention-norm", action="store_true",
                        help="Explicit mixed variant: FP16 weights/ops except FP32 attention and layer normalization")
    parser.add_argument("--chunk-attention", action="store_true", help="Equivalent global SDPA with query chunks of 256; separate package")
    parser.add_argument("--compute-plan", action="store_true", help="Inspect host estimated operation placement")
    parser.add_argument("--fixture", choices=["neutral", "random", "xkcd", "peppercarrot-set", "peppercarrot-ja"], default="neutral")
    parser.add_argument("--bounded-attention-only", action="store_true", help="Isolate Q/K/V affine and bare/manual SDPA counterfactuals")
    parser.add_argument("--half-storage-model", action="store_true", help="Benchmark the separately generated FP16 storage / FP32 arithmetic chunked candidate")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--runs", type=int, default=1)
    args = parser.parse_args()
    if args.runs < 1 or args.threads < 1:
        parser.error("runs and threads must be positive")
    if args.stage != "resolution" and args.resolution != 1152:
        parser.error("Lower input shapes require --stage resolution; legacy stages are fixed1152")
    if args.stage == "resolution":
        resolution_export(args)
        return
    OUT.mkdir(parents=True, exist_ok=True)
    # Keep import-time caches, Core ML compilation scratch, and downloads in scope.
    os.environ["HF_HOME"] = str(OUT / "hf-cache")
    os.environ["MPLCONFIGDIR"] = str(OUT / "matplotlib")
    os.environ["TMPDIR"] = str(OUT / "tmp")
    Path(os.environ["TMPDIR"]).mkdir(parents=True, exist_ok=True)
    installed = {d.metadata["Name"]: d.version for d in importlib.metadata.distributions()}
    (OUT / "requirements-lock.txt").write_text("".join(f"{key}=={value}\n" for key, value in sorted(installed.items())))
    if args.stage == "summary":
        summarize()
        return
    if args.stage == "host-benchmark":
        host_benchmark(args)
        return
    if args.stage == "half-storage":
        half_constant_storage()
        return
    if args.stage == "device-fixture":
        device_fixture()
        return
    import numpy as np
    import torch
    import coremltools as ct
    torch.set_num_threads(args.threads)
    if args.probe and args.stage == "parity":
        parser.error("probe diagnostics require --stage all or export")
    tag = ("-probe" if args.probe else "") + ("-fp32-diagnostic" if args.precision == "fp32" else "")
    if args.fp32_attention_norm:
        tag += "-mixed-attention-norm"
    if args.chunk_attention:
        tag += "-chunked"
    report_path = OUT / f"report{tag}.json"
    if args.stage == "diagnose":
        report_path = OUT / ("report-bounded-attention.json" if args.bounded_attention_only else "report-bounded.json")
    if args.stage == "real-parity":
        report_path = OUT / "report-real-parity.json"
    names = NAMES + (["probe_backbone", "probe_encoder_logits", "probe_topk", "probe_ref_enc"] if args.probe else [])
    if args.stage != "parity" and report_path.exists():
        previous = json.loads(report_path.read_text())
        if previous.get("failure"):
            number = len(list(OUT.glob("failure_*.json")))
            save_json(OUT / (f"failure_{number}_" + previous["failure"]["phase"] + ".json"), previous)
    report = json.loads(report_path.read_text()) if args.stage == "parity" and report_path.exists() else {}
    report.update(source={"repo": REPO, "revision": REVISION, "weights_sha256": WEIGHTS_SHA256},
                  host={"platform": platform.platform(), "machine": platform.machine(), "threads": args.threads},
                  versions={p: importlib.metadata.version(p) for p in
                            ["torch", "torchvision", "rfdetr", "transformers", "coremltools", "numpy", "safetensors"]},
                  mobile={"measured": False, "target": "iPhone 15 Pro Max", "latency_seconds": None,
                          "ane_placement": "unverified; host compute units do not prove mobile placement"})
    phase = "source"
    try:
        if importlib.metadata.version("rfdetr") != "1.7.0":
            raise RuntimeError("rfdetr==1.7.0 is required")
        weights = download("model.safetensors")
        if digest(weights) != WEIGHTS_SHA256:
            raise RuntimeError("Pinned safetensors SHA256 mismatch")
        config = json.loads(download("inference_config.json").read_text())
        report["upstream_config"] = config
        from rfdetr import RFDETRSeg2XLarge
        from safetensors.torch import load_file
        phase = "strict_load"
        print("Constructing pinned RFDETRSeg2XLarge and strictly loading SafeTensors", flush=True)
        detector, seconds = timed(lambda: RFDETRSeg2XLarge(
            pretrain_weights=None, resolution=1152, num_select=160, num_classes=4))
        model = detector.model.model.cpu().eval()
        incompatible = model.load_state_dict(load_file(str(weights), device="cpu"), strict=True)
        report["strict_load"] = {"missing": list(incompatible.missing_keys),
                                 "unexpected": list(incompatible.unexpected_keys), "construct_seconds": seconds,
                                 "parameters": sum(p.numel() for p in model.parameters())}
        report["model_config"] = detector.model_config.model_dump(mode="json")
        rng = np.random.default_rng(20261014)
        # Neutral gray and random RGB pixels; no source pages or visual inspection.
        raw_inputs = {"neutral": np.full((1, 3, 1152, 1152), 0.5, np.float32),
                      "random": rng.random((1, 3, 1152, 1152), dtype=np.float32)}
        inputs = {k: np.ascontiguousarray((v - np.array(MEAN, np.float32)[None, :, None, None]) /
                                         np.array(STD, np.float32)[None, :, None, None]) for k, v in raw_inputs.items()}
        if args.stage == "real-parity":
            phase = "real_selected_mask_parity"
            fixtures = (["peppercarrot_01", "peppercarrot_02", "peppercarrot_03"] if args.fixture == "peppercarrot-set" else
                        ["peppercarrot_ja01"] if args.fixture == "peppercarrot-ja" else ["xkcd"])
            for fixture in fixtures:
                real_parity(model, report, fixture)
            report["status"] = "real_selected_parity_complete"
            return
        if args.stage == "diagnose":
            phase = "bounded_counterfactual"
            bounded_diagnostics(model, inputs, report, args.bounded_attention_only)
            report["status"] = "diagnostics_complete"
            return
        phase = "reference"
        reference = {}
        report["torch_reference_seconds"] = {}
        captured_global_inputs = []
        if args.chunk_attention:
            global_attention = model.backbone[0].encoder.encoder.encoder.layer[3].attention.attention
            capture_handle = global_attention.register_forward_pre_hook(
                lambda module, values: captured_global_inputs.append(values[0].detach().clone()))
        with torch.inference_mode():
            for name, x in inputs.items():
                print(f"Reference inference: {name}", flush=True)
                y, seconds = timed(lambda: model(torch.from_numpy(x)))
                reference[name] = [y[k].numpy() for k in ["pred_boxes", "pred_logits", "pred_masks"]]
                report["torch_reference_seconds"][name] = seconds
                np.save(OUT / f"{name}_input.npy", x)
                x.tofile(OUT / f"{name}_input.f32")
                np.savez(OUT / f"{name}_reference.npz", **dict(zip(NAMES, reference[name])))
                del y
        if args.chunk_attention:
            capture_handle.remove()
        shapes = {k: list(v.shape) for k, v in zip(NAMES, reference["neutral"])}
        contract = {"resolution": 1152, "batch": 1, "input": {"name": "image", "dtype": "float32",
                    "shape": [1, 3, 1152, 1152], "layout": "NCHW", "channels": "RGB",
                    "normalization": "(RGB / 255 - mean) / std", "mean": MEAN, "std": STD,
                    "resize": "stretch to 1152x1152, torchvision tensor bilinear antialias=True; no letterbox",
                    "binary_fixtures": "little-endian contiguous float32; already normalized"},
                    "outputs": shapes, "output_dtype": "float32", "internal_precision": args.precision.upper(),
                    "boxes": "normalized cx,cy,w,h; multiply x/w by original width and y/h by original height",
                    "logits": "raw sigmoid logits, not softmax; preserve all slots including background slot",
                    "masks": "raw instance logits; bilinear resize to original H,W align_corners=False; threshold >0",
                    "classes": {"0": "text", "1": "sfx", "2": "bubble", "3": "panel"},
                    "thresholds": [0.25, 0.20, 0.50, 0.50], "num_select": 160,
                    "selection": "upstream top-160 over flattened sigmoid(query,class); gather query boxes/masks; filter class IDs 0..3 then per-class threshold",
                    "source_revision": REVISION, "weights_sha256": WEIGHTS_SHA256}
        contract["minimum_deployment_target"] = "iOS18"
        if args.fp32_attention_norm:
            contract["internal_precision"] = "mixed: FP16 except FP32 attention and layer normalization"
        save_json(OUT / f"contract{tag}.json", contract)
        report["tensor_bytes"] = {k: {"fp32": int(v.nbytes), "fp16": int(v.size * 2)}
                                  for k, v in zip(NAMES, reference["neutral"])}
        report["tensor_bytes"]["input"] = {"fp32": int(inputs["neutral"].nbytes)}
        package = OUT / ("KoharuRFDETRSeg2XLarge1152FP16.mlpackage" if args.precision == "fp16" else
                         "KoharuRFDETRSeg2XLarge1152FP32Diagnostic.mlpackage")
        if args.probe:
            package = package.with_name(package.stem + "Probe.mlpackage")
        if args.fp32_attention_norm:
            package = package.with_name(package.stem + "MixedAttentionNorm.mlpackage")
        if args.chunk_attention:
            package = package.with_name(package.stem + "Chunked.mlpackage")
        if args.stage != "parity":
            phase = "export_forward_parity"
            model.export()
            report["rewrites"] = {"depthwise_pythonop_to_conv2d": rewrite_depthwise(model),
                                  "reason": "TorchScript save rejects _DepthwiseConvWithoutCuDNN PythonOp",
                                  "proposal_grid": "fixed integer H/W; equivalent for fixed 1152 input"}
            specialize_proposal_grid()
            report["rewrites"]["deformable_attention_rank_five"] = rewrite_deformable_attention(model)
            if args.chunk_attention:
                report["rewrites"]["global_attention_query_chunks_256"] = chunk_global_attention(model)
                report["chunked_attention_counterfactual"] = {}
                with torch.inference_mode():
                    for key, captured in zip(inputs, captured_global_inputs):
                        original = global_attention._unchunked_forward(captured)[0]
                        chunked = global_attention(captured)[0]
                        value = metrics(original.numpy(), chunked.numpy())
                        report["chunked_attention_counterfactual"][key] = value
                        if value["max_abs"] > 0.0002 or value["mean_abs"] > 0.000005:
                            raise ValueError(f"Chunked attention isolated FP32 equivalence failed: {value}")
                        del original, chunked
                captured_global_inputs.clear()
            if args.probe:
                model = probe_wrapper(model)
            report["export_forward_parity"] = {}
            export_reference = {}
            with torch.inference_mode():
                for name, x in inputs.items():
                    y = model(torch.from_numpy(x))
                    report["export_forward_parity"][name] = {
                        key: metrics(a, b.numpy()) for key, a, b in zip(NAMES, reference[name], y)}
                    for a, b in zip(reference[name], y[:3]):
                        if not args.chunk_attention:
                            np.testing.assert_allclose(a, b.numpy(), rtol=1e-3, atol=1e-3)
                    if args.chunk_attention:
                        report["chunked_torch_roundoff_gate"] = "isolated global attention max <=.0002, mean <=.000005; full query-row differences recorded, selected masks evaluated separately"
                    if args.probe:
                        reference[name] += [b.numpy() for b in y[3:]]
                        np.savez(OUT / f"{name}_probe_reference.npz", **dict(zip(names, reference[name])))
                    export_reference[name] = [b.numpy() for b in y]
                phase = "trace"
                print("Tracing native 1152 export", flush=True)
                traced, seconds = timed(lambda: torch.jit.trace(model, torch.from_numpy(inputs["neutral"]), check_trace=False))
                report["trace_seconds"] = seconds
                report["trace_ops"] = dict(Counter(n.kind() for n in traced.inlined_graph.nodes()))
                for name, x in inputs.items():
                    for a, b in zip(export_reference[name], traced(torch.from_numpy(x))):
                        np.testing.assert_allclose(a, b.numpy(), rtol=1e-3, atol=1e-3)
                traced.save(str(OUT / ("export-probe.pt" if args.probe else "export.pt")))
            phase = "coreml_conversion"
            print(f"Converting to iOS18 MLProgram {args.precision}", flush=True)
            precision = ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32
            if args.fp32_attention_norm:
                precision = ct.transform.FP16ComputePrecision(
                    op_selector=lambda op: op.op_type not in {"scaled_dot_product_attention", "layer_norm"})
                report["precision_policy"] = "FP16 except FP32 scaled_dot_product_attention and layer_norm"
            converted, seconds = timed(lambda: ct.convert(
                traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
                inputs=[ct.TensorType(name="image", shape=(1, 3, 1152, 1152), dtype=np.float32)],
                outputs=[ct.TensorType(name=n, dtype=np.int32 if n == "probe_topk" else np.float32) for n in names],
                compute_precision=precision,
                skip_model_load=True))
            report["conversion_seconds"] = seconds
            converted.user_defined_metadata.update({"source_revision": REVISION, "weights_sha256": WEIGHTS_SHA256,
                                                     "preprocessing": json.dumps(contract["input"])})
            converted.save(str(package))
            report["package_bytes"] = sum(p.stat().st_size for p in package.rglob("*") if p.is_file())
            report["package_path"] = str(package)
            report["mil_ops"] = dict(Counter(op.op_type for op in converted._mil_program.functions["main"].operations))
            report["attention_memory"] = []
            for op in converted._mil_program.functions["main"].operations:
                if op.op_type == "scaled_dot_product_attention":
                    shape = list(op.inputs["query"].shape)
                    count = int(np.prod(shape[:-2]) * shape[-2] * op.inputs["key"].shape[-2])
                    report["attention_memory"].append({"query_shape": shape,
                        "hypothetical_materialized_score_fp16_bytes": count * 2,
                        "hypothetical_materialized_score_fp32_bytes": count * 4,
                        "note": "SDPA is fused/opaque; these are logical matrix sizes, not measured allocations"})
            report["export_status"] = "success"
            save_json(report_path, report)
        if args.stage != "export":
            phase = "coreml_host_parity"
            print(f"Loading host Core ML: {args.compute_units}", flush=True)
            mlmodel, seconds = timed(lambda: ct.models.MLModel(str(package), compute_units=getattr(ct.ComputeUnit, args.compute_units)))
            host = {"load_compile_seconds": seconds, "compute_units": args.compute_units, "inputs": {}}
            if args.compute_plan:
                try:
                    save_json(OUT / f"compute-plan{tag}-{args.compute_units}.json",
                              compute_plan(mlmodel, getattr(ct.ComputeUnit, args.compute_units)))
                except Exception as error:
                    host["compute_plan_error"] = str(error)
            for name, x in inputs.items():
                print(f"Host Core ML inference: {name}", flush=True)
                first, first_seconds = timed(lambda: mlmodel.predict({"image": x}))
                times = []
                actual = first
                for _ in range(args.runs):
                    actual, seconds = timed(lambda: mlmodel.predict({"image": x}))
                    times.append(seconds)
                parity = {key: metrics(a, actual[key]) for key, a in zip(names, reference[name])}
                # Explicit raw-tensor criterion; synthetic parity is not real-page quality evidence.
                passed = all(v["finite"] and v["mean_abs"] <= (0.002 if k == "boxes" else 0.05)
                             and v["max_abs"] <= (0.02 if k == "boxes" else 1.0) for k, v in parity.items())
                suffix = tag.replace("-", "_")
                np.savez(OUT / f"{name}_coreml_{args.compute_units}{suffix}.npz", **actual)
                host["inputs"][name] = {"first_seconds": first_seconds, "warm_seconds": times,
                                        "parity": parity, "raw_parity_pass": passed}
            report.setdefault("host_coreml", {})[args.compute_units] = host
            report["host_parity_pass"] = all(i["raw_parity_pass"] for i in host["inputs"].values())
            report["raw_parity_gate"] = {"boxes_mean_abs_max": 0.002, "boxes_max_abs_max": 0.02,
                                        "other_mean_abs_max": 0.05, "other_max_abs_max": 1.0,
                                        "scope": "synthetic raw outputs; does not prove real-page accuracy"}
        report["package_fingerprints"] = {str(p.relative_to(package)): digest(p)
                                          for p in package.rglob("*") if p.is_file()}
        report["precision"] = contract["internal_precision"]
        report["integration_approved"] = False
        report["integration_reason"] = "Main compares one candidate on actual iPhone; host raw parity is a separate gate"
        report["status"] = "complete"
    except Exception as error:
        report["status"] = "failed"
        report["failure"] = {"phase": phase, "type": type(error).__name__, "message": str(error),
                             "traceback": traceback.format_exc()}
        raise
    finally:
        report["peak_host_rss_bytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        save_json(report_path, report)


if __name__ == "__main__":
    main()
