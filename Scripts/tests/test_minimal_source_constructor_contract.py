"""Static early-construction guards; no build, model load or inference.

Helper owners separately test actual numeric behavior. These checks prevent a
late minimal return from accidentally retaining the expensive accepted graph.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
ENSEMBLE = ROOT / "Aidoku/Core/Translation/NativeEngine/Ensemble"


def body(text, marker):
    start = text.index("{", text.index(marker))
    depth = 1
    for index in range(start + 1, len(text)):
        depth += (text[index] == "{") - (text[index] == "}")
        if depth == 0:
            return text[start + 1:index]
    raise AssertionError("unclosed Swift body")


class MinimalSourceConstructorContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.backend = (ENSEMBLE / "NativeOperationalSourceInference.swift").read_text()
        cls.factory = (ENSEMBLE / "NativeSourceInputFactory.swift").read_text()
        cls.host = (ROOT / "Scripts/image-translation/HostOperationalAppearance.swift").read_text()

    def test_auxiliary_construction_is_inside_accepted_branch(self):
        init = body(self.backend, "init(bundle:")
        accepted = body(init, "if policy.usesAcceptedAppearance")
        for constructor in ("NativeAppearanceModelHeads(", "NativeAppearanceInferenceGraph(heads:",
                            "NativeAcceptedSourceFontInference(heads:", "NativeAcceptedSourceWeightInference(heads:"):
            self.assertEqual(init.count(constructor), accepted.count(constructor))
            self.assertGreater(accepted.count(constructor), 0)
        self.assertLess(init.index("NativeSourceInferencePolicy.validate()"), init.index("MLModel(contentsOf:"))
        self.assertIn("appearance=nil; font=nil; weight=nil", init)
        weight = body(accepted, "if policy.usesAcceptedWeight")
        self.assertEqual(accepted.count("NativeAcceptedSourceFontInference(heads:"),
                         weight.count("NativeAcceptedSourceFontInference(heads:"))
        self.assertEqual(accepted.count("NativeAcceptedSourceWeightInference(heads:"),
                         weight.count("NativeAcceptedSourceWeightInference(heads:"))

    def test_m1_opt_in_wires_actual_five_roles_and_whole_page_body_without_accepted_graph(self):
        policy = (ENSEMBLE / "NativeSourceInferencePolicy.swift").read_text()
        for mode in ('"minimal-m1-p9-body32-v1"', '"minimal-m1-p9-body64-v1"'):
            self.assertIn(mode, policy)
        init = body(self.backend, "init(bundle:")
        accepted = body(init, "if policy.usesAcceptedAppearance {")
        self.assertIn("NativeAppearanceInferenceGraph(heads:", accepted)
        self.assertEqual(init.count("NativeAppearanceInferenceGraph(heads:"), accepted.count("NativeAppearanceInferenceGraph(heads:"))
        self.assertIn("m1Page = try NativeM1SourcePageInference(bundle: bundle, variant: variant,", init)
        self.assertIn("stagedM1StyleDirectory(override: m1StyleDirectory)", init)
        minimal = body(self.backend, "private func annotateMinimal(")
        learned = body(minimal, "if let m1Page")
        self.assertIn("makeM1StyleObservation(owner: owner)", learned)
        self.assertIn("let page = try m1Page.predict(measured)", learned)
        self.assertNotIn("NativePhysicalSourceStyle.estimate(", learned)
        self.assertNotIn("appearance.predict(", learned)
        self.assertIn('"learnedSourceAuxiliaryHeadCount": 7', self.host)
        self.assertIn('"pinnedFontDescriptorValidationPerCrop": true', self.host)
        page = (ENSEMBLE / "NativeM1SourcePageInference.swift").read_text()
        self.assertIn("NativeSingleBodyWeightInference(directory: models, measurementSpec: resolved, measurementABI: .base4)", page)
        self.assertIn("Self.resolvedBodyBase4Spec(modelDirectory: models, fontResources: fontResources)", page)
        self.assertIn("NativeSourceFontResolver.resolveBodyBase4MeasurementSpec(spec", page)
        self.assertNotIn("includeMetadata: true", page)
        self.assertNotIn("metadataTreeFoundation", page)
        self.assertIn("NativeM1SourcePageInference.bodyBase4SpecSHA256", policy)
        self.assertNotIn("NativeAppearanceModelHeads(", page)
        self.assertNotIn("CoreML", page)
        self.assertIn("let weights = try body.estimate(inputs, styles: styles)", page)

    def test_rich_predict_cannot_execute_minimal(self):
        predict = body(self.backend, "func predict(_ inputs:")
        self.assertLess(predict.index("guard !policy.usesMinimalObservations, let appearance"),
                        predict.index("segmentation.segment("))
        self.assertEqual(predict.count("font.estimate("), 2)

    def test_minimal_annotation_precedes_rich_factory(self):
        annotate = body(self.backend, "constructorObserver: (([NativeSourceInputFactory.Owner]")
        branch = body(annotate, "if policy.usesMinimalObservations")
        self.assertIn("return try annotateMinimal(", branch)
        self.assertLess(annotate.index("if policy.usesMinimalObservations"), annotate.index("NativeSourceInputFactory.make("))

    def test_minimal_does_not_measure_or_invent_legacy_observations(self):
        minimal = body(self.backend, "private func annotateMinimal(")
        for forbidden in ("font.estimate(", "weight.estimate(", "appearance.predict(",
                          "SourceNativeInput(", "SourceFontContext(", "NativeOperationalAppearance.apply("):
            self.assertNotIn(forbidden, minimal)
        self.assertIn("segmentation.predictMinimal(input)", minimal)
        self.assertIn('"boundary": false', minimal)
        self.assertIn("observation.nativeSeed", minimal)

    def test_minimal_page_retains_only_observations_and_rf_digests(self):
        factory = body(self.factory, "static func makeMinimal(")
        self.assertIn("let observation = try observe(input)", factory)
        owner = body(self.factory, "struct MinimalOwner")
        self.assertNotIn("NativeMinimalSourceSegmentation.Input", owner)
        observation = body(self.factory, "struct MinimalObservation")
        self.assertNotIn("[Float]", observation)
        self.assertIn("let fullRFSHA256: String", observation)
        self.assertIn("let coarseRFSHA256: String", observation)
        minimal = body(self.backend, "private func annotateMinimal(")
        self.assertEqual(minimal.count("segmentation.predictMinimal("), 1)
        for rf in ("fullRF", "coarseRF"):
            self.assertIn(f"{rf}SHA256: input.{rf}.withUnsafeBytes(Self.sha256)", minimal)
            self.assertIn(f'"{rf}SHA256": owner.observation.{rf}SHA256', minimal)

    def test_minimal_factory_recomputes_prior_and_skips_ocr(self):
        factory = body(self.factory, "static func makeMinimal(")
        for forbidden in ('item["sourceFontSize"]', "ocr(", "wordEvidence(", "contexts(", "SourceNativeInput("):
            self.assertNotIn(forbidden, factory)
        self.assertIn("NativeSimpleSourceFont.prior(", factory)
        self.assertIn("text.unicodeScalars.count", factory)

    def test_host_binding_returns_before_registry_read(self):
        binding = body(self.host, "private func modelBinding()")
        minimal = body(binding, "if NativeSourceInferencePolicy.selected.usesMinimalObservations")
        self.assertIn("return [", minimal)
        self.assertNotIn("Data(contentsOf:", minimal)
        self.assertIn('"registryLoaded": false', minimal)
        self.assertLess(binding.index("if NativeSourceInferencePolicy.selected.usesMinimalObservations"),
                        binding.index("Data(contentsOf:"))

    def test_policy_projection_has_no_resource_io(self):
        policy = (ENSEMBLE / "NativeSourceInferencePolicy.swift").read_text()
        for forbidden in ("Data(contentsOf:", "Registry(", "MLModel(", "FileManager"):
            self.assertNotIn(forbidden, policy)
        self.assertIn("static var cacheProjection:", policy)
        self.assertIn('"minimal-primary-v1"', policy)
        self.assertIn('"minimal-rf-v1"', policy)

    def test_hybrid_skips_original_members_font_but_retains_actual_bbox_for_weight(self):
        predict = body(self.backend, "func predict(_ inputs:")
        accepted_font = body(predict, "if policy == .accepted")
        self.assertIn("let accepted=try font.estimate(", accepted_font)
        self.assertIn("simpleFontConfiguration.estimate(", predict)
        self.assertIn("geometry:.bboxOnly", body(predict, "if let weight"))
        self.assertNotIn("NativeAcceptedSourceFontInference.Result(", self.backend)
        self.assertIn("struct FontPrediction", self.backend)

    def test_single_selected_font_configuration_drives_cache_and_both_runtime_routes(self):
        policy = (ENSEMBLE / "NativeSourceInferencePolicy.swift").read_text()
        self.assertEqual(self.backend.count("simpleFontConfiguration.estimate("), 2)
        self.assertIn("String(calibration.scale)", policy)
        self.assertIn("String(calibration.bias)", policy)
        self.assertIn("String(relativeGap)", policy)
        self.assertIn("scale: 0.43853239073260936, bias: 4.094089327930639", policy)
        self.assertIn("memberShortScale: 0.4140206805546956", policy)
        self.assertIn("relativeGap: 0.35", policy)
        self.assertIn("threshold: 0.25, closingRadius: 1", policy)
        self.assertIn("weakRecovery: .init(minimumPrimaryProbability: 0.01, radius: 2)", policy)
        self.assertIn("String(weak.minimumPrimaryProbability)", policy)
        self.assertIn("String(weak.radius)", policy)
        self.assertNotIn("0.7989624386717498", self.backend)
        self.assertIn("static let defaultMode: Mode = .minimalM1P9Body64", policy)
        self.assertIn('case simpleFontAcceptedStyleBody = "simple-font-accepted-style-body-v1"', policy)
        self.assertIn('"sourcePrimaryFeatureSamplingPolicy": NativePixelRFFeatures.samplingPolicyVersion', policy)
        self.assertIn("?? defaultMode.rawValue", policy)
        self.assertIn("memberPolygons:$0.memberPolygons", self.backend)
        self.assertIn("memberPolygons: $0.memberPolygons", self.backend)
        self.assertIn("bodyRatioWeight: 0.8212525806130213, maximumLogDistance: 0.9705176286667344", policy)
        self.assertIn("consistencyRule: consistencyRule", policy)
        self.assertIn("String(rule.bodyRatioWeight)", policy)
        self.assertIn("String(rule.maximumLogDistance)", policy)
        self.assertIn('"simple-font-accepted-style-body-fixed-gap-v1"', policy)

    def test_rich_hybrid_prior_does_not_inherit_learned_source_font(self):
        factory = body(self.factory, "static func make(source:")
        geometry_prior = body(factory, "if geometryFontPriorOnly")
        self.assertIn("NativeSimpleSourceFont.prior(", geometry_prior)
        self.assertNotIn('item["sourceFontSize"]', geometry_prior)
        self.assertIn("geometryFontPriorOnly:policy.usesSimpleFont", self.backend)

    def test_single_body_branch_never_constructs_full_font_or_uses_bbox_context(self):
        constructor = body(body(self.backend, "init(bundle:"), "if policy.usesSingleBodyWeight")
        self.assertIn("NativeSingleBodyWeightInference(heads:", constructor)
        self.assertNotIn("NativeAcceptedSourceFontInference(", constructor)
        self.assertNotIn("NativeAcceptedSourceWeightInference(", constructor)
        measurement = body(self.backend, "private static func bodyMeasurementSpec(")
        self.assertIn("NativeSourceFontResolver.resolveMeasurementSpec(", measurement)
        self.assertNotIn("PrototypeBank", measurement)
        self.assertNotIn("heads.model(", measurement)
        estimate = body(body(self.backend, "func predict(_ inputs:"), "if let bodyWeight")
        self.assertIn("bodyWeight.estimate(outputs,styles:styles)", estimate)
        self.assertNotIn("font.estimate(", estimate)

    def test_single_body_runtime_and_cache_share_frozen_role_and_threshold(self):
        policy = (ENSEMBLE / "NativeSourceInferencePolicy.swift").read_text()
        helper = (ENSEMBLE / "NativeSingleBodyWeightInference.swift").read_text()
        self.assertIn('"simple-font-accepted-style-body-v1"', policy)
        for field in ("threshold", "modelIdentity", "modelSHA256", "revision"):
            self.assertIn("NativeSingleBodyWeightInference." + field, policy)
        self.assertIn("static let threshold = 0.025", helper)
        estimate = body(helper, "private func estimateObservations(")
        for signature in ("func estimate(_ inputs: [SourceNativeInput]", "func estimate(_ inputs: [NativeMinimalSourceStyleInput]"):
            self.assertIn("estimateObservations(inputs.map", body(helper, signature))
        for fake in ('"physicalFontPairs":', '"referencePairs":', '"sourceAngle":', '"weightMemberPolygons":'):
            self.assertNotIn(fake, estimate)
        self.assertIn('request["sourceEm"] = input.fontPriorSourcePixels', estimate)
        base4 = body(estimate, "if measurementABI == .base4 {")
        self.assertIn('fonts.count == 4', base4)
        self.assertIn('request["measurementABI"] = measurementABI.rawValue', base4)
        self.assertIn('request["measurementSpec"] = ["fonts": fonts]', base4)
        for fake in ('request["sourceEm"]', 'request["style"]', 'request["ownership"]', 'request["memberPolygons"]'):
            self.assertNotIn(fake, base4)
        for preserved in ('request["ownership"] = Data(input.ownMask)', 'request["style"] = style',
                          'request["measurementSpec"] = measurementSpec', 'request["memberPolygons"] = input.memberPolygons.map'):
            self.assertIn(preserved, estimate)
        self.assertIn('Self.extractRaw597(packet: request, measurementABI: measurementABI)', estimate)
        dispatch = body(helper, "static func extractRaw597(")
        self.assertIn('measurementABI == .base4 ? AIDExtractSourceWeightRaw597Base4(packet, &error)', dispatch)
        self.assertIn('values["raw597"] as? [Double]', dispatch)
        self.assertIn('extracted["measurementABI"] as? String != measurementABI.rawValue', dispatch)
        self.assertIn('vector.count == Self.rawFeatureCount', dispatch)
        self.assertIn('vector.allSatisfy(\\.isFinite)', dispatch)
        self.assertIn('vector.prefix(6).allSatisfy({ $0 == 0 })', dispatch)
        self.assertIn("AIDExtractSourceWeightRaw597(packet, &error)", dispatch)
        self.assertNotIn("AIDExtractSourceWeightSignals(", estimate + dispatch)
        self.assertIn('projection["sourceBoldMeasurementBridge"] = selected.usesMinimalM1Style ?', policy)
        self.assertIn("NativeSingleBodyWeightInference.MeasurementABI.base4.rawValue", policy)
        self.assertIn("NativeSingleBodyWeightInference.MeasurementABI.genericAdmission.rawValue", policy)
        numeric = body(helper, "func predict(raw597:")
        self.assertIn("NativeSourceWeightGraph.pageContext(raw597)", numeric)
        self.assertIn("model.predictProbability(page)", numeric)
        self.assertNotIn("Float(", numeric)

    def test_body_host_metadata_describes_dedicated_raw_only_bridge(self):
        host = (ROOT / "Scripts/image-translation/HostOperationalAppearance.swift").read_text()
        self.assertIn("dedicatedRaw597Only;direct7Fill71NotComputed", host)
        self.assertIn("actualStyleOwnershipSourceEmAndPinnedDescriptorsValidated", host)
        self.assertNotIn("genericBridgeExtraDirect7Fill71NotConsumed", host)

    def test_minimal_style_features_measure_typed_base35_without_rich_placeholders(self):
        helper = (ENSEMBLE / "NativeM1SourceStyleFeatures44.swift").read_text()
        dto = (ENSEMBLE / "NativeMinimalSourceStyleInput.swift").read_text()
        self.assertIn("NativeMinimalSourceStyleInput", helper)
        self.assertIn("NativeAppearanceSourceFeatures209.extractPhysicalWithLabs(", helper)
        self.assertNotIn("NativeAppearanceSourceFeatures209.extract(", helper)
        self.assertNotIn("SourceNativeInput(", helper)
        for missing in ("boundary:", "rf:", "ocr:", "contextMask:", "affinityScores:"):
            self.assertNotIn(missing, dto)
            self.assertNotIn(missing, helper)
        rich = (ENSEMBLE / "NativeAppearanceSourceFeatures209.swift").read_text()
        physical = body(rich, "static func extractPhysicalWithLabs(")
        for missing in ("fused(", "input.boundary", "input.rf", "input.ocr", "input.memberPolygons"):
            self.assertNotIn(missing, physical)
        self.assertIn("return (packet, labs, near, radius)", physical)

    def test_erasure_postprocess_does_not_overwrite_rich_feature_masks(self):
        annotate = body(self.backend, "constructorObserver: (([NativeSourceInputFactory.Owner]")
        erasure = body(annotate, "if let configuration = NativeSourceInferencePolicy.erasureSegmentationConfiguration")
        self.assertIn("postprocessPrimary(input.primary", erasure)
        self.assertNotIn("input.ownMask=", annotate)
        self.assertNotIn("input.ownMask =", annotate)
        self.assertNotIn("input.contextMask=", annotate)
        self.assertNotIn("input.contextMask =", annotate)
        policy = (ENSEMBLE / "NativeSourceInferencePolicy.swift").read_text()
        self.assertIn('projection["sourceErasurePolicySHA256"] = erasure.policySHA256', policy)

    def test_masks_receive_typed_actual_decoder_attestation_not_item_strings(self):
        annotate = body(self.backend, "constructorObserver: (([NativeSourceInputFactory.Owner]")
        self.assertIn("ProducerIdentity(producerOriginal:source,decodedSource:decoded)", annotate)
        self.assertIn("producerIdentity:producerIdentity", annotate)
        minimal = body(self.backend, "private func annotateMinimal(")
        self.assertIn("producerIdentity: producerIdentity", minimal)
        self.assertNotIn('items["sourceIdentity"]', annotate)


if __name__ == "__main__":
    unittest.main()
