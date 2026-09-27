import Foundation

/// What a node in the moment graph represents. Finer nodes sit inside coarser ones.
public enum MomentNodeKind: String, Codable, CaseIterable, Sendable {
    case sentence, utterance, topicSegment, storyBeat, scene, demoSegment, candidate
}

/// The part a stretch of speech plays in a story, used to choose natural clip boundaries.
public enum StoryRole: String, Codable, CaseIterable, Sendable {
    case hook, context, setup, tension, turn, payoff, resolution, callToAction, aside

    /// Roles a self-contained clip can start with.
    public var canOpenClip: Bool { [.hook, .context, .setup, .tension].contains(self) }
    /// Roles a self-contained clip can end on.
    public var canCloseClip: Bool { [.payoff, .resolution, .callToAction].contains(self) }
}

public struct MomentNode: Codable, Equatable, Sendable {
    public let id: MomentNodeID
    public let kind: MomentNodeKind
    public let range: MediaTimeRange
    /// A short description for search and review; never renderer input.
    public let summary: String?
    /// How important this span is to the whole source, 0...1.
    public let salience: Double
    public let storyRole: StoryRole?
    public let topicIDs: [TopicID]
    public let speakerID: String?
    public let provenance: Provenance

    public init(id: MomentNodeID = MomentNodeID(), kind: MomentNodeKind, range: MediaTimeRange,
                summary: String? = nil, salience: Double, storyRole: StoryRole? = nil,
                topicIDs: [TopicID] = [], speakerID: String? = nil, provenance: Provenance) throws {
        guard V2Validation.unit(salience),
              summary.map({ V2Validation.text($0, maximum: 500) }) ?? true,
              speakerID.map({ V2Validation.text($0, maximum: 64) }) ?? true,
              topicIDs.count <= 32, Set(topicIDs).count == topicIDs.count else {
            throw ModelError.invalid("MomentNode")
        }
        self.id = id
        self.kind = kind
        self.range = range
        self.summary = summary
        self.salience = salience
        self.storyRole = storyRole
        self.topicIDs = topicIDs
        self.speakerID = speakerID
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(MomentNodeID.self, forKey: .id),
                      kind: c.decode(MomentNodeKind.self, forKey: .kind),
                      range: c.decode(MediaTimeRange.self, forKey: .range),
                      summary: c.decodeIfPresent(String.self, forKey: .summary),
                      salience: c.decode(Double.self, forKey: .salience),
                      storyRole: c.decodeIfPresent(StoryRole.self, forKey: .storyRole),
                      topicIDs: c.decodeIfPresent([TopicID].self, forKey: .topicIDs) ?? [],
                      speakerID: c.decodeIfPresent(String.self, forKey: .speakerID),
                      provenance: c.decode(Provenance.self, forKey: .provenance))
    }
}

/// A directed relation, read as "from <kind> to", e.g. a setup `setsUp` its payoff.
public enum MomentEdgeKind: String, Codable, CaseIterable, Sendable {
    case follows, contains, setsUp, paysOff, answers, elaborates, contrasts, repeats, references, sameTopic
}

public struct MomentEdge: Codable, Equatable, Sendable {
    public let from: MomentNodeID
    public let to: MomentNodeID
    public let kind: MomentEdgeKind
    public let weight: Double
    public let provenance: Provenance

    public init(from: MomentNodeID, to: MomentNodeID, kind: MomentEdgeKind,
                weight: Double = 1, provenance: Provenance) throws {
        guard from != to, V2Validation.unit(weight) else { throw ModelError.invalid("MomentEdge") }
        self.from = from
        self.to = to
        self.kind = kind
        self.weight = weight
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(from: c.decode(MomentNodeID.self, forKey: .from),
                      to: c.decode(MomentNodeID.self, forKey: .to),
                      kind: c.decode(MomentEdgeKind.self, forKey: .kind),
                      weight: c.decode(Double.self, forKey: .weight),
                      provenance: c.decode(Provenance.self, forKey: .provenance))
    }
}

public struct StoryBeat: Codable, Equatable, Sendable {
    public let role: StoryRole
    public let range: MediaTimeRange

    public init(role: StoryRole, range: MediaTimeRange) {
        self.role = role
        self.range = range
    }
}

/// A coherent story found in the source: ordered beats over moment nodes.
public struct StoryUnit: Codable, Equatable, Sendable {
    public let id: StoryUnitID
    public let range: MediaTimeRange
    public let beats: [StoryBeat]
    public let nodeIDs: [MomentNodeID]
    /// How complete the story is on its own, 0...1.
    public let completeness: Double
    public let title: String?

    public init(id: StoryUnitID = StoryUnitID(), range: MediaTimeRange, beats: [StoryBeat],
                nodeIDs: [MomentNodeID], completeness: Double, title: String? = nil) throws {
        guard !beats.isEmpty, beats.count <= 64,
              V2Validation.ordered(beats.map(\.range)),
              beats.allSatisfy({ V2Validation.contains(range, $0.range) }),
              !nodeIDs.isEmpty, Set(nodeIDs).count == nodeIDs.count,
              V2Validation.unit(completeness),
              title.map({ V2Validation.text($0, maximum: 120) }) ?? true else {
            throw ModelError.invalid("StoryUnit")
        }
        self.id = id
        self.range = range
        self.beats = beats
        self.nodeIDs = nodeIDs
        self.completeness = completeness
        self.title = title
    }

    /// Whether the unit can stand alone: it opens and closes on suitable roles.
    public var isSelfContained: Bool {
        (beats.first?.role.canOpenClip ?? false) && (beats.last?.role.canCloseClip ?? false)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(StoryUnitID.self, forKey: .id),
                      range: c.decode(MediaTimeRange.self, forKey: .range),
                      beats: c.decode([StoryBeat].self, forKey: .beats),
                      nodeIDs: c.decode([MomentNodeID].self, forKey: .nodeIDs),
                      completeness: c.decode(Double.self, forKey: .completeness),
                      title: c.decodeIfPresent(String.self, forKey: .title))
    }
}

/// The structure of one source: spans of speech and picture, how they relate, and the
/// stories they form. Regeneratable from the transcript, analysis, and model evidence.
public struct MomentGraph: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumNodes = 20_000
    public static let maximumEdges = 100_000

    public let schemaVersion: Int
    public let assetID: AssetID
    public let nodes: [MomentNode]
    public let edges: [MomentEdge]
    public let storyUnits: [StoryUnit]

    public init(assetID: AssetID, nodes: [MomentNode], edges: [MomentEdge],
                storyUnits: [StoryUnit] = []) throws {
        schemaVersion = Self.currentVersion
        self.assetID = assetID
        self.nodes = nodes
        self.edges = edges
        self.storyUnits = storyUnits
        try checkStructure()
    }

    private func checkStructure() throws {
        guard nodes.count <= Self.maximumNodes, edges.count <= Self.maximumEdges,
              storyUnits.count <= 1_000 else { throw ModelError.invalid("MomentGraph size") }
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard byID.count == nodes.count else { throw ModelError.invalid("MomentGraph duplicate node") }
        var seen = Set<String>()
        for edge in edges {
            guard let from = byID[edge.from], let to = byID[edge.to] else {
                throw ModelError.invalid("MomentGraph dangling edge")
            }
            guard seen.insert("\(edge.from.rawValue)>\(edge.to.rawValue)>\(edge.kind.rawValue)").inserted else {
                throw ModelError.invalid("MomentGraph duplicate edge")
            }
            // Direction carries meaning; reject edges whose time order contradicts it.
            let ordered: Bool = switch edge.kind {
            case .contains: V2Validation.contains(from.range, to.range)
            case .follows, .setsUp: from.range.start <= to.range.start
            case .paysOff, .answers: to.range.start <= from.range.start
            case .elaborates, .contrasts, .repeats, .references, .sameTopic: true
            }
            guard ordered else { throw ModelError.invalid("MomentGraph edge order: \(edge.kind.rawValue)") }
        }
        guard Set(storyUnits.map(\.id)).count == storyUnits.count,
              storyUnits.allSatisfy({ unit in
                  unit.nodeIDs.allSatisfy { id in byID[id].map { V2Validation.contains(unit.range, $0.range) } ?? false }
              }) else {
            throw ModelError.invalid("MomentGraph story unit")
        }
    }

    /// Checks every range against the source it claims to describe.
    public func validate(for asset: MediaAsset) throws {
        guard assetID == asset.id,
              nodes.allSatisfy({ $0.range.end <= asset.duration }),
              storyUnits.allSatisfy({ $0.range.end <= asset.duration }) else {
            throw ModelError.invalid("MomentGraph source bounds")
        }
    }

    public func node(_ id: MomentNodeID) -> MomentNode? { nodes.first { $0.id == id } }

    public func edges(from id: MomentNodeID, kind: MomentEdgeKind? = nil) -> [MomentEdge] {
        edges.filter { $0.from == id && (kind == nil || $0.kind == kind) }
    }

    /// Nodes directly contained by `id`, in time order.
    public func children(of id: MomentNodeID) -> [MomentNode] {
        edges(from: id, kind: .contains).compactMap { node($0.to) }.sorted { $0.range.start < $1.range.start }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, assetID, nodes, edges, storyUnits }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try V2Validation.version(c.decode(Int.self, forKey: .schemaVersion),
                                 current: Self.currentVersion, "MomentGraph")
        try self.init(assetID: c.decode(AssetID.self, forKey: .assetID),
                      nodes: c.decode([MomentNode].self, forKey: .nodes),
                      edges: c.decode([MomentEdge].self, forKey: .edges),
                      storyUnits: c.decodeIfPresent([StoryUnit].self, forKey: .storyUnits) ?? [])
    }
}
