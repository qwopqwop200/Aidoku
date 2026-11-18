#pragma once
#ifdef __OBJC__
#import <Foundation/Foundation.h>
// Same-source bounded crop; kind is directional/eligibility/reference/soft.
// Carries primary/boundary/native/RF/valid bytes from the existing producer.
// No model execution, source-ID lookup or GT at this boundary.
FOUNDATION_EXPORT NSDictionary<NSString*,id>* _Nullable AIDMeasureSourceWeightImageEvidence(
    NSDictionary* _Nonnull packet,NSError* _Nullable* _Nullable error);
#endif
