# MomentGraph

The MomentGraph is V2's model of one source video: its meaningful spans, how they relate, and the stories they form. V1 turned local candidate windows straight into clips. From V2-1 on, moment discovery, story-aware clipping, search, and the assistant all read the same graph.

The types live in `Sources/ClipHelmCore/V2/MomentGraph.swift`. V2-0 defines and persists them; nothing builds a graph yet.

## Nodes

A `MomentNode` is a source-time span with:
- a kind;
- a salience from 0 to 1;
- an optional story role, speaker, and topics;
- a short summary for search and review;
- its provenance: local, model, or user.

| Kind | Typical source | Contains |
| --- | --- | --- |
| `sentence` | Transcript punctuation and pauses | — |
| `utterance` | One speaker's continuous turn | sentences |
| `topicSegment` | Topic shifts in transcript and model evidence | utterances, sentences |
| `storyBeat` | A span with a story role (hook, setup, payoff, and so on) | sentences |
| `scene` | Local scene analysis | — |
| `demoSegment` | Screen or demo activity | — |
| `candidate` | A possible clip window | sentences, beats |

The summary is display text for search and review. It is never renderer input.

## Edges

Edges are directed and read as "from ⟨kind⟩ to". Some kinds have a required time order, and the graph rejects any edge that contradicts it.

| Kind | Meaning | Required order |
| --- | --- | --- |
| `contains` | from's range contains to's range | containment |
| `follows` | to comes after from | from starts no later than to |
| `setsUp` | from prepares what to delivers | from starts no later than to |
| `paysOff` | from resolves to | to starts no later than from |
| `answers` | from answers the question in to | to starts no later than from |
| `elaborates`, `contrasts`, `repeats`, `references`, `sameTopic` | semantic relations | none |

`repeats` lets V2 avoid clips that say the same thing twice. `setsUp`/`paysOff` let story-aware clipping (V2-3) extend a clip back to its setup or forward to its payoff.

## Story units

A `StoryUnit` groups nodes into one coherent story:
- ordered, non-overlapping beats, each with a `StoryRole`, inside the unit's range;
- the IDs of the nodes it covers (each must lie inside the unit);
- a completeness score and an optional title.

A unit `isSelfContained` when its first beat can open a clip (hook, context, setup, tension) and its last can close one (payoff, resolution, call to action).

## Validation

Construction and decoding enforce all of the following. A failure throws `ModelError`, and the graph is then regenerated instead of partly used.

- Unique node IDs, and edges only between existing nodes.
- No self loops and no duplicate edges.
- The edge time-order rules above.
- Story-unit consistency.
- Size limits: 20,000 nodes, 100,000 edges, 1,000 story units.
- Schema version: format 1; a newer graph is rejected.

`validate(for:)` additionally checks the asset ID and that every range lies within the source duration.

## Persistence

The graph is **derived data**. It is rebuilt, never migrated, and never stored in `project.json`.

- **Location:** `<project>.cliphelm/Cache/v2/moment-graph-v1.json`, written by `DerivedArtifactStore` with private permissions and an atomic write.
- **Envelope:** kind, format version, input fingerprint, generator label, creation time, and the graph.
- **Input fingerprint:** `DerivedArtifactStore.fingerprint([...])` over:
  - the asset ID and duration;
  - a hash of the transcript words and times;
  - the analysis cache fingerprint;
  - the builder version;
  - the OpenRouter model ID used for semantic edges, or "local" when none was used.

  Any change produces a different fingerprint, so the old graph reads as missing.
- **Invalidation:** loading returns nothing for a missing, corrupt, oversized, symlinked, other-version, or other-fingerprint file. The builder then regenerates the graph, and `removeAll(kind:)` clears stale versions.
- **Format changes:** bump `DerivedArtifactKind.momentGraph.version` and `MomentGraph.currentVersion`. Old files are ignored.

What is *not* derived: user decisions about moments, such as pinning or rejecting a candidate or accepting a clip. These belong in the project manifest (authoritative, versioned) and refer to graph nodes by time range, not by node ID, because node IDs change when the graph is rebuilt.

## How later phases use it

| Phase | Use |
| --- | --- |
| V2-1 | Build nodes from transcript and analysis locally; add topics, entities, and semantic edges with a model; cache |
| V2-2 | Rank candidates with graph context (salience, topic coverage, `repeats`) |
| V2-3 | Choose clip boundaries from story units and `setsUp`/`paysOff` edges |
| V2-12 | Index nodes, topics, and entities for search; `SearchResult.nodeID` points into the graph |
