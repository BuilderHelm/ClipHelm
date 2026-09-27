# V2 migrations

How ClipHelm reads files written by older and newer versions of itself. The rule is simple: **older files open, newer files are refused, and nothing is rewritten until the user changes something.**

## Formats and versions

| Format | Current | Reads | On a newer file | On an older file |
| --- | --- | --- | --- | --- |
| `project.json` | 5 | 1–5 | Project refused, files untouched, Home explains | Opens in memory; backup kept on first write |
| `ClipHelmEditSpec` | 3 | 1–3 | The containing project is refused | Decodes with defaults (no layout cues before 3, sound mode before 2) |
| `ProjectV2Metadata` | part of project 5 | missing → empty | n/a | Missing block reads as "no V2 choices" |
| `BrandKit` | 1 | 1 | Rejected | n/a |
| `Cache/analysis-v1.json` | 1 | 1 | Ignored, regenerated | Ignored, regenerated |
| `Cache/v2/moment-graph-v1.json` | 1 | 1 | Ignored, regenerated | Ignored, regenerated |
| `Cache/v2/project-intelligence-v1.json` | 1 | 1 | Ignored, regenerated | Ignored, regenerated |

Versions live in code: `ProjectSchema.currentVersion`, `ClipHelmEditSpec.currentVersion`, `MomentGraph.currentVersion`, `ProjectIntelligence.currentVersion`, `BrandKit.currentVersion`, and `DerivedArtifactKind`.

## Authoritative versus derived data

- **Authoritative** data is the user's decisions and anything expensive or impossible to recreate: configuration, source metadata, the transcript (it may have cost API credits), clip records and their EditSpecs, V2 metadata (brand kit choice, platform targets, variants), and brand kits. It lives in `project.json` or next to it, is versioned, is migrated, and is never deleted by ClipHelm.
- **Derived** data can be rebuilt from authoritative data plus the source: local analysis, the MomentGraph, project intelligence, and later search indexes. It lives under `Cache/`. It is written through `DerivedArtifactStore` (or the V1 analysis cache), keyed by format version and an input fingerprint, and **discarded rather than migrated** when either changes.
- **Session** data is never persisted: source file URLs, downloads, proxies, and thumbnails.

## How a project opens

1. `SchemaMigrator` reads only `schemaVersion`.
   - If it is newer than this build, the project is refused with `SchemaMigrationError.futureVersion`. Home says it was saved by a newer ClipHelm. No cleanup runs in its package.
   - If it is missing or not an integer, the project is refused as unreadable.
2. Registered structural steps run in memory, in order. Formats 1–5 are additive and need none.
3. The typed decoder fills in defaults for fields an older format lacks, and records `loadedSchemaVersion`.
4. Launch validation checks IDs, bounds, clip files, and that every variant points at a real clip.

Opening a project never writes `project.json`.

## How a project is saved

All writes go through `ProjectStore.writeManifest`:

- If the record was read from an older format and no backup exists yet, the file on disk is first copied to `project.v<N>.json` with private permissions.
- The manifest is then written atomically, at the current format, with private permissions.
- Later writes leave the backup alone.

So the first change to a V1 project keeps an exact copy that an older ClipHelm can still open.

## Adding a version

1. **Additive change** (new optional field): bump the format's `currentVersion`, decode the field with `decodeIfPresent` and a default, and add a test that the previous version opens with that default. No migration step is needed.
2. **Structural change** (rename, split, or move): also register a `SchemaMigrationStep(from: N)` that rewrites the JSON object from N to N+1. Once a step exists at N, typed decoders no longer see pre-N layouts of the fields it touches.
3. **Derived format change:** bump its version in `DerivedArtifactKind` (or the cache file name). Old files are ignored and regenerated; never write a migration for derived data.
4. Update the table above, and add the new version to the opt-in real-project check.

## Tests

- `SchemaMigratorTests`: additive pass-through, future and too-old rejection, missing or malformed versions, ordered structural steps, failing steps.
- `DerivedArtifactStoreTests`: round trip, mismatched inputs or versions read as missing, corrupt files, unsafe symlinked caches, fingerprint separation.
- `V2MigrationTests`:
  - Format 1 and 4 projects open with empty V2 metadata and are not rewritten.
  - The first change keeps one backup.
  - Newer projects are refused and untouched.
  - EditSpec 2 and 3 inside a project open; format 4 is refused.
  - V2 metadata persists and must reference real clips.
  - The opt-in `CLIPHELM_QA_PROJECTS_DIR` check opens a copy of real projects and verifies no byte changed.
- Existing: `EditingEngineTests` (EditSpec 1 and 2 → 3), `CoreModelTests` (EditSpec 4 rejected), `AppStateTests` (project 1 and 3 upgrades).
