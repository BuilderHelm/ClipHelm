import AVFoundation
import Foundation
import Vision
import XCTest
import ClipHelmCore
import ClipHelmAnalysis
import ClipHelmFraming

/// Before/after Smart Auto Frame on a real project, scored against faces found
/// independently on full-resolution frames. Opt-in; it needs a project folder and
/// its source video:
///
///     CLIPHELM_FRAMING_PROJECT=~/Library/…/Projects/<id>.cliphelm \
///     CLIPHELM_FRAMING_SOURCE=/path/to/source.mp4 \
///     swift test --filter FramingBenchmarkTests
///
/// "Before" is the crop each saved clip renders today (a section with no crop path
/// is center-cropped). "After" re-plans the same sections with `ShotFramer`.
/// Set CLIPHELM_FRAMING_OUT to a folder to also write a before | after image of
/// each second, faceless shots included.
final class FramingBenchmarkTests: XCTestCase {
    private struct Score {
        var faceFrames = 0, mainInside = 0, anyInside = 0, missed = 0
        mutating func add(_ other: Score) {
            faceFrames += other.faceFrames; mainInside += other.mainInside
            anyInside += other.anyInside; missed += other.missed
        }
        var summary: String {
            func percent(_ value: Int) -> String {
                String(format: "%5.1f%%", 100 * Double(value) / Double(max(1, faceFrames)))
            }
            return "main face in frame \(percent(mainInside)) · any face \(percent(anyInside)) · " +
                "pointing elsewhere \(percent(missed)) (\(faceFrames) frames with faces)"
        }
    }

    func testBeforeAndAfter() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let projectPath = environment["CLIPHELM_FRAMING_PROJECT"],
              let sourcePath = environment["CLIPHELM_FRAMING_SOURCE"] else {
            throw XCTSkip("Set CLIPHELM_FRAMING_PROJECT and CLIPHELM_FRAMING_SOURCE to run the benchmark.")
        }
        let projectURL = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
        let sourceURL = URL(fileURLWithPath: (sourcePath as NSString).expandingTildeInPath)
        let project = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: projectURL.appending(path: "project.json"))) as? [String: Any])
        let asset = try JSONDecoder().decode(MediaAsset.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(project["mediaAsset"])))
        let clips = try XCTUnwrap(project["clips"] as? [[String: Any]])
        let specs = try clips.map { clip in
            try JSONDecoder().decode(ClipHelmEditSpec.self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(clip["spec"])))
        }
        let framed: Set<ShotLayout> = [.speakerFocus, .original, .screenAndSpeaker, .pictureInPicture]
        let evidence = try await FocusSampler().sample(sourceURL: sourceURL, asset: asset,
            ranges: specs.flatMap { $0.segments.map(\.sourceRange) })

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let output = environment["CLIPHELM_FRAMING_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        var before = Score(), after = Score()
        for (index, spec) in specs.enumerated() {
            var clipBefore = Score(), clipAfter = Score()
            let replanned = try spec.layoutCues.filter { framed.contains($0.layout) }.flatMap {
                try ShotFramer().frame(range: $0.sourceRange, asset: asset,
                                       format: spec.outputFormat, evidence: evidence).paths
            }
            let center = try centerCrop(asset: asset, format: spec.outputFormat)
            for segment in spec.segments {
                var seconds = Double(segment.sourceRange.start.microseconds) / 1_000_000
                let end = Double(segment.sourceRange.end.microseconds) / 1_000_000
                while seconds < end {
                    defer { seconds += 0.25 }
                    let time = try MediaTime(microseconds: Int64(seconds * 1_000_000))
                    guard let cue = spec.layoutCues.first(where: { $0.sourceRange.start <= time &&
                        time < $0.sourceRange.end }), framed.contains(cue.layout) else { continue }
                    let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
                    let old = try spec.cropPaths.first { $0.sourceRange.start <= time && time < $0.sourceRange.end }
                        .map { try $0.rect(atSourceTime: time) } ?? center
                    let new = try replanned.first { $0.sourceRange.start <= time && time < $0.sourceRange.end }
                        .map { try $0.rect(atSourceTime: time) } ?? center
                    if let output, Int((seconds * 4).rounded()) % 4 == 0 {
                        try writeComparison(image, old, new, to: output.appending(
                            path: String(format: "clip%d-%07.2f.png", index + 1, seconds)))
                    }
                    let faces = try groundTruthFaces(image)
                    guard !faces.isEmpty else { continue }
                    clipBefore.add(score(old, faces))
                    clipAfter.add(score(new, faces))
                }
            }
            print("FRAMING clip \(index + 1) before: \(clipBefore.summary)")
            print("FRAMING clip \(index + 1) after:  \(clipAfter.summary)")
            before.add(clipBefore)
            after.add(clipAfter)
        }
        print("FRAMING total before: \(before.summary)")
        print("FRAMING total after:  \(after.summary)")
        XCTAssertLessThanOrEqual(after.missed, before.missed)
    }

    /// The two crops side by side, as the viewer would see them.
    private func writeComparison(_ image: CGImage, _ old: ClipHelmCore.NormalizedRect,
                                 _ new: ClipHelmCore.NormalizedRect, to url: URL) throws {
        func cropped(_ rect: ClipHelmCore.NormalizedRect) -> CGImage? {
            image.cropping(to: CGRect(x: rect.x * Double(image.width), y: rect.y * Double(image.height),
                                      width: rect.width * Double(image.width), height: rect.height * Double(image.height)))
        }
        guard let left = cropped(old), let right = cropped(new),
              let context = CGContext(data: nil, width: left.width + right.width + 12, height: max(left.height, right.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.draw(left, in: CGRect(x: 0, y: 0, width: left.width, height: left.height))
        context.draw(right, in: CGRect(x: left.width + 12, y: 0, width: right.width, height: right.height))
        guard let composite = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, composite, nil)
        CGImageDestinationFinalize(destination)
    }

    private func groundTruthFaces(_ image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).filter { $0.confidence >= 0.6 && $0.boundingBox.width >= 0.035 }
            .map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY,
                          width: $0.boundingBox.width, height: $0.boundingBox.height) }
            .sorted { $0.width * $0.height > $1.width * $1.height }
    }

    private func score(_ crop: ClipHelmCore.NormalizedRect, _ faces: [CGRect]) -> Score {
        let frame = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height).insetBy(dx: -0.001, dy: -0.001)
        return Score(faceFrames: 1,
                     mainInside: frame.contains(faces[0]) ? 1 : 0,
                     anyInside: faces.contains { frame.contains($0) } ? 1 : 0,
                     missed: faces.contains { frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ? 0 : 1)
    }

    private func centerCrop(asset: MediaAsset, format: OutputFormat) throws -> ClipHelmCore.NormalizedRect {
        let width = min(1, Double(format.width) / Double(format.height) / (Double(asset.width) / Double(asset.height)))
        let height = min(1, Double(asset.width) / Double(asset.height) / (Double(format.width) / Double(format.height)))
        return try ClipHelmCore.NormalizedRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}
