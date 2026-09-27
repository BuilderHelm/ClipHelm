import Foundation

/// A color as `#RRGGBB`. Stored as text so brand kits stay readable and diffable.
public struct BrandColor: Hashable, Codable, Sendable {
    public let hex: String

    public init(hex: String) throws {
        let digits = hex.dropFirst()
        guard hex.count == 7, hex.first == "#", digits.allSatisfy(\.isHexDigit) else {
            throw ModelError.invalid("BrandColor")
        }
        self.hex = hex.uppercased()
    }

    public init(from decoder: Decoder) throws {
        try self.init(hex: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

public enum BrandMarkPlacement: String, Codable, CaseIterable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
}

/// A creator's look, applied to every clip: caption style, colors, font, and logo.
public struct BrandKit: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let schemaVersion: Int
    public let id: BrandKitID
    public let name: String
    public let primaryColor: BrandColor
    public let accentColor: BrandColor
    public let textColor: BrandColor
    public let captionStyle: CaptionStyle
    public let captionWordByWord: Bool
    /// An installed font's PostScript or family name; nil uses the caption style's font.
    public let fontName: String?
    /// A plain file name inside the brand kit's folder. Never a path or URL.
    public let logoFileName: String?
    public let logoPlacement: BrandMarkPlacement
    public let logoOpacity: Double

    public init(id: BrandKitID = BrandKitID(), name: String, primaryColor: BrandColor,
                accentColor: BrandColor, textColor: BrandColor, captionStyle: CaptionStyle,
                captionWordByWord: Bool = false, fontName: String? = nil, logoFileName: String? = nil,
                logoPlacement: BrandMarkPlacement = .bottomTrailing, logoOpacity: Double = 0.9) throws {
        let fontValid = fontName.map { font in
            (1...64).contains(font.count) &&
                font.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || " -".unicodeScalars.contains($0) }
        } ?? true
        guard V2Validation.text(name, maximum: 80), fontValid,
              logoFileName.map(Self.isPlainImageName) ?? true, V2Validation.unit(logoOpacity) else {
            throw ModelError.invalid("BrandKit")
        }
        schemaVersion = Self.currentVersion
        self.id = id
        self.name = name
        self.primaryColor = primaryColor
        self.accentColor = accentColor
        self.textColor = textColor
        self.captionStyle = captionStyle
        self.captionWordByWord = captionWordByWord
        self.fontName = fontName
        self.logoFileName = logoFileName
        self.logoPlacement = logoPlacement
        self.logoOpacity = logoOpacity
    }

    static func isPlainImageName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return (1...128).contains(name.count) && !name.hasPrefix(".") &&
            !name.contains("/") && !name.contains("\\") && !name.contains(":") &&
            ["png", "jpg", "jpeg", "heic"].contains { lower.hasSuffix(".\($0)") }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, primaryColor, accentColor, textColor, captionStyle
        case captionWordByWord, fontName, logoFileName, logoPlacement, logoOpacity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try V2Validation.version(c.decode(Int.self, forKey: .schemaVersion),
                                 current: Self.currentVersion, "BrandKit")
        try self.init(id: c.decode(BrandKitID.self, forKey: .id),
                      name: c.decode(String.self, forKey: .name),
                      primaryColor: c.decode(BrandColor.self, forKey: .primaryColor),
                      accentColor: c.decode(BrandColor.self, forKey: .accentColor),
                      textColor: c.decode(BrandColor.self, forKey: .textColor),
                      captionStyle: c.decode(CaptionStyle.self, forKey: .captionStyle),
                      captionWordByWord: c.decodeIfPresent(Bool.self, forKey: .captionWordByWord) ?? false,
                      fontName: c.decodeIfPresent(String.self, forKey: .fontName),
                      logoFileName: c.decodeIfPresent(String.self, forKey: .logoFileName),
                      logoPlacement: c.decodeIfPresent(BrandMarkPlacement.self, forKey: .logoPlacement) ?? .bottomTrailing,
                      logoOpacity: c.decodeIfPresent(Double.self, forKey: .logoOpacity) ?? 0.9)
    }
}

public enum PlatformID: String, Codable, CaseIterable, Sendable {
    case youtubeShorts, tiktok, instagramReels, youtube, linkedin, x
}

/// Output rules for one destination. Built-in values are defaults, not platform guarantees.
public struct PlatformProfile: Codable, Equatable, Sendable {
    public let id: PlatformID
    public let displayName: String
    public let outputFormat: OutputFormat
    public let minimumSeconds: Int
    public let maximumSeconds: Int
    /// Where captions stay clear of the platform's own buttons and labels.
    public let captionSafeArea: NormalizedRect

    public init(id: PlatformID, displayName: String, outputFormat: OutputFormat,
                minimumSeconds: Int, maximumSeconds: Int, captionSafeArea: NormalizedRect) throws {
        guard V2Validation.text(displayName, maximum: 40),
              minimumSeconds > 0, minimumSeconds < maximumSeconds, maximumSeconds <= 43_200 else {
            throw ModelError.invalid("PlatformProfile")
        }
        self.id = id
        self.displayName = displayName
        self.outputFormat = outputFormat
        self.minimumSeconds = minimumSeconds
        self.maximumSeconds = maximumSeconds
        self.captionSafeArea = captionSafeArea
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(PlatformID.self, forKey: .id),
                      displayName: c.decode(String.self, forKey: .displayName),
                      outputFormat: c.decode(OutputFormat.self, forKey: .outputFormat),
                      minimumSeconds: c.decode(Int.self, forKey: .minimumSeconds),
                      maximumSeconds: c.decode(Int.self, forKey: .maximumSeconds),
                      captionSafeArea: c.decode(NormalizedRect.self, forKey: .captionSafeArea))
    }

    /// Defaults limited to canvases the V1 renderer supports (9:16 and 16:9).
    public static let builtIn: [PlatformProfile] = {
        let tall = try! NormalizedRect(x: 0.08, y: 0.12, width: 0.76, height: 0.68)
        let wide = try! NormalizedRect(x: 0.06, y: 0.08, width: 0.88, height: 0.8)
        return [
            try! PlatformProfile(id: .youtubeShorts, displayName: "YouTube Shorts", outputFormat: .vertical,
                                 minimumSeconds: 5, maximumSeconds: 180, captionSafeArea: tall),
            try! PlatformProfile(id: .tiktok, displayName: "TikTok", outputFormat: .vertical,
                                 minimumSeconds: 5, maximumSeconds: 600, captionSafeArea: tall),
            try! PlatformProfile(id: .instagramReels, displayName: "Instagram Reels", outputFormat: .vertical,
                                 minimumSeconds: 5, maximumSeconds: 180, captionSafeArea: tall),
            try! PlatformProfile(id: .youtube, displayName: "YouTube", outputFormat: .horizontal,
                                 minimumSeconds: 10, maximumSeconds: 43_200, captionSafeArea: wide),
            try! PlatformProfile(id: .linkedin, displayName: "LinkedIn", outputFormat: .vertical,
                                 minimumSeconds: 5, maximumSeconds: 600, captionSafeArea: tall),
            try! PlatformProfile(id: .x, displayName: "X", outputFormat: .horizontal,
                                 minimumSeconds: 5, maximumSeconds: 140, captionSafeArea: wide),
        ]
    }()

    public static func builtIn(_ id: PlatformID) -> PlatformProfile? { builtIn.first { $0.id == id } }
}

public enum VariantStatus: String, Codable, CaseIterable, Sendable {
    case planned, rendered, failed
}

/// A platform-specific version of an accepted clip. The base clip is never changed.
public struct ClipVariant: Codable, Equatable, Sendable {
    public let id: ClipVariantID
    public let baseClipID: ClipID
    public let platform: PlatformID
    public let title: String
    public let status: VariantStatus
    public let spec: ClipHelmEditSpec?
    public let previewFileName: String?
    public let finalFileName: String?

    public init(id: ClipVariantID = ClipVariantID(), baseClipID: ClipID, platform: PlatformID,
                title: String, status: VariantStatus, spec: ClipHelmEditSpec? = nil,
                previewFileName: String? = nil, finalFileName: String? = nil) throws {
        let names = [previewFileName, finalFileName].compactMap { $0 }
        let renderedComplete = status != .rendered ||
            (spec != nil && previewFileName != nil && finalFileName != nil && previewFileName != finalFileName)
        guard V2Validation.text(title, maximum: 120), renderedComplete,
              names.allSatisfy(Self.isPlainVideoName) else {
            throw ModelError.invalid("ClipVariant")
        }
        self.id = id
        self.baseClipID = baseClipID
        self.platform = platform
        self.title = title
        self.status = status
        self.spec = spec
        self.previewFileName = previewFileName
        self.finalFileName = finalFileName
    }

    static func isPlainVideoName(_ name: String) -> Bool {
        (5...128).contains(name.count) && name.hasSuffix(".mp4") && !name.hasPrefix(".") &&
            !name.contains("/") && !name.contains("\\") && !name.contains(":")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(ClipVariantID.self, forKey: .id),
                      baseClipID: c.decode(ClipID.self, forKey: .baseClipID),
                      platform: c.decode(PlatformID.self, forKey: .platform),
                      title: c.decode(String.self, forKey: .title),
                      status: c.decode(VariantStatus.self, forKey: .status),
                      spec: c.decodeIfPresent(ClipHelmEditSpec.self, forKey: .spec),
                      previewFileName: c.decodeIfPresent(String.self, forKey: .previewFileName),
                      finalFileName: c.decodeIfPresent(String.self, forKey: .finalFileName))
    }
}

/// V2 decisions stored in the project manifest (schema 5+). Every field has an empty
/// default, so a V1 manifest reads as "no V2 choices made yet".
public struct ProjectV2Metadata: Codable, Equatable, Sendable {
    public var brandKitID: BrandKitID?
    public var platformTargets: [PlatformID]
    public var variants: [ClipVariant]

    public static let empty = ProjectV2Metadata()

    public init(brandKitID: BrandKitID? = nil, platformTargets: [PlatformID] = [],
                variants: [ClipVariant] = []) {
        self.brandKitID = brandKitID
        self.platformTargets = platformTargets
        self.variants = variants
    }

    public func validate(clipIDs: Set<ClipID>) throws {
        guard Set(platformTargets).count == platformTargets.count, variants.count <= 5_000,
              Set(variants.map(\.id)).count == variants.count,
              variants.allSatisfy({ clipIDs.contains($0.baseClipID) }) else {
            throw ModelError.invalid("ProjectV2Metadata")
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brandKitID = try c.decodeIfPresent(BrandKitID.self, forKey: .brandKitID)
        platformTargets = try c.decodeIfPresent([PlatformID].self, forKey: .platformTargets) ?? []
        variants = try c.decodeIfPresent([ClipVariant].self, forKey: .variants) ?? []
    }
}
