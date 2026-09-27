import Foundation
import CryptoKit
import XCTest
import ClipHelmCore
import ClipHelmProjects
import ClipHelmProcessing
@testable import ClipHelmApp

/// Project files from V1 must open in V2 unchanged until the user changes something, and
/// files from a newer ClipHelm must never be modified.
@MainActor
final class V2MigrationTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-V2Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func asset() throws -> MediaAsset {
        try MediaAsset(id: AssetID(), displayName: "talk.mov",
                       duration: MediaTime(microseconds: 20_000_000), width: 1920, height: 1080)
    }

    /// A saved record's JSON, rewritten to look like an older format.
    private func manifest(version: Int, mediaAsset: MediaAsset? = nil,
                          clips: [ProjectClipRecord] = []) throws -> (ProjectID, [String: Any]) {
        var draft = ProjectDraft()
        draft.title = "Old project"
        draft.sourceName = "talk.mov"
        var record = try ProjectRecord(draft: draft, mediaAsset: mediaAsset)
        record.clips = clips
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["schemaVersion"] = version
        if version < 5 { json.removeValue(forKey: "v2") }
        if version == 1 {
            json["outputFormat"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OutputFormat.vertical))
            json["framingMode"] = FramingMode.smartAuto.rawValue
            json["selectedLengths"] = [ClipLength.minutes1to2.rawValue]
            json["captionStyle"] = CaptionStyle.pop.rawValue
            json.removeValue(forKey: "configuration")
        }
        return (record.id, json)
    }

    @discardableResult
    private func write(_ id: ProjectID, _ json: [String: Any]) throws -> URL {
        let package = root.appending(path: "\(id.rawValue.uuidString).cliphelm", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appending(path: "project.json")
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: file)
        return file
    }

    private func hash(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    private func clip(for media: MediaAsset, specVersion: Int? = nil) throws -> (ProjectClipRecord, [String: Any]) {
        let range = try MediaTimeRange(start: MediaTime(microseconds: 0), end: MediaTime(microseconds: 5_000_000))
        let proposal = try ClipProposal(assetID: media.id, range: range, title: "A moment",
                                        rationale: "Test", confidence: 0.8)
        let spec = try ClipHelmEditSpec(clipID: ClipID(), sourceAssetID: media.id,
            segments: [EditSegment(sourceRange: range)], outputFormat: .vertical,
            framingMode: .classicFullFrame, pacingMode: .balanced, soundMode: .source, captionStyle: nil)
        let record = ProjectClipRecord(ProcessedClip(proposal: proposal, spec: spec,
            previewURL: URL(fileURLWithPath: "/tmp/clip-preview.mp4"), finalURL: URL(fileURLWithPath: "/tmp/clip.mp4")))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        if let specVersion, var specJSON = json["spec"] as? [String: Any] {
            specJSON["schemaVersion"] = specVersion
            if specVersion < 3 { specJSON.removeValue(forKey: "layoutCues") }
            json["spec"] = specJSON
        }
        return (record, json)
    }

    func testV1AndV4ProjectsOpenWithEmptyV2MetadataAndAreNotRewrittenOnLoad() throws {
        for version in [1, 4] {
            let (id, json) = try manifest(version: version)
            let file = try write(id, json)
            let before = try hash(file)
            let store = ProjectStore(rootURL: root)
            let project = try XCTUnwrap(store.projects.first { $0.id == id }, "version \(version)")
            XCTAssertEqual(project.v2, .empty)
            XCTAssertEqual(project.loadedSchemaVersion, version)
            XCTAssertEqual(project.schemaVersion, ProjectSchema.currentVersion)
            XCTAssertNil(store.loadError)
            XCTAssertEqual(try hash(file), before, "Opening must not rewrite a version \(version) project")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent()
                .appending(path: ProjectSchema.backupFileName(forVersion: version)).path))
        }
    }

    func testFirstChangeToAnOlderProjectKeepsOneBackupThenWritesTheCurrentFormat() throws {
        let (id, json) = try manifest(version: 4)
        let file = try write(id, json)
        let original = try Data(contentsOf: file)
        let store = ProjectStore(rootURL: root)
        let media = try asset()
        try store.attachMediaAsset(media, to: id)

        let backup = file.deletingLastPathComponent().appending(path: "project.v4.json")
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(written["schemaVersion"] as? Int, ProjectSchema.currentVersion)
        XCTAssertNotNil(written["v2"])
        XCTAssertEqual(store.projects.first?.loadedSchemaVersion, ProjectSchema.currentVersion)

        // Later writes leave the backup alone.
        let transcript = try Transcript(assetID: media.id, segments: [])
        try store.saveTranscript(transcript, for: id)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(ProjectStore(rootURL: root).projects.first?.loadedSchemaVersion, ProjectSchema.currentVersion)
    }

    func testProjectsFromANewerClipHelmAreRefusedAndLeftUntouched() throws {
        let (id, json) = try manifest(version: ProjectSchema.currentVersion + 1)
        let file = try write(id, json)
        let exports = file.deletingLastPathComponent().appending(path: "Exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let orphan = exports.appending(path: "\(UUID().uuidString).mp4")
        try Data([1]).write(to: orphan)
        let before = try hash(file)

        let store = ProjectStore(rootURL: root)
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(store.loadError?.contains("newer version of ClipHelm") == true)
        XCTAssertEqual(try hash(file), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path),
                      "Cleanup must not run inside a project this version cannot read")
    }

    func testOlderEditSpecsInsideAProjectStillOpenAndFutureOnesAreRejected() throws {
        let media = try asset()
        for specVersion in [2, 3] {
            let (_, clipJSON) = try clip(for: media, specVersion: specVersion)
            let (id, projectJSON) = try manifest(version: 4, mediaAsset: media)
            var json = projectJSON
            json["clips"] = [clipJSON]
            try write(id, json)
            let project = try XCTUnwrap(ProjectStore(rootURL: root).projects.first { $0.id == id })
            XCTAssertEqual(project.clips.first?.spec.schemaVersion, ClipHelmEditSpec.currentVersion)
            XCTAssertEqual(project.clips.first?.spec.layoutCues, [])
        }

        let (_, futureClip) = try clip(for: media, specVersion: ClipHelmEditSpec.currentVersion + 1)
        let (futureID, projectJSON) = try manifest(version: 4, mediaAsset: media)
        var json = projectJSON
        json["clips"] = [futureClip]
        let file = try write(futureID, json)
        let before = try hash(file)
        let store = ProjectStore(rootURL: root)
        XCTAssertNil(store.projects.first { $0.id == futureID })
        XCTAssertEqual(try hash(file), before)
    }

    func testV2MetadataPersistsAndMustReferenceRealClips() throws {
        let media = try asset()
        let (clipRecord, _) = try clip(for: media)
        var draft = ProjectDraft()
        draft.sourceName = "talk.mov"
        var record = try ProjectRecord(draft: draft, mediaAsset: media)
        record.clips = [clipRecord]
        record.v2 = ProjectV2Metadata(platformTargets: [.tiktok, .youtubeShorts], variants: [
            try ClipVariant(baseClipID: clipRecord.id, platform: .tiktok, title: "TikTok cut", status: .planned),
        ])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        try write(record.id, json)
        let restored = try XCTUnwrap(ProjectStore(rootURL: root).projects.first { $0.id == record.id })
        XCTAssertEqual(restored.v2, record.v2)

        // A variant pointing at a clip that is not in the project makes the manifest invalid.
        record.v2 = ProjectV2Metadata(variants: [
            try ClipVariant(baseClipID: ClipID(), platform: .tiktok, title: "Orphan", status: .planned),
        ])
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        try write(record.id, json)
        let reloaded = ProjectStore(rootURL: root)
        XCTAssertNil(reloaded.projects.first { $0.id == record.id })
        XCTAssertNotNil(reloaded.loadError)
    }

    /// Opt-in: opens a copy of real V1 projects and checks nothing is lost or rewritten.
    func testOptInRealV1ProjectsOpenUnchanged() throws {
        guard let path = ProcessInfo.processInfo.environment["CLIPHELM_QA_PROJECTS_DIR"] else {
            throw XCTSkip("Set CLIPHELM_QA_PROJECTS_DIR to a folder of V1 projects; a copy is used")
        }
        let copy = root.appending(path: "Projects")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path, isDirectory: true), to: copy)
        let packages = try FileManager.default.contentsOfDirectory(at: copy, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "cliphelm" }
        var hashes: [URL: String] = [:]
        var versions: [Int: Int] = [:]
        for package in packages {
            let file = package.appending(path: "project.json")
            hashes[file] = try hash(file)
            let version = try ProjectSchema.migrator.version(of: Data(contentsOf: file))
            versions[version, default: 0] += 1
        }
        let store = ProjectStore(rootURL: copy)
        print("QA_V2_PROJECTS packages=\(packages.count) opened=\(store.projects.count) versions=\(versions.sorted { $0.key < $1.key }) loadError=\(store.loadError ?? "none")")
        XCTAssertEqual(store.projects.count, packages.count)
        XCTAssertTrue(store.projects.allSatisfy { $0.v2 == .empty })
        for (file, before) in hashes { XCTAssertEqual(try hash(file), before, file.path) }
    }
}
