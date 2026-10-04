import AppKit
import AVFoundation
import AVKit
import SwiftUI
import ClipHelmCore
import ClipHelmSources
import ClipHelmRendering

private struct ReviewSelection: Identifiable {
    let clipID: ClipID
    let autoplay: Bool
    var id: UUID { clipID.rawValue }
}

struct ClipResultsView: View {
    let project: ProjectRecord
    let source: PreparedSource?
    let exportsDirectory: URL?
    let cacheDirectory: URL?
    let saveClip: @MainActor (ProjectClipRecord) throws -> Void
    let deleteClip: @MainActor (ClipID) throws -> Void

    @State private var selected: Set<ClipID> = []
    @State private var reviewing: ReviewSelection?
    @State private var deleting: ClipID?
    @State private var exportJob: Task<Void, Never>?
    @State private var exporting = false
    @State private var exportFraction = 0.0
    @State private var message: String?
    @State private var messageTone: StatusTone = .info

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                Text("Generated clips").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if !project.clips.isEmpty {
                    Text("\(project.clips.count)")
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, DS.Space.xs)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .accessibilityLabel("\(project.clips.count) clips")
                }
                Spacer()
                if !project.clips.isEmpty {
                    if selected.isEmpty {
                        Button("Select All") { selected = Set(downloadableClips.map(\.id)) }
                            .disabled(exporting)
                    } else {
                        Text("\(selected.count) selected")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Deselect All") { selected.removeAll() }
                            .disabled(exporting)
                    }
                    // One download action that follows the selection, rather than two
                    // filled buttons where one is always disabled.
                    Button {
                        chooseExportFolder(for: selected.isEmpty
                            ? downloadableClips
                            : project.clips.filter { selected.contains($0.id) })
                    } label: {
                        Label(selected.isEmpty ? "Download All" : "Download \(selected.count) Selected",
                              systemImage: "arrow.down.circle")
                    }
                    .primaryAction(ready: !exporting && exportsDirectory != nil && !downloadableClips.isEmpty)
                }
            }
            if project.clips.isEmpty {
                ContentUnavailableView("No clips yet", systemImage: "film.stack",
                    description: Text("Process this project to see its clips here."))
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .surfaceCard()
            } else if let exportsDirectory {
                // Capped widths keep tall 9:16 cards from growing past a comfortable height.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: isVerticalOutput ? 170 : 260,
                                                       maximum: isVerticalOutput ? 220 : 360),
                                             spacing: DS.Space.md, alignment: .top)],
                          alignment: .leading, spacing: DS.Space.md) {
                    ForEach(rankedClips) { clip in
                        resultCard(clip, directory: exportsDirectory)
                    }
                }
            }
            if exporting {
                TaskProgressRow(label: "Exporting clips…", fraction: exportFraction) {
                    exportJob?.cancel()
                }
                .surfaceCard()
            }
            if let message {
                StatusMessage(text: message, tone: messageTone)
            }
        }
        .sheet(item: $reviewing) { selection in
            if let clip = project.clips.first(where: { $0.id == selection.clipID }),
               let exportsDirectory {
                ClipReviewView(clip: clip, project: project, source: source,
                    exportsDirectory: exportsDirectory, cacheDirectory: cacheDirectory,
                    autoplay: selection.autoplay, saveClip: saveClip,
                    exportClip: { chooseExportFolder(for: [$0]) },
                    deleteClip: { id in
                        try deleteClip(id)
                        selected.remove(id)
                        reviewing = nil
                    })
            }
        }
        .confirmationDialog("Delete this clip from the project?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Delete Clip", role: .destructive) {
                guard let id = deleting else { return }
                do {
                    try deleteClip(id)
                    selected.remove(id)
                } catch { show("The clip could not be removed. Try again.", .error) }
                deleting = nil
            }
        } message: {
            Text("Its generated project files will be removed. Files already exported elsewhere stay untouched.")
        }
        .onDisappear { exportJob?.cancel() }
    }

    /// Clips whose final file exists, so they can be exported.
    private var downloadableClips: [ProjectClipRecord] {
        guard let exportsDirectory else { return [] }
        return project.clips.filter {
            FileManager.default.fileExists(atPath: exportsDirectory.appending(path: $0.finalFileName).path)
        }
    }

    /// Most promising clips first.
    private var rankedClips: [ProjectClipRecord] {
        project.clips.sorted { ($0.viralPotential ?? 0) > ($1.viralPotential ?? 0) }
    }

    private var isVerticalOutput: Bool {
        project.outputFormat.height > project.outputFormat.width
    }

    private func show(_ text: String, _ tone: StatusTone) {
        message = text
        messageTone = tone
    }

    private func resultCard(_ clip: ProjectClipRecord, directory: URL) -> some View {
        ResultCard(clip: clip, directory: directory,
            isSelected: Binding(
                get: { selected.contains(clip.id) },
                set: { if $0 { selected.insert(clip.id) } else { selected.remove(clip.id) } }),
            selecting: !selected.isEmpty, exporting: exporting,
            play: { reviewing = ReviewSelection(clipID: clip.id, autoplay: true) },
            edit: { reviewing = ReviewSelection(clipID: clip.id, autoplay: false) },
            download: { chooseExportFolder(for: [clip]) },
            delete: { deleting = clip.id })
    }

    private func chooseExportFolder(for clips: [ProjectClipRecord]) {
        guard !clips.isEmpty, let exportsDirectory else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Clips"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                let items = clips.map { ClipExportItem(title: $0.title,
                    fileURL: exportsDirectory.appending(path: $0.finalFileName)) }
                exporting = true
                exportFraction = 0
                message = nil
                exportJob = Task { @MainActor in
                    do {
                        let files = try await ClipExporter().export(items,
                            from: exportsDirectory, to: destination) { fraction in
                            Task { @MainActor in exportFraction = fraction }
                        }
                        show("Exported \(files.count) \(files.count == 1 ? "clip" : "clips").", .success)
                    } catch is CancellationError {
                        show("Export cancelled. No new files were kept.", .info)
                    } catch let error as LocalizedError {
                        show(error.errorDescription ?? "Export failed. Check the destination and try again.", .error)
                    } catch {
                        show("Export failed. Check the destination and try again.", .error)
                    }
                    exporting = false
                }
            }
        }
    }
}

/// One generated clip. The play glyph and selection checkbox appear on hover, or
/// whenever a selection is in progress, so a grid of 20+ clips reads as pictures
/// rather than as rows of controls. Every action is also in the context menu.
private struct ResultCard: View {
    let clip: ProjectClipRecord
    let directory: URL
    @Binding var isSelected: Bool
    let selecting: Bool
    let exporting: Bool
    let play: () -> Void
    let edit: () -> Void
    let download: () -> Void
    let delete: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasPreview: Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: clip.previewFileName).path)
    }
    private var hasFinal: Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: clip.finalFileName).path)
    }
    private var vertical: Bool { clip.spec.outputFormat.height > clip.spec.outputFormat.width }
    private var showsControls: Bool { hovering || selecting || isSelected }

    var body: some View {
        let hasPreview = hasPreview
        let hasFinal = hasFinal
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button(action: play) {
                ResultThumbnail(url: directory.appending(path: clip.previewFileName),
                                aspectRatio: vertical ? 9 / 16 : 16 / 9)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Text(ClipTimeLabel.duration(clip.spec))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(DS.Space.xs)
                    }
                    .overlay(alignment: .topTrailing) {
                        if let viral = clip.viralPotential {
                            ViralBadge(value: viral).padding(DS.Space.xs)
                        }
                    }
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 40))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                            .opacity(hasPreview && hovering ? 0.95 : 0)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressableCard)
            .disabled(!hasPreview)
            .help("Play \(clip.title)")
            .accessibilityLabel("Play \(clip.title)")
            .overlay(alignment: .topLeading) {
                Toggle("Select \(clip.title)", isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                    .padding(DS.Space.xs)
                    .disabled(exporting || !hasFinal)
                    // Hidden visually until needed; still reachable by keyboard and VoiceOver.
                    .opacity(showsControls ? 1 : 0)
            }

            // Two reserved lines keep cards in a row the same height.
            Text(clip.title).font(.headline)
                .lineLimit(2, reservesSpace: true)
                .help(clip.title)
            Text("Source \(ClipTimeLabel.source(clip.spec)) · \(ClipTimeLabel.aspect(clip.spec.outputFormat))")
                .font(.callout).foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            if !clip.proposal.rationale.isEmpty {
                Text(clip.proposal.rationale)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .help(clip.proposal.rationale)
            }
            if !hasPreview || !hasFinal {
                StatusMessage(text: "A generated file is missing. Reprocess the source or remove this clip from the project.",
                              tone: .warning)
            }
            HStack(spacing: DS.Space.xs) {
                Button("Edit", action: edit)
                    .disabled(!hasPreview)
                Button(action: download) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(exporting || !hasFinal)
                .help("Save this clip, with its captions, to a folder")
                Spacer(minLength: 0)
                Menu {
                    menuItems(hasPreview: hasPreview, hasFinal: hasFinal)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("More actions for \(clip.title)")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(DS.Space.xs)
        .background(isSelected ? DS.accent.opacity(0.08) : DS.surface,
                    in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(isSelected ? DS.accent : DS.hairline, lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        .contextMenu { menuItems(hasPreview: hasPreview, hasFinal: hasFinal) }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : DS.Motion.quick, value: showsControls)
        .animation(reduceMotion ? nil : DS.Motion.quick, value: hovering)
    }

    @ViewBuilder
    private func menuItems(hasPreview: Bool, hasFinal: Bool) -> some View {
        Button("Play", action: play).disabled(!hasPreview)
        Button("Edit…", action: edit).disabled(!hasPreview)
        Button("Download…", action: download).disabled(exporting || !hasFinal)
        Button(isSelected ? "Deselect" : "Select") { isSelected.toggle() }
            .disabled(exporting || !hasFinal)
        Divider()
        Button("Delete from Project…", role: .destructive, action: delete)
    }
}

private struct ResultThumbnail: View {
    let url: URL
    let aspectRatio: CGFloat
    @State private var image: NSImage?

    var body: some View {
        // The shape sets the size; the frame is an overlay so it can never resize the cell.
        DS.videoBackground
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "film")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .clipped()
            .accessibilityLabel("Video preview")
        .task(id: url) {
            image = nil
            // Large enough for a sharp card thumbnail in either orientation.
            image = await ClipFrame.thumbnail(of: url, maxDimension: 540)
        }
    }
}

/// Thumbnails for generated clips, taken a second in so fade-ins and cut-ins
/// don't leave a black cover.
enum ClipFrame {
    static func thumbnail(of url: URL, maxDimension: CGFloat) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ]))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        var frame = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        if frame == nil { frame = try? await generator.image(at: .zero).image }
        return frame.map { NSImage(cgImage: $0, size: .zero) }
    }
}

private enum ClipTimeLabel {
    static func clock(_ time: MediaTime) -> String {
        let seconds = time.microseconds / 1_000_000
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }

    static func duration(_ spec: ClipHelmEditSpec) -> String {
        let micros = spec.segments.reduce(Int64(0)) { $0 + $1.sourceRange.durationMicroseconds }
        let seconds = micros / 1_000_000
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }

    static func source(_ spec: ClipHelmEditSpec) -> String {
        guard let first = spec.segments.first, let last = spec.segments.last else { return "—" }
        return "\(clock(first.sourceRange.start))–\(clock(last.sourceRange.end))"
    }

    static func aspect(_ format: OutputFormat) -> String {
        format.height > format.width ? "9:16" : "16:9"
    }
}

struct ClipReviewView: View {
    let project: ProjectRecord
    let source: PreparedSource?
    let exportsDirectory: URL
    let cacheDirectory: URL?
    let saveClip: @MainActor (ProjectClipRecord) throws -> Void
    let exportClip: @MainActor (ProjectClipRecord) -> Void
    let deleteClip: @MainActor (ClipID) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var current: ProjectClipRecord
    @State private var player: AVPlayer
    @State private var title: String
    @State private var framing: FramingMode
    @State private var pacing: PacingMode
    @State private var captions: CaptionStyle?
    @State private var trimStart: Double
    @State private var trimEnd: Double
    @State private var focusX: Double
    @State private var focusY: Double
    @State private var busy = false
    @State private var renderStage = ""
    @State private var renderFraction = 0.0
    @State private var job: Task<Void, Never>?
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @State private var messageTone: StatusTone = .info
    private let autoplay: Bool

    init(clip: ProjectClipRecord, project: ProjectRecord, source: PreparedSource?,
         exportsDirectory: URL, cacheDirectory: URL?, autoplay: Bool,
         saveClip: @escaping @MainActor (ProjectClipRecord) throws -> Void,
         exportClip: @escaping @MainActor (ProjectClipRecord) -> Void,
         deleteClip: @escaping @MainActor (ClipID) throws -> Void) {
        self.project = project
        self.source = source
        self.exportsDirectory = exportsDirectory
        self.cacheDirectory = cacheDirectory
        self.saveClip = saveClip
        self.exportClip = exportClip
        self.deleteClip = deleteClip
        self.autoplay = autoplay
        _current = State(initialValue: clip)
        _player = State(initialValue: AVPlayer(playerItem: Self.localItem(
            exportsDirectory.appending(path: clip.previewFileName))))
        _title = State(initialValue: clip.title)
        _framing = State(initialValue: clip.spec.framingMode)
        _pacing = State(initialValue: clip.spec.pacingMode)
        _captions = State(initialValue: clip.spec.captionStyle)
        let trim = clip.trimRange ?? clip.proposal.range
        _trimStart = State(initialValue: Double(trim.start.microseconds) / 1_000_000)
        _trimEnd = State(initialValue: Double(trim.end.microseconds) / 1_000_000)
        let rect = clip.spec.cropPaths.first?.keyframes.first?.rect
        _focusX = State(initialValue: rect.map { $0.x + $0.width / 2 } ?? 0.5)
        _focusY = State(initialValue: rect.map { $0.y + $0.height / 2 } ?? 0.5)
    }

    private var isVertical: Bool {
        current.spec.outputFormat.height > current.spec.outputFormat.width
    }

    private var editingLocked: Bool { busy || source == nil || cacheDirectory == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.md)
            Divider()
            // Tall clips sit beside the controls; wide clips sit above them.
            if isVertical {
                HStack(alignment: .top, spacing: 0) {
                    playerView
                        .aspectRatio(9 / 16, contentMode: .fit)
                        .frame(maxWidth: 340)
                        .padding(DS.Space.lg)
                    Divider()
                    editorForm
                }
            } else {
                VStack(spacing: 0) {
                    playerView
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 340)
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.top, DS.Space.md)
                    editorForm
                }
            }
            Divider()
            footer
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.sm)
                .background(.bar)
        }
        .frame(minWidth: isVertical ? 760 : 560, idealWidth: isVertical ? 880 : 720,
               minHeight: 560, idealHeight: 800)
        .interactiveDismissDisabled(hasUnsavedChanges)
        .onAppear { if autoplay { player.play() } }
        .onDisappear { player.pause(); job?.cancel() }
        .confirmationDialog("Delete this clip from the project?", isPresented: $confirmDelete) {
            Button("Delete Clip", role: .destructive) {
                do { try deleteClip(current.id) }
                catch { show("The clip could not be removed. Try again.", .error) }
            }
        } message: {
            Text("Its generated project files will be removed. Files already exported elsewhere stay untouched.")
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("The clip keeps its last saved title, framing, pacing, trim, and captions.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review Clip").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("\(ClipTimeLabel.duration(current.spec)) · Source \(ClipTimeLabel.source(current.spec)) · \(ClipTimeLabel.aspect(current.spec.outputFormat))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasUnsavedChanges {
                StatusBadge(text: "Unsaved changes", tone: .warning)
            }
            Button("Done") { requestDismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var playerView: some View {
        NativeVideoPlayer(player: player)
            .background(DS.videoBackground)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
    }

    private var editorForm: some View {
        Form {
            if source == nil || cacheDirectory == nil {
                Section {
                    StatusMessage(text: "Locate the original video in the workspace to edit framing, pacing, trim, or captions. Rename, playback, and export still work.",
                                  tone: .info)
                }
            }
            Section("Clip") {
                TextField("Title", text: $title)
                LabeledContent("Output", value: "\(current.spec.outputFormat.width) × \(current.spec.outputFormat.height)")
            }
            Section("Framing") {
                Picker("Mode", selection: $framing) {
                    ForEach([FramingMode.smartAuto, .fullFrame, .classicFullFrame, .blurred], id: \.self) {
                        Label($0.label, systemImage: $0.symbol).tag($0)
                    }
                }
                Text(framing.description).font(.callout).foregroundStyle(.secondary)
                if framing == .fullFrame {
                    LabeledContent("Horizontal focus") {
                        Slider(value: $focusX, in: 0...1) {
                            Text("Horizontal focus")
                        } minimumValueLabel: {
                            Image(systemName: "arrow.left").accessibilityHidden(true)
                        } maximumValueLabel: {
                            Image(systemName: "arrow.right").accessibilityHidden(true)
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    LabeledContent("Vertical focus") {
                        Slider(value: $focusY, in: 0...1) {
                            Text("Vertical focus")
                        } minimumValueLabel: {
                            Image(systemName: "arrow.up").accessibilityHidden(true)
                        } maximumValueLabel: {
                            Image(systemName: "arrow.down").accessibilityHidden(true)
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }
                Button("Regenerate Framing") {
                    framing = .smartAuto
                    focusX = 0.5
                    focusY = 0.5
                    saveChanges(forceRender: true)
                }
                .disabled(editingLocked)
                .help("Reset to Smart Auto Frame and render again")
            }
            .disabled(editingLocked)
            Section("Pacing and Trim") {
                Picker("Pacing", selection: $pacing) {
                    ForEach(PacingMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(pacing.detail).font(.callout).foregroundStyle(.secondary)
                LabeledContent("In") {
                    HStack {
                        TextField("In", value: $trimStart,
                            format: .number.precision(.fractionLength(2)))
                            .labelsHidden()
                            .monospacedDigit()
                            .frame(width: 90)
                        Text("seconds in source").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Out") {
                    HStack {
                        TextField("Out", value: $trimEnd,
                            format: .number.precision(.fractionLength(2)))
                            .labelsHidden()
                            .monospacedDigit()
                            .frame(width: 90)
                        Text("seconds in source").foregroundStyle(.secondary)
                    }
                }
                Text("Available: \(ClipTimeLabel.clock(current.proposal.range.start))–\(ClipTimeLabel.clock(current.proposal.range.end)). Pacing recalculates pause cuts inside the trim.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(editingLocked)
            Section("Captions") {
                Picker("Style", selection: $captions) {
                    Text("Off").tag(nil as CaptionStyle?)
                    ForEach(CaptionStyle.pickerOrder, id: \.self) { style in
                        Text(style.label).tag(Optional(style))
                    }
                }
                .disabled(project.transcript?.hasMeaningfulSpeech != true)
                if let captions {
                    CaptionStyleSwatch(style: captions)
                        .frame(height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                }
                if project.transcript?.hasMeaningfulSpeech != true {
                    Text("No meaningful speech was found for captions.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(editingLocked)
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if busy {
                TaskProgressRow(label: renderStage, fraction: renderFraction) { job?.cancel() }
            } else if let message {
                StatusMessage(text: message, tone: messageTone)
            }
            HStack(spacing: DS.Space.sm) {
                Button("Delete from Project", role: .destructive) { confirmDelete = true }
                    .disabled(busy)
                Spacer()
                Button {
                    exportClip(current)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(busy || hasUnsavedChanges)
                .help(hasUnsavedChanges ? "Save changes before exporting" : "Export this clip")
                Button("Save Changes") { saveChanges() }
                    .primaryAction(ready: !busy && hasUnsavedChanges)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .controlSize(.large)
        }
    }

    private func requestDismiss() {
        if hasUnsavedChanges && !busy { confirmDiscard = true } else { dismiss() }
    }

    private func show(_ text: String, _ tone: StatusTone) {
        message = text
        messageTone = tone
    }

    private var hasUnsavedChanges: Bool {
        let trim = current.trimRange ?? current.proposal.range
        let firstFocus = current.spec.cropPaths.first?.keyframes.first?.rect
        let savedX = firstFocus.map { $0.x + $0.width / 2 } ?? 0.5
        let savedY = firstFocus.map { $0.y + $0.height / 2 } ?? 0.5
        return title.trimmingCharacters(in: .whitespacesAndNewlines) != current.title ||
            framing != current.spec.framingMode || pacing != current.spec.pacingMode ||
            captions != current.spec.captionStyle ||
            abs(trimStart - Double(trim.start.microseconds) / 1_000_000) > 0.000_01 ||
            abs(trimEnd - Double(trim.end.microseconds) / 1_000_000) > 0.000_01 ||
            (framing == .fullFrame && (abs(focusX - savedX) > 0.000_01 ||
                                        abs(focusY - savedY) > 0.000_01))
    }

    private func saveChanges(forceRender: Bool = false) {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty, cleanedTitle.count <= 120,
              !cleanedTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            show("Use a title between 1 and 120 characters without control characters.", .error)
            return
        }
        let lower = Double(current.proposal.range.start.microseconds) / 1_000_000
        let upper = Double(current.proposal.range.end.microseconds) / 1_000_000
        guard trimStart.isFinite, trimEnd.isFinite, trimStart >= lower,
              trimEnd <= upper, trimEnd - trimStart >= 0.5 else {
            show("Keep trim times inside the available source range, at least half a second apart.", .error)
            return
        }
        do {
            let range = try MediaTimeRange(
                start: MediaTime(microseconds: Int64((trimStart * 1_000_000).rounded())),
                end: MediaTime(microseconds: Int64((trimEnd * 1_000_000).rounded())))
            let originalTrim = current.trimRange ?? current.proposal.range
            let currentFocus = current.spec.cropPaths.first?.keyframes.first?.rect
            let savedX = currentFocus.map { $0.x + $0.width / 2 } ?? 0.5
            let savedY = currentFocus.map { $0.y + $0.height / 2 } ?? 0.5
            let needsRender = forceRender || range != originalTrim ||
                framing != current.spec.framingMode || pacing != current.spec.pacingMode ||
                captions != current.spec.captionStyle ||
                (framing == .fullFrame && (abs(focusX - savedX) > 0.000_01 ||
                                            abs(focusY - savedY) > 0.000_01))
            guard needsRender else {
                var renamed = current
                renamed.title = cleanedTitle
                try saveClip(renamed)
                current = renamed
                show("Clip renamed.", .success)
                return
            }
            guard let source, let cacheDirectory else {
                show("Locate the original source in the workspace before changing this clip.", .warning)
                return
            }
            busy = true
            renderFraction = 0
            renderStage = "Preparing edit…"
            message = nil
            let options = ClipRevisionOptions(trimRange: range, framing: framing,
                pacing: pacing, captionStyle: captions, focusX: focusX,
                focusY: focusY, forceReframe: forceRender)
            let previous = current
            job = Task { @MainActor in
                let stem = "clip-\(previous.id.rawValue.uuidString)-\(UUID().uuidString)"
                let preview = exportsDirectory.appending(path: stem + "-preview.mp4")
                let final = exportsDirectory.appending(path: stem + ".mp4")
                defer { busy = false }
                do {
                    let spec = try await ClipRevisionPlanner().revise(previous,
                        source: source, transcript: project.transcript,
                        configuration: project.configuration,
                        cacheDirectory: cacheDirectory, options: options)
                    try Task.checkCancellation()
                    renderStage = "Rendering preview…"
                    _ = try await ClipRenderer().render(spec, sourceURL: source.fileURL,
                        asset: source.asset, outputURL: preview, quality: .preview) { update in
                        Task { @MainActor in renderFraction = update.fraction * 0.5 }
                    }
                    renderStage = "Rendering final clip…"
                    _ = try await ClipRenderer().render(spec, sourceURL: source.fileURL,
                        asset: source.asset, outputURL: final) { update in
                        Task { @MainActor in renderFraction = 0.5 + update.fraction * 0.5 }
                    }
                    try Task.checkCancellation()
                    var revised = previous
                    revised.spec = spec
                    revised.previewFileName = preview.lastPathComponent
                    revised.finalFileName = final.lastPathComponent
                    revised.title = cleanedTitle
                    revised.trimRange = range == previous.proposal.range ? nil : range
                    try saveClip(revised)
                    current = revised
                    if let rect = revised.spec.cropPaths.first?.keyframes.first?.rect {
                        focusX = rect.x + rect.width / 2
                        focusY = rect.y + rect.height / 2
                    }
                    player.pause()
                    player.replaceCurrentItem(with: Self.localItem(preview))
                    renderFraction = 1
                    show("Changes saved. Preview the new clip before exporting.", .success)
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: preview)
                    try? FileManager.default.removeItem(at: final)
                    show("Edit cancelled. The previous clip is unchanged.", .info)
                } catch let error as LocalizedError {
                    try? FileManager.default.removeItem(at: preview)
                    try? FileManager.default.removeItem(at: final)
                    show(error.errorDescription ?? "The edit could not be saved. Try again.", .error)
                } catch {
                    try? FileManager.default.removeItem(at: preview)
                    try? FileManager.default.removeItem(at: final)
                    show("The edit could not be saved. Check the original source and try again.", .error)
                }
            }
        } catch {
            show("The trim range is invalid.", .error)
        }
    }

    private static func localItem(_ url: URL) -> AVPlayerItem {
        AVPlayerItem(asset: AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ]))
    }
}

extension ProjectClipRecord {
    /// The model's estimate that this clip performs well; nil for visual-only picks.
    var viralPotential: Double? { proposal.score?.viralPotential }
}

/// Viral chance as a percentage with a word, so it never relies on color.
struct ViralBadge: View {
    let value: Double

    private var tone: (label: String, color: Color) {
        switch value {
        case 0.7...: ("High", .green)
        case 0.45..<0.7: ("Medium", .secondary)
        default: ("Low", .secondary)
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
            Text("\(Int((value * 100).rounded()))% · \(tone.label)")
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // Only a high estimate earns color; the rest sit quietly on the frame, so a
        // grid of mid-range clips is not a wall of orange warning pills.
        .background(value >= 0.7 ? Color.green.opacity(0.9) : Color.black.opacity(0.6), in: Capsule())
        .help("Viral chance: an estimate from the clip's hook, interest, completeness, and story")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Viral chance \(Int((value * 100).rounded())) percent, \(tone.label)")
    }
}
