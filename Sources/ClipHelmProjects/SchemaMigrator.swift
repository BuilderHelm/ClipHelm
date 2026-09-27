import Foundation

public enum SchemaMigrationError: Error, Equatable, LocalizedError, Sendable {
    case unreadable(document: String)
    case missingVersion(document: String)
    case futureVersion(document: String, found: Int, supported: Int)
    case unsupportedVersion(document: String, found: Int, oldest: Int)
    case stepFailed(document: String, from: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let document): "The \(document) file is not valid JSON."
        case .missingVersion(let document): "The \(document) file has no schema version."
        case .futureVersion(let document, let found, let supported):
            "This \(document) was saved by a newer version of ClipHelm (format \(found); this version reads up to \(supported)). Update ClipHelm to open it."
        case .unsupportedVersion(let document, let found, let oldest):
            "This \(document) uses format \(found), which is older than this version of ClipHelm supports (\(oldest))."
        case .stepFailed(let document, let from):
            "The \(document) could not be upgraded from format \(from)."
        }
    }
}

/// One structural change between adjacent versions, applied to the decoded JSON object.
public struct SchemaMigrationStep: Sendable {
    public let from: Int
    let transform: @Sendable (inout [String: Any]) throws -> Void

    public init(from: Int, transform: @escaping @Sendable (inout [String: Any]) throws -> Void) {
        self.from = from
        self.transform = transform
    }
}

public struct MigrationOutcome: Sendable {
    /// JSON ready for the current typed decoder.
    public let data: Data
    /// The version the document was stored with, before any upgrade.
    public let originalVersion: Int
    public let currentVersion: Int

    public var isUpgrade: Bool { originalVersion < currentVersion }
}

/// Gatekeeper and upgrader for one versioned JSON document type.
///
/// It reads the version, rejects documents from a newer ClipHelm, and applies any registered
/// structural steps in order. Additive changes (new optional fields) need no step: the typed
/// decoder supplies defaults. Migration happens in memory; callers decide when to write.
public struct SchemaMigrator: Sendable {
    public let document: String
    public let versionKey: String
    public let currentVersion: Int
    public let oldestSupportedVersion: Int
    private let steps: [Int: SchemaMigrationStep]

    public init(document: String, versionKey: String = "schemaVersion", currentVersion: Int,
                oldestSupportedVersion: Int = 1, steps: [SchemaMigrationStep] = []) {
        precondition(oldestSupportedVersion >= 1 && oldestSupportedVersion <= currentVersion)
        precondition(steps.allSatisfy { (oldestSupportedVersion..<currentVersion).contains($0.from) })
        precondition(Set(steps.map(\.from)).count == steps.count)
        self.document = document
        self.versionKey = versionKey
        self.currentVersion = currentVersion
        self.oldestSupportedVersion = oldestSupportedVersion
        self.steps = Dictionary(uniqueKeysWithValues: steps.map { ($0.from, $0) })
    }

    /// Reads only the version, without trusting the rest of the document.
    public func version(of data: Data) throws -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SchemaMigrationError.unreadable(document: document)
        }
        return try version(in: object)
    }

    private func version(in object: [String: Any]) throws -> Int {
        guard let number = object[versionKey] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue,
              let version = Int(exactly: number.doubleValue) else {
            throw SchemaMigrationError.missingVersion(document: document)
        }
        return version
    }

    public func migrate(_ data: Data) throws -> MigrationOutcome {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SchemaMigrationError.unreadable(document: document)
        }
        let original = try version(in: object)
        guard original <= currentVersion else {
            throw SchemaMigrationError.futureVersion(document: document, found: original, supported: currentVersion)
        }
        guard original >= oldestSupportedVersion else {
            throw SchemaMigrationError.unsupportedVersion(document: document, found: original,
                                                          oldest: oldestSupportedVersion)
        }
        let pending = (original..<currentVersion).compactMap { steps[$0] }
        guard !pending.isEmpty else {
            return MigrationOutcome(data: data, originalVersion: original, currentVersion: currentVersion)
        }
        for step in pending {
            do { try step.transform(&object) }
            catch { throw SchemaMigrationError.stepFailed(document: document, from: step.from) }
            object[versionKey] = step.from + 1
        }
        let upgraded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return MigrationOutcome(data: upgraded, originalVersion: original, currentVersion: currentVersion)
    }
}
