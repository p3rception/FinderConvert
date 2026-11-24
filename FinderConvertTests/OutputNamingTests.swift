import FinderConvertCore
import XCTest

final class OutputNamingTests: XCTestCase {
    func testFirstCollisionUsesConvertedSuffix() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceURL = tempDirectory.appending(path: "sample.png", directoryHint: .notDirectory)
        try Data().write(to: sourceURL)

        let destination = try OutputNamingStrategy().destinationURL(for: sourceURL, outputFormat: .jpeg)
        XCTAssertEqual(destination.lastPathComponent, "sample converted.jpg")
    }

    func testLaterCollisionAppendsIndex() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceURL = tempDirectory.appending(path: "sample.jpg", directoryHint: .notDirectory)
        let first = tempDirectory.appending(path: "sample converted.png", directoryHint: .notDirectory)
        try Data().write(to: sourceURL)
        try Data().write(to: first)

        let destination = try OutputNamingStrategy().destinationURL(for: sourceURL, outputFormat: .png)
        XCTAssertEqual(destination.lastPathComponent, "sample converted 2.png")
    }

    // The root's own absolute path repeated inside it used to be stripped
    // everywhere, not just as the prefix
    func testMirroredPathStripsOnlyTheRootPrefix() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let root = tempRoot.resolvingSymlinksInPath()
        let nested = String(root.path.dropFirst()) + "/img.png"
        let source = root.appending(path: nested, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: source)

        let newRoot = tempRoot.deletingLastPathComponent().appending(path: "\(UUID().uuidString) converted", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: newRoot) }
        let destination = try OutputNamingStrategy().destinationURL(
            for: source, outputFormat: .jpeg,
            policy: .mirroredDirectory(originalRoot: root, newRoot: newRoot)
        )
        XCTAssertEqual(destination.path, newRoot.appending(path: nested).deletingPathExtension().appendingPathExtension("jpg").path)
    }
}
