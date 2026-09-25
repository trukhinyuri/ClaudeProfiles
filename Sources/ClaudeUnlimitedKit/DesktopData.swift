import Foundation

/// Plan usage as last recorded by Claude Desktop itself (`plan-usage-history.json`).
public struct Usage: Equatable, Sendable {
    /// Percent of the rolling 5-hour limit used.
    public var fiveHour: Int?
    /// Percent of the weekly limit used.
    public var week: Int?
    public var sampledAt: Date

    public init(fiveHour: Int?, week: Int?, sampledAt: Date) {
        self.fiveHour = fiveHour
        self.week = week
        self.sampledAt = sampledAt
    }

    /// The 5-hour window has certainly rolled over since this sample, so its value no longer applies.
    public func isFiveHourStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(sampledAt) > 5 * 3600
    }
}

/// Read-only access to the few non-secret facts ClaudeUnlimited needs from a Claude Desktop data directory.
///
/// Privacy boundary: `config.json` also holds OAuth token caches. Only `lastKnownAccountUuid` is read
/// from it; nothing else is decoded, stored, logged or sent anywhere.
public enum DesktopData {
    /// UUID of the account last signed in to this data directory, if any.
    public static func accountID(in dataDir: URL) -> String? {
        guard let data = try? Data(contentsOf: dataDir.appending(path: "config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["lastKnownAccountUuid"] as? String, id.count == 36
        else { return nil }
        return id
    }

    public static func usage(in dataDir: URL) -> Usage? {
        struct History: Decodable {
            struct Sample: Decodable {
                struct Values: Decodable { let fh: Int?; let sd: Int? }
                let t: Double
                let u: Values?
            }
            let samples: [Sample]
        }
        guard let data = try? Data(contentsOf: dataDir.appending(path: "plan-usage-history.json")),
              let history = try? JSONDecoder().decode(History.self, from: data),
              let last = history.samples.max(by: { $0.t < $1.t })
        else { return nil }
        return Usage(fiveHour: last.u?.fh, week: last.u?.sd, sampledAt: Date(timeIntervalSince1970: last.t / 1000))
    }

    /// Email of the signed-in account, taken from the claude.ai profile that Claude Desktop caches in IndexedDB.
    /// The cache stores the account UUID shortly before `email_address`; requiring both avoids picking up
    /// unrelated addresses (for example, teammates listed in an organization).
    public static func email(in dataDir: URL, accountID: String) -> String? {
        let root = dataDir.appending(path: "IndexedDB", directoryHint: .isDirectory)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else { return nil }
        var files: [(Date, URL)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) < 64 << 20 else { continue }
            files.append((values.contentModificationDate ?? .distantPast, url))
        }
        for (_, url) in files.sorted(by: { $0.0 > $1.0 }) {
            if let data = try? Data(contentsOf: url), let found = email(inBlob: data, accountID: accountID) {
                return found
            }
        }
        return nil
    }

    static let emailMarker = Data("email_address".utf8)

    static func email(inBlob blob: Data, accountID: String) -> String? {
        let account = Data(accountID.utf8)
        var searchStart = blob.startIndex
        while let marker = blob.range(of: emailMarker, in: searchStart..<blob.endIndex) {
            searchStart = marker.upperBound
            let before = blob[max(blob.startIndex, marker.lowerBound - 80)..<marker.lowerBound]
            guard before.range(of: account) != nil else { continue }
            let after = blob[marker.upperBound..<min(blob.endIndex, marker.upperBound + 140)]
            if let found = firstEmail(in: after) { return found }
        }
        return nil
    }

    /// The first printable run in `bytes` that looks like an email address.
    static func firstEmail(in bytes: Data) -> String? {
        let text = String(decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : 0x20 }, as: UTF8.self)
        guard let range = text.range(of: #"[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,120}\.[A-Za-z]{2,24}"#, options: .regularExpression)
        else { return nil }
        return String(text[range])
    }
}
