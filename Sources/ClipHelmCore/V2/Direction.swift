import Foundation

public enum EditorialObjective: String, Codable, CaseIterable, Sendable {
    case hook, educate, entertain, inspire, promote, announce
}

/// What a clip is for and what it must keep or avoid. Guides planning; it does not cut.
public struct EditorialIntent: Codable, Equatable, Sendable {
    public let proposalID: UUID
    public let objective: EditorialObjective
    public let keepRanges: [MediaTimeRange]
    public let avoidRanges: [MediaTimeRange]
    public let minimumMicroseconds: Int64?
    public let maximumMicroseconds: Int64?
    public let provenance: Provenance

    public init(proposalID: UUID, objective: EditorialObjective, keepRanges: [MediaTimeRange] = [],
                avoidRanges: [MediaTimeRange] = [], minimumMicroseconds: Int64? = nil,
                maximumMicroseconds: Int64? = nil, provenance: Provenance) throws {
        let boundsValid: Bool = switch (minimumMicroseconds, maximumMicroseconds) {
        case let (low?, high?): low > 0 && low < high
        case let (low?, nil): low > 0
        case let (nil, high?): high > 0
        case (nil, nil): true
        }
        guard boundsValid, keepRanges.count <= 100, avoidRanges.count <= 100,
              V2Validation.ordered(keepRanges), V2Validation.ordered(avoidRanges),
              !keepRanges.contains(where: { keep in avoidRanges.contains { V2Validation.overlaps(keep, $0) } }) else {
            throw ModelError.invalid("EditorialIntent")
        }
        self.proposalID = proposalID
        self.objective = objective
        self.keepRanges = keepRanges
        self.avoidRanges = avoidRanges
        self.minimumMicroseconds = minimumMicroseconds
        self.maximumMicroseconds = maximumMicroseconds
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(proposalID: c.decode(UUID.self, forKey: .proposalID),
                      objective: c.decode(EditorialObjective.self, forKey: .objective),
                      keepRanges: c.decodeIfPresent([MediaTimeRange].self, forKey: .keepRanges) ?? [],
                      avoidRanges: c.decodeIfPresent([MediaTimeRange].self, forKey: .avoidRanges) ?? [],
                      minimumMicroseconds: c.decodeIfPresent(Int64.self, forKey: .minimumMicroseconds),
                      maximumMicroseconds: c.decodeIfPresent(Int64.self, forKey: .maximumMicroseconds),
                      provenance: c.decode(Provenance.self, forKey: .provenance))
    }
}

public enum ShotSubject: String, Codable, CaseIterable, Sendable {
    case speaker, screen, wide, reaction, object
}

public enum ShotEmphasis: String, Codable, CaseIterable, Sendable {
    case neutral, emphasize, reveal
}

/// What the viewer should see during a span, before any geometry is chosen.
public struct ShotIntent: Codable, Equatable, Sendable {
    public let range: MediaTimeRange
    public let subject: ShotSubject
    public let speakerID: String?
    public let emphasis: ShotEmphasis
    public let preferredLayout: ShotLayout?
    public let confidence: Double
    public let provenance: Provenance

    public init(range: MediaTimeRange, subject: ShotSubject, speakerID: String? = nil,
                emphasis: ShotEmphasis = .neutral, preferredLayout: ShotLayout? = nil,
                confidence: Double, provenance: Provenance) throws {
        guard V2Validation.unit(confidence),
              speakerID.map({ V2Validation.text($0, maximum: 64) }) ?? true,
              speakerID == nil || subject == .speaker || subject == .reaction else {
            throw ModelError.invalid("ShotIntent")
        }
        self.range = range
        self.subject = subject
        self.speakerID = speakerID
        self.emphasis = emphasis
        self.preferredLayout = preferredLayout
        self.confidence = confidence
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(range: c.decode(MediaTimeRange.self, forKey: .range),
                      subject: c.decode(ShotSubject.self, forKey: .subject),
                      speakerID: c.decodeIfPresent(String.self, forKey: .speakerID),
                      emphasis: c.decodeIfPresent(ShotEmphasis.self, forKey: .emphasis) ?? .neutral,
                      preferredLayout: c.decodeIfPresent(ShotLayout.self, forKey: .preferredLayout),
                      confidence: c.decode(Double.self, forKey: .confidence),
                      provenance: c.decode(Provenance.self, forKey: .provenance))
    }
}

public enum CameraMotionKind: String, Codable, CaseIterable, Sendable {
    case hold, punchIn, pushIn, pullOut, pan
}

public enum MotionEasing: String, Codable, CaseIterable, Sendable {
    case linear, easeInOut
}

/// A virtual camera move between two crop rectangles on the source frame.
public struct CameraMotion: Codable, Equatable, Sendable {
    /// The smallest crop side, as a fraction of the source; tighter crops look soft.
    public static let minimumCropSide = 0.2

    public let kind: CameraMotionKind
    public let range: MediaTimeRange
    public let from: NormalizedRect
    public let to: NormalizedRect
    public let easing: MotionEasing

    public init(kind: CameraMotionKind, range: MediaTimeRange, from: NormalizedRect,
                to: NormalizedRect, easing: MotionEasing = .easeInOut) throws {
        let fromArea = from.width * from.height
        let toArea = to.width * to.height
        let shapeValid: Bool = switch kind {
        case .hold: from == to
        case .punchIn, .pushIn: toArea < fromArea
        case .pullOut: toArea > fromArea
        case .pan: from != to && abs(fromArea - toArea) <= fromArea * 0.05
        }
        guard shapeValid,
              [from.width, from.height, to.width, to.height].allSatisfy({ $0 >= Self.minimumCropSide }) else {
            throw ModelError.invalid("CameraMotion")
        }
        self.kind = kind
        self.range = range
        self.from = from
        self.to = to
        self.easing = easing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: c.decode(CameraMotionKind.self, forKey: .kind),
                      range: c.decode(MediaTimeRange.self, forKey: .range),
                      from: c.decode(NormalizedRect.self, forKey: .from),
                      to: c.decode(NormalizedRect.self, forKey: .to),
                      easing: c.decodeIfPresent(MotionEasing.self, forKey: .easing) ?? .easeInOut)
    }
}

public enum DirectorReason: String, Codable, CaseIterable, Sendable {
    case speakerChange, demoPriority, emphasis, reaction, continuity, fallback, userOverride
}

/// The Director Engine's choice for a span: layout, focus, and optional motion, with why.
public struct DirectorDecision: Codable, Equatable, Sendable {
    public let range: MediaTimeRange
    public let layout: ShotLayout
    public let focus: NormalizedRect?
    public let motion: CameraMotion?
    public let reason: DirectorReason
    public let confidence: Double
    public let provenance: Provenance

    public init(range: MediaTimeRange, layout: ShotLayout, focus: NormalizedRect? = nil,
                motion: CameraMotion? = nil, reason: DirectorReason,
                confidence: Double, provenance: Provenance) throws {
        guard V2Validation.unit(confidence),
              motion.map({ V2Validation.contains(range, $0.range) }) ?? true,
              reason != .userOverride || provenance == .user else {
            throw ModelError.invalid("DirectorDecision")
        }
        self.range = range
        self.layout = layout
        self.focus = focus
        self.motion = motion
        self.reason = reason
        self.confidence = confidence
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(range: c.decode(MediaTimeRange.self, forKey: .range),
                      layout: c.decode(ShotLayout.self, forKey: .layout),
                      focus: c.decodeIfPresent(NormalizedRect.self, forKey: .focus),
                      motion: c.decodeIfPresent(CameraMotion.self, forKey: .motion),
                      reason: c.decode(DirectorReason.self, forKey: .reason),
                      confidence: c.decode(Double.self, forKey: .confidence),
                      provenance: c.decode(Provenance.self, forKey: .provenance))
    }
}

public enum ScreenRegionKind: String, Codable, CaseIterable, Sendable {
    case code, terminal, browser, slides, document, application, video, cursorArea
}

/// A part of a screen recording worth keeping readable, e.g. an editor pane.
public struct ScreenRegion: Codable, Equatable, Sendable {
    public let id: ScreenRegionID
    public let kind: ScreenRegionKind
    public let bounds: NormalizedRect
    public let range: MediaTimeRange
    public let importance: Double

    public init(id: ScreenRegionID = ScreenRegionID(), kind: ScreenRegionKind, bounds: NormalizedRect,
                range: MediaTimeRange, importance: Double) throws {
        guard V2Validation.unit(importance) else { throw ModelError.invalid("ScreenRegion") }
        self.id = id
        self.kind = kind
        self.bounds = bounds
        self.range = range
        self.importance = importance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(ScreenRegionID.self, forKey: .id),
                      kind: c.decode(ScreenRegionKind.self, forKey: .kind),
                      bounds: c.decode(NormalizedRect.self, forKey: .bounds),
                      range: c.decode(MediaTimeRange.self, forKey: .range),
                      importance: c.decode(Double.self, forKey: .importance))
    }
}

public enum DemoEventKind: String, Codable, CaseIterable, Sendable {
    case click, typing, scroll, windowChange, codeChange, slideChange, cursorMove, highlight
}

/// Something happening on screen that a viewer should notice.
public struct DemoEvent: Codable, Equatable, Sendable {
    public let kind: DemoEventKind
    public let range: MediaTimeRange
    public let regionID: ScreenRegionID?
    public let focus: NormalizedRect?
    public let confidence: Double

    public init(kind: DemoEventKind, range: MediaTimeRange, regionID: ScreenRegionID? = nil,
                focus: NormalizedRect? = nil, confidence: Double) throws {
        guard V2Validation.unit(confidence) else { throw ModelError.invalid("DemoEvent") }
        self.kind = kind
        self.range = range
        self.regionID = regionID
        self.focus = focus
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: c.decode(DemoEventKind.self, forKey: .kind),
                      range: c.decode(MediaTimeRange.self, forKey: .range),
                      regionID: c.decodeIfPresent(ScreenRegionID.self, forKey: .regionID),
                      focus: c.decodeIfPresent(NormalizedRect.self, forKey: .focus),
                      confidence: c.decode(Double.self, forKey: .confidence))
    }
}

public enum CaptionEmphasisLevel: String, Codable, CaseIterable, Sendable {
    case subtle, strong, keyword
}

public enum CaptionEmphasisReason: String, Codable, CaseIterable, Sendable {
    case keyword, number, entity, punchline, emotion, question, callToAction
}

/// A word that deserves visual weight in captions, keyed by its source time.
public struct CaptionEmphasis: Codable, Equatable, Sendable {
    public let wordRange: MediaTimeRange
    public let text: String
    public let level: CaptionEmphasisLevel
    public let reason: CaptionEmphasisReason
    public let provenance: Provenance

    public init(wordRange: MediaTimeRange, text: String, level: CaptionEmphasisLevel,
                reason: CaptionEmphasisReason, provenance: Provenance) throws {
        guard V2Validation.text(text, maximum: 60), !text.contains("\n") else {
            throw ModelError.invalid("CaptionEmphasis")
        }
        self.wordRange = wordRange
        self.text = text
        self.level = level
        self.reason = reason
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(wordRange: c.decode(MediaTimeRange.self, forKey: .wordRange),
                      text: c.decode(String.self, forKey: .text),
                      level: c.decode(CaptionEmphasisLevel.self, forKey: .level),
                      reason: c.decode(CaptionEmphasisReason.self, forKey: .reason),
                      provenance: c.decode(Provenance.self, forKey: .provenance))
    }
}
