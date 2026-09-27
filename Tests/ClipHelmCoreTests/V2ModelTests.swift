import Foundation
import XCTest
@testable import ClipHelmCore

final class V2ModelTests: XCTestCase {
    private func range(_ start: Double, _ end: Double) throws -> MediaTimeRange {
        try MediaTimeRange(start: MediaTime(microseconds: Int64(start * 1_000_000)),
                           end: MediaTime(microseconds: Int64(end * 1_000_000)))
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func asset(seconds: Int64 = 600) throws -> MediaAsset {
        try MediaAsset(id: AssetID(), displayName: "talk.mp4",
                       duration: MediaTime(microseconds: seconds * 1_000_000), width: 1920, height: 1080)
    }

    /// A topic segment containing a setup sentence and its payoff.
    private func sampleGraph(asset: MediaAsset) throws -> (MomentGraph, MomentNode, MomentNode, MomentNode) {
        let segment = try MomentNode(kind: .topicSegment, range: range(10, 70), summary: "Why small bets win",
                                     salience: 0.8, provenance: .model)
        let setup = try MomentNode(kind: .sentence, range: range(12, 20), salience: 0.6,
                                   storyRole: .setup, speakerID: "A", provenance: .local)
        let payoff = try MomentNode(kind: .sentence, range: range(55, 66), salience: 0.9,
                                    storyRole: .payoff, speakerID: "A", provenance: .local)
        let edges = try [
            MomentEdge(from: segment.id, to: setup.id, kind: .contains, provenance: .local),
            MomentEdge(from: segment.id, to: payoff.id, kind: .contains, provenance: .local),
            MomentEdge(from: setup.id, to: payoff.id, kind: .setsUp, weight: 0.7, provenance: .model),
            MomentEdge(from: payoff.id, to: setup.id, kind: .paysOff, weight: 0.7, provenance: .model),
        ]
        let story = try StoryUnit(range: range(10, 70), beats: [
            StoryBeat(role: .setup, range: range(12, 20)),
            StoryBeat(role: .payoff, range: range(55, 66)),
        ], nodeIDs: [setup.id, payoff.id], completeness: 0.8, title: "Small bets")
        let graph = try MomentGraph(assetID: asset.id, nodes: [segment, setup, payoff],
                                    edges: edges, storyUnits: [story])
        return (graph, segment, setup, payoff)
    }

    func testMomentGraphRoundTripsAndAnswersStructuralQueries() throws {
        let source = try asset()
        let (graph, segment, setup, payoff) = try sampleGraph(asset: source)
        XCTAssertEqual(try roundTrip(graph), graph)
        try graph.validate(for: source)
        XCTAssertEqual(graph.children(of: segment.id).map(\.id), [setup.id, payoff.id])
        XCTAssertEqual(graph.edges(from: setup.id, kind: .setsUp).map(\.to), [payoff.id])
        XCTAssertTrue(graph.storyUnits[0].isSelfContained)
        XCTAssertThrowsError(try graph.validate(for: asset(seconds: 30)))
    }

    func testMomentGraphRejectsInconsistentStructure() throws {
        let source = try asset()
        let (_, segment, setup, payoff) = try sampleGraph(asset: source)
        let stranger = MomentNodeID()
        // Dangling edge.
        XCTAssertThrowsError(try MomentGraph(assetID: source.id, nodes: [setup, payoff], edges: [
            MomentEdge(from: setup.id, to: stranger, kind: .follows, provenance: .local)]))
        // Duplicate node IDs.
        XCTAssertThrowsError(try MomentGraph(assetID: source.id, nodes: [setup, setup], edges: []))
        // Self loop.
        XCTAssertThrowsError(try MomentEdge(from: setup.id, to: setup.id, kind: .follows, provenance: .local))
        // Containment that does not contain.
        XCTAssertThrowsError(try MomentGraph(assetID: source.id, nodes: [setup, payoff], edges: [
            MomentEdge(from: setup.id, to: payoff.id, kind: .contains, provenance: .local)]))
        // Time order that contradicts the edge's meaning.
        XCTAssertThrowsError(try MomentGraph(assetID: source.id, nodes: [setup, payoff], edges: [
            MomentEdge(from: payoff.id, to: setup.id, kind: .follows, provenance: .local)]))
        XCTAssertThrowsError(try MomentGraph(assetID: source.id, nodes: [setup, payoff], edges: [
            MomentEdge(from: setup.id, to: payoff.id, kind: .answers, provenance: .model)]))
        // Duplicate edge.
        let edge = try MomentEdge(from: setup.id, to: payoff.id, kind: .follows, provenance: .local)
        XCTAssertThrowsError(try MomentGraph(assetID: source.id, nodes: [setup, payoff], edges: [edge, edge]))
        // A story unit naming a node outside its range.
        let outside = try StoryUnit(range: range(50, 70), beats: [StoryBeat(role: .payoff, range: range(55, 66))],
                                    nodeIDs: [setup.id], completeness: 0.5)
        XCTAssertThrowsError(try MomentGraph(assetID: source.id, nodes: [segment, setup, payoff],
                                             edges: [], storyUnits: [outside]))
    }

    func testFutureMomentGraphVersionIsRejected() throws {
        let source = try asset()
        let (graph, _, _, _) = try sampleGraph(asset: source)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(graph)) as? [String: Any])
        object["schemaVersion"] = MomentGraph.currentVersion + 1
        XCTAssertThrowsError(try JSONDecoder().decode(MomentGraph.self,
                                                      from: JSONSerialization.data(withJSONObject: object)))
    }

    func testStoryUnitsNeedOrderedBeatsInsideTheirRange() throws {
        XCTAssertThrowsError(try StoryUnit(range: range(0, 30), beats: [
            StoryBeat(role: .payoff, range: range(20, 25)), StoryBeat(role: .hook, range: range(0, 5)),
        ], nodeIDs: [MomentNodeID()], completeness: 0.5))
        XCTAssertThrowsError(try StoryUnit(range: range(0, 10), beats: [StoryBeat(role: .hook, range: range(5, 15))],
                                           nodeIDs: [MomentNodeID()], completeness: 0.5))
        XCTAssertThrowsError(try StoryUnit(range: range(0, 10), beats: [], nodeIDs: [MomentNodeID()], completeness: 0.5))
        let aside = try StoryUnit(range: range(0, 10), beats: [StoryBeat(role: .aside, range: range(0, 10))],
                                  nodeIDs: [MomentNodeID()], completeness: 0.2)
        XCTAssertFalse(aside.isSelfContained)
    }

    func testProjectIntelligenceValidatesChaptersTopicsAndBounds() throws {
        let source = try asset()
        let topic = try Topic(label: "Space food", keywords: ["menu", "flavor"], ranges: [range(100, 160)], salience: 0.7)
        let entity = try SemanticEntity(name: "ISS", kind: .place, aliases: ["space station"],
                                        mentions: [range(5, 6), range(40, 41)])
        let intelligence = try ProjectIntelligence(assetID: source.id, summary: "An astronaut on daily life.",
            languageCode: "en", chapters: [Chapter(title: "Intro", range: range(0, 60)),
                                           Chapter(title: "Food", range: range(60, 200))],
            topics: [topic], entities: [entity])
        XCTAssertEqual(try roundTrip(intelligence), intelligence)
        try intelligence.validate(for: source)
        XCTAssertThrowsError(try ProjectIntelligence(assetID: source.id, summary: "", chapters: [
            Chapter(title: "A", range: range(0, 60)), Chapter(title: "B", range: range(30, 90))]))
        XCTAssertThrowsError(try ProjectIntelligence(assetID: source.id, summary: "", languageCode: "en; rm -rf"))
        XCTAssertThrowsError(try Topic(label: "", ranges: [range(0, 1)], salience: 0.5))
        XCTAssertThrowsError(try Topic(label: "x", ranges: [], salience: 0.5))
        XCTAssertThrowsError(try Topic(label: "x", ranges: [range(0, 1)], salience: 1.5))
    }

    func testSearchResultsMustPointAtWhatTheyDescribe() throws {
        XCTAssertNoThrow(try SearchResult(kind: .transcript, range: range(1, 2), snippet: "food", score: 0.9))
        XCTAssertNoThrow(try SearchResult(kind: .clip, clipID: ClipID(), snippet: "", score: 0.4))
        XCTAssertThrowsError(try SearchResult(kind: .clip, range: range(1, 2), snippet: "x", score: 0.4))
        XCTAssertThrowsError(try SearchResult(kind: .topic, snippet: "x", score: 0.4))
        XCTAssertThrowsError(try SearchResult(kind: .transcript, range: range(1, 2),
                                              snippet: String(repeating: "a", count: 301), score: 0.4))
    }

    func testDirectionTypesRejectImpossibleGeometryAndClaims() throws {
        let wide = try NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        let tight = try NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let tooTight = try NormalizedRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        let punch = try CameraMotion(kind: .punchIn, range: range(0, 1), from: wide, to: tight)
        XCTAssertEqual(try roundTrip(punch), punch)
        XCTAssertThrowsError(try CameraMotion(kind: .punchIn, range: range(0, 1), from: tight, to: wide))
        XCTAssertThrowsError(try CameraMotion(kind: .pullOut, range: range(0, 1), from: wide, to: tight))
        XCTAssertThrowsError(try CameraMotion(kind: .hold, range: range(0, 1), from: wide, to: tight))
        XCTAssertThrowsError(try CameraMotion(kind: .punchIn, range: range(0, 1), from: wide, to: tooTight))

        let decision = try DirectorDecision(range: range(0, 4), layout: .speakerFocus, focus: tight,
                                            motion: punch, reason: .emphasis, confidence: 0.8, provenance: .local)
        XCTAssertEqual(try roundTrip(decision), decision)
        XCTAssertThrowsError(try DirectorDecision(range: range(2, 4), layout: .speakerFocus, motion: punch,
                                                  reason: .emphasis, confidence: 0.8, provenance: .local))
        XCTAssertThrowsError(try DirectorDecision(range: range(0, 4), layout: .original, reason: .userOverride,
                                                  confidence: 1, provenance: .model))

        XCTAssertThrowsError(try ShotIntent(range: range(0, 2), subject: .screen, speakerID: "A",
                                            confidence: 0.5, provenance: .model))
        XCTAssertThrowsError(try EditorialIntent(proposalID: UUID(), objective: .educate,
            keepRanges: [range(0, 10)], avoidRanges: [range(5, 6)], provenance: .model))
        XCTAssertThrowsError(try EditorialIntent(proposalID: UUID(), objective: .hook,
            minimumMicroseconds: 30_000_000, maximumMicroseconds: 10_000_000, provenance: .model))
        XCTAssertThrowsError(try CaptionEmphasis(wordRange: range(1, 2), text: "two\nlines",
                                                 level: .strong, reason: .keyword, provenance: .model))

        let region = try ScreenRegion(kind: .code, bounds: tight, range: range(0, 30), importance: 0.9)
        let event = try DemoEvent(kind: .typing, range: range(3, 5), regionID: region.id, confidence: 0.7)
        XCTAssertEqual(try roundTrip(region), region)
        XCTAssertEqual(try roundTrip(event), event)
    }

    func testBrandKitAcceptsOnlyPlainValues() throws {
        let kit = try BrandKit(name: "Studio", primaryColor: BrandColor(hex: "#1e66d8"),
                               accentColor: BrandColor(hex: "#7FEDD4"), textColor: BrandColor(hex: "#FFFFFF"),
                               captionStyle: .pop, fontName: "SF Pro Rounded", logoFileName: "logo.png")
        XCTAssertEqual(kit.primaryColor.hex, "#1E66D8")
        XCTAssertEqual(try roundTrip(kit), kit)
        for bad in ["1E66D8", "#1E66D", "#GGGGGG", "#1E66D8FF"] {
            XCTAssertThrowsError(try BrandColor(hex: bad), bad)
        }
        for badLogo in ["../logo.png", "/tmp/logo.png", ".hidden.png", "logo.svg", "a:b.png"] {
            XCTAssertThrowsError(try BrandKit(name: "x", primaryColor: kit.primaryColor, accentColor: kit.accentColor,
                                              textColor: kit.textColor, captionStyle: .pop, logoFileName: badLogo), badLogo)
        }
        XCTAssertThrowsError(try BrandKit(name: "x", primaryColor: kit.primaryColor, accentColor: kit.accentColor,
                                          textColor: kit.textColor, captionStyle: .pop, fontName: "Font; rm"))
    }

    func testBuiltInPlatformsUseRenderableCanvasesAndVariantsNeedTheirFiles() throws {
        XCTAssertEqual(Set(PlatformProfile.builtIn.map(\.id)), Set(PlatformID.allCases))
        XCTAssertTrue(PlatformProfile.builtIn.allSatisfy { [OutputFormat.vertical, .horizontal].contains($0.outputFormat) })
        XCTAssertEqual(PlatformProfile.builtIn(.tiktok)?.outputFormat, .vertical)

        let base = ClipID()
        let planned = try ClipVariant(baseClipID: base, platform: .youtubeShorts, title: "Shorts cut", status: .planned)
        XCTAssertEqual(try roundTrip(planned), planned)
        XCTAssertThrowsError(try ClipVariant(baseClipID: base, platform: .tiktok, title: "x", status: .rendered))
        XCTAssertThrowsError(try ClipVariant(baseClipID: base, platform: .tiktok, title: "x", status: .planned,
                                             finalFileName: "../escape.mp4"))

        let metadata = ProjectV2Metadata(platformTargets: [.tiktok], variants: [planned])
        try metadata.validate(clipIDs: [base])
        XCTAssertThrowsError(try metadata.validate(clipIDs: [ClipID()]))
        XCTAssertThrowsError(try ProjectV2Metadata(platformTargets: [.tiktok, .tiktok]).validate(clipIDs: []))
        XCTAssertEqual(try JSONDecoder().decode(ProjectV2Metadata.self, from: Data("{}".utf8)), .empty)
    }

    func testAssistantActionsRoundTripAndRejectAnythingElse() throws {
        let clip = ClipID()
        let actions: [AssistantAction] = try [
            .search(query: "space food"), .findMoments(query: "funny moments"),
            .renameClip(clipID: clip, title: "Better title"), .trimClip(clipID: clip, range: range(1, 20)),
            .setCaptionStyle(clipID: clip, style: .impact), .setLayout(clipID: clip, range: range(1, 5), layout: .screenFocus),
            .removeFillers(clipID: clip), .applyBrandKit(clipID: clip, brandKitID: BrandKitID()),
            .createVariant(clipID: clip, platform: .instagramReels),
        ]
        XCTAssertEqual(Set(actions.map(\.kind)), Set(AssistantAction.Kind.allCases))
        for action in actions { XCTAssertEqual(try roundTrip(action), action) }
        XCTAssertFalse(AssistantAction.search(query: "x").requiresConfirmation)
        XCTAssertTrue(AssistantAction.removeFillers(clipID: clip).requiresConfirmation)

        for json in [#"{"type":"runShell","command":"rm -rf /"}"#,
                     #"{"type":"search"}"#,
                     #"{"type":"search","query":""}"#,
                     #"{"type":"renameClip","clipID":"\#(clip.rawValue.uuidString)","title":"a\nb"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(AssistantAction.self, from: Data(json.utf8)), json)
        }
    }
}
