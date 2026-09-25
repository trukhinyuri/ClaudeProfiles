import Foundation

/// Filesystem helpers shared by `SessionSync` and `CoworkSync`, which keep different per-org files
/// consistent inside the same kind of `<account>/<organization>` folders.
enum SyncFolders {
    /// Every `<account>/<organization>` folder named `folder` across all data directories.
    static func pairs(dataDirs: [URL], folder: String) -> [URL] {
        var result: [URL] = []
        for dataDir in dataDirs {
            let root = dataDir.appending(path: folder, directoryHint: .isDirectory)
            for account in contents(of: root) where account.lastPathComponent.count == 36 && isRealDirectory(account) {
                for org in contents(of: account) where !org.lastPathComponent.hasPrefix(".") && isRealDirectory(org) {
                    result.append(org)
                }
            }
        }
        return result
    }

    static func contents(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// Read from the file system each time: `URL` caches resource values, which would hide a write Claude has
    /// just made.
    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
