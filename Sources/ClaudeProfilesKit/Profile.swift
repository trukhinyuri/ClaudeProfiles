import Foundation

/// An additional Claude Desktop profile: its own window, Dock icon and sign-in.
/// The main Claude app is not a `Profile`; it is always present and never modified.
public struct Profile: Codable, Identifiable, Hashable, Sendable {
    /// Stable slug; names the data directory and the engine clone.
    public var id: String
    /// Short text drawn on the Dock icon, e.g. "WORK".
    public var label: String
    /// The account the user intends to sign in with. Used only to warn about a mismatch.
    public var email: String?
    /// Icon badge color, `#RRGGBB`.
    public var color: String
    public var createdAt: Date

    public init(id: String, label: String, email: String?, color: String, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.email = email
        self.color = color
        self.createdAt = createdAt
    }

    public static let palette = ["#1971C2", "#2F9E44", "#7048E8", "#0C8599", "#C2255C", "#E8590C", "#5C940D", "#862E9C"]
    public static let mainColor = "#D97757"
    public static let maxLabelLength = 8

    /// Suggests a label from an email: `jane.doe@acme.com` → `JANE`.
    public static func suggestedLabel(for email: String, taken: Set<String>) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let word = local.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? "acct"
        let base = String(word.uppercased().prefix(maxLabelLength))
        let upperTaken = Set(taken.map { $0.uppercased() })
        if !upperTaken.contains(base) { return base.isEmpty ? "ACCT" : base }
        for n in 2...99 {
            let candidate = String(base.prefix(maxLabelLength - String(n).count)) + String(n)
            if !upperTaken.contains(candidate) { return candidate }
        }
        return String(UUID().uuidString.prefix(6))
    }

    /// Filesystem-safe id for a label: lowercase ASCII letters, digits and dashes.
    public static func slug(for label: String) -> String {
        let allowed = label.lowercased().unicodeScalars.map { scalar -> Character in
            ("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)) ? Character(scalar) : "-"
        }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "profile" : String(collapsed.prefix(24))
    }

    public static func isValidLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= maxLabelLength
            && trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    public static func isValidEmail(_ email: String) -> Bool {
        email.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }
}

/// The list of profiles, stored as JSON in the Claude Profiles state directory.
public struct ProfileRegistry: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    /// - Throws: if the registry exists but can't be read, so a damaged file is never silently replaced.
    public func load() throws -> [Profile] {
        guard FileManager.default.fileExists(atPath: paths.registryFile.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Profile].self, from: Data(contentsOf: paths.registryFile))
    }

    public func save(_ profiles: [Profile]) throws {
        try FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let backup = paths.registryFile.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: paths.registryFile.path) {
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: paths.registryFile, to: backup)
        }
        try encoder.encode(profiles).write(to: paths.registryFile, options: .atomic)
    }
}
