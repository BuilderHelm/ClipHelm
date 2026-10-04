import SwiftUI

/// The app's Settings window (⌘,). A separate window, as on every Mac app, so
/// changing a key or updating the downloader never replaces the work on screen.
struct SettingsView: View {
    private enum Tab: Hashable { case general, openRouter, downloader }
    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            pane { OpenRouterSettingsView() }
                .tabItem { Label("OpenRouter", systemImage: "key") }
                .tag(Tab.openRouter)
            pane { YouTubeToolSettingsView() }
                .tabItem { Label("Downloader", systemImage: "arrow.down.circle") }
                .tag(Tab.downloader)
        }
        .frame(width: 560)
        .tint(DS.accent)
    }

    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) { content() }
            .padding(DS.Space.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var general: some View {
        Form {
            Section {
                HStack(spacing: DS.Space.md) {
                    AppLogo(size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ClipHelm").font(.headline)
                        Text(Self.versionLabel).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Storage") {
                LabeledContent("Appearance", value: "Follows macOS")
                LabeledContent("Projects", value: "Application Support › ClipHelm › Projects")
                Text("Project drafts and source metadata are saved on this Mac. Source access must be granted again after relaunch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Keyboard Shortcuts") {
                shortcut("New project", "⌘N")
                shortcut("Home / Recent Projects", "⌘1 / ⌘2")
                shortcut("Settings", "⌘,")
                shortcut("Toggle inspector", "⌘I")
                shortcut("Previous / next setup step", "⌘[ / ⌘]")
                shortcut("Start making clips", "⌘↩")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) {
            Text(keys).monospaced().foregroundStyle(.secondary)
        }
    }

    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }
}
