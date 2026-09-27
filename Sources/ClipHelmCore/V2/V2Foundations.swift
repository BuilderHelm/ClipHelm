import Foundation

/// A typed identifier for V2 records. The tag keeps, for example, a topic ID from being
/// passed where a moment-node ID is expected.
public struct Identifier<Tag>: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum MomentNodeTag {}
public enum StoryUnitTag {}
public enum TopicTag {}
public enum SemanticEntityTag {}
public enum ScreenRegionTag {}
public enum BrandKitTag {}
public enum ClipVariantTag {}

public typealias MomentNodeID = Identifier<MomentNodeTag>
public typealias StoryUnitID = Identifier<StoryUnitTag>
public typealias TopicID = Identifier<TopicTag>
public typealias SemanticEntityID = Identifier<SemanticEntityTag>
public typealias ScreenRegionID = Identifier<ScreenRegionTag>
public typealias BrandKitID = Identifier<BrandKitTag>
public typealias ClipVariantID = Identifier<ClipVariantTag>

/// Who produced a V2 value. Model-produced values are suggestions that passed validation;
/// they never carry renderer instructions.
public enum Provenance: String, Codable, Sendable {
    case local, model, user
}

/// Shared checks for V2 values, so every type rejects the same malformed input.
enum V2Validation {
    static func unit(_ values: Double...) -> Bool {
        values.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    /// Plain display text: bounded, and free of control characters that could hide content.
    static func text(_ value: String, maximum: Int, allowEmpty: Bool = false) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (allowEmpty || !trimmed.isEmpty) && value.count <= maximum &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }
    }

    /// Ranges in order and not overlapping.
    static func ordered(_ ranges: [MediaTimeRange]) -> Bool {
        zip(ranges, ranges.dropFirst()).allSatisfy { $0.end <= $1.start }
    }

    static func contains(_ outer: MediaTimeRange, _ inner: MediaTimeRange) -> Bool {
        outer.start <= inner.start && inner.end <= outer.end
    }

    static func overlaps(_ lhs: MediaTimeRange, _ rhs: MediaTimeRange) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    /// Rejects documents written by a newer ClipHelm instead of guessing at their meaning.
    static func version(_ found: Int, current: Int, _ name: String) throws {
        guard (1...current).contains(found) else { throw ModelError.invalid("\(name) version \(found)") }
    }
}
