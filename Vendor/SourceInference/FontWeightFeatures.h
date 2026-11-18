// Bounded source-weight measurements only; no model inference or page context.
#pragma once
#ifdef __OBJC__
#import <Foundation/Foundation.h>
// Packet uses FontTemplateFeatures RGB byte/stride, bbox, original prior/text,
// source-predicted style, ownership and pinned4/8/4 measurementSpec contracts.
// sourceEm is required, finite and positive: final em for fill71 v1 only.
// raw597/direct7 always use original prior. Supplied native156 is never reused.
// Returns NSNumber arrays raw597, direct7, fill71, or nil with NSError.
// Optional physicalFontPairs contains three pairs of explicit path/faceIndex
// descriptors. When present, paired48 is measured from the same RGB/final em.
FOUNDATION_EXPORT
NSDictionary<NSString *, id> *_Nullable AIDExtractSourceWeightSignals(
    NSDictionary *_Nonnull packet, NSError *_Nullable *_Nullable error);
// Raw-only sibling with identical required bounded packet admission (including
// positive sourceEm and pinned4/8/4 banks). Computes no direct/fill/paired/band/
// residual output; optional requests for those latter paths are rejected.
FOUNDATION_EXPORT
NSDictionary<NSString *, id> *_Nullable AIDExtractSourceWeightRaw597(
    NSDictionary *_Nonnull packet, NSError *_Nullable *_Nullable error);
// Explicit BASE4-only intrinsic RGB/bbox/prior/text contract. Ordered pinned
// BASE font bytes/faces/optional wght remain real required inputs.
FOUNDATION_EXPORT
NSDictionary<NSString *, id> *_Nullable AIDExtractSourceWeightRaw597Base4(
    NSDictionary *_Nonnull packet, NSError *_Nullable *_Nullable error);
#endif
