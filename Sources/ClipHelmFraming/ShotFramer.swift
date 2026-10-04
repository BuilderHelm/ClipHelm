import Foundation
import ClipHelmCore
import ClipHelmAnalysis

/// Plans Smart Auto Frame crops from dense focus evidence, one camera cut at a time.
///
/// - Camera cuts in the source are cuts in the crop: the frame jumps to the new
///   shot's subject instead of panning across the edit.
/// - Faces lead. With two faces that fit together, both are framed; with two that
///   don't, the one who is talking (mouth movement) is framed, switching on a cut.
/// - A shot without faces frames its most salient region (a product, hands)
///   rather than the dead center; a shot with neither borrows its neighbor's framing.
/// - The camera holds still whenever one position keeps the subject inside the
///   frame for the whole shot, and otherwise follows smoothly. Either way the
///   subject's face is kept fully inside the crop.
public struct ShotFramer: Sendable {
    public init() { }

    /// `screenRanges` mark screen recordings, where faces (a webcam inset) are not
    /// the subject; those shots frame their salient region instead.
    public func frame(range: MediaTimeRange, asset: MediaAsset, format: OutputFormat,
                      evidence: FocusEvidence, screenRanges: [MediaTimeRange] = []) throws -> FramingResult {
        try evidence.validate(for: asset)
        guard range.end <= asset.duration, evidence.covers(range) else {
            throw ModelError.invalid("ShotFramer inputs")
        }
        let crop = CropSize(asset: asset, format: format)
        if crop.width >= 0.9999 && crop.height >= 0.9999 {
            let rect = try crop.rect(center: Center(x: 0.5, y: 0.5))
            return FramingResult(paths: [try CropPath(sourceRange: range,
                keyframes: [CropKeyframe(sourceTime: range.start, rect: rect)])], uncertainRanges: [])
        }
        let frames = evidence.frames.filter { range.start <= $0.time && $0.time < range.end }
        let cuts = evidence.cuts.filter { range.start < $0 && $0 < range.end }
        let edges = [range.start] + cuts + [range.end]
        var segments: [Segment] = []
        for (start, end) in zip(edges, edges.dropFirst()) where start < end {
            try Task.checkCancellation()
            let shot = try MediaTimeRange(start: start, end: end)
            var shotFrames = frames.filter { start <= $0.time && $0.time < end }
            let middle = try MediaTime(microseconds: start.microseconds + shot.durationMicroseconds / 2)
            if screenRanges.contains(where: { $0.start <= middle && middle < $0.end }) {
                shotFrames = shotFrames.map { FocusFrame(time: $0.time, faces: [], salient: $0.salient) }
            }
            segments += try plan(shot: shot, frames: shotFrames, crop: crop)
        }
        resolveUnframed(&segments)
        var paths: [CropPath] = []
        for segment in segments {
            paths += try crop.paths(for: segment)
        }
        return FramingResult(paths: paths,
                             uncertainRanges: segments.filter { !$0.grounded }.map(\.range))
    }

    // MARK: Shots

    private func plan(shot: MediaTimeRange, frames: [FocusFrame], crop: CropSize) throws -> [Segment] {
        let tracks = FaceTrack.link(frames)
        if tracks.isEmpty {
            // No face: follow the one object that draws the eye most consistently.
            guard let object = RegionTrack.best(frames, crop: crop) else {
                return [Segment(range: shot, positions: [], grounded: false)]
            }
            let boxes = object.boxes.map { $0.map { Subject(boxes: [$0], isFace: false) } }
            return [Segment(range: shot, positions: camera(frames: frames, subjects: boxes, crop: crop),
                            grounded: true)]
        }
        let ranked = tracks.map { ($0, $0.score(frameCount: frames.count)) }
            .sorted { $0.1 > $1.1 }
        let primary = ranked[0].0
        if ranked.count >= 2 {
            let second = ranked[1].0
            if ranked[1].1 >= ranked[0].1 * 0.5,
               primary.fitsWith(second, crop: crop) {
                let subjects = frames.indices.map { index -> Subject? in
                    let boxes = [primary.faces[index], second.faces[index]].compactMap { $0?.bounds }
                    return boxes.isEmpty ? nil : Subject(boxes: boxes, isFace: true)
                }
                return [Segment(range: shot, positions: camera(frames: frames, subjects: subjects, crop: crop),
                                grounded: true)]
            }
            let strong = ranked.map(\.0).filter { $0.presence(frameCount: frames.count) >= 0.35 }
            if strong.count >= 2, shot.durationMicroseconds >= 3_000_000 {
                return try followSpeaker(shot: shot, frames: frames, candidates: Array(strong.prefix(3)),
                                         crop: crop)
            }
        }
        // One clear subject; a talker outranks a silent listener of similar presence.
        let loudest = ranked.map { $0.0.activity() }.max() ?? 0
        func weight(_ entry: (FaceTrack, Double)) -> Double {
            entry.1 + (loudest > 0.006 ? 0.35 * entry.0.activity() / loudest : 0)
        }
        let chosen = ranked.max { weight($0) < weight($1) }!.0
        let subjects = frames.indices.map { chosen.faces[$0].map { Subject(boxes: [$0.bounds], isFace: true) } }
        return [Segment(range: shot, positions: camera(frames: frames, subjects: subjects, crop: crop),
                        grounded: true)]
    }

    /// Two or three people too far apart to share the frame: show whoever is
    /// talking, switching with a cut once the other person clearly takes over.
    private func followSpeaker(shot: MediaTimeRange, frames: [FocusFrame], candidates: [FaceTrack],
                               crop: CropSize) throws -> [Segment] {
        let window = 5  // one second of samples
        let windows = stride(from: 0, to: frames.count, by: window).map { $0..<min(frames.count, $0 + window) }
        let activity = windows.map { range in candidates.map { $0.activity(in: range) } }
        var current = candidates.indices.max { left, right in
            candidates[left].activity() < candidates[right].activity()
        }!
        var owners = [Int](repeating: current, count: windows.count)
        var lastSwitch = 0
        for index in windows.indices {
            let best = activity[index].indices.max { activity[index][$0] < activity[index][$1] }!
            let sustained = index + 1 < windows.count &&
                activity[index + 1][best] >= activity[index + 1][current] * 1.5 + 0.004
            if best != current, sustained,
               activity[index][best] >= activity[index][current] * 1.5 + 0.004,
               index - lastSwitch >= 2 {
                current = best
                lastSwitch = index
            }
            owners[index] = current
        }
        var segments: [Segment] = []
        var runStart = 0
        for index in windows.indices where index == windows.count - 1 || owners[index + 1] != owners[index] {
            let first = windows[runStart].lowerBound, last = windows[index].upperBound
            let start = runStart == 0 ? shot.start : frames[first].time
            let end = index == windows.count - 1 ? shot.end : frames[last].time
            let track = candidates[owners[index]]
            let slice = Array(frames[first..<last])
            let subjects = (first..<last).map { track.faces[$0].map { Subject(boxes: [$0.bounds], isFace: true) } }
            if start < end {
                segments.append(Segment(range: try MediaTimeRange(start: start, end: end),
                    positions: camera(frames: slice, subjects: subjects, crop: crop), grounded: true))
            }
            runStart = index + 1
        }
        return segments
    }

    // MARK: Camera

    /// One center per frame. Holds still when a single position keeps every
    /// sighting in frame; otherwise follows with look-ahead and limited speed.
    private func camera(frames: [FocusFrame], subjects: [Subject?], crop: CropSize) -> [(MediaTime, Center)] {
        let known = subjects.indices.filter { subjects[$0] != nil }
        guard !known.isEmpty else { return [] }
        // Fill gaps with the nearest sighting so a blink or turned head doesn't move the camera.
        let filled: [Subject] = subjects.indices.map { index in
            if let subject = subjects[index] { return subject }
            let nearest = known.min { abs($0 - index) < abs($1 - index) }!
            return subjects[nearest]!
        }
        let x = axis(filled.map { $0.span(\.x, \.width, size: crop.width, headroom: 0) }, size: crop.width,
                     times: frames.map(\.time))
        let headroom = filled.first?.isFace == true ? 0.12 * crop.height : 0
        let y = axis(filled.map { $0.span(\.y, \.height, size: crop.height, headroom: headroom) },
                     size: crop.height, times: frames.map(\.time))
        return frames.indices.map { (frames[$0].time, Center(x: x[$0], y: y[$0])) }
    }

    private func axis(_ spans: [Span], size: Double, times: [MediaTime]) -> [Double] {
        guard size < 0.9999 else { return spans.map { _ in 0.5 } }
        let lowest = size / 2, highest = 1 - size / 2
        func clampToFrame(_ value: Double) -> Double { min(highest, max(lowest, value)) }
        let low = spans.map(\.low).max()!, high = spans.map(\.high).min()!
        let targets = spans.map(\.target)
        if low <= high {
            // Locked-off: one position keeps the subject in frame for the whole shot.
            let held = clampToFrame(min(high, max(low, median(targets))))
            return spans.map { _ in held }
        }
        var position = clampToFrame(min(spans[0].high, max(spans[0].low, median(Array(targets.prefix(3))))))
        var result: [Double] = []
        for index in spans.indices {
            if index > 0 {
                let elapsed = max(0.001, Double(times[index].microseconds - times[index - 1].microseconds) / 1_000_000)
                let desired = targets[min(targets.count - 1, index + 2)]
                if abs(desired - position) > 0.12 * size {
                    let step = (desired - position) * (1 - exp(-elapsed / 0.45))
                    let limit = 0.6 * elapsed
                    position += min(limit, max(-limit, step))
                }
                // Never let the face leave the frame, even mid-move.
                position = min(spans[index].high, max(spans[index].low, position))
            }
            position = clampToFrame(position)
            result.append(position)
        }
        return result
    }

    /// Shots with nothing to frame (a dissolve, a blank title) borrow the next
    /// shot's framing, or the previous one's at the end, so the crop never parks
    /// on an empty corner between two real shots.
    private func resolveUnframed(_ segments: inout [Segment]) {
        for index in segments.indices where segments[index].positions.isEmpty {
            let next = segments[(index + 1)...].first { !$0.positions.isEmpty }?.positions.first?.1
            let previous = segments[..<index].last { !$0.positions.isEmpty }?.positions.last?.1
            let center = next ?? previous ?? Center(x: 0.5, y: 0.5)
            segments[index].positions = [(segments[index].range.start, center)]
        }
    }
}

// MARK: - Model

struct Center: Equatable { let x: Double; let y: Double }

private struct Segment {
    let range: MediaTimeRange
    var positions: [(MediaTime, Center)]
    let grounded: Bool
}

/// The allowed and preferred crop centers on one axis for one frame.
private struct Span { let target: Double; let low: Double; let high: Double }

private struct Subject {
    let boxes: [NormalizedRect]
    let isFace: Bool

    func span(_ origin: KeyPath<NormalizedRect, Double>, _ length: KeyPath<NormalizedRect, Double>,
              size: Double, headroom: Double) -> Span {
        let start = boxes.map { $0[keyPath: origin] }.min()!
        let end = boxes.map { $0[keyPath: origin] + $0[keyPath: length] }.max()!
        let margin = isFace ? 0.2 * (boxes.map { $0[keyPath: length] }.max()!) : 0
        let target = (start + end) / 2 + headroom
        let low = end + margin - size / 2, high = start - margin + size / 2
        // A subject wider than the crop can't fit; aim at its middle without pinning
        // the camera to every frame's box, so it holds instead of jittering.
        return low <= high ? Span(target: min(high, max(low, target)), low: low, high: high)
            : Span(target: (start + end) / 2, low: -.infinity, high: .infinity)
    }
}

/// One salient object across the samples of a faceless shot.
private struct RegionTrack {
    var boxes: [NormalizedRect?]
    var weight: Double

    /// The object seen most often and most confidently, preferring ones the crop
    /// can actually show whole.
    static func best(_ frames: [FocusFrame], crop: CropSize) -> RegionTrack? {
        var tracks: [RegionTrack] = []
        var centers: [Double] = []
        for (index, frame) in frames.enumerated() {
            for region in frame.salient {
                let center = region.bounds.x + region.bounds.width / 2
                let fits = region.bounds.width <= crop.width * 0.95
                let weight = region.confidence * (fits ? 1 : 0.4)
                if let match = centers.indices.filter({ abs(centers[$0] - center) < 0.12 && tracks[$0].boxes[index] == nil })
                    .min(by: { abs(centers[$0] - center) < abs(centers[$1] - center) }) {
                    tracks[match].boxes[index] = region.bounds
                    tracks[match].weight += weight
                    centers[match] = center
                } else {
                    var boxes = [NormalizedRect?](repeating: nil, count: frames.count)
                    boxes[index] = region.bounds
                    tracks.append(RegionTrack(boxes: boxes, weight: weight))
                    centers.append(center)
                }
            }
        }
        return tracks.max { $0.weight < $1.weight }
    }
}

/// One person's face across consecutive samples of a shot.
private struct FaceTrack {
    var faces: [FocusFace?]

    static func link(_ frames: [FocusFrame]) -> [FaceTrack] {
        var tracks: [FaceTrack] = []
        var lastSeen: [Int] = []
        for (index, frame) in frames.enumerated() {
            var claimed = Set<Int>()
            for face in frame.faces.sorted(by: { $0.bounds.width > $1.bounds.width }) {
                let center = face.bounds.x + face.bounds.width / 2
                let match = tracks.indices.filter { !claimed.contains($0) && index - lastSeen[$0] <= 3 }
                    .compactMap { track -> (Int, Double)? in
                        guard let previous = tracks[track].faces[lastSeen[track]] else { return nil }
                        let distance = abs(previous.bounds.x + previous.bounds.width / 2 - center)
                        let ratio = max(previous.bounds.width, face.bounds.width) /
                            max(0.001, min(previous.bounds.width, face.bounds.width))
                        return distance < max(0.06, 0.75 * face.bounds.width) && ratio < 1.6
                            ? (track, distance) : nil
                    }
                    .min { $0.1 < $1.1 }?.0
                if let match {
                    tracks[match].faces[index] = face
                    lastSeen[match] = index
                    claimed.insert(match)
                } else {
                    var faces = [FocusFace?](repeating: nil, count: frames.count)
                    faces[index] = face
                    tracks.append(FaceTrack(faces: faces))
                    lastSeen.append(index)
                    claimed.insert(tracks.count - 1)
                }
            }
        }
        // A face seen once in a long shot is more likely a poster or a false hit.
        let minimum = frames.count >= 10 ? 2 : 1
        return tracks.filter { $0.faces.compactMap { $0 }.count >= minimum }
    }

    func presence(frameCount: Int) -> Double {
        Double(faces.compactMap { $0 }.count) / Double(max(1, frameCount))
    }

    func score(frameCount: Int) -> Double {
        let seen = faces.compactMap { $0 }
        let size = median(seen.map(\.bounds.width))
        let confidence = seen.map(\.confidence).reduce(0, +) / Double(max(1, seen.count))
        return pow(presence(frameCount: frameCount), 0.7) * min(1, 0.35 + size * 5) * confidence
    }

    /// How much the mouth moves between consecutive samples: high while talking.
    func activity(in range: Range<Int>? = nil) -> Double {
        let indices = Array(range ?? faces.indices)
        let steps = zip(indices, indices.dropFirst()).compactMap { first, second -> Double? in
            guard let a = faces[first]?.mouthOpening, let b = faces[second]?.mouthOpening else { return nil }
            return abs(a - b)
        }
        return steps.isEmpty ? 0 : steps.reduce(0, +) / Double(steps.count)
    }

    func box() -> NormalizedRect? {
        let seen = faces.compactMap { $0?.bounds }
        guard !seen.isEmpty else { return nil }
        return try? NormalizedRect(x: median(seen.map(\.x)), y: median(seen.map(\.y)),
                                   width: median(seen.map(\.width)), height: median(seen.map(\.height)))
    }

    /// Whether both faces fit in one crop with breathing room.
    func fitsWith(_ other: FaceTrack, crop: CropSize) -> Bool {
        guard let first = box(), let second = other.box() else { return false }
        let horizontal = max(first.x + first.width, second.x + second.width) - min(first.x, second.x)
        let vertical = max(first.y + first.height, second.y + second.height) - min(first.y, second.y)
        return horizontal <= crop.width * 0.85 && vertical <= crop.height * 0.85
    }
}

// MARK: - Geometry

private struct CropSize {
    let width: Double
    let height: Double

    init(asset: MediaAsset, format: OutputFormat) {
        let sourceAspect = Double(asset.width) / Double(asset.height)
        let targetAspect = Double(format.width) / Double(format.height)
        width = min(1, targetAspect / sourceAspect)
        height = min(1, sourceAspect / targetAspect)
    }

    func rect(center: Center) throws -> NormalizedRect {
        var x = min(1 - width, max(0, center.x - width / 2))
        var y = min(1 - height, max(0, center.y - height / 2))
        if x + width > 1 { x = (1 - width).nextDown }
        if y + height > 1 { y = (1 - height).nextDown }
        return try NormalizedRect(x: max(0, x), y: max(0, y), width: width, height: height)
    }

    /// Keyframes only where the camera moves, split so no path exceeds the limit.
    func paths(for segment: Segment) throws -> [CropPath] {
        let positions = segment.positions
        guard let first = positions.first?.1 else { return [] }
        let moving = positions.contains { abs($0.1.x - first.x) > 0.0005 || abs($0.1.y - first.y) > 0.0005 }
        guard moving else {
            return [try CropPath(sourceRange: segment.range,
                keyframes: [CropKeyframe(sourceTime: segment.range.start, rect: rect(center: first))])]
        }
        var points = [(segment.range.start, first)] +
            positions.dropFirst().filter { segment.range.start < $0.0 && $0.0 < segment.range.end }
        points.append((segment.range.end, positions.last!.1))
        // Drop keyframes that lie on the straight line between their neighbors.
        var kept = [points[0]]
        for index in 1..<(points.count - 1) {
            let previous = kept.last!, next = points[index + 1], point = points[index]
            let fraction = Double(point.0.microseconds - previous.0.microseconds) /
                Double(max(1, next.0.microseconds - previous.0.microseconds))
            let expectedX = previous.1.x + (next.1.x - previous.1.x) * fraction
            let expectedY = previous.1.y + (next.1.y - previous.1.y) * fraction
            if abs(point.1.x - expectedX) > 0.001 || abs(point.1.y - expectedY) > 0.001 { kept.append(point) }
        }
        kept.append(points.last!)
        var paths: [CropPath] = []
        var start = 0
        while start < kept.count - 1 {
            let end = min(kept.count - 1, start + 239)
            let slice = kept[start...end]
            paths.append(try CropPath(sourceRange: MediaTimeRange(start: slice.first!.0, end: slice.last!.0),
                keyframes: slice.map { CropKeyframe(sourceTime: $0.0, rect: try rect(center: $0.1)) }))
            start = end
        }
        return paths
    }
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0.5 }
    let sorted = values.sorted()
    return sorted.count.isMultiple(of: 2)
        ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
}
