"""Compare every field of the three frozen geometry models against strict JSON decoding."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MODEL = ROOT / "Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRRawBoundaryGenerator.swift"
RESOURCES = ROOT / "Aidoku/Resources/Translation/RawCanonicalGeometry"

# Compile this extension in the model's source file to keep private forest storage
# out of the production API. Signed zero and the order of every tree matter here.
CHECK = r'''
extension NativeOCRRawBoundaryGenerator.Model {
    func compare(to other: Self) -> Int {
        precondition(featureNames == other.featureNames && heads.count == other.heads.count)
        var nodeCount = 0
        for (a, b) in zip(heads, other.heads) {
            precondition(a.bias.bitPattern == b.bias.bitPattern)
            precondition(a.learningRate.bitPattern == b.learningRate.bitPattern)
            precondition(a.trees.count == b.trees.count)
            for (treeA, treeB) in zip(a.trees, b.trees) {
                precondition(treeA.count == treeB.count)
                for (n, m) in zip(treeA, treeB) {
                    precondition(n.feature == m.feature && n.left == m.left && n.right == m.right)
                    precondition(n.threshold.bitPattern == m.threshold.bitPattern && n.value.bitPattern == m.value.bitPattern)
                }
                nodeCount += treeA.count
            }
        }
        return nodeCount
    }
    static func isPinnedForTest(_ bytes: Data) -> Bool { isFrozenGeometry(bytes) }
}
typealias Model = NativeOCRRawBoundaryGenerator.Model
struct Header: Decodable { let featureNames: [String] }
for path in CommandLine.arguments.dropFirst() {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    precondition(Model.isPinnedForTest(data))
    let names = try JSONDecoder().decode(Header.self, from: data).featureNames
    let start = CFAbsoluteTimeGetCurrent()
    let frozen = try Model(data: data, expectedFeatureNames: names)
    let fast = CFAbsoluteTimeGetCurrent() - start
    var equivalent = data
    equivalent.append(UInt8(ascii: " "))
    precondition(!Model.isPinnedForTest(equivalent))
    let strictStart = CFAbsoluteTimeGetCurrent()
    let reference = try Model(data: equivalent, expectedFeatureNames: names)
    let strict = CFAbsoluteTimeGetCurrent() - strictStart
    print(URL(fileURLWithPath: path).lastPathComponent, "bit-identical nodes", frozen.compare(to: reference),
          "frozen seconds", fast, "strict seconds", strict)
    var reordered = names
    reordered.swapAt(0, 1)
    do {
        _ = try Model(data: data, expectedFeatureNames: reordered)
        preconditionFailure("accepted reordered feature names")
    } catch NativeOCRRawBoundaryGenerator.Failure.invalidBundle("header") {}
    var tampered = data
    // A same-length, valid JSON with an unknown root field must go through strict validation.
    tampered[2] = UInt8(ascii: "x")
    precondition(!Model.isPinnedForTest(tampered))
    do {
        _ = try Model(data: tampered, expectedFeatureNames: names)
        preconditionFailure("accepted an unknown root field")
    } catch NativeOCRRawBoundaryGenerator.Failure.invalidBundle("unknown or missing keys") {}
}
'''

with tempfile.TemporaryDirectory(prefix="aidoku-raw-geometry-") as directory:
    temp = Path(directory)
    source = temp / "main.swift"
    source.write_text(MODEL.read_text() + "\n" + CHECK)
    binary = temp / "check"
    subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "6", "-strict-concurrency=complete",
                    "-warnings-as-errors", "-module-cache-path", str(temp / "modules"),
                    str(source), "-o", str(binary)], check=True)
    files = sorted(RESOURCES.glob("*8D.json"))
    assert len(files) == 3
    subprocess.run([str(binary), *map(str, files)], check=True)
