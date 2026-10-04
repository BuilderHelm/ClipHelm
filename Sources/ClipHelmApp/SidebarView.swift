import SwiftUI

/// What the sidebar list can select: a top-level destination or one project.
enum SidebarSelection: Hashable {
    case route(AppRoute)
    case project(UUID)
}

/// A Finder-style source list: Library destinations, then recent projects. Actions
/// (New Clip Project) live in the window toolbar and Settings in the app menu (⌘,),
/// so the sidebar holds only places to go.
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
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        let vertical = project.outputFormat.height > project.outputFormat.width
        let status = project.clips.isEmpty
            ? "Draft"
            : "\(project.clips.count) \(project.clips.count == 1 ? "clip" : "clips")"
        let detail = "\(status) · \(project.createdAt.formatted(.relative(presentation: .named)))"
        // One line per row, as in Finder. The canvas shape is the icon (filled once
        // clips exist, outlined while a draft) and the clip count is the badge.
        return Label(project.title,
                     systemImage: (vertical ? "rectangle.portrait" : "rectangle")
                        + (project.clips.isEmpty ? "" : ".fill"))
            .lineLimit(1)
            .badge(project.clips.count)
            .help("\(project.title) — \(detail) · \(project.sourceLabel)")
            .accessibilityLabel("\(project.title), \(detail)")
    }
}
