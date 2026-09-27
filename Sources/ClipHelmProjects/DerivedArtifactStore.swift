import Foundation
import CryptoKit

/// Stores regeneratable V2 artifacts (MomentGraph, ProjectIntelligence, search indexes) in a
/// project's cache. Each file records its kind, format version, and a fingerprint of the
/// inputs that produced it. Anything stale, corrupt, or from another version reads as
/// missing, so the caller regenerates it. Authoritative data never lives here.
public struct DerivedArtifactStore: Sendable {
    public static let maximumBytes = 50_000_000

    private struct Envelope<Payload: Codable>: Codable {
        let kind: String
        let version: Int
        let inputs: String
        let generator: String
        let createdAt: Date
        let payload: Payload
    }

    private struct Header: Decodable {
        let kind: String
        let version: Int
        let inputs: String
    }

    public let directory: URL

    /// `cacheDirectory` is the project's `Cache` folder; artifacts go in its `v2` subfolder.
    public init(cacheDirectory: URL) {
        directory = cacheDirectory.appending(path: "v2", directoryHint: .isDirectory)
    }

    /// Stable fingerprint for the inputs of an artifact, e.g. asset ID, transcript hash, model ID.
    public static func fingerprint(_ parts: [String]) -> String {
        let joined = parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidKind(_ kind: String) -> Bool {
        (1...40).contains(kind.count) &&
            kind.unicodeScalars.allSatisfy { CharacterSet.lowercaseLetters.contains($0) ||
                CharacterSet.decimalDigits.contains($0) || $0 == "-" } &&
            kind.unicodeScalars.allSatisfy(\.isASCII)
    }

    func fileURL(kind: String, version: Int) -> URL {
        directory.appending(path: "\(kind)-v\(version).json")
    }

    /// Returns the payload only if kind, version, and input fingerprint all match.
    public func load<Payload: Codable>(_ type: Payload.Type, kind: String, version: Int,
                                       inputs: String) -> Payload? {
        guard Self.isValidKind(kind), version > 0 else { return nil }
        let file = fileURL(kind: kind, version: version)
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              let size = values.fileSize, (1...Self.maximumBytes).contains(size),
              let data = try? Data(contentsOf: file),
              let header = try? JSONDecoder().decode(Header.self, from: data),
              header.kind == kind, header.version == version, header.inputs == inputs,
              let envelope = try? JSONDecoder().decode(Envelope<Payload>.self, from: data) else {
            return nil
        }
        return envelope.payload
    }

    public func save<Payload: Codable>(_ payload: Payload, kind: String, version: Int,
                                       inputs: String, generator: String) throws {
        guard Self.isValidKind(kind), version > 0, (1...80).contains(generator.count) else {
            throw DerivedArtifactError.invalidKey
        }
        try prepareDirectory()
        let data = try JSONEncoder().encode(Envelope(kind: kind, version: version, inputs: inputs,
            generator: generator, createdAt: Date(), payload: payload))
        guard data.count <= Self.maximumBytes else { throw DerivedArtifactError.tooLarge }
        let file = fileURL(kind: kind, version: version)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Deletes every stored version of an artifact kind, e.g. after its inputs change.
    public func removeAll(kind: String) {
        guard Self.isValidKind(kind),
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                  includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix("\(kind)-v") &&
            file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func prepareDirectory() throws {
        for folder in [directory.deletingLastPathComponent(), directory] {
            if let values = try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                throw DerivedArtifactError.unsafeLocation
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}

public enum DerivedArtifactError: Error, Equatable, Sendable {
    case invalidKey, tooLarge, unsafeLocation
}

/// Artifact kinds and format versions. Bump a version when its payload format changes;
/// older files are then ignored and regenerated.
public enum DerivedArtifactKind {
    public static let momentGraph = (kind: "moment-graph", version: 1)
    public static let projectIntelligence = (kind: "project-intelligence", version: 1)
}
