import Foundation
import Testing
@testable import Aidoku

struct LocalPathContainmentTests {
    @Test func dotTraversalRootSiblingAndSymlinkEscapeRejectedWithoutTouchingData() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = sandbox.appendingPathComponent("Local")
        let outside = sandbox.appendingPathComponent("outside")
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }
        let sentinel = outside.appendingPathComponent("sentinel")
        let original = Data("keep".utf8)
        try original.write(to: sentinel)
        try fm.createSymbolicLink(at: local.appendingPathComponent("link"), withDestinationURL: outside)
        for path in ["..", ".", "", "../outside/sentinel", "../Local-other/target", "link/sentinel", "link/new.png"] {
            #expect(!LocalFileManager.isContainedLocalURL(local.appendingPathComponent(path), root: local))
        }
        let redirectedRoot = sandbox.appendingPathComponent("RedirectedLocal")
        try fm.createSymbolicLink(at: redirectedRoot, withDestinationURL: outside)
        #expect(!LocalFileManager.isContainedLocalURL(redirectedRoot.appendingPathComponent("sentinel"), root: redirectedRoot))
        #expect(!LocalFileManager.isContainedLocalURL(redirectedRoot.appendingPathComponent("new.png"), root: redirectedRoot))
        let nested = local.appendingPathComponent("Series/Volume 1")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let existing = nested.appendingPathComponent("001.png")
        try original.write(to: existing)
        #expect(LocalFileManager.isContainedLocalURL(existing, root: local))
        #expect(try Data(contentsOf: existing) == original)
        #expect(try Data(contentsOf: sentinel) == original)
        #expect(LocalFileManager.isContainedLocalURL(local.appendingPathComponent("Series/Volume 1/001.png"), root: local))
        #expect(LocalFileManager.isContainedLocalURL(local.appendingPathComponent("한글/日本語.cbz"), root: local))
        #expect(LocalFileManager.isContainedLocalURL(local.appendingPathComponent("Series/a/../001.png"), root: local))
    }
    @Test func nonexistentLeafResolvesExistingAndDanglingSymlinkAncestors() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = sandbox.appendingPathComponent("Local")
        let inside = local.appendingPathComponent("Series")
        let outside = sandbox.appendingPathComponent("outside")
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }
        let bytes = Data("outside must remain unchanged".utf8)
        let sentinel = outside.appendingPathComponent("sentinel")
        try bytes.write(to: sentinel)
        try fm.createSymbolicLink(at: local.appendingPathComponent("escape"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: local.appendingPathComponent("internal"), withDestinationURL: inside)
        try fm.createSymbolicLink(at: local.appendingPathComponent("dangling"), withDestinationURL: outside.appendingPathComponent("not-created"))
        for suffix in ["new.png", "new/nested/001.png"] {
            #expect(!LocalFileManager.isContainedLocalURL(local.appendingPathComponent("escape/" + suffix), root: local))
            #expect(!LocalFileManager.isContainedLocalURL(local.appendingPathComponent("dangling/" + suffix), root: local))
            #expect(LocalFileManager.isContainedLocalURL(local.appendingPathComponent("internal/" + suffix), root: local))
            #expect(LocalFileManager.isContainedLocalURL(local.appendingPathComponent("日本語/" + suffix), root: local))
        }
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(!outside.appendingPathComponent("new.png").exists)
        #expect(!outside.appendingPathComponent("new").exists)
        #expect(!outside.appendingPathComponent("not-created").exists)
    }

}
