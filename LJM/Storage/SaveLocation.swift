import Foundation

/// Default folder is `~/Movies/LJM`, allowed by the Movies sandbox entitlement.
/// A user-chosen folder is persisted as an app-scoped security-scoped bookmark.
enum SaveLocation {
    static let bookmarkKey = "ljm.saveBookmark"

    final class Access {
        let directory: URL
        private let scoped: Bool
        private var stopped = false

        fileprivate init(directory: URL, scoped: Bool) {
            self.directory = directory
            self.scoped = scoped
        }

        func stop() {
            guard scoped, !stopped else { return }
            stopped = true
            directory.stopAccessingSecurityScopedResource()
        }

        deinit { stop() }

        var abbreviatedPath: String {
            SaveLocation.abbreviate(directory)
        }
    }

    struct RecordingPaths {
        let partial: URL
        let final: URL
    }

    /// Refuses to start a take when the destination volume has less than 500 MB
    /// of important-usage capacity left. If the volume cannot report that value,
    /// recording is allowed to proceed.
    static let minimumFreeBytes: Int64 = 500 * 1024 * 1024

    static func ensureFreeSpace(at directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity < minimumFreeBytes {
            throw CaptureError.diskSpaceLow
        }
    }

    static func beginAccess() throws -> Access {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw SaveError.bookmarkRejected
            }
            if stale, let refreshed = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return Access(directory: url, scoped: true)
        }

        let directory = try defaultDirectory()
        return Access(directory: directory, scoped: false)
    }

    static func defaultDirectory() throws -> URL {
        guard let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            throw SaveError.noMoviesFolder
        }
        let directory = movies.appendingPathComponent("LJM", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func storeBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    static func clearBookmark() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    static var hasCustomFolder: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// `LJM-2026-11-12-16-40-05.mp4`. The writer fills a `.partial.mp4` first so a crash
    /// cannot leave a truncated file under the final name.
    static func makePaths(in directory: URL, now: Date = Date()) -> RecordingPaths {
        sweepStalePartials(in: directory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let stamp = formatter.string(from: now)
        var name = "LJM-\(stamp)"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).mp4").path) {
            name = "LJM-\(stamp)-\(counter)"
            counter += 1
        }
        return RecordingPaths(
            partial: directory.appendingPathComponent("\(name).partial.mp4"),
            final: directory.appendingPathComponent("\(name).mp4")
        )
    }

    struct RecordingFile {
        let url: URL
        let name: String
        let size: Int64
        let modified: Date
        let duration: Double?
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func listRecordings(in directory: URL, limit: Int = 24) -> [RecordingFile] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let mapped: [RecordingFile] = files.compactMap { url in
            let name = url.lastPathComponent
            guard url.pathExtension.lowercased() == "mp4", !name.contains(".partial.") else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return RecordingFile(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? Date.distantPast,
                duration: nil
            )
        }
        .sorted { $0.modified > $1.modified }
        return Array(mapped.prefix(limit))
    }

    static func abbreviate(_ url: URL) -> String {
        let path = url.path
        if let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
            let home = movies.deletingLastPathComponent().path
            if path == home { return "~" }
            if path.hasPrefix(home + "/") {
                return "~" + path.dropFirst(home.count)
            }
        }
        return path
    }

    private static func sweepStalePartials(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.lastPathComponent.contains(".partial.mp4") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

enum SaveError: LocalizedError {
    case noMoviesFolder
    case bookmarkRejected

    var errorDescription: String? {
        switch self {
        case .noMoviesFolder:
            return "找不到「影片」文件夹。"
        case .bookmarkRejected:
            return "无法访问之前选择的文件夹。请在设置里重新选一次。"
        }
    }
}
