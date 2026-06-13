# macapp/ — Native macOS Transmission Remote

## What this is

A **native macOS app in Swift + AppKit** that talks to a single Transmission
BitTorrent daemon over JSON-RPC. It's a from-scratch rewrite living alongside the
legacy Free Pascal / Lazarus app that fills the rest of this repo.

- **The legacy Pascal app (repo root: `../*.pas`, `*.lfm`) stays untouched.** It's
  the reference for protocol/feature behavior, not something to modify. `../rpc.pas`
  is the authoritative source for the Transmission RPC protocol.
- All native work happens **on branch `mac-native-mvp`**, inside `macapp/`.
- Scope is a deliberately minimal MVP for the owner's daily use — not feature parity.

## Current status (feature-parity pass complete)

Done and verified against the owner's real server (~1040 torrents, Transmission
4.1.2). Core MVP: connect, live torrent list with a state-coloured progress bar,
sortable columns, **start / stop / force-start / rename / move / verify / queue-move
/ bandwidth priority / remove**, and a fuzzy/exact toolbar search.

All `feature-ranking.md` items above "Other stuff not worth doing yet" are now
implemented:

- **Files tab** — tabbed detail pane (Info / Files); per-file table with a wanted
  checkbox (`files-wanted`/`files-unwanted`), size, live progress, and priority
  (`priority-*`). Fetched on demand per selected torrent, refreshed on the poll.
- **Add torrents** — Add toolbar pull-down + File-menu (⌘O file, ⌘L magnet/URL),
  drag-and-drop onto the window, and Dock/Open-With (`CFBundleDocumentTypes` in
  `Info.plist`). Shared options sheet (destination prefilled from session
  download-dir, Start-when-added) → `torrent-add` with duplicate detection.
- **Sidebar filter groups** — source-list `NSOutlineView`: Status / Trackers /
  Folders with live counts (native take on `filtering.pas`). Applied before search.
- **Column customization** — Size / Added / Tracker columns (hidden by default),
  all sortable; right-click header menu toggles visibility + Auto-Size; reordering
  and column state persist.
- **Aggregate status bar + free-space** — per-status counts and the download dir's
  free space (`free-space` RPC).
- **Info tab polish** — comment, full dates, error detail, downloaded/uploaded-ever,
  tracker, and a download/upload speed sparkline.
- **Persistence** — window frame, split positions, column order/width/visibility,
  and sort descriptor all persist across launches.

Native follow-ups (`04-native-followups.md`) also done: blue app icon (modern
icns), sortable **Ratio-Limit column** (hidden by default), disambiguated sidebar
folder labels (minimal unique suffix), and a "Connecting…" first-launch state
that no longer flashes an offline/error message before the first handshake.

Round-2 follow-ups (`05-native-followups-2.md`) done and verified live:
**asset-catalog AppIcon** so the Dock tile renders the blue badge (the `.icns`
stays for Finder; needed an IconServices/Dock cache flush — `lsregister -f` +
empty `$DARWIN_USER_CACHE_DIR/com.apple.iconservices` + `killall Dock`); ETA shows
**"—" for completed/seeding** torrents (`Torrent.etaDisplay`; "∞" only while
genuinely downloading); **folder-dupe locations merged** (counts keyed on
`Torrent.normalizedDownloadDir`, folder filter matches normalized on both sides);
**sidebar scroll preserved across polls** (structure-fingerprint → in-place count
updates + `reloadItem`, full reload only on structural change with scroll
save/restore); and **reorderable sidebar sections** (`SidebarGroup` order in
`UserDefaults` `SidebarGroupOrder`, drag-to-reorder group rows + right-click Move
Up/Down).

Intentionally dropped: **label filtering and the Labels column/sidebar group.**

- **Remove**'s data-deleting path and the per-file wanted/priority **writes** were
  intentionally **not** fired against the owner's prod server. Read paths and
  non-destructive RPCs (`torrent-get files/fileStats`, `free-space`, `torrent-add`
  duplicate) were validated live.

- Plans live in `../.context/`, numbered chronologically: `01-mac-port-plan.md` (MVP),
  `02-feature-backlog.md`, `03-feature-ranking.md` (ranked backlog), `04-native-followups.md`
  (icon recolor, Ratio-Limit column, folder-filter fix, connecting state),
  `05-native-followups-2.md` (Dock icon, completed-ETA, folder dupes, sidebar scroll +
  reordering).

## Layout (`macapp/Sources/`)

- `main.swift` — explicit AppKit entry point (see gotcha below).
- `AppDelegate.swift` — app lifecycle, menus (Reload Config, Find ⌘F, Edit).
- `MainWindowController.swift` — window, `NSTableView`, detail pane, status bar,
  sorting, search/filter (`displayed` is the filtered view of the `torrents` model).
- `MainWindowController+Actions.swift` — toolbar (incl. Add pull-down), context
  menu, action methods, and the search toolbar item.
- `MainWindowController+Files.swift` — the Files tab table + wanted/priority actions.
- `MainWindowController+Add.swift` — add-torrent flows (file/magnet/drag) + `DropView`.
- `SidebarController.swift` — the source-list filter sidebar (`NSOutlineView`).
- `Filtering.swift` — `StatusFilter` / `SidebarFilter` (filter predicates).
- `TransmissionClient.swift` — `actor` over `URLSession`; HTTP Basic auth + the
  **409 / `X-Transmission-Session-Id` CSRF retry**; typed RPC wrappers.
- `RefreshController.swift` — `@MainActor` poll loop (~4s), connection state,
  pause-on-minimize, default download-dir + free-space.
- `Models.swift`, `AppConfig.swift`, `Formatters.swift`, `ProgressCellView.swift`,
  `SpeedGraphView.swift`.

Project is generated by **XcodeGen** from `project.yml` (committed). The generated
`.xcodeproj` and `build/` are gitignored.

## Build & run

```sh
cd macapp
xcodegen generate          # only after editing project.yml / adding files
xcodebuild -project TransmissionRemote.xcodeproj -scheme TransmissionRemote \
  -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/TransmissionRemote-*/Build/Products/Debug/"Transmission Remote.app"
```

Keep the build **clean with zero warnings** (Swift 6 strict concurrency `complete`).

## Config

User-editable JSONC at `~/.config/transmission-remote-mac/config.jsonc`
(auto-created with a commented template on first run; parsed via
`JSONSerialization(.json5Allowed)`). It holds host/port/credentials and
`refreshSeconds`. The owner's real server config already lives there — **do not
print the password**. "Reload Config" in the menu re-reads it without a rebuild.

## Gotchas (learned the hard way — don't regress these)

1. **Use `main.swift`, not `@main`.** `@main` on a bare `NSApplicationDelegate`
   did not install the delegate on this toolchain (window never appeared, no
   config written). The explicit `NSApplication.shared` + `app.run()` entry point
   in `main.swift` is required.
2. **`ENABLE_DEBUG_DYLIB: NO`** in `project.yml` — the explicit entry point needs
   this, or Xcode 16's debug-dylib split fails to link (`_main` undefined).
3. **Don't lay the main UI out with `NSStackView`** — it collapsed the split view
   (and the torrent table inside it) to zero height, so the list didn't show. Use
   explicit Auto Layout constraints (split pinned above a fixed-height status bar).
4. **Outward actions on a live server are real.** Start/stop/rename/move hit the
   owner's production daemon (1000+ torrents). Test against a disposable torrent and
   restore state; get the owner's OK before mutating, and never use broad
   `pkill -f "Transmission Remote"` — it also matches the legacy "Transmission
   Remote GUI" app. Match `pkill -f "Debug/Transmission Remote.app"` instead.

## Verifying changes in the running app

`screencapture` often returns blank because the window opens on a different Mission
Control **Space**. Verify via the **accessibility tree** instead (it's the source
of truth here). Requires accessibility permission for the controlling process.

```applescript
tell application "System Events" to tell process "Transmission Remote"
  -- the torrent table:
  table 1 of scroll area 1 of splitter group 1 of window 1
  -- the toolbar search field:
  text field 1 of (last UI element of toolbar 1 of window 1)
end tell
```

Notes: `entire contents of window 1` **chokes** on the 1041-row tree — drill explicit
paths. To drive the search filter in a test, **`set value of <searchField>`** fires
the filter action reliably; `keystroke` into the field is flaky.
