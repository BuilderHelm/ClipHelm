import Foundation

/// The complete set of things Ask ClipHelm may request. A model's natural-language answer
/// must decode into one of these cases; anything else is rejected. None carries a path,
/// URL, shell text, or renderer argument, and each is re-validated against the project
/// before it runs.
public enum AssistantAction: Codable, Equatable, Sendable {
    case search(query: String)
    case findMoments(query: String)
    case renameClip(clipID: ClipID, title: String)
    case trimClip(clipID: ClipID, range: MediaTimeRange)
    case setCaptionStyle(clipID: ClipID, style: CaptionStyle)
    case setLayout(clipID: ClipID, range: MediaTimeRange, layout: ShotLayout)
    case removeFillers(clipID: ClipID)
    case applyBrandKit(clipID: ClipID, brandKitID: BrandKitID)
    case createVariant(clipID: ClipID, platform: PlatformID)

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case search, findMoments, renameClip, trimClip, setCaptionStyle, setLayout
        case removeFillers, applyBrandKit, createVariant
    }

    public var kind: Kind {
        switch self {
        case .search: .search
        case .findMoments: .findMoments
        case .renameClip: .renameClip
        case .trimClip: .trimClip
        case .setCaptionStyle: .setCaptionStyle
        case .setLayout: .setLayout
        case .removeFillers: .removeFillers
        case .applyBrandKit: .applyBrandKit
        case .createVariant: .createVariant
        }
    }

    /// Whether the user must confirm first: anything that changes a clip or spends time or credits.
    public var requiresConfirmation: Bool {
        switch self {
        case .search: false
        case .findMoments, .renameClip, .trimClip, .setCaptionStyle, .setLayout,
             .removeFillers, .applyBrandKit, .createVariant: true
        }
    }

    public var clipID: ClipID? {
        switch self {
        case .search, .findMoments: nil
        case .renameClip(let id, _), .trimClip(let id, _), .setCaptionStyle(let id, _),
             .setLayout(let id, _, _), .removeFillers(let id), .applyBrandKit(let id, _),
             .createVariant(let id, _): id
        }
    }

    public func validate() throws {
        let valid: Bool = switch self {
        case .search(let query), .findMoments(let query): V2Validation.text(query, maximum: 500)
        case .renameClip(_, let title): V2Validation.text(title, maximum: 120) && !title.contains("\n")
        case .trimClip, .setCaptionStyle, .setLayout, .removeFillers, .applyBrandKit, .createVariant: true
        }
        guard valid else { throw ModelError.invalid("AssistantAction") }
    }

    private enum CodingKeys: String, CodingKey {
        case type, query, clipID, title, range, style, layout, brandKitID, platform
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let action: AssistantAction = switch try c.decode(Kind.self, forKey: .type) {
        case .search: .search(query: try c.decode(String.self, forKey: .query))
        case .findMoments: .findMoments(query: try c.decode(String.self, forKey: .query))
        case .renameClip: .renameClip(clipID: try c.decode(ClipID.self, forKey: .clipID),
                                      title: try c.decode(String.self, forKey: .title))
        case .trimClip: .trimClip(clipID: try c.decode(ClipID.self, forKey: .clipID),
                                  range: try c.decode(MediaTimeRange.self, forKey: .range))
        case .setCaptionStyle: .setCaptionStyle(clipID: try c.decode(ClipID.self, forKey: .clipID),
                                                style: try c.decode(CaptionStyle.self, forKey: .style))
        case .setLayout: .setLayout(clipID: try c.decode(ClipID.self, forKey: .clipID),
                                    range: try c.decode(MediaTimeRange.self, forKey: .range),
                                    layout: try c.decode(ShotLayout.self, forKey: .layout))
        case .removeFillers: .removeFillers(clipID: try c.decode(ClipID.self, forKey: .clipID))
        case .applyBrandKit: .applyBrandKit(clipID: try c.decode(ClipID.self, forKey: .clipID),
                                            brandKitID: try c.decode(BrandKitID.self, forKey: .brandKitID))
        case .createVariant: .createVariant(clipID: try c.decode(ClipID.self, forKey: .clipID),
                                            platform: try c.decode(PlatformID.self, forKey: .platform))
        }
        try action.validate()
        self = action
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .type)
        switch self {
        case .search(let query), .findMoments(let query):
            try c.encode(query, forKey: .query)
        case .renameClip(let id, let title):
            try c.encode(id, forKey: .clipID)
            try c.encode(title, forKey: .title)
        case .trimClip(let id, let range):
            try c.encode(id, forKey: .clipID)
            try c.encode(range, forKey: .range)
        case .setCaptionStyle(let id, let style):
            try c.encode(id, forKey: .clipID)
            try c.encode(style, forKey: .style)
        case .setLayout(let id, let range, let layout):
            try c.encode(id, forKey: .clipID)
            try c.encode(range, forKey: .range)
            try c.encode(layout, forKey: .layout)
        case .removeFillers(let id):
            try c.encode(id, forKey: .clipID)
        case .applyBrandKit(let id, let brandKitID):
            try c.encode(id, forKey: .clipID)
            try c.encode(brandKitID, forKey: .brandKitID)
        case .createVariant(let id, let platform):
            try c.encode(id, forKey: .clipID)
            try c.encode(platform, forKey: .platform)
        }
    }
}
