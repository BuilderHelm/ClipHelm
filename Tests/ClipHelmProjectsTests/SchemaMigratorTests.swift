import Foundation
import XCTest
@testable import ClipHelmProjects

final class SchemaMigratorTests: XCTestCase {
    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testAdditiveVersionsPassThroughUnchangedAndReportTheirOrigin() throws {
        let original = try json(["schemaVersion": 4, "title": "Podcast"])
        let outcome = try ProjectSchema.migrator.migrate(original)
        XCTAssertEqual(outcome.data, original)
        XCTAssertEqual(outcome.originalVersion, 4)
        XCTAssertEqual(outcome.currentVersion, ProjectSchema.currentVersion)
        XCTAssertTrue(outcome.isUpgrade)
        let current = try ProjectSchema.migrator.migrate(try json(["schemaVersion": ProjectSchema.currentVersion]))
        XCTAssertFalse(current.isUpgrade)
    }

    func testFutureVersionsAreRejectedWithoutGuessing() throws {
        XCTAssertThrowsError(try ProjectSchema.migrator.migrate(
            try json(["schemaVersion": ProjectSchema.currentVersion + 1]))) { error in
            XCTAssertEqual(error as? SchemaMigrationError, .futureVersion(document: "project",
                found: ProjectSchema.currentVersion + 1, supported: ProjectSchema.currentVersion))
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("newer version") == true)
        }
    }

    func testMissingMalformedAndTooOldVersionsAreRejected() throws {
        let migrator = SchemaMigrator(document: "cache", currentVersion: 5, oldestSupportedVersion: 3)
        XCTAssertThrowsError(try migrator.migrate(Data("not json".utf8))) {
            XCTAssertEqual($0 as? SchemaMigrationError, .unreadable(document: "cache"))
        }
        for bad: Any in ["5", true, 4.5, NSNull()] {
            XCTAssertThrowsError(try migrator.migrate(try json(["schemaVersion": bad]))) {
                XCTAssertEqual($0 as? SchemaMigrationError, .missingVersion(document: "cache"))
            }
        }
        XCTAssertThrowsError(try migrator.migrate(try json(["title": "x"])))
        XCTAssertThrowsError(try migrator.migrate(try json(["schemaVersion": 2]))) {
            XCTAssertEqual($0 as? SchemaMigrationError, .unsupportedVersion(document: "cache", found: 2, oldest: 3))
        }
    }

    func testStructuralStepsRunInOrderAndBumpTheVersion() throws {
        let migrator = SchemaMigrator(document: "demo", currentVersion: 4, steps: [
            SchemaMigrationStep(from: 1) { object in
                object["name"] = object.removeValue(forKey: "title")
            },
            SchemaMigrationStep(from: 3) { object in
                object["tags"] = (object["tags"] as? [String] ?? []) + ["migrated"]
            },
        ])
        let outcome = try migrator.migrate(try json(["schemaVersion": 1, "title": "Talk"]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.data) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "Talk")
        XCTAssertNil(object["title"])
        XCTAssertEqual(object["tags"] as? [String], ["migrated"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 4)
        XCTAssertEqual(outcome.originalVersion, 1)
        // A document already past a step does not repeat it.
        let later = try migrator.migrate(try json(["schemaVersion": 2, "name": "Kept"]))
        let laterObject = try XCTUnwrap(JSONSerialization.jsonObject(with: later.data) as? [String: Any])
        XCTAssertEqual(laterObject["name"] as? String, "Kept")
    }

    func testAFailingStepReportsWhereItStopped() throws {
        struct Broken: Error {}
        let migrator = SchemaMigrator(document: "demo", currentVersion: 2, steps: [
            SchemaMigrationStep(from: 1) { _ in throw Broken() },
        ])
        XCTAssertThrowsError(try migrator.migrate(try json(["schemaVersion": 1]))) {
            XCTAssertEqual($0 as? SchemaMigrationError, .stepFailed(document: "demo", from: 1))
        }
    }
}

final class DerivedArtifactStoreTests: XCTestCase {
    private struct Payload: Codable, Equatable { let words: Int }

    private func makeStore() throws -> (DerivedArtifactStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "ClipHelm-derived-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (DerivedArtifactStore(cacheDirectory: root.appending(path: "Cache")), root)
    }

    func testRoundTripRequiresMatchingKindVersionAndInputs() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = DerivedArtifactStore.fingerprint(["asset-1", "transcript-a", "model-x"])
        try store.save(Payload(words: 42), kind: "moment-graph", version: 1, inputs: inputs, generator: "tests")
        XCTAssertEqual(store.load(Payload.self, kind: "moment-graph", version: 1, inputs: inputs), Payload(words: 42))
        XCTAssertNil(store.load(Payload.self, kind: "moment-graph", version: 1,
                                inputs: DerivedArtifactStore.fingerprint(["asset-1", "transcript-b", "model-x"])))
        XCTAssertNil(store.load(Payload.self, kind: "moment-graph", version: 2, inputs: inputs))
        XCTAssertNil(store.load(Payload.self, kind: "project-intelligence", version: 1, inputs: inputs))
        let file = store.fileURL(kind: "moment-graph", version: 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        store.removeAll(kind: "moment-graph")
        XCTAssertNil(store.load(Payload.self, kind: "moment-graph", version: 1, inputs: inputs))
    }

    func testCorruptOrUnsafeArtifactsReadAsMissing() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(Payload(words: 1), kind: "moment-graph", version: 1, inputs: "a", generator: "tests")
        try Data("{broken".utf8).write(to: store.fileURL(kind: "moment-graph", version: 1))
        XCTAssertNil(store.load(Payload.self, kind: "moment-graph", version: 1, inputs: "a"))
        XCTAssertThrowsError(try store.save(Payload(words: 1), kind: "../escape", version: 1, inputs: "a", generator: "tests"))
        XCTAssertThrowsError(try store.save(Payload(words: 1), kind: "Moment", version: 1, inputs: "a", generator: "tests"))
        XCTAssertNil(store.load(Payload.self, kind: "../escape", version: 1, inputs: "a"))
    }

    func testRefusesToWriteThroughASymlinkedCache() throws {
        let (_, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Cache"), withDestinationURL: elsewhere)
        let store = DerivedArtifactStore(cacheDirectory: root.appending(path: "Cache"))
        XCTAssertThrowsError(try store.save(Payload(words: 1), kind: "moment-graph", version: 1,
                                            inputs: "a", generator: "tests")) {
            XCTAssertEqual($0 as? DerivedArtifactError, .unsafeLocation)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    func testFingerprintSeparatesAmbiguousJoins() {
        XCTAssertNotEqual(DerivedArtifactStore.fingerprint(["ab", "c"]), DerivedArtifactStore.fingerprint(["a", "bc"]))
        XCTAssertEqual(DerivedArtifactStore.fingerprint(["a", "b"]), DerivedArtifactStore.fingerprint(["a", "b"]))
    }
}
