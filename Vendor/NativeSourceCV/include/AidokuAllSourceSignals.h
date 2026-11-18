#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Full source signal extraction implemented by FontTemplateFeatures.mm.
/// Packet schema is the template worker's typed source-observation dictionary.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable AIDExtractAllSourceSignals(
    NSDictionary *packet, NSError * _Nullable * _Nullable error);
/// Same bounded source observations, original OCR prior plus final sourceEm.
/// Returns raw597, direct7 and fill71 (version1); no weight model execution.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable AIDExtractSourceWeightSignals(
    NSDictionary *packet, NSError * _Nullable * _Nullable error);
/// Same required admission; raw597 only, no unused direct/fill measurements.
/// Residual/angle/paired/band optional requests are explicitly unsupported.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable AIDExtractSourceWeightRaw597(
    NSDictionary *packet, NSError * _Nullable * _Nullable error);
/// Explicit raw597-base4-v1 ABI: intrinsic RGB/bbox/prior/text + real pinned
/// BASE4 only, no unrelated source style/ownership or legacy8/4 banks.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable AIDExtractSourceWeightRaw597Base4(
    NSDictionary *packet, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable AIDMeasureSourceWeightImageEvidence(
    NSDictionary *packet, NSError * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
