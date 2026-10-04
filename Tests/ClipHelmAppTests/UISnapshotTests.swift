import AppKit
import SwiftUI
import XCTest
@testable import ClipHelmApp

/// Renders screens off-screen to PNGs for layout review without taking over the
/// screen. Light appearance only: off-screen drawing skips AppKit-backed pieces
/// (sidebar List, bordered buttons, tab bars) and mixes appearances in dark mode,
/// so color and materials must still be checked in the running app.
/// Skipped unless CLIPHELM_SNAPSHOT_DIR is set; it reads this Mac's real projects
/// so reviews show real content. Nothing here touches the Keychain's key data.
///
///     CLIPHELM_SNAPSHOT_DIR=/tmp/cliphelm-shots swift test --filter UISnapshotTests
@MainActor
final class UISnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["CLIPHELM_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set CLIPHELM_SNAPSHOT_DIR to render design snapshots.")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testHome() throws {
        try renderLight("home", size: CGSize(width: 1180, height: 900)) {
            AppShell(navigation: self.navigation(.home)).tint(DS.accent)
        }
    }

    func testRecentProjects() throws {
        try renderLight("recent", size: CGSize(width: 1180, height: 760)) {
            AppShell(navigation: self.navigation(.recent)).tint(DS.accent)
        }
    }

    func testWizardSteps() throws {
        for step in [WizardStep.source, .format, .captions, .review] {
            let navigation = navigation(.newProject)
            navigation.step = step
            try renderLight("wizard-\(step.rawValue)", size: CGSize(width: 1180, height: 820)) {
                AppShell(navigation: navigation).tint(DS.accent)
            }
        }
    }

    func testGeneratedClips() throws {
        let store = ProjectStore()
        guard let project = store.projects.max(by: { $0.clips.count < $1.clips.count }),
              !project.clips.isEmpty else { throw XCTSkip("No project with clips on this Mac.") }
        try renderLight("clips", size: CGSize(width: 1080, height: 1100)) {
            ScrollView {
                ClipResultsView(project: project, source: nil,
                    exportsDirectory: try? store.exportsDirectory(for: project.id),
                    cacheDirectory: nil, saveClip: { _ in }, deleteClip: { _ in })
                    .padding(DS.Space.lg)
            }
            .tint(DS.accent)
        }
    }

    func testSettings() throws {
        try renderLight("settings", size: CGSize(width: 560, height: 520)) {
            SettingsView()
        }
    }

    // MARK: Rendering

    private func navigation(_ route: AppRoute) -> NavigationState {
        let defaults = UserDefaults(suiteName: "ClipHelmSnapshots-\(UUID().uuidString)")!
        let navigation = NavigationState(defaults: defaults)
        navigation.inspectorVisible = false
        navigation.route = route
        return navigation
    }

    private func renderLight<Content: View>(_ name: String, size: CGSize,
                                          @ViewBuilder content: @escaping () -> Content) throws {
        try render(content(), name: name, size: size, appearance: NSAppearance(named: .aqua)!)
    }

    private func render<Content: View>(_ view: Content, name: String, size: CGSize,
                                       appearance: NSAppearance) throws {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = appearance
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderBack(nil)
        // Let tasks (thumbnails, stores) settle before drawing.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("No bitmap for \(name)"); return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appending(path: "\(name).png"))
        window.orderOut(nil)
    }
}
