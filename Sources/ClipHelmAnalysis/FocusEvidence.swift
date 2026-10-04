import Foundation
import AVFoundation
import Vision
import CoreGraphics
import ClipHelmCore
import ClipHelmMedia

/// One face seen in a focus sample. Bounds are normalized with a top-left origin.
public struct FocusFace: Codable, Equatable, Sendable {
    public let bounds: ClipHelmCore.NormalizedRect
    public let confidence: Double
    /// Inner-lip opening as a fraction of face height, when landmarks were found.
    /// It changes from sample to sample while a person talks.
    public let mouthOpening: Double?

    public init(bounds: ClipHelmCore.NormalizedRect, confidence: Double, mouthOpening: Double? = nil) throws {
        guard confidence.isFinite, (0...1).contains(confidence),
              mouthOpening.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
            throw ModelError.invalid("FocusFace")
        }
        self.bounds = bounds
        self.confidence = confidence
        self.mouthOpening = mouthOpening
    }
}

/// A distinct object that draws the eye (a product, hands), with Vision's confidence.
public struct FocusRegion: Codable, Equatable, Sendable {
    public let bounds: ClipHelmCore.NormalizedRect
    public let confidence: Double

    public init(bounds: ClipHelmCore.NormalizedRect, confidence: Double) throws {
        guard confidence.isFinite, (0...1).contains(confidence) else { throw ModelError.invalid("FocusRegion") }
        self.bounds = bounds
        self.confidence = confidence
    }
}

/// What the camera could point at in one sampled source frame.
public struct FocusFrame: Codable, Equatable, Sendable {
    public let time: MediaTime
    public let faces: [FocusFace]
    /// Separate salient objects, measured only when no face is visible.
    public let salient: [FocusRegion]

    public init(time: MediaTime, faces: [FocusFace], salient: [FocusRegion] = []) {
        self.time = time
        self.faces = faces
        self.salient = salient
    }
}

/// Dense, clip-local evidence for Smart Auto Frame: frames a few times a second
/// plus camera cuts located to the frame. Whole-source analysis samples once
/// every 1–3 seconds, too sparse to follow a multi-camera edit.
public struct FocusEvidence: Codable, Equatable, Sendable {
    public let assetID: AssetID
    public let ranges: [MediaTimeRange]
    public let frames: [FocusFrame]
    /// Source times where the picture cuts to a different shot.
    public let cuts: [MediaTime]

    public init(assetID: AssetID, ranges: [MediaTimeRange], frames: [FocusFrame],
                cuts: [MediaTime]) throws {
        guard zip(frames, frames.dropFirst()).allSatisfy({ $0.time < $1.time }),
              zip(cuts, cuts.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(ranges, ranges.dropFirst()).allSatisfy({ $0.end <= $1.start }) else {
            throw ModelError.invalid("FocusEvidence")
        }
        self.assetID = assetID
        self.ranges = ranges
        self.frames = frames
        self.cuts = cuts
    }

    public func validate(for asset: MediaAsset) throws {
        guard assetID == asset.id,
              ranges.allSatisfy({ $0.end <= asset.duration }),
              frames.allSatisfy({ $0.time < asset.duration }),
              cuts.allSatisfy({ $0 < asset.duration }) else {
            throw ModelError.invalid("FocusEvidence asset")
        }
    }

    /// Whether the evidence was sampled across all of `range`.
    public func covers(_ range: MediaTimeRange) -> Bool {
        ranges.contains { $0.start <= range.start && range.end <= $0.end }
    }
}

/// Samples clip ranges densely for framing: faces with mouth landmarks, a salient
/// region when no face is visible, and camera cuts found at the exact frame.
/// Each range is decoded once, in order, so no frame needs a separate seek.
public struct FocusSampler: Sendable {
    /// 5 samples a second: dense enough to follow a talking head, cheap enough
    /// to run for every clip.
    public static let interval: Int64 = 200_000

    public init() { }

    public func sample(sourceURL: URL, asset: MediaAsset, ranges: [MediaTimeRange],
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> FocusEvidence {
        guard sourceURL.isFileURL, ranges.allSatisfy({ $0.end <= asset.duration }) else {
            throw ModelError.invalid("FocusSampler inputs")
        }
        let merged = Self.merge(ranges)
        return try await runAnalysisOffMain {
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
            let source = AVURLAsset(url: sourceURL, options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
            ])
            guard let track = try await source.loadTracks(withMediaType: .video).first else {
                throw MediaEngineError.unsupportedMedia
            }
            let orientation = Self.orientation(try await track.load(.preferredTransform))
            let total = Double(max(1, merged.reduce(Int64(0)) { $0 + $1.durationMicroseconds }))
            var finished = 0.0
            var frames: [FocusFrame] = []
            var cuts: [MediaTime] = []
            for range in merged {
                let (rangeFrames, rangeCuts) = try Self.read(source: source, track: track,
                    orientation: orientation, range: range, asset: asset) { fraction in
                    progress?((finished + fraction * Double(range.durationMicroseconds)) / total)
                }
                finished += Double(range.durationMicroseconds)
                frames.append(contentsOf: rangeFrames)
                cuts.append(contentsOf: rangeCuts.filter { cut in cuts.last.map { $0 < cut } ?? true })
            }
            progress?(1)
            return try FocusEvidence(assetID: asset.id, ranges: merged, frames: frames, cuts: cuts)
        }
    }

    private static func read(source: AVURLAsset, track: AVAssetTrack,
                             orientation: CGImagePropertyOrientation, range: MediaTimeRange,
                             asset: MediaAsset,
                             progress: (Double) -> Void) throws -> ([FocusFrame], [MediaTime]) {
        let reader = try AVAssetReader(asset: source)
        reader.timeRange = CMTimeRange(
            start: CMTime(value: range.start.microseconds, timescale: 1_000_000),
            end: CMTime(value: range.end.microseconds, timescale: 1_000_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaEngineError.unsupportedMedia }
        reader.add(output)
        guard reader.startReading() else { throw MediaEngineError.unsupportedMedia }
        defer { reader.cancelReading() }

        var frames: [FocusFrame] = []
        var cutCandidates: [(time: MediaTime, change: Double)] = []
        var changes: [(time: MediaTime, value: Double)] = []
        var previous: [UInt8]?
        var nextSample = range.start.microseconds
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let stamp = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard stamp.isNumeric else { continue }
            let micros = Int64((stamp.seconds * 1_000_000).rounded())
            guard micros >= range.start.microseconds, micros < range.end.microseconds,
                  micros < asset.duration.microseconds else { continue }
            let time = try MediaTime(microseconds: micros)
            let luma = Self.luma(pixels)
            if let previous { changes.append((time, Self.change(previous, luma))) }
            previous = luma
            if micros >= nextSample {
                nextSample = max(nextSample + Self.interval, micros + Self.interval / 2)
                let faces = (try? Self.faces(in: pixels, orientation: orientation)) ?? []
                let salient = faces.isEmpty
                    ? (try? Self.salientRegions(in: pixels, orientation: orientation)) ?? [] : []
                if frames.last.map({ $0.time < time }) ?? true {
                    frames.append(FocusFrame(time: time, faces: faces, salient: salient))
                }
                progress(Double(micros - range.start.microseconds) / Double(range.durationMicroseconds))
            }
        }
        if reader.status == .failed { throw MediaEngineError.processingFailed }
        cutCandidates = Self.cuts(in: changes)
        let faceCuts = Self.faceJumps(in: frames).filter { jump in
            // A face jump confirms a cut only where the picture also changed.
            !cutCandidates.contains { abs($0.time.microseconds - jump.microseconds) <= Self.interval } &&
            changes.contains { abs($0.time.microseconds - jump.microseconds) <= Self.interval && $0.value >= 0.06 }
        }.compactMap { jump in
            // Place it on the largest frame-to-frame change near the jump.
            changes.filter { $0.time <= jump && jump.microseconds - $0.time.microseconds <= Self.interval }
                .max { $0.value < $1.value }.map { (time: $0.time, change: $0.value) }
        }
        let all = (cutCandidates + faceCuts).sorted { $0.time < $1.time }
        var result: [MediaTime] = []
        for cut in all where result.last.map({ cut.time.microseconds - $0.microseconds > 100_000 }) ?? true {
            result.append(cut.time)
        }
        return (frames, result)
    }

    // MARK: Ranges

    static func merge(_ ranges: [MediaTimeRange]) -> [MediaTimeRange] {
        var merged: [MediaTimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, range.start <= last.end {
                if range.end > last.end, let joined = try? MediaTimeRange(start: last.start, end: range.end) {
                    merged[merged.count - 1] = joined
                }
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func orientation(_ transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }

    // MARK: Faces and saliency

    static func faces(in pixels: CVPixelBuffer,
                      orientation: CGImagePropertyOrientation) throws -> [FocusFace] {
        let rectangles = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation)
        try handler.perform([rectangles])
        let found = (rectangles.results ?? []).filter { $0.confidence >= 0.5 }
        guard !found.isEmpty else { return [] }
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = found
        try? handler.perform([landmarks])
        let marked = landmarks.results ?? []
        return try found.compactMap { face in
            let box = face.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isNull, box.width > 0.01, box.height > 0.01 else { return nil }
            let lips = marked.first { $0.boundingBox == face.boundingBox }?.landmarks?.innerLips
            let opening = lips.flatMap { region -> Double? in
                let points = region.normalizedPoints
                guard points.count >= 4,
                      let low = points.map(\.y).min(), let high = points.map(\.y).max() else { return nil }
                return min(1, max(0, Double(high - low)))
            }
            return try FocusFace(bounds: ClipHelmCore.NormalizedRect(x: box.minX, y: 1 - box.maxY,
                                                        width: box.width, height: box.height),
                                 confidence: Double(face.confidence), mouthOpening: opening)
        }
    }

    /// Objectness saliency keeps separate objects apart (a band in one hand, a watch
    /// in the other); attention saliency, which merges them into one blob, is only
    /// the fallback when no object stands out.
    static func salientRegions(in pixels: CVPixelBuffer,
                               orientation: CGImagePropertyOrientation) throws -> [FocusRegion] {
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation).perform([objectness, attention])
        func regions(_ request: VNImageBasedRequest) -> [FocusRegion] {
            let observation = request.results?.first as? VNSaliencyImageObservation
            return (observation?.salientObjects ?? []).filter { $0.confidence > 0.2 }.compactMap { object in
                let box = object.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !box.isNull, box.width > 0.01, box.height > 0.01,
                      let bounds = try? ClipHelmCore.NormalizedRect(x: box.minX, y: 1 - box.maxY,
                                                                   width: box.width, height: box.height) else { return nil }
                return try? FocusRegion(bounds: bounds, confidence: Double(min(1, max(0, object.confidence))))
            }
        }
        let objects = regions(objectness)
        return objects.isEmpty ? regions(attention) : objects
    }

    // MARK: Cuts

    /// A 32 × 32 luma grid read straight from the decoded frame, without scaling.
    static func luma(_ pixels: CVPixelBuffer) -> [UInt8] {
        let side = 32
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return [] }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var grid = [UInt8](repeating: 0, count: side * side)
        for gy in 0..<side {
            let y = min(height - 1, (gy * height + height / 2) / side)
            for gx in 0..<side {
                let x = min(width - 1, (gx * width + width / 2) / side)
                let pixel = bytes + y * row + x * 4
                // BGRA → Rec. 601 luma.
                grid[gy * side + gx] = UInt8((Int(pixel[2]) * 77 + Int(pixel[1]) * 150 + Int(pixel[0]) * 29) >> 8)
            }
        }
        return grid
    }

    /// Mean absolute luma difference, normalized by the frames' own contrast so a
    /// cut between two dark shots registers as strongly as one between bright shots.
    static func change(_ first: [UInt8], _ second: [UInt8]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        let difference = zip(first, second).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        let mean = Double(difference) / Double(first.count)
        func spread(_ values: [UInt8]) -> Double {
            let average = Double(values.reduce(0) { $0 + Int($1) }) / Double(values.count)
            return values.reduce(0.0) { $0 + abs(Double($1) - average) } / Double(values.count)
        }
        let contrast = max(12, (spread(first) + spread(second)) / 2)
        return min(1, mean / (contrast * 2))
    }

    /// Frame-to-frame changes that stand out from the steady motion around them.
    /// Every frame is decoded, so a hard cut is a single-frame spike.
    static func cuts(in changes: [(time: MediaTime, value: Double)]) -> [(time: MediaTime, change: Double)] {
        guard changes.count >= 3 else { return [] }
        var result: [(time: MediaTime, change: Double)] = []
        for index in changes.indices {
            let value = changes[index].value
            guard value >= 0.12 else { continue }
            let window = (max(0, index - 15)...min(changes.count - 1, index + 15))
                .filter { abs($0 - index) > 1 }.map { changes[$0].value }.sorted()
            let typical = window.isEmpty ? 0 : window[window.count / 2]
            let peak = (index == 0 || value >= changes[index - 1].value) &&
                (index == changes.count - 1 || value >= changes[index + 1].value)
            if peak && (value >= 0.45 || value >= max(0.12, typical * 4)) {
                result.append((changes[index].time, value))
            }
        }
        return result
    }

    /// Sample times where the dominant face moves or resizes too far to be the
    /// same shot, the signature of a cut between two similar-looking angles.
    static func faceJumps(in frames: [FocusFrame]) -> [MediaTime] {
        zip(frames, frames.dropFirst()).compactMap { before, after in
            guard let first = before.faces.max(by: { $0.bounds.width < $1.bounds.width }),
                  let second = after.faces.max(by: { $0.bounds.width < $1.bounds.width }) else { return nil }
            let distance = abs(first.bounds.x + first.bounds.width / 2 -
                               second.bounds.x - second.bounds.width / 2)
            let resized = max(first.bounds.width, second.bounds.width) /
                max(0.001, min(first.bounds.width, second.bounds.width))
            return distance > 0.2 || resized > 1.8 ? after.time : nil
        }
    }
}
