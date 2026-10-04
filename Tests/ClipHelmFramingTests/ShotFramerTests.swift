import Foundation
import XCTest
import ClipHelmCore
@testable import ClipHelmAnalysis
import ClipHelmFraming

/// Smart Auto Frame from dense evidence: synthetic shots with known answers.
final class ShotFramerTests: XCTestCase {
    private let source = try! MediaAsset(id: AssetID(), displayName: "fixture.mov",
        duration: MediaTime(microseconds: 30_000_000), width: 1920, height: 1080)

    private func time(_ seconds: Double) throws -> MediaTime {
        try MediaTime(microseconds: Int64((seconds * 1_000_000).rounded()))
    }

    private func range(_ start: Double, _ end: Double) throws -> MediaTimeRange {
        try MediaTimeRange(start: time(start), end: time(end))
    }

    private func face(_ centerX: Double, width: Double = 0.1, mouth: Double? = nil) throws -> FocusFace {
        try FocusFace(bounds: NormalizedRect(x: centerX - width / 2, y: 0.2, width: width, height: width * 1.6),
                      confidence: 0.9, mouthOpening: mouth)
    }

    /// Samples every 0.2 s from `start` to `end`, with faces from `faces(t)`.
    private func frames(_ start: Double, _ end: Double,
                        faces: (Double) throws -> [FocusFace],
                        salient: [FocusRegion] = []) throws -> [FocusFrame] {
        try stride(from: start, to: end - 0.0001, by: 0.2).map { seconds in
            let found = try faces(seconds)
            return FocusFrame(time: try time(seconds), faces: found, salient: found.isEmpty ? salient : [])
        }
    }

    private func region(_ x: Double, _ width: Double, confidence: Double) throws -> FocusRegion {
        try FocusRegion(bounds: NormalizedRect(x: x, y: 0.3, width: width, height: 0.4), confidence: confidence)
    }

    private func evidence(_ frames: [FocusFrame], cuts: [Double] = [],
                          range: (Double, Double) = (0, 30)) throws -> FocusEvidence {
        try FocusEvidence(assetID: source.id, ranges: [self.range(range.0, range.1)],
                          frames: frames, cuts: cuts.map(time))
    }

    private func frame(_ evidence: FocusEvidence, _ start: Double = 0, _ end: Double = 30,
                       format: OutputFormat = .vertical) throws -> FramingResult {
        try ShotFramer().frame(range: range(start, end), asset: source, format: format, evidence: evidence)
    }

    private func center(_ result: FramingResult, at seconds: Double) throws -> Double {
        let t = try time(seconds)
        let path = try XCTUnwrap(result.paths.first { $0.sourceRange.start <= t && t < $0.sourceRange.end })
        let rect = try path.rect(atSourceTime: t)
        return rect.x + rect.width / 2
    }

    private func contains(_ result: FramingResult, face: FocusFace, at seconds: Double) throws -> Bool {
        let t = try time(seconds)
        let path = try XCTUnwrap(result.paths.first { $0.sourceRange.start <= t && t < $0.sourceRange.end })
        let rect = try path.rect(atSourceTime: t)
        return face.bounds.x >= rect.x - 0.0001 && face.bounds.x + face.bounds.width <= rect.x + rect.width + 0.0001
    }

    func testCameraCutJumpsInsteadOfPanning() throws {
        // Guest on the right for 10 s, then a cut to the host on the left.
        let samples = try frames(0, 20) { seconds in [try self.face(seconds < 10 ? 0.70 : 0.25)] }
        let result = try frame(evidence(samples, cuts: [10]), 0, 20)
        XCTAssertEqual(try center(result, at: 9.9), 0.70, accuracy: 0.03)
        // The first frame after the cut is already on the host: no pan through empty space.
        XCTAssertEqual(try center(result, at: 10.0), 0.25, accuracy: 0.03)
        XCTAssertEqual(try center(result, at: 10.1), 0.25, accuracy: 0.03)
    }

    func testStillTalkingHeadIsLockedOff() throws {
        // Small natural sway stays inside one framing: the camera doesn't move at all.
        let samples = try frames(0, 12) { seconds in
            let x: Double = 0.40 + 0.015 * sin(seconds * 2)
            return [try self.face(x)]
        }
        let result = try frame(evidence(samples), 0, 12)
        XCTAssertEqual(result.paths.count, 1)
        XCTAssertEqual(result.paths[0].keyframes.count, 1)
        XCTAssertTrue(result.uncertainRanges.isEmpty)
    }

    func testMovingSubjectStaysInsideTheFrame() throws {
        // Walks from left to right across the room in 8 s.
        let walk: (Double) throws -> [FocusFace] = { seconds in
            let x: Double = 0.15 + 0.7 * min(1, seconds / 8)
            return [try self.face(x)]
        }
        let samples = try frames(0, 10, faces: walk)
        let result = try frame(evidence(samples), 0, 10)
        for seconds in stride(from: 0.0, to: 9.9, by: 0.2) {
            XCTAssertTrue(try contains(result, face: walk(seconds)[0], at: seconds), "face left the crop at \(seconds) s")
        }
        XCTAssertGreaterThan(try center(result, at: 9.8) - center(result, at: 0), 0.5)
    }

    func testDissolveWithNoSubjectBorrowsNextShot() throws {
        // A 0.6 s dissolve between two shots shows nothing; it must not park on a corner.
        let samples = try frames(0, 10) { seconds in
            seconds < 4 ? [try self.face(0.30)] : seconds < 4.6 ? [] : [try self.face(0.65)]
        }
        let result = try frame(evidence(samples, cuts: [4, 4.6]), 0, 10)
        XCTAssertEqual(try center(result, at: 4.2), 0.65, accuracy: 0.03)
        XCTAssertFalse(result.uncertainRanges.isEmpty)
    }

    func testFacelessShotFramesItsSalientRegion() throws {
        // Product on the right side of a top-down shot: aim there, not at the center.
        let samples = try frames(0, 6, faces: { _ in [] }, salient: [region(0.70, 0.12, confidence: 0.6)])
        let result = try frame(evidence(samples), 0, 6)
        XCTAssertEqual(try center(result, at: 3), 0.76, accuracy: 0.03)
    }

    func testFacelessShotPicksOneObjectAndDoesNotFlip() throws {
        // A band in the left hand and a watch on the right; Vision's order changes
        // between frames. The crop settles on the stronger object for the whole shot.
        let samples = try (0..<30).map { index in
            let band = try region(0.12, 0.27, confidence: 0.58), watch = try region(0.68, 0.14, confidence: 0.51)
            return FocusFrame(time: try time(Double(index) * 0.2), faces: [],
                              salient: index.isMultiple(of: 2) ? [band, watch] : [watch, band])
        }
        let result = try frame(evidence(samples, range: (0, 6)), 0, 6)
        XCTAssertEqual(result.paths.count, 1)
        XCTAssertEqual(result.paths[0].keyframes.count, 1)
        XCTAssertEqual(try center(result, at: 3), 0.255, accuracy: 0.03)
    }

    func testTwoCloseFacesAreFramedTogether() throws {
        let samples = try frames(0, 6) { _ in [try self.face(0.42, width: 0.08), try self.face(0.58, width: 0.08)] }
        let result = try frame(evidence(samples), 0, 6)
        XCTAssertEqual(try center(result, at: 3), 0.50, accuracy: 0.03)
    }

    func testWideTwoShotFollowsWhoeverIsTalking() throws {
        // Left person talks for 6 s, then the right person answers for 6 s.
        let samples = try frames(0, 12) { seconds in
            let wobble = Int((seconds * 5).rounded()).isMultiple(of: 2) ? 0.02 : 0.12
            return [try self.face(0.2, mouth: seconds < 6 ? wobble : 0.03),
                    try self.face(0.8, mouth: seconds < 6 ? 0.03 : wobble)]
        }
        let result = try frame(evidence(samples), 0, 12)
        XCTAssertEqual(try center(result, at: 3), 0.2, accuracy: 0.05)
        XCTAssertEqual(try center(result, at: 10), 0.8, accuracy: 0.05)
        // The switch is a cut, never a pan across the empty middle.
        for seconds in stride(from: 0.0, to: 11.9, by: 0.1) {
            let x = try center(result, at: seconds)
            XCTAssertTrue(abs(x - 0.2) < 0.1 || abs(x - 0.8) < 0.1, "camera in the middle at \(seconds) s")
        }
    }

    func testOneOffFalseFaceInLongShotIsIgnored() throws {
        // A poster face flickers once; the real speaker is in the shot throughout.
        let samples = try frames(0, 8) { seconds in
            abs(seconds - 4) < 0.05 ? [try self.face(0.85, width: 0.2), try self.face(0.35)] : [try self.face(0.35)]
        }
        let result = try frame(evidence(samples), 0, 8)
        XCTAssertEqual(try center(result, at: 4), 0.35, accuracy: 0.03)
    }

    func testScreenRangesIgnoreWebcamFaces() throws {
        let screen = try FocusRegion(bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.6), confidence: 0.7)
        let samples = try (0..<30).map { index in
            FocusFrame(time: try time(Double(index) * 0.2), faces: [try face(0.9, width: 0.06)], salient: [screen])
        }
        let result = try ShotFramer().frame(range: range(0, 6), asset: source, format: .vertical,
            evidence: evidence(samples, range: (0, 6)), screenRanges: [range(0, 6)])
        XCTAssertLessThan(try center(result, at: 3), 0.6)
    }

    func testSameShapeOutputNeedsNoCropAndEvidenceMustCoverRange() throws {
        let samples = try frames(0, 6) { _ in [try self.face(0.3)] }
        let full = try frame(evidence(samples, range: (0, 6)), 0, 6, format: .horizontal)
        XCTAssertEqual(full.paths.count, 1)
        XCTAssertEqual(full.paths[0].keyframes[0].rect.width, 1, accuracy: 0.000001)
        XCTAssertThrowsError(try frame(evidence(samples, range: (0, 6)), 0, 10))
    }

    func testEnginePrefersEvidenceAndFallsBackWithoutIt() throws {
        let samples = try frames(0, 10) { _ in [try self.face(0.75)] }
        let scenes = [Scene(assetID: source.id, range: try range(0, 30))]
        let analysis = try AnalysisResult(asset: source, scenes: scenes, signals: [], detections: [],
            subjectTracks: [], classifications: [ContentClassification(range: range(0, 30),
                                                                       kind: .unknown, confidence: 0.2)])
        let withEvidence = try SmartAutoFrameEngine().frame(range: range(0, 10), asset: source,
            format: .vertical, analysis: analysis, evidence: evidence(samples, range: (0, 10)))
        XCTAssertEqual(try center(withEvidence, at: 5), 0.75, accuracy: 0.03)
        let without = try SmartAutoFrameEngine().frame(range: range(0, 10), asset: source,
            format: .vertical, analysis: analysis)
        XCTAssertEqual(try center(without, at: 5), 0.5, accuracy: 0.03)
    }

    func testLongMovingShotSplitsUnderTheKeyframeLimit() throws {
        let samples = try frames(0, 30) { seconds in
            let x: Double = 0.5 + 0.35 * sin(seconds * 1.3)
            return [try self.face(x)]
        }
        let result = try frame(evidence(samples), 0, 30)
        XCTAssertTrue(result.paths.allSatisfy { $0.keyframes.count <= 256 })
        for pair in zip(result.paths, result.paths.dropFirst()) {
            XCTAssertEqual(pair.0.sourceRange.end, pair.1.sourceRange.start)
        }
        XCTAssertEqual(result.paths.first?.sourceRange.start, try time(0))
        XCTAssertEqual(result.paths.last?.sourceRange.end, try time(30))
    }

    private func changes(_ value: (Int) -> Double) throws -> [(time: MediaTime, value: Double)] {
        try (0..<60).map { index in
            let time = try MediaTime(microseconds: Int64(index) * 33_366)
            return (time: time, value: value(index))
        }
    }

    func testCutDetectionFindsHardCutsAndIgnoresSteadyMotion() throws {
        let steady = try changes { index in index == 30 ? 0.6 : 0.03 + 0.01 * Double(index % 3) }
        XCTAssertEqual(FocusSampler.cuts(in: steady).map(\.time), [steady[30].time])
        // A dark-to-dark cut: small absolute change, but far above its neighbors.
        let dark = try changes { index in index == 20 ? 0.16 : 0.01 }
        XCTAssertEqual(FocusSampler.cuts(in: dark).map(\.time), [dark[20].time])
    }
}
