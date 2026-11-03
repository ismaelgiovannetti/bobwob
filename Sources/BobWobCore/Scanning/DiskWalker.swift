import Foundation

public struct WalkResult: Sendable, Equatable {
    public var allocatedBytes: Int64 = 0
    public var fileCount = 0
    public var inaccessibleCount = 0
    public var hasSharedBlocks = false

    public var size: SizeEstimate {
        hasSharedBlocks || inaccessibleCount > 0 ? .estimated(allocatedBytes) : .exact(allocatedBytes)
    }
}

public enum DiskWalker {
    private static let cancellationCheckInterval = 4096
    private static let progressInterval = 20_000

    /// Sums allocated blocks, never apparent sizes, and counts hard-linked inodes once.
    /// Symbolic links are not followed and the walk stays on the root's volume.
    public static func walk(
        root: String,
        excluding excludedPaths: Set<String> = [],
        shouldDescend: ((String) -> Bool)? = nil,
        largeFileThreshold: Int64? = nil,
        onLargeFile: ((String, Int64) -> Void)? = nil,
        onProgress: ((Int64) -> Void)? = nil
    ) throws -> WalkResult {
        var result = WalkResult()
        guard let rootCopy = strdup(root) else { return result }
        defer { free(rootCopy) }

        var arguments: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            result.inaccessibleCount = 1
            return result
        }
        defer { fts_close(stream) }

        let needsDirectoryPath = !excludedPaths.isEmpty || shouldDescend != nil
        var seenLinks = Set<FileKey>()
        var visited = 0

        while let entry = fts_read(stream) {
            visited += 1
            if visited % cancellationCheckInterval == 0, Task.isCancelled {
                throw CancellationError()
            }
            if visited % progressInterval == 0 {
                onProgress?(result.allocatedBytes)
            }

            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                if needsDirectoryPath, entry.pointee.fts_level > 0 {
                    let path = String(cString: entry.pointee.fts_path)
                    if excludedPaths.contains(path) || shouldDescend?(path) == false {
                        fts_set(stream, entry, FTS_SKIP)
                    }
                }
            case FTS_DNR, FTS_ERR, FTS_NS:
                result.inaccessibleCount += 1
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let info = entry.pointee.fts_statp?.pointee else { continue }
                if needsDirectoryPath, !excludedPaths.isEmpty, entry.pointee.fts_level > 0,
                    excludedPaths.contains(String(cString: entry.pointee.fts_path)) {
                    continue
                }
                if info.st_nlink > 1 {
                    result.hasSharedBlocks = true
                    guard seenLinks.insert(FileKey(device: info.st_dev, inode: info.st_ino)).inserted else { continue }
                }
                let allocated = Int64(info.st_blocks) * 512
                result.allocatedBytes += allocated
                result.fileCount += 1
                if let largeFileThreshold, allocated >= largeFileThreshold {
                    onLargeFile?(String(cString: entry.pointee.fts_path), allocated)
                }
            default:
                break
            }
        }
        return result
    }

    private struct FileKey: Hashable {
        let device: Int32
        let inode: UInt64
    }
}
