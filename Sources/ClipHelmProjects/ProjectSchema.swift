import Foundation

/// Versions of every persisted format, in one place. See docs/V2_MIGRATIONS.md.
public enum ProjectSchema {
    /// project.json. 5 adds optional V2 metadata; 1–4 read with defaults.
    public static let currentVersion = 5
    public static let oldestSupportedVersion = 1

    /// Structural JSON steps. Versions 1–5 are additive and need none: the typed decoder
    /// supplies defaults for fields a version lacks.
    public static let migrator = SchemaMigrator(document: "project",
                                                currentVersion: currentVersion,
                                                oldestSupportedVersion: oldestSupportedVersion)

    /// Name for the one-time copy of a manifest kept before its first upgrade is written.
    public static func backupFileName(forVersion version: Int) -> String {
        "project.v\(version).json"
    }
}
