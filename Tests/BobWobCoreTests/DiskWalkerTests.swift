import Foundation
import Testing

@testable import BobWobCore

@Suite struct DiskWalkerTests {
    @Test func countsAllocatedBytesNotApparentSize() throws {
        let directory = try TemporaryDirectory()
        let sparse = directory.url.appending(path: "sparse.raw")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 1_000_000_000)
        try handle.close()

        let result = try DiskWalker.walk(root: directory.url.path)

        #expect(result.fileCount == 1)
        #expect(result.allocatedBytes < 1_000_000)
    }

    @Test func countsHardLinksOnceAndFlagsEstimate() throws {
        let directory = try TemporaryDirectory()
        let original = try directory.write("a/original", bytes: 100_000)
        try FileManager.default.linkItem(at: original, to: directory.url.appending(path: "a/linked"))

        let single = try DiskWalker.walk(root: original.path)
        let result = try DiskWalker.walk(root: directory.url.path)

        #expect(result.allocatedBytes == single.allocatedBytes)
        #expect(result.fileCount == 1)
        #expect(result.size == .estimated(single.allocatedBytes))
    }

    @Test func doesNotFollowSymbolicLinks() throws {
        let directory = try TemporaryDirectory()
        let outside = try TemporaryDirectory()
        try outside.write("big", bytes: 2_000_000)
        try FileManager.default.createSymbolicLink(
            at: directory.url.appending(path: "link"),
            withDestinationURL: outside.url
        )

        let result = try DiskWalker.walk(root: directory.url.path)

        #expect(result.allocatedBytes < 100_000)
    }

    @Test func skipsExcludedPathsAndRefusedDirectories() throws {
        let directory = try TemporaryDirectory()
        try directory.write("keep/file", bytes: 100_000)
        let excluded = try directory.write("excluded/file", bytes: 1_000_000)
        try directory.write("refused/file", bytes: 1_000_000)

        let result = try DiskWalker.walk(
            root: directory.url.path,
            excluding: [excluded.deletingLastPathComponent().path],
            shouldDescend: { !$0.hasSuffix("/refused") }
        )

        #expect(result.fileCount == 1)
        #expect(result.allocatedBytes < 500_000)
    }

    @Test func reportsUnreadableDirectoryInsteadOfZero() throws {
        let directory = try TemporaryDirectory()
        let locked = directory.url.appending(path: "locked")
        try directory.write("locked/file")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

        let result = try DiskWalker.walk(root: directory.url.path)

        #expect(result.inaccessibleCount >= 1)
        #expect(result.size == .estimated(result.allocatedBytes))
    }

    @Test func reportsMissingRootAsInaccessible() throws {
        let result = try DiskWalker.walk(root: "/nonexistent/bobwob-\(UUID().uuidString)")
        #expect(result.inaccessibleCount == 1)
        #expect(result.fileCount == 0)
    }

    @Test func stopsWhenCancelled() async throws {
        let directory = try TemporaryDirectory()
        for index in 0..<5000 {
            try directory.write("f/\(index)", bytes: 1)
        }
        let root = directory.url.path
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DiskWalker.walk(root: root)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
