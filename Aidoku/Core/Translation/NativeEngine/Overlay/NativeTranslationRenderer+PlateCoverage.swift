import CoreGraphics

extension NativeTranslationRenderer {
    static func commitPlateGrowthCoverage(_ panel: inout NativeTranslationSourceStylePostPolish.Panel,
        result: NativeTypographyPlateGrowth.Result) {
        panel.rect = usedRect(result.plate)
        guard let coverage = result.coverage else { return }
        panel.coverage = coverage
        // A no-added trial retains its current inset/SVG/none declaration.
        // The returned dataset coverage alone is not a CSS assignment event.
        guard result.coverageClipWritten else { return }
        panel.clipped = coverage.count > 1 || panel.clipped
        panel.coverageClip = panel.clipped ? NativeCSSCoveragePath.declaration(coverage: coverage,
            origin: result.plate.origin, commands: .relative) : nil
    }
}
