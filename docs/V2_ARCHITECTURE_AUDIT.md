# V2 architecture audit

Phase V2-0, 2026-09-27. Audit of ClipHelm V1 (`main` at `60ef11b`) before any V2 product work. It records what V2 can build on unchanged, what it must extend or version, and where the structure is risky.

## How the audit was done

Each area was read in source and checked against its tests. Persisted formats were then exercised for real: a copy of the ten projects on the development Mac (formats 1, 3, and 4) was opened with the V2-0 code and compared byte for byte (`V2MigrationTests.testOptInRealV1ProjectsOpenUnchanged`). All ten opened; none was modified.

## Inventory

| Area | Where | Current state | V2 verdict |
| --- | --- | --- | --- |
| Time and IDs | `ClipHelmCore/IdentityAndTime.swift` | Integer-microsecond `MediaTime`, half-open `MediaTimeRange`, typed `ProjectID`/`AssetID`/`ClipID` | **Keep.** V2 types reuse them; new IDs use `Identifier<Tag>` |
| Project model | `ClipHelmApp/ProjectStore.swift` | `ProjectRecord` format 4 → **5**, atomic writes, launch validation, interrupted-render cleanup | **Versioned** (format 5, V2 metadata). **Risk:** lives in the app target |
| Project persistence | same | Five separate write sites | **Consolidated** into one `writeManifest` with pre-upgrade backup |
| EditSpec | `ClipHelmCore/EditingModels.swift`, `EditSpecOperations.swift` | Format 3; reads 1–3; rejects newer; strict validation | **Keep 3 for now.** Director, motion, emphasis, and brand fields arrive as format 4 (additive) |
| Timeline | `ClipHelmEditing/EditTimeline.swift`, `EditHistory.swift` | Source↔edited mapping; in-memory undo/redo | **Keep.** Transcript editing (V2-9) extends typed operations |
| Source ingestion | `ClipHelmSources` | Local files, YouTube via verified yt-dlp, DASH mux | **Keep** |
| OpenRouter | `ClipHelmOpenRouter` | One gateway; one method per task (proposal, framing, layout, transcription); strict JSON schemas | **Extend.** V2 adds several structured tasks; see risk 4 |
| Transcription | `ClipHelmTranscription` | OpenRouter (word-timed, parallel) and on-device (`SpeechAnalyzer`, legacy fallback) | **Keep** |
| Scene analysis, subjects | `ClipHelmAnalysis` | Local scenes, motion, audio, pauses, faces, text density, content labels; cache format 1 | **Keep.** MomentGraph consumes it |
| Moment discovery | `ClipHelmMoments` | Local candidates, bounded model ratings, viral potential, short-form default; results not persisted | **Extend** in V2-1/V2-2 with MomentGraph input and persistence |
| Framing | `ClipHelmFraming`, `ClipHelmFramingVision` | Damped crop paths per scene; optional vision hints | **Keep.** Director Engine (V2-4) decides *what*; framing still computes geometry |
| Layouts | `ClipHelmLayouts`, `ClipHelmLayoutVision` | Seven `ShotLayout`s with hysteresis; OCR screen subtypes | **Extend** with `ScreenRegion`/`DemoEvent` in V2-6 |
| Pacing | `ClipHelmPacing` | Dead air, long pauses, fillers; demo protection | **Keep** |
| Captions | `ClipHelmCaptions` | Word track, phrase grouping, eight styles, shared preview/export drawing | **Extend** with `CaptionEmphasis` and brand styling (V2-7, V2-10) |
| Rendering | `ClipHelmRendering` | AVFoundation + CoreImage compositor; 9:16 and 16:9 at 1080/2160 | **Extend** for motion, brand marks, and new canvases |
| Export | `ClipHelmApp/ClipExporter.swift` | Safe copies to a chosen folder | **Keep** |
| App pipeline | `ClipHelmApp/ClipPipeline.swift` | App-owned jobs, phases, download-while-choosing | **Keep.** New phases slot into its phase list |
| Tests | 22 targets | 140 tests before V2-0; live tests opt-in | **Keep.** V2-0 adds 25 (see below) |

## What stays unchanged

- Media time, ranges, and IDs.
- Source ingestion and the YouTube tool manager.
- The Keychain vault and the single OpenRouter gateway.
- Transcription backends and `TranscriptEngine`.
- Local analysis and its cache.
- Smart framing, smart layouts, and pacing.
- The caption program and renderer.
- The render pipeline and export.
- The guided flow and `ClipPipeline`.
- EditSpec format 3 semantics: every clip made by V1 remains editable and renders the same.

## What needs extension

| System | Extension | Phase |
| --- | --- | --- |
| Project model | Move `ProjectRecord`/`ProjectStore` into `ClipHelmProjects` so V2 libraries can read projects | V2-1 |
| OpenRouter gateway | Generic typed structured-completion entry point shared by V2 tasks | V2-1 |
| Moment discovery | Build from and write to `MomentGraph`; story-aware boundaries | V2-1 – V2-3 |
| `ClipPlanner` | Consume `EditorialIntent`, `ShotIntent`, `DirectorDecision` | V2-4 |
| EditSpec | Format 4: optional director decisions, camera motion, caption emphasis, brand overlay | V2-4 – V2-10 |
| Renderer | Camera motion, brand marks, 1:1 and 4:5 canvases | V2-5, V2-10, V2-11 |
| Captions | Emphasis levels, brand fonts and colors | V2-7, V2-10 |
| Search | Index over transcript, MomentGraph, topics, entities, clips | V2-12 |

## What needs versioning

Every persisted format now has an explicit version and a rule for older and newer files. See [V2_MIGRATIONS.md](V2_MIGRATIONS.md).

| Format | Version | Authoritative? |
| --- | --- | --- |
| `project.json` | 5 (reads 1–5) | Yes |
| `ClipHelmEditSpec` (inside clips and variants) | 3 (reads 1–3) | Yes |
| `ProjectV2Metadata` (inside the project) | additive, part of format 5 | Yes |
| `BrandKit` | 1 | Yes (stored with brand kits in V2-10) |
| `Cache/analysis-v1.json` | 1 | No, regenerated |
| `MomentGraph` (`Cache/v2/moment-graph-v1.json`) | 1 | No, regenerated |
| `ProjectIntelligence` (`Cache/v2/project-intelligence-v1.json`) | 1 | No, regenerated |

## Architectural risks

Ranked by likely cost if ignored.

1. **The project model lives in the app target.** `ProjectRecord`, `ProjectStore`, and `ProjectDraft` sit in `ClipHelmApp`, so no library (search, assistant, variants) can read a project without depending on UI code. V2-0 added the `ClipHelmProjects` module for the version gate and derived storage. *Mitigation:* move the record and store there in V2-1. The draft and UI enums stay in the app.
2. **One bad record hides a whole project.** Launch validation rejects the entire project if any clip, transcript, or V2 metadata entry is invalid. As V2 adds more records, a single malformed variant could make a project disappear from the list. *Mitigation:* quarantine invalid clips and variants individually and report them (V2-1 or V2-13).
3. **The analysis cache key includes the file's modification time.** A re-downloaded YouTube source gets a new modification time, so analysis, and anything keyed on it such as the MomentGraph, is recomputed each session. *Mitigation:* key remote sources on sampled content plus duration (V2-1, before the MomentGraph relies on it).
4. **The gateway grows one method per task.** V1 has four task methods, each with its own schema and limits. V2 would add at least six (topics, story roles, direction, emphasis, search reranking, assistant intent). *Mitigation:* one typed `completeStructured(task:schema:)` path with per-task decoders and limits, keeping validation outside the gateway (V2-1).
5. **Processing is one fixed sequence.** `ProcessingCoordinator` runs transcribe → analyze → discover → vision → plan → render in a fixed order, and `ClipPipeline` separately orchestrates transcription. V2 inserts intelligence and direction stages. *Mitigation:* typed stage outputs cached through `DerivedArtifactStore`, with the pipeline's phase list extended rather than a second orchestrator.
6. **The renderer supports only 9:16 and 16:9.** `ClipRenderer.supports` rejects 1:1 and 4:5, which some platform variants need. `PlatformProfile.builtIn` stays within the supported canvases until V2-11.
7. **Caption style values exist twice.** `CaptionRenderer` presets and `CaptionStyleSwatch` duplicate fonts and colors. Brand kits add a third consumer. *Mitigation:* one style table shared by preview, swatch, and renderer (V2-7).
8. **A second processing path still exists.** `WorkspacePlaybackController` keeps its own transcription and moment-discovery code for the optional explore cards. It can drift from the pipeline. *Mitigation:* route it through `ClipPipeline` services when those cards change.
9. **The manifest holds the transcript.** Long transcripts count toward the 25 MB manifest cap. A four-hour podcast measured about 4 MB, so this is fine for now, but V2 must keep derived data out of the manifest.
10. **There is no quality benchmark.** Quality claims rest on opt-in live runs. *Mitigation:* a fixed, rights-cleared evaluation set scored after each quality phase (before V2-2).

## What V2-0 changed

- `ClipHelmCore/V2/`: typed, validated, `Codable` models for every system named in the V2 plan. `MomentGraph`, `MomentNode`, `MomentEdge`, `StoryUnit`, `StoryRole`, `ProjectIntelligence`, `Topic`, `SemanticEntity`, `EditorialIntent`, `ShotIntent`, `DirectorDecision`, `CameraMotion`, `ScreenRegion`, `DemoEvent`, `CaptionEmphasis`, `BrandKit`, `ClipVariant`, `PlatformProfile`, `SearchResult`, `AssistantAction`, plus `ProjectV2Metadata`. They hold data and validation only; no V2 behavior runs.
- `ClipHelmProjects` (new module): `SchemaMigrator` (version gate and structural steps), `ProjectSchema` (format 5), `DerivedArtifactStore` (versioned, fingerprinted, regeneratable artifacts).
- `ProjectStore`:
  - Reads through the migrator.
  - Refuses projects from a newer ClipHelm and leaves them untouched, including their exports cleanup.
  - Writes through one path that keeps a one-time `project.v<N>.json` backup before first upgrading an older file.
  - Loads V2 metadata, defaulting to empty.
- Tests: 25 new (9 Core model, 9 migrator and artifact store, 6 store-level migration, including one opt-in real-project check).
