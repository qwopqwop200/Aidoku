"""Shared block preprocessing (mirrored exactly in PipelineRemovalMask.swift): integer box downscale by
k = max(1, round(T / TN)), edge-replicated to a multiple of k and then of ALIGN; inputs RGB, max|RGB - bg|,
poly fraction, roi fraction (all 0-1)."""
import numpy as np
ALIGN = 8

def factor(T, tn, mode='round'):
    if mode == 'ceil': return max(1, int(np.ceil(T / tn)))
    return max(1, int(np.floor(T / tn + 0.5)))

def pool(a, k):
    """a: (h, w, c) float32 -> box mean over k x k cells, edge-replicated to a multiple of k."""
    h, w = a.shape[:2]
    H, W = -(-h // k) * k, -(-w // k) * k
    if (H, W) != (h, w):
        a = np.pad(a, ((0, H - h), (0, W - w), (0, 0)), mode='edge')
    return a.reshape(H // k, k, W // k, k, -1).mean(axis=(1, 3))

def align(a):
    h, w = a.shape[:2]
    H, W = -(-h // ALIGN) * ALIGN, -(-w // ALIGN) * ALIGN
    return np.pad(a, ((0, H - h), (0, W - w), (0, 0)), mode='edge') if (H, W) != (h, w) else a

def inputs(rgb, bg, poly, roi, k):
    """rgb uint8 (h, w, 3) frame crop; returns (C, H, W) float32 model input and pooled size (ph, pw)."""
    f = rgb.astype(np.float32) / 255
    dist = np.abs(f - np.asarray(bg, np.float32)).max(axis=2, keepdims=True)
    a = np.concatenate([f, dist, poly[..., None].astype(np.float32), roi[..., None].astype(np.float32)], axis=2)
    p = pool(a, k)
    return align(p).transpose(2, 0, 1).copy(), p.shape[:2]

def upsample(prob, k, h, w):
    """prob (ph, pw) coarse -> (h, w): bilinear, fine x samples coarse (x + 0.5) / k - 0.5 clamped."""
    if k == 1: return prob[:h, :w]
    def axis(n, m):
        c = np.clip((np.arange(n) + 0.5) / k - 0.5, 0, m - 1)
        i0 = np.floor(c).astype(int); i1 = np.minimum(i0 + 1, m - 1)
        return i0, i1, (c - i0).astype(np.float32)
    y0, y1, fy = axis(h, prob.shape[0]); x0, x1, fx = axis(w, prob.shape[1])
    top = prob[y0][:, x0] * (1 - fx) + prob[y0][:, x1] * fx
    bot = prob[y1][:, x0] * (1 - fx) + prob[y1][:, x1] * fx
    return top * (1 - fy[:, None]) + bot * fy[:, None]
