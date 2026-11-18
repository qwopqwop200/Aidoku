"""Source registration only for isolated real-native admission smokes.

No imports/builds of Swift, source rewriting, runtime stubs, or cache changes.
The caller continues to extract its actual production primitive/composer types.
"""

# Admission validates retained cohort certificates even when a smoke never
# proposes a new cohort motion. Include the real validators and their source
# context dependencies; disabling a runtime feature cannot remove Swift types.
_DEPENDENCIES = {
    "NativeSourceStylePaint": ("NativeDiskAlphaMaximum",),
    "NativeMandatoryDisplayStroke": ("NativeDiskAlphaMaximum",),
    "NativeAOTRawTextPainter": (
        "NativeFixedFontRecovery", "NativeTerminalRoundedSourcePaint", "NativeJointSourceWidthPacking",
        "NativeEffectSafePitch", "NativeExactAlphaOrigins", "NativeRecoveryDrawBudget", "NativeStyledRowGap",
        "NativeSourceObstructionRecovery", "NativeSourceTextRotation",
    ),
    "NativeMandatoryDisplayStroke+Composer": ("NativeFixedFontRecovery", "NativeStyledRowGap"),
    "NativeFinalTextPaintAdmission": (
        "NativeSourceCohortCenterBalance", "NativePageEdgePeerPacking",
    ),
    "NativeSourceCohortCenterBalance": (
        "NativeBodySourceAnchorRecovery", "NativeSourcePhysicalInteriorContext",
    ),
    "NativeBodySourceAnchorRecovery": ("NativeFinalTextPaintAdmission",),
    "NativeSourceObstructionRecovery": ("NativeCohortFitPlanner", "NativeSourcePhysicalInteriorContext"),
    "NativeCohortFitPlanner": ("NativeAOTRawTextPainter", "NativeOperationalAppearance", "NativeBalloonPlacement"),
    "NativeSourcePhysicalInteriorContext": (
        "NativeSourcePixelInterior", "NativeSourceClosedBarrierInterior", "NativeSourceTextRotation",
    ),
    "NativeSourceClosedBarrierInterior": ("NativeSourcePixelInterior",),
}


def admission_source_closure(names):
    """Preserve original order; append transitive runtime dependencies once.

    Names are extensionless Swift basenames, as in the existing smoke SOURCES
    arrays. Cyclic native references are legal; each file is registered once.
    Do not add the full composer here: some callers extract its actual carrier
    separately while others compile the full extension with real TextLayer.
    """
    result = list(dict.fromkeys(names))
    seen = set(result)
    for name in result:
        for dependency in _DEPENDENCIES.get(name, ()):
            if dependency not in seen:
                seen.add(dependency)
                result.append(dependency)
    return result
