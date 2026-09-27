# ClipHelm V2 architecture

V1 answers *which parts of a long video should become clips*. V2 also answers:
- what each moment is about, and where its story starts and ends;
- what the viewer should see, and whether a demo should take the frame;
- which words deserve emphasis;
- how each clip should adapt to each platform.

It does this by adding layers above the V1 engine, not by replacing it. [V2_ARCHITECTURE_AUDIT.md](V2_ARCHITECTURE_AUDIT.md) explains what was kept and why.

## Layers

```text
Source video
   │  SourceIngestor (V1)
   ▼
Media intelligence (V1, local)      transcript · audio signals · scenes · subjects · screen text
   │
   ▼
MomentGraph (V2-1)                  nodes, edges, story units — derived, cached
   │
   ▼
Project intelligence (V2-1)         summary · chapters · topics · entities — derived, cached
   │
   ├──► Search / Ask ClipHelm (V2-12)    SearchResult · AssistantAction
   ▼
Moment Engine 2.0 + story clipping (V2-2, V2-3)   ClipProposal with story-aware ranges
   │
   ▼
Editor Brain + Director (V2-4 – V2-6)   EditorialIntent · ShotIntent · DirectorDecision
   │                                    CameraMotion · ScreenRegion · DemoEvent
   ▼
ClipPlanner (V1, extended)          framing geometry · layouts · pacing · captions (+ CaptionEmphasis)
   │
   ▼
ClipHelmEditSpec                    format 3 today; format 4 adds direction, motion, emphasis, brand
   │
   ├──► Audio 2.0 (V2-8) · BrandKit (V2-10) · Variants (V2-11: ClipVariant, PlatformProfile)
   ▼
ClipRenderer (V1, extended)         deterministic AVFoundation + CoreImage
```

## Modules

| Module | Status | Owns |
| --- | --- | --- |
| `ClipHelmCore` | V1, extended in V2-0 | V1 domain types, plus `V2/`: every V2 value type, validated, no I/O |
| `ClipHelmProjects` | **new in V2-0** | Format versions (`ProjectSchema`), `SchemaMigrator`, `DerivedArtifactStore`; receives `ProjectRecord`/`ProjectStore` in V2-1 |
| `ClipHelmIntelligence` | planned, V2-1 | Builds `MomentGraph` and `ProjectIntelligence` from transcript, analysis, and model evidence |
| `ClipHelmDirector` | planned, V2-4 | Editor Brain and Director Engine: intents → decisions |
| `ClipHelmSearch` | planned, V2-12 | Index and query over the graph, intelligence, and clips; assistant intent parsing |
| All V1 modules | unchanged | See [ARCHITECTURE.md](ARCHITECTURE.md) |

New modules depend on Core and on V1 service modules, never on the app target. The app stays the composition root.

## The AI boundary

This is unchanged from V1 and applies to every V2 system:

```text
OpenRouter model ──► typed JSON (strict schema) ──► V2 type initializer (validation)
                  ──► ClipHelm planner ──► ClipHelmEditSpec ──► deterministic renderer
```

- The gateway returns only JSON that must decode into a Core type. Every Core V2 initializer validates ranges, bounds, lengths, and IDs, and decoding goes through the same initializer, so model output cannot skip validation.
- No V2 type can hold a shell command, file path, URL, FFmpeg argument, or filter string. `BrandKit.logoFileName` and `ClipVariant` file names are plain names checked against separators. `AssistantAction` is a closed set of typed commands; anything else fails to decode.
- Model values carry `Provenance.model`. Planners may weigh them against local evidence (`.local`) and must let the user's choices (`.user`) win.
- Every model-assisted system needs a deterministic fallback that runs without a key or network. Examples: MomentGraph nodes from sentences and scenes, directions from local layout rules, emphasis from numbers and named entities.
- OpenRouter stays the single credential. Model IDs remain configurable per task through `OpenRouterModelRegistry`.

## Data classes

| Class | Examples | Where | Lifecycle |
| --- | --- | --- | --- |
| Authoritative | Configuration, source metadata, transcript, clips and EditSpecs, `ProjectV2Metadata`, brand kits | `project.json` and project folders | Versioned, migrated, backed up before first upgrade |
| Derived | Analysis, `MomentGraph`, `ProjectIntelligence`, search index | `Cache/`, `Cache/v2/` | Keyed by format version and input fingerprint; regenerated, never migrated |
| Session | Source URLs, downloads, proxies, thumbnails | Memory, temporary folders | Never persisted |

See [V2_MIGRATIONS.md](V2_MIGRATIONS.md) for formats and rules, and [MOMENT_GRAPH.md](MOMENT_GRAPH.md) for the graph.

## Type map

| Type | Purpose | Built in |
| --- | --- | --- |
| `MomentGraph`, `MomentNode`, `MomentEdge`, `StoryUnit`, `StoryRole`, `StoryBeat` | Structure of the source | V2-1, V2-3 |
| `ProjectIntelligence`, `Topic`, `SemanticEntity`, `Chapter` | Source-wide understanding | V2-1 |
| `EditorialIntent` | What a clip is for; ranges it must keep or avoid | V2-4 |
| `ShotIntent` | What the viewer should see in a span | V2-4 |
| `DirectorDecision`, `CameraMotion` | Chosen layout, focus, and virtual camera move, with a reason | V2-4, V2-5 |
| `ScreenRegion`, `DemoEvent` | Readable screen areas and on-screen actions | V2-6 |
| `CaptionEmphasis` | Words that deserve visual weight | V2-7 |
| `BrandKit`, `BrandColor` | A creator's caption style, colors, font, and logo | V2-10 |
| `PlatformProfile`, `ClipVariant` | Per-platform outputs of an accepted clip | V2-11 |
| `SearchResult`, `AssistantAction` | Search hits and typed assistant commands | V2-12 |
| `ProjectV2Metadata` | V2 choices stored in the project | V2-0 (empty until later phases) |

## Engineering rules for every phase

- Inspect first; implement only the phase in hand; reuse V1 systems.
- Keep V1 projects opening and V1 clips editable.
- Add a format version plus a migration test for any persisted change.
- Keep expensive work cancellable, with progress reported through `ClipPipeline` phases.
- Keep new services testable with mocks (`MockOpenRouterGateway`, fixtures).
- Every phase ends with build, full tests, a representative live workflow, documentation, and a list of remaining limitations.
