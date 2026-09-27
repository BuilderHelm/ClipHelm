import Foundation

public struct Topic: Codable, Equatable, Sendable {
    public let id: TopicID
    public let label: String
    public let keywords: [String]
    /// Where the topic is discussed, in time order.
    public let ranges: [MediaTimeRange]
    public let salience: Double

    public init(id: TopicID = TopicID(), label: String, keywords: [String] = [],
                ranges: [MediaTimeRange], salience: Double) throws {
        guard V2Validation.text(label, maximum: 120), keywords.count <= 20,
              keywords.allSatisfy({ V2Validation.text($0, maximum: 60) }),
              !ranges.isEmpty, ranges.count <= 1_000, V2Validation.ordered(ranges),
              V2Validation.unit(salience) else {
            throw ModelError.invalid("Topic")
        }
        self.id = id
        self.label = label
        self.keywords = keywords
        self.ranges = ranges
        self.salience = salience
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(TopicID.self, forKey: .id),
                      label: c.decode(String.self, forKey: .label),
                      keywords: c.decodeIfPresent([String].self, forKey: .keywords) ?? [],
                      ranges: c.decode([MediaTimeRange].self, forKey: .ranges),
                      salience: c.decode(Double.self, forKey: .salience))
    }
}

public enum SemanticEntityKind: String, Codable, CaseIterable, Sendable {
    case person, organization, product, place, concept, work, event, other
}

/// Something named in the source, e.g. a guest, a product, or a book.
public struct SemanticEntity: Codable, Equatable, Sendable {
    public let id: SemanticEntityID
    public let name: String
    public let kind: SemanticEntityKind
    public let aliases: [String]
    public let mentions: [MediaTimeRange]

    public init(id: SemanticEntityID = SemanticEntityID(), name: String, kind: SemanticEntityKind,
                aliases: [String] = [], mentions: [MediaTimeRange]) throws {
        guard V2Validation.text(name, maximum: 120), aliases.count <= 10,
              aliases.allSatisfy({ V2Validation.text($0, maximum: 120) }),
              !mentions.isEmpty, mentions.count <= 5_000,
              zip(mentions, mentions.dropFirst()).allSatisfy({ $0.start <= $1.start }) else {
            throw ModelError.invalid("SemanticEntity")
        }
        self.id = id
        self.name = name
        self.kind = kind
        self.aliases = aliases
        self.mentions = mentions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(SemanticEntityID.self, forKey: .id),
                      name: c.decode(String.self, forKey: .name),
                      kind: c.decode(SemanticEntityKind.self, forKey: .kind),
                      aliases: c.decodeIfPresent([String].self, forKey: .aliases) ?? [],
                      mentions: c.decode([MediaTimeRange].self, forKey: .mentions))
    }
}

public struct Chapter: Codable, Equatable, Sendable {
    public let title: String
    public let range: MediaTimeRange

    public init(title: String, range: MediaTimeRange) throws {
        guard V2Validation.text(title, maximum: 120) else { throw ModelError.invalid("Chapter") }
        self.title = title
        self.range = range
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(title: c.decode(String.self, forKey: .title),
                      range: c.decode(MediaTimeRange.self, forKey: .range))
    }
}

/// Source-wide understanding: what the video is about, its chapters, topics, and names.
/// Regeneratable; built once per source and shared by clipping, search, and the assistant.
public struct ProjectIntelligence: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let schemaVersion: Int
    public let assetID: AssetID
    public let summary: String
    /// A BCP 47 language tag such as "en" or "pt-BR", when known.
    public let languageCode: String?
    public let chapters: [Chapter]
    public let topics: [Topic]
    public let entities: [SemanticEntity]

    public init(assetID: AssetID, summary: String, languageCode: String? = nil,
                chapters: [Chapter] = [], topics: [Topic] = [], entities: [SemanticEntity] = []) throws {
        let languageShape = languageCode.map { code in
            (2...12).contains(code.count) &&
                code.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        } ?? true
        guard V2Validation.text(summary, maximum: 4_000, allowEmpty: true), languageShape,
              chapters.count <= 500, V2Validation.ordered(chapters.map(\.range)),
              topics.count <= 500, Set(topics.map(\.id)).count == topics.count,
              entities.count <= 2_000, Set(entities.map(\.id)).count == entities.count else {
            throw ModelError.invalid("ProjectIntelligence")
        }
        schemaVersion = Self.currentVersion
        self.assetID = assetID
        self.summary = summary
        self.languageCode = languageCode
        self.chapters = chapters
        self.topics = topics
        self.entities = entities
    }

    public func validate(for asset: MediaAsset) throws {
        guard assetID == asset.id,
              chapters.allSatisfy({ $0.range.end <= asset.duration }),
              topics.allSatisfy({ $0.ranges.allSatisfy { $0.end <= asset.duration } }),
              entities.allSatisfy({ $0.mentions.allSatisfy { $0.end <= asset.duration } }) else {
            throw ModelError.invalid("ProjectIntelligence source bounds")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, assetID, summary, languageCode, chapters, topics, entities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try V2Validation.version(c.decode(Int.self, forKey: .schemaVersion),
                                 current: Self.currentVersion, "ProjectIntelligence")
        try self.init(assetID: c.decode(AssetID.self, forKey: .assetID),
                      summary: c.decode(String.self, forKey: .summary),
                      languageCode: c.decodeIfPresent(String.self, forKey: .languageCode),
                      chapters: c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? [],
                      topics: c.decodeIfPresent([Topic].self, forKey: .topics) ?? [],
                      entities: c.decodeIfPresent([SemanticEntity].self, forKey: .entities) ?? [])
    }
}

public enum SearchResultKind: String, Codable, CaseIterable, Sendable {
    case transcript, moment, story, topic, entity, clip
}

/// One hit from project search. Each kind must point at the record it describes.
public struct SearchResult: Codable, Equatable, Sendable {
    public let kind: SearchResultKind
    public let range: MediaTimeRange?
    public let nodeID: MomentNodeID?
    public let storyUnitID: StoryUnitID?
    public let topicID: TopicID?
    public let entityID: SemanticEntityID?
    public let clipID: ClipID?
    public let snippet: String
    public let score: Double

    public init(kind: SearchResultKind, range: MediaTimeRange? = nil, nodeID: MomentNodeID? = nil,
                storyUnitID: StoryUnitID? = nil, topicID: TopicID? = nil,
                entityID: SemanticEntityID? = nil, clipID: ClipID? = nil,
                snippet: String, score: Double) throws {
        let referenced: Bool = switch kind {
        case .transcript: range != nil
        case .moment: nodeID != nil
        case .story: storyUnitID != nil
        case .topic: topicID != nil
        case .entity: entityID != nil
        case .clip: clipID != nil
        }
        guard referenced, V2Validation.text(snippet, maximum: 300, allowEmpty: true),
              V2Validation.unit(score) else {
            throw ModelError.invalid("SearchResult")
        }
        self.kind = kind
        self.range = range
        self.nodeID = nodeID
        self.storyUnitID = storyUnitID
        self.topicID = topicID
        self.entityID = entityID
        self.clipID = clipID
        self.snippet = snippet
        self.score = score
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: c.decode(SearchResultKind.self, forKey: .kind),
                      range: c.decodeIfPresent(MediaTimeRange.self, forKey: .range),
                      nodeID: c.decodeIfPresent(MomentNodeID.self, forKey: .nodeID),
                      storyUnitID: c.decodeIfPresent(StoryUnitID.self, forKey: .storyUnitID),
                      topicID: c.decodeIfPresent(TopicID.self, forKey: .topicID),
                      entityID: c.decodeIfPresent(SemanticEntityID.self, forKey: .entityID),
                      clipID: c.decodeIfPresent(ClipID.self, forKey: .clipID),
                      snippet: c.decode(String.self, forKey: .snippet),
                      score: c.decode(Double.self, forKey: .score))
    }
}
