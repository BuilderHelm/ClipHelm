# Design System

ClipHelm is a native macOS tool for creators. The interface uses system controls, SF Pro, SF Symbols, and a follows-macOS appearance. On top of that it adds one brand accent and a small set of shared components. Tokens and components live in `Sources/ClipHelmApp/DesignSystem.swift`. Views use them and don't hard-code spacing, radii, colors, or status text.

## Principles

1. **One primary action per screen.** Home: Choose Clip Options. Wizard: Continue / Create Project in the pinned footer. Workspace: the circular Start button, or Download once clips exist. Review sheet: Save Changes. The sidebar's New Clip Project is bordered, not filled, so it never competes.
2. **Status is never color alone.** Every state pairs an SF Symbol with text (`StatusMessage`, `StatusBadge`).
3. **Show, don't name.** Visual choices (canvas, framing, pacing, caption style) are picked from cards with an icon, a description, or a rendered sample.
4. **Explain disabled actions.** When a forward action is unavailable, the reason appears next to it (for example, "Choose a video to continue.").
5. **Respect the platform.** Native pickers, forms, sheets, keyboard shortcuts, and a standard Settings window (⌘,). Reduce Motion turns off step and drop-zone transitions and swaps press scaling for a dim.
6. **Feedback lands on press-in.** Every custom button uses `.pressableCard` or `.pressableRow`, so a click responds before mouse-up.
7. **Controls appear when they're needed.** Dense grids (generated clips) show pictures first; play and selection controls appear on hover or once a selection exists, and every action is also in the context menu.
8. **Color is spent on meaning.** One accent (`DS.accent`), also used for info. Semantic colors appear only when the state calls for it: a viral badge is green only for High, neutral otherwise.

## Tokens

| Token | Values |
|---|---|
| `DS.Space` | 4 · 8 · 12 · 16 · 24 · 32 · 48 pt |
| `DS.Radius` | small 6 · medium 10 (cards, controls) · large 14 (surfaces, video) |
| `DS.Width` | form 720 (wizard, settings) · content 1080 (workspace) |
| `DS.Motion` | press 0.12 s strong ease-out (press feedback) · quick 0.18 s snappy (selection, hover reveal) · standard 0.25 s smooth (step change) |
| `DS.accent` | the logo's blue: light `#1E66D8`, dark `#2F6FE4`; white labels on either meet 4.5:1 (5.3:1 and 4.65:1) |
| `DS.brandGradient` | the logo's teal `#7FEDD4` to blue `#326FE6`; brand moments only, never text |
| `DS.surface` | `controlBackgroundColor`, with a hairline `primary @ 10%` stroke |
| `DS.videoBackground` | black, for players and thumbnails |

The accent is applied once at the window root with `.tint(DS.accent)` (and on the Settings window). Info messages use the accent, so there is only one blue. Success, warning, and error use system green, orange, and red so they adapt to both appearances and to Increase Contrast.

## Components

| Component | Use |
|---|---|
| `surfaceCard(padding:highlighted:)` | Groups one task or topic. `highlighted` marks the ready or primary card. |
| `readableColumn(_:padding:)` | Centers detail content at a readable maximum width. |
| `PageHeader` / `Eyebrow` | Title block for every route: optional eyebrow, large title, subtitle, trailing accessory. |
| `StatusMessage` | Inline icon + text feedback. Tones: info, success, warning, error. `neutral` is plain secondary helper text with no icon. |
| `PressableButtonStyle` | `.pressableCard` (scale 0.97 on press) for cards, tiles, and thumbnails; `.pressableRow` (highlight on press) for list rows. Use instead of `.plain`. |
| `StatusBadge` | Compact state capsule for a stage or project ("Running", "Done", "3 clips saved"). |
| `TaskProgressRow` | The single progress pattern: bar or spinner, stage text, percent, Cancel. |
| `OptionCard` / `OptionCardGrid` | Single-select (radio indicator) or multi-select (`multiple: true`, checkbox indicator) choice cards. |
| `UniformGrid` | Card grid where every cell shares one width and the tallest cell's height, and columns never outnumber cells. Use it for any group of peer cards so they line up. |
| `AppLogo` | The bundled app icon (Home hero, About, empty Recent Projects). Draws nothing in unbundled runs. |
| `ToggleRow` | Switch with icon and description, for independent options. |
| `StageCard` | Workspace stage with icon, title, status badge, header actions, and body. |
| `CaptionStyleSwatch` / `CaptionStyleCard` | Static sample of each caption style. Colors and fonts mirror `CaptionRenderer`'s presets and must be kept in sync. |

## Screen structure

- **Sidebar**: logo and wordmark, then **New Clip Project** as a full-width bordered button (an action, not a destination). Below that, a Library section (Home, and Recent Projects with a count badge) and a Projects section listing the eight most recent projects. Each project row shows its canvas shape (filled once it has clips, outlined while a draft), its status, and a relative date so same-named projects stay distinct. A Settings link that opens the Settings window is pinned to the bottom.
- **Home**: a words-only hero (the sidebar already carries the logo), the YouTube link card, a link for local files, then recent projects with a frame from each project's best clip. The three-step "how it works" row replaces Recent Projects only when there are no projects yet.
- **New Clip Project**: header, clickable step rail (completed steps jump back), step content, and a pinned footer with Back, the blocking reason, and Continue. The Review step lists every choice with an Edit link to its step.
- **Workspace**: the clip job card first. Before a run it holds the circular **Start** button, the live download line, and a summary of the chosen options; during a run it lists every phase with its state and percent; afterwards it summarizes the result. Generated clips follow, then the player (a taller stage for vertical sources), the source-access card when needed, and an optional "Explore the source" group: Local analysis, Transcript, Best moments.
- **Generated clips**: adaptive grid of cards with thumbnails (a frame one second in) in the output's aspect ratio, a duration badge, and Edit, Download, and More actions. The play glyph and selection checkbox appear on hover or once anything is selected; the same actions are in the card's context menu. The header has one filled Download button that reads "Download All" or "Download N Selected", next to Select All or "N selected · Deselect All".
- **Review Clip sheet**: vertical clips sit beside the controls, horizontal clips above them. A pinned footer holds Delete, Export, and Save Changes (⌘S). Closing with unsaved changes asks before discarding.
- **Settings**: a standard Settings window (ClipHelm ▸ Settings…, ⌘,) with General (about, storage, keyboard shortcuts), OpenRouter, and Downloader tabs.

## App icon

The icon source is `Resources/ClipHelm.icon`, an Icon Composer file with light and dark fills and glass layers. `scripts/build-app.sh` compiles it with `actool` into `Assets.car` plus a `ClipHelm.icns` fallback for macOS versions before 26, and `Info.plist` names it through `CFBundleIconName` and `CFBundleIconFile`. Edit the icon in Icon Composer and replace the whole `.icon` folder; don't edit the exported PNGs.

## Checklist for new UI

- [ ] Uses `DS` tokens; no raw hex, ad hoc padding, or corner radii.
- [ ] Custom buttons use `.pressableCard` / `.pressableRow`, not `.plain`.
- [ ] At most one filled (`.borderedProminent`) button visible per screen.
- [ ] Status and errors use `StatusMessage` / `StatusBadge` (icon + text).
- [ ] Long tasks use `TaskProgressRow` with Cancel.
- [ ] Icon-only controls have an accessibility label and a `.help` tooltip.
- [ ] Selected cards expose `.isSelected`; headers expose `.isHeader`.
- [ ] Animations check `accessibilityReduceMotion`.
- [ ] Lays out at the 780 × 560 minimum window and in both appearances. `UISnapshotTests` renders light-mode layouts off-screen (`CLIPHELM_SNAPSHOT_DIR=… swift test --filter UISnapshotTests`); check color, materials, and dark mode in the running app.
