#!/usr/bin/env python3
"""Run focused production grouping/adapter tests on macOS, without the app target.

Copies value declarations verbatim from production; excludes only unused title
admission state from the pre-translation region. Neither admission logic nor
pixel sampling is stubbed. This does not certify an iOS app build.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / 'Scripts'))
from swift_replay_cache import compile_replay, write_if_changed
translation = root / 'Aidoku/Core/Translation'
ocr = translation / 'NativeEngine/OCR'


def between(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


def function(text, start):
    begin = text.index(start)
    cursor = text.index('{', begin) + 1
    depth = 1
    while depth:
        depth += (text[cursor] == '{') - (text[cursor] == '}')
        cursor += 1
    return text[begin:cursor]


pipeline = (ocr / 'NativeCoreMLOCRPipeline.swift').read_text()
service = (translation / 'ReaderTranslationService.swift').read_text()
region = between(service, 'struct ReaderTranslationRegion:', '    /// If translation') + '}\n'
region = region.replace('    var translationReuseIdentity: NativeTranslationReuseIdentity?\n', '')
# Unused persisted receipts are outside this focused adapter's dependency graph.
region = '\n'.join(line for line in region.split('\n') if not any(name in line for name in (
    'var sourceColumnRecognition:', 'var sourceRFParagraphRecognition:', 'var sourceRoleEvidence:')))
support = 'import Foundation\nimport CoreGraphics\n'
support += between(pipeline, 'struct NativeCoreMLOCRLine:', '@available(iOS 18.0, *)\nstruct NativeCoreMLOCRPipelineDiagnostics')
support += 'enum NativeOCRScopeGeometry {\n' + function(pipeline, '    static func bounds(for ') + '\n}\n'
balloon = (translation / 'ReaderTranslationEnclosedBackground.swift').read_text()
support += between(balloon, 'struct ReaderTranslationBalloonInterior:', '/// Bounded light-background')
support += 'struct ReaderTranslationSourceOCRAlternative:' + (ocr / 'NativeOCRMixedScriptColumnRecovery.swift').read_text().split('struct ReaderTranslationSourceOCRAlternative:', 1)[1]
lobed = (translation / 'ReaderTranslationLobedRequestMerger.swift').read_text()
support += 'enum ReaderTranslationLobedRequestMerger {\n' + function(lobed, '    static func continuesRequest(') + '\n}\n'
support += region
tests = (root / 'AidokuTests/Translation/NativeEngine/NativeParagraphFragmentGroupingTests.swift').read_text()
tests = tests.replace('import Testing\n', '').replace('@testable import Aidoku\n', '').replace('#expect', 'precondition')
tests = re.sub(r'    @Test\(arguments:.*\)\n', '', tests).replace('@Test ', '')
main = support + tests + '''
let tests = NativeParagraphFragmentGroupingTests()
tests.columnGeometryDoesNotTreatTranscriptionLengthAsFontSize()
tests.observationGraphKeepsSparseIDsIndependentOfReadingDirection()
for scale: CGFloat in [0.5, 1, 2] {
 tests.closedCarrierKeepsUnclaimedComponentsAndCoveredReadings(scale: scale)
 tests.selectedCoveredReadingsKeepImmutableEvidence(scale: scale)
 tests.repeatedOriginalGuttersNeedIndependentIntervalWitnesses(scale: scale)
 tests.privateHeadsKeepUnclaimedAmbiguityUnowned(scale: scale)
 tests.commonColumnFramePreservesSlantedOriginalReading(scale: scale)
 tests.horizontalInventoryVetoIsLocalToItsOriginalComponent(scale: scale)
 tests.closedOriginalColumnsPreserveIndentedHeads(scale: scale)
 tests.overlappingSelectedReadRequiresExactPrivatePartition(scale: scale)
 tests.shortEndpointDoesNotBridgeParagraphGutter(scale: scale)
 tests.overlappingGlyphRequiresOwnerAndIndependentInk(scale: scale)
 tests.columnContinuationPreservesInterveningMarks(scale: scale)
 tests.multiColumnTailRequiresScopeCoverage(scale: scale)
 tests.measuredColumnsRequireIndependentAgreement(scale: scale)
 tests.modelShortColumnRequiresCompleteMaskSupportAndExhaustiveTextScope(scale: scale)
 tests.modelOriginalGridRequiresClosedCompleteCohort(scale: scale)
 tests.overlappingMeasuredFacesNeedSharedCompleteInkAndExteriorSupport(scale: scale)
 tests.sharedObservationColumnExtendsOnlyWithClosedIndependentEvidence(scale: scale)
 tests.primaryColumnUsesPacketsInsteadOfParagraphEnvelope(scale: scale)
 tests.primaryPacketInsertionPreservesEveryOriginalSequence(scale: scale)
 tests.equalPhysicalEndpointsAreNotContinuation(scale: scale)
 tests.componentBridgeRequiresReciprocalMultiColumnEvidence(scale: scale)
 tests.closedSharedCarrierRequiresCompleteOwnership(scale: scale)
 tests.repeatedWholeColumnContactNeedsIndependentExteriorInk(scale: scale)
 tests.reciprocalColumnContactPreservesGlyphScaleAndReading(scale: scale)
 tests.compactHorizontalGlyphContactRequiresReciprocalOwnership(scale: scale)
 tests.jointComponentContactPreservesNestedDuplicateAndOriginalOrder(scale: scale)
 tests.uncertainInteriorAllowsOnlyUniqueKnownOuterExtensions(scale: scale)
 tests.scopeExtensionNeedsOneProvenOwnerAndSingleColumn(scale: scale)
 tests.originalColumnProofSurvivesAggregationWithoutParagraphBootstrapping(scale: scale)
 tests.proofConnectedColumnExtensionPreservesOriginalTextAndPackets(scale: scale)
 tests.completeCoreHintsSupplementButNeverReplaceSourceGeometry(scale: scale)
 tests.completeInkBoundaryDoesNotShrinkOriginalSourceOrMaskSupport(scale: scale)
 tests.horizontalWordTailRequiresCompleteColumnSupportAndKeepsAtomicText(scale: scale)
 tests.independentInkAxisRepairsPaddingWithoutBorrowingCandidateOwnership(scale: scale)
 tests.horizontalRowsRequireCompleteScopeAndOriginalOwnership(scale: scale)
 tests.compoundHorizontalHeadsPreserveOriginalWords(scale: scale)
 tests.partiallyDetectedOriginalBlocksRequireDisconnectedOwnedInk(scale: scale)
 tests.unprofiledGraphPartitionsRequireCompleteOriginalSources(scale: scale)
 tests.nativeAnchorRequiresCompleteStrongSourceCohort(scale: scale)
 tests.nativeOriginalGridExtendsWithoutRFQuery(scale: scale)
 tests.ambiguousOnlyCarrierRequiresWholeTableClosure(scale: scale)
 tests.closedCarrierConnectsIndependentOriginalColumns(scale: scale)
 tests.reciprocalOriginalColumnsDoNotDependOnStrongProposal(scale: scale)
 tests.completeOwnedGridExplainsProposalMargins(scale: scale)
 tests.completeSingleColumnScopePreservesBlankSpacingAndOrder(scale: scale)
 tests.exteriorModelPeerRequiresIndependentInkAndNoTailConnection(scale: scale)
}
tests.invalidPartitionsRemainUntouched()
tests.pipelinePreservesSourcesAndPhysicalMembers()
tests.pipelineSamplesOriginalInkAndInsertsGlyphAtItsColumn()
tests.nestedObservationsRetainPrimaryAndRejectAmbiguity()
tests.independentTextBlocksRequireExactOriginalLineage()
print("PASS 144 production Swift grouping/adapter test invocations: shared observation graph, scale/order, complete ownership and boundary negatives, immutable covered-reading provenance, closed shared carriers with unclaimed components and RF margins, source/evidence conservation, original column graphs, native/model grids, horizontal rows and real pixels")
'''
if os.environ.get('AIDOKU_GROUPING_TEST_TRACE') == '1':
    main = main.replace('precondition(', 'checked(')
    main = '''import Foundation
func checked(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
    if !condition() { fputs("FAILED line \\(line): \\(message())\\n", stderr); exit(1) }
}
''' + main
    main = re.sub(r'(?m)^(\s*)tests\.(\w+)\(',
                  lambda match: f'{match[1]}print("RUN {match[2]}"); fflush(stdout); tests.{match[2]}(', main)
workspace = root / ('build/paragraph-fragment-smoke-trace' if os.environ.get('AIDOKU_GROUPING_TEST_TRACE') == '1'
                    else 'build/paragraph-fragment-smoke')
snapshot = workspace / 'production-snapshot'
snapshot.mkdir(parents=True, exist_ok=True)
binary = workspace / 'smoke'
sources = [ocr / 'BrowserOCRSourceOrientation.swift', ocr / 'NativeOCRDetectorSeedEvidence.swift', ocr / 'NativeOCRSourceROIProbabilityEvidence.swift',
           ocr / 'NativeOCRAcceptedSource.swift', translation / 'NativeParagraphFragmentGrouping.swift',
           translation / 'NativeParagraphFragmentGrouping+Pipeline.swift']
frozen = []
for path in sources:
    target = snapshot / path.name
    write_if_changed(target, path.read_bytes())
    frozen.append(target)
started = time.monotonic()
compile_replay(workspace, frozen, main, binary)
print(f'Host compile seconds: {time.monotonic() - started:.2f}', flush=True)
started = time.monotonic()
subprocess.run([str(binary)], check=True)
print(f'Host tests seconds: {time.monotonic() - started:.2f}', flush=True)
