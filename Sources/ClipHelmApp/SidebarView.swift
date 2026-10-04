import SwiftUI

/// What the sidebar list can select: a top-level destination or one project.
enum SidebarSelection: Hashable {
    case route(AppRoute)
    case project(UUID)
}

/// Brand header and New Clip Project on top, library and projects in the middle,
/// Settings pinned to the bottom. Creating a project is an action, not a place,
/// so it is a button rather than a row. It stays bordered rather than prominent so
/// each screen's own primary action is the only filled button in the window.
struct SidebarView: View {
    @ObservedObject var navigation: NavigationState
    let projects: [ProjectRecord]

    /// Enough to reach recent work in one click; the full list lives in Recent Projects.
    private let projectLimit = 8

    private var selection: Binding<SidebarSelection?> {
        Binding(
            get: {
                switch navigation.route {
                case .home, .recent: .route(navigation.route)
                case .workspace: navigation.selectedProjectID.map(SidebarSelection.project)
                case .newProject: nil
                }
            },
            set: { newValue in
                switch newValue {
                case .route(let route): navigation.route = route
                case .project(let id): navigation.openProject(id)
                case nil: break
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section("Library") {
                Label("Home", systemImage: "house")
                    .tag(SidebarSelection.route(.home))
                Label("Recent Projects", systemImage: "clock.arrow.circlepath")
                    .badge(projects.count)
                    .tag(SidebarSelection.route(.recent))
            }
            Section("Projects") {
                if projects.isEmpty {
                    Text("Projects you create appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(projects.prefix(projectLimit)) { project in
                        projectRow(project)
                            .tag(SidebarSelection.project(project.id.rawValue))
                    }
                    if projects.count > projectLimit {
                        Label("Show All \(projects.count)", systemImage: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                            .tag(SidebarSelection.route(.recent))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.xs) {
                AppLogo(size: 28)
                Text("ClipHelm")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Button {
                navigation.startProject()
            } label: {
                Label("New Clip Project", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("New Clip Project (⌘N)")
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.top, DS.Space.xs)
        .padding(.bottom, DS.Space.sm)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            SettingsLink {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "gearshape")
                        .frame(width: 20)
                    Text("Settings")
                    Spacer()
                    Text("⌘,")
                        .font(.callout.monospaced())
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, DS.Space.xs)
                .padding(.vertical, 6)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressableRow)
            .help("Open Settings (⌘,)")
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Space.xs)
        }
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        let vertical = project.outputFormat.height > project.outputFormat.width
        let status = project.clips.isEmpty
            ? "Draft"
            : "\(project.clips.count) \(project.clips.count == 1 ? "clip" : "clips")"
        // The date tells same-named projects apart.
        let detail = "\(status) · \(project.createdAt.formatted(.relative(presentation: .named)))"
        return Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(project.title).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            // Shape tells the canvas; a filled shape means clips exist, an outline a draft.
            Image(systemName: (vertical ? "rectangle.portrait" : "rectangle")
                  + (project.clips.isEmpty ? "" : ".fill"))
                .foregroundStyle(project.clips.isEmpty ? Color.secondary : DS.accent)
                .accessibilityHidden(true)
        }
        .help("\(project.title) — \(project.sourceLabel)")
        .accessibilityLabel("\(project.title), \(detail)")
    }
}
