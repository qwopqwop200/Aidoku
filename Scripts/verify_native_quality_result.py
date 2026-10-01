#!/usr/bin/env python3
"""Require all native restoration matrix suites and argument cases in an xcresult."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

# Ruby's 200 immutable records run inside one aggregate test so it can enforce
# the shared acceptance bound. Thus 219 executions cover 418 scenario groups.
EXPECTED = {
    'NativeSourceSegmentationMatrixTests': {
        'groundTruthInkAndBackground': 120,
        'independentOwnedInkSurvivesDisplayRoleRejection': 7,
        'reviewedArtGuards': 6,
        'nativeWidthGradientFringe': 0,
        'expandedEnvironmentColorsAndSurface': 13,
    },
    'NativeSlantedRestorationMatrixTests': {
        'convexPenetrationControls': 0,
        'syntheticSlantedInkPreservesCrossingRule': 12,
        'invalidAndOverBudgetSlantedGeometry': 0,
        'glyphFootprintAndContrastControls': 0,
        'realArtworkHasNoDamageOrMissingOwnedInk': 24,
        'unsupportedBackingRetainsSource': 5,
        'allTwoHundredRubyCapturesAndAggregateAcceptance': 0,
        'inferredRubyCannotClaimNeighborOwnership': 0,
        'obliqueRubyUsesRetainedOCRQuad': 0,
        'denseRecoveryPreservesReviewedOwnedFootprint': 4,
        'nativeOutlineCapturesRemoveWholeSilhouette': 2,
    },
    'NativeSourceOwnershipMatrixTests': {
        'bodyArtworkEvidenceAndExactPixels': 6,
        'explicitUnresolvedAndAuxiliaryProofControls': 4,
        'establishedPlacementPrecedesFreshProofAndFailureRollsBack': 0,
        'unresolvedExplicitAuxiliaryVetoesResidualSpeckRetry': 0,
        'segmentedRecoveryRetainsUnownedSource': 6,
        'segmentedRecoveryCannotLeakIntoSlantedNeighborMask': 0,
    },
}
SCENARIO_GROUPS = {
    'NativeSourceSegmentationMatrixTests': 147,
    'NativeSlantedRestorationMatrixTests': 252,
    'NativeSourceOwnershipMatrixTests': 19,
}


def nodes(value):
    yield value
    for child in value.get('children', []):
        yield from nodes(child)


def verify(document):
    all_nodes = [node for root in document.get('testNodes', []) for node in nodes(root)]
    summaries = []
    for name, expected in EXPECTED.items():
        found = [node for node in all_nodes if node.get('nodeType') == 'Test Suite' and node.get('name') == name]
        if len(found) != 1:
            raise ValueError(f'{name}: expected one executed suite, found {len(found)}')
        suite = found[0]
        descendants = list(nodes(suite))
        if any(node.get('result') != 'Passed' for node in descendants):
            raise ValueError(f'{name}: suite contains a failed, skipped or non-passing result')
        cases = [node for node in descendants if node.get('nodeType') == 'Test Case']
        executions = 0
        for method, count in expected.items():
            matches = [node for node in cases if node.get('name', '').split('(', 1)[0] == method]
            if len(matches) != 1:
                raise ValueError(f'{name}/{method}: expected one executed declaration, found {len(matches)}')
            arguments = [node for node in nodes(matches[0]) if node.get('nodeType') == 'Arguments']
            if len(arguments) != count or len({node.get('name') for node in arguments}) != count:
                raise ValueError(f'{name}/{method}: expected {count} distinct argument cases, found {len(arguments)}')
            executions += max(1, count)
        summaries.append({'suite': name, 'requiredDeclarations': len(expected),
                          'requiredCaseExecutions': executions, 'scenarioGroups': SCENARIO_GROUPS[name]})
    return {'passed': True, 'suites': summaries,
            'requiredDeclarations': sum(row['requiredDeclarations'] for row in summaries),
            'requiredCaseExecutions': sum(row['requiredCaseExecutions'] for row in summaries),
            'scenarioGroups': sum(row['scenarioGroups'] for row in summaries), 'skipped': 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        raw = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
                                       '--path', str(args.bundle), '--compact'])
        tree = json.loads(raw)
        args.output.with_suffix('.tests.json').write_bytes(raw)
        result = verify(tree)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result))
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'Native quality execution verification failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
