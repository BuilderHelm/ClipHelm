import SwiftUI
import ClipHelmCore
import ClipHelmSources
import ClipHelmProcessing

struct AppShell: View {
    @ObservedObject var navigation: NavigationState
    @StateObject private var store: ProjectStore
    @State private var draft = ProjectDraft()
    @State private var errorMessage = ""
    @State private var showsError = false
    @StateObject private var pipeline = ClipPipeline()
    @State private var authorizedRemote = false

    init(navigation: NavigationState, store: ProjectStore = ProjectStore()) {
        self.navigation = navigation
        _store = StateObject(wrappedValue: store)
    }

    private var selectedProject: ProjectRecord? {
        store.projects.first { $0.id.rawValue == navigation.selectedProjectID }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { navigation.route == .workspace && navigation.inspectorVisible },
            set: { navigation.inspectorVisible = $0 }
        )
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(navigation: navigation, projects: store.projects)
        } detail: {
            Group {
                switch navigation.route {
                case .home: home
                case .recent: recent
                case .newProject:
                    WizardView(draft: $draft, step: $navigation.step, pipeline: pipeline,
                               authorizedRemote: $authorizedRemote, onSave: saveDraft)
                case .workspace:
                    if let selectedProject {
                        workspace(selectedProject)
                    } else {
                        ContentUnavailableView("Project unavailable", systemImage: "folder.badge.questionmark",
                                               description: Text("Choose a project from Recent Projects."))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .toolbar {
                // Actions live in the toolbar, as in Finder; the sidebar holds only places.
                ToolbarItemGroup(placement: .primaryAction) {
                    if navigation.route != .newProject {
                        Button {
                            navigation.startProject()
                        } label: {
                            Label("New Clip Project", systemImage: "plus")
                        }
                        .help("New Clip Project (⌘N)")
                    }
                    if navigation.route == .workspace {
                        Button {
                            navigation.inspectorVisible.toggle()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.right")
                        }
                        .help("Show or hide the inspector (⌘I)")
                    }
                }
            }
        }
        .inspector(isPresented: inspectorBinding) {
            if let selectedProject {
                inspector(selectedProject)
            }
        }
        .alert("Could not save project", isPresented: $showsError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            if let data = UserDefaults.standard.data(forKey: "draftPreferences"),
               let restored = try? JSONDecoder().decode(ProjectDraft.self, from: data) {
                draft = restored
            }
            if navigation.route == .workspace && selectedProject == nil {
                navigation.route = .recent
            }
        }
        .onChange(of: draft) { _, newValue in
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "draftPreferences")
            }
        }
    }

    private var title: String {
        switch navigation.route {
        case .home: "Home"
        case .recent: "Recent Projects"
        case .newProject: "New Clip Project"
        case .workspace: selectedProject?.title ?? "Project Workspace"
        }
    }

    /// Returning creators see their work right under the link field; the
    /// "how it works" primer is only for a first run with nothing to show yet.
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    // The sidebar already carries the logo, so the hero is words only.
                    Text("A better cut starts\nwith the right moment.")
                        .font(.system(size: 36, weight: .bold))
                        .tracking(-0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Paste a YouTube link and choose your clip options while it downloads. Then press Start and ClipHelm finds the best moments.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 600, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    QuickClipView(onContinue: continueWithLink)
                    HStack(spacing: DS.Space.xxs) {
                        Text("Working from a local file?")
                            .foregroundStyle(.secondary)
                        Button("Start a project from a file…") {
                            navigation.startProject()
                        }
                        .buttonStyle(.link)
                        .help("Choose a local file or customize format, framing, length, and captions (⌘N)")
                    }
                    .font(.callout)
                }

                if store.projects.isEmpty {
                    UniformGrid(minimumWidth: 200) {
                        howItWorks
                    }
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Recent Projects").font(.title2.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Button("View All \(store.projects.count)") { navigation.route = .recent }
                                .buttonStyle(.link)
                        }
                        projectList(Array(store.projects.prefix(4)))
                    }
                }
            }
            .readableColumn(DS.Width.form + 80, padding: DS.Space.xxl)
        }
    }

    @ViewBuilder
    private var howItWorks: some View {
        howItWorksStep(1, "Choose a source", "A local video or a YouTube link you may process.", "film")
        howItWorksStep(2, "Set the direction", "Format, framing, length, sound, and captions.", "slider.horizontal.3")
        howItWorksStep(3, "Review the clips", "Play, trim, reframe, and export what you keep.", "rectangle.stack.badge.play")
    }

    private func howItWorksStep(_ number: Int, _ title: String, _ detail: String,
                                _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(DS.accent)
                .frame(height: 28, alignment: .leading)
                .accessibilityHidden(true)
            Text("\(number). \(title)").font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surfaceCard()
        .accessibilityElement(children: .combine)
    }

    private var recent: some View {
        Group {
            if store.projects.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No Projects Yet")
                    } icon: {
                        AppLogo(size: 64)
                    }
                } description: {
                    Text("Start a new clip project to create a workspace.")
                } actions: {
                    Button("New Clip Project") {
                        navigation.startProject()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.lg) {
                        PageHeader(title: "Recent Projects",
                                   subtitle: "\(store.projects.count) \(store.projects.count == 1 ? "project" : "projects") saved on this Mac")
                        projectList(store.projects)
                    }
                    .readableColumn(DS.Width.form + 80, padding: DS.Space.xl)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let loadError = store.loadError {
                StatusMessage(text: loadError, tone: .warning)
                    .padding(DS.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
    }

    private func projectList(_ projects: [ProjectRecord]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                if index > 0 { Divider().padding(.leading, 64) }
                projectRow(project)
            }
        }
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(DS.hairline)
        }
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        ProjectRow(project: project, exportsDirectory: try? store.exportsDirectory(for: project.id)) {
            navigation.openProject(project.id.rawValue)
        }
    }

    private func workspace(_ project: ProjectRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                PageHeader(eyebrow: project.sourceLabel, title: project.title) {
                    StatusBadge(text: project.clips.isEmpty ? "Draft" : "\(project.clips.count) clips saved",
                                tone: project.clips.isEmpty ? .neutral : .success)
                }
                // Finished clips lead; before there are any, Start is the page's one action.
                if project.clips.isEmpty {
                    jobCard(project)
                } else {
                    results(project)
                    jobCard(project)
                }
                WorkspacePlaybackView(project: project, source: pipeline.sources[project.id],
                    analysisCacheDirectory: try? store.analysisCacheDirectory(for: project.id),
                    exportsDirectory: try? store.exportsDirectory(for: project.id),
                    ingestor: pipeline.ingestor,
                    saveTranscript: { try store.saveTranscript($0, for: project.id) },
                    saveProcessingResult: { try store.saveProcessingResult($0, for: project.id) },
                    reattachSource: { try await reattachSource($0, to: project) },
                    reattachRemote: { try await reattachRemote($0, authorized: $1,
                        to: project, progress: $2) })
            }
            .readableColumn(DS.Width.content, padding: DS.Space.lg)
        }
    }

    private func jobCard(_ project: ProjectRecord) -> some View {
        let job = pipeline.job(for: project.id)
        return ClipJobCard(job: job, hasClips: !project.clips.isEmpty,
                           startBlocker: startBlocker(project, job: job),
                           summary: jobSummary(project),
                           onStart: { pipeline.start(project, store: store) },
                           onCancel: { pipeline.cancel(project.id) })
            .task { await pipeline.loadCatalog() }
    }

    private func startBlocker(_ project: ProjectRecord, job: ClipJob) -> String? {
        if pipeline.sources[project.id] != nil { return nil }
        if let failure = job.source?.failure { return failure }
        if job.source != nil { return nil }
        return project.sourceKind == .local
            ? "Locate the original video below to start."
            : "Re-enter the video link below to start."
    }

    private func jobSummary(_ project: ProjectRecord) -> [(label: String, value: String)] {
        let configuration = project.configuration
        let lengths = configuration.selectedLengths.isEmpty
            ? "Auto length (10 s – 2 min)" : configuration.selectedLengths.map(\.label).joined(separator: ", ")
        let transcription: String
        if project.transcript != nil {
            transcription = "Saved transcript"
        } else if project.transcriptionModelID == ClipPipeline.onDeviceTranscription {
            transcription = "On this Mac"
        } else if let id = pipeline.resolvedTranscriptionModelID(project.transcriptionModelID) {
            transcription = pipeline.transcriptionModels.first { $0.id == id }?.name ?? id
        } else {
            transcription = "Recommended OpenRouter model (on this Mac without a key)"
        }
        return [
            ("Format", "\(configuration.outputFormat.width) × \(configuration.outputFormat.height) · \(configuration.framingMode.label)"),
            ("Captions", configuration.captionStyle?.label ?? "Off"),
            ("Clips", "\(configuration.requestedClipCount.map { "Up to \($0)" } ?? "AI decides") · \(lengths)"),
            ("Transcription", transcription),
            ("Moments", (project.momentModelID ?? pipeline.recommendedMomentModelID)
                .map { id in pipeline.momentModels.first { $0.id == id }?.name ?? id } ?? "Recommended model"),
        ]
    }

    private func results(_ project: ProjectRecord) -> some View {
        ClipResultsView(project: project, source: pipeline.sources[project.id],
            exportsDirectory: try? store.exportsDirectory(for: project.id),
            cacheDirectory: try? store.analysisCacheDirectory(for: project.id),
            saveClip: { try store.updateClip($0, for: project.id) },
            deleteClip: { try store.deleteClip($0, from: project.id) })
    }

    private func inspector(_ project: ProjectRecord) -> some View {
        Form {
            Section("Project") {
                LabeledContent("Status", value: project.clips.isEmpty ? "Draft" : "\(project.clips.count) clips saved")
                LabeledContent("Source", value: project.sourceLabel)
                LabeledContent("Type", value: project.sourceKind.rawValue)
                if let asset = project.mediaAsset {
                    LabeledContent("Source size", value: "\(asset.width) × \(asset.height)")
                    LabeledContent("Duration", value: Self.durationLabel(asset.duration))
                }
            }
            Section("Output") {
                LabeledContent("Canvas", value: "\(project.outputFormat.width) × \(project.outputFormat.height)")
                LabeledContent("Framing", value: project.framingMode.label)
                LabeledContent("Pacing", value: project.configuration.pacingMode.label)
                LabeledContent("Number", value: project.configuration.requestedClipCount.map { "Up to \($0)" } ?? "AI decides")
                LabeledContent("Sound", value: project.configuration.soundMode == .normalize ? "Normalize" : "Original")
                LabeledContent("Captions", value: project.captionStyle?.label ?? "Off")
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 240, ideal: 280, max: 340)
    }

    private func saveDraft() {
        do {
            var saving = draft
            let prepared = pipeline.draftSource?.prepared
            if saving.title == ProjectDraft().title, let title = prepared?.title { saving.title = title }
            let project = try store.save(draft: saving, mediaAsset: prepared?.asset)
            pipeline.adoptDraftSource(for: project.id)
            // Keep the chosen options as the next project's defaults; only the source resets.
            draft.title = ProjectDraft().title
            draft.remoteURL = ""
            draft.sourceName = ""
            authorizedRemote = false
            navigation.openProject(project.id.rawValue)
        } catch {
            errorMessage = "Check the source and project name, then try again."
            showsError = true
        }
    }

    /// Home's link entry: start the download and continue to the clip options.
    private func continueWithLink(_ link: String, descriptor: SourceDescriptor) {
        draft.sourceKind = .youtube
        draft.remoteURL = link
        authorizedRemote = true
        pipeline.prepareDraftSource(descriptor)
        navigation.step = .format
        navigation.route = .newProject
    }

    private func reattachSource(_ url: URL, to project: ProjectRecord) async throws {
        guard project.sourceKind == .local, let original = project.mediaAsset,
              url.lastPathComponent == project.sourceLabel else {
            throw SourceIngestError.invalidMedia
        }
        let prepared = try await pipeline.ingestor.prepare(SourceDescriptor(localFile: url))
        guard prepared.asset.duration == original.duration,
              prepared.asset.width == original.width,
              prepared.asset.height == original.height else {
            throw SourceIngestError.invalidMedia
        }
        pipeline.setSource(PreparedSource(descriptor: prepared.descriptor,
            fileURL: prepared.fileURL, asset: original, hasAudio: prepared.hasAudio), for: project.id)
    }

    private func reattachRemote(_ rawURL: String, authorized: Bool,
                                to project: ProjectRecord,
                                progress: @escaping @Sendable (SourceProgress) -> Void) async throws {
        guard project.sourceKind != .local, let original = project.mediaAsset else {
            throw SourceIngestError.invalidMedia
        }
        let descriptor = try SourceDescriptor(remoteURL: rawURL,
            youtube: project.sourceKind == .youtube, authorized: authorized)
        guard URLComponents(string: rawURL)?.host?.lowercased() == project.sourceLabel else {
            throw SourceIngestError.invalidMedia
        }
        let prepared = try await pipeline.ingestor.prepare(descriptor, progress: progress)
        try Task.checkCancellation()
        guard prepared.asset.duration == original.duration,
              prepared.asset.width == original.width,
              prepared.asset.height == original.height else {
            throw SourceIngestError.invalidMedia
        }
        pipeline.setSource(PreparedSource(descriptor: descriptor,
            fileURL: prepared.fileURL, asset: original, hasAudio: prepared.hasAudio), for: project.id)
    }

    private static func durationLabel(_ duration: MediaTime) -> String {
        let seconds = duration.microseconds / 1_000_000
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct ProjectRow: View {
    let project: ProjectRecord
    let exportsDirectory: URL?
    let open: () -> Void
    @State private var hovering = false

    /// A frame from the strongest clip, so a project is recognizable at a glance.
    private var coverURL: URL? {
        guard let exportsDirectory else { return nil }
        let best = project.clips.max { ($0.viralPotential ?? 0) < ($1.viralPotential ?? 0) }
        return best.map { exportsDirectory.appending(path: $0.previewFileName) }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: DS.Space.sm) {
                ProjectCover(url: coverURL, vertical: project.outputFormat.height > project.outputFormat.width)
                    .frame(width: 56, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title).font(.headline).lineLimit(1)
                    Text("\(project.sourceLabel) · \(project.clips.isEmpty ? "Draft" : "\(project.clips.count) clips")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: DS.Space.xs)
                // Relative, matching the sidebar, so one project never shows two date styles.
                Text(project.createdAt.formatted(.relative(presentation: .named)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(project.createdAt.formatted(date: .long, time: .shortened))
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.sm)
            .background(hovering ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
        .onHover { hovering = $0 }
        .help(project.title)
        .accessibilityLabel("Open \(project.title)")
    }
}

/// A project's thumbnail: a frame from its best clip, or the canvas shape for drafts.
private struct ProjectCover: View {
    let url: URL?
    let vertical: Bool
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(image == nil ? AnyShapeStyle(DS.accent.opacity(0.1)) : AnyShapeStyle(DS.videoBackground))
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: vertical ? "rectangle.portrait" : "rectangle")
                        .font(.title3)
                        .foregroundStyle(DS.accent)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
            .task(id: url) {
                image = nil
                guard let url else { return }
                image = await ClipFrame.thumbnail(of: url, maxDimension: 160)
            }
    }
}

extension FramingMode {
    var label: String {
        switch self {
        case .smartAuto: "Smart Auto Frame"
        case .fullFrame: "Full Frame"
        case .classicFullFrame: "Classic Full Frame"
        case .blurred: "Blurred"
        }
    }

    var description: String {
        switch self {
        case .smartAuto: "Follow the subject and important on-screen content."
        case .fullFrame: "Fill the canvas while keeping important content in view."
        case .classicFullFrame: "Keep the complete original frame, adding bars when needed."
        case .blurred: "Keep the full frame over a soft, blurred background."
        }
    }
}

extension PacingMode {
    var label: String { rawValue.capitalized }
}

extension CaptionStyle {
    var label: String {
        switch self {
        case .pop: "Pop"
        case .spotlight: "Spotlight"
        case .impact: "Impact"
        case .glowBox: "Glow Box"
        case .editorial: "Editorial"
        case .highPunch: "High Punch"
        case .neonHeadline: "Neon Headline"
        case .paper: "Paper"
        }
    }
}
