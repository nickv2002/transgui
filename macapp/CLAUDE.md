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
Up/Down). Follow-up after the plan: the Folders group sorts by its **displayed
label** (the disambiguating suffix) via `localizedStandardCompare`, not the full
download path.

Round-3 (`06-multi-server-and-polish.md`) done and verified live: **search
placeholder** reflects the active match mode ("Fuzzy/Exact filter by name");
**color-tinted sidebar status icons** (`StatusFilter.color`, `Node.tint`,
`FilterCellView` tint param — consistent with `progressColor`); **adaptive
region-aware Added date** (`Formatters.compactDate` numeric-short when the column
is narrow, full `date` + time when wide; the flip is driven by a custom
`AddedDateCellView` that re-picks its form in `layout()` against a measured ~162pt
threshold — so it adapts **live mid-drag** as the column resizes, with no resize
notification needed; `cellText` keeps the full form so Auto-Size fits it);
**multi-server** — `config.jsonc` moved outright to a
`servers: [ServerConfig]` array shape (no backward-compat decode; falls back to a
single localhost default), `TransmissionClient.init(server:)`, a **Server menu**
(right of Edit) that checkmarks the active server and switches the live connection,
selection persisted in `UserDefaults` `SelectedServerName` (resolved
UserDefaults → `currentServer` → first), window title shows the active server when
>1 configured; and a **bottom-left fetch spinner + idle dot**
(`RefreshController.onFetchingChanged`, transition-coalesced; `circle.fill` dot
tinted by connection state when idle, `NSProgressIndicator` while polling — note the
spinner is near-invisible against a fast LAN server whose fetch is ~2ms). The owner's
real config was migrated by hand to the new shape (backed up first); a second
example `Local` entry was added so the Server menu has two to switch between.
Follow-up fix this round: the app menu gained standard **Hide / Hide Others /
Show All** items so **⌘H** is bound (it was a no-op before).

Intentionally dropped: **label filtering and the Labels column/sidebar group.**

- **Remove**'s data-deleting path and the per-file wanted/priority **writes** were
  intentionally **not** fired against the owner's prod server. Read paths and
  non-destructive RPCs (`torrent-get files/fileStats`, `free-space`, `torrent-add`
  duplicate) were validated live.

- Plans live in `../.context/`, numbered chronologically: `01-mac-port-plan.md` (MVP),
  `02-feature-backlog.md`, `03-feature-ranking.md` (ranked backlog), `04-native-followups.md`
  (icon recolor, Ratio-Limit column, folder-filter fix, connecting state),
  `05-native-followups-2.md` (Dock icon, completed-ETA, folder dupes, sidebar scroll +
  reordering), `06-multi-server-and-polish.md` (search placeholder, tinted sidebar
  icons, adaptive Added date, multi-server + Server menu, fetch spinner/idle dot),
  `07-resize-tints-window-frame.md` (column h-scroll, status tints, window frame),
  `08-native-prefs-and-tests.md` (Application Support preferences store + Settings
  window replacing JSONC; XCTest unit-test target).

## Layout (`macapp/Sources/`)

- `main.swift` — explicit AppKit entry point (see gotcha below).
- `AppDelegate.swift` — app lifecycle, menus (Settings… ⌘,, Find ⌘F, Edit, Server).
- `SettingsWindowController.swift` — native preferences window (Servers / General).
- `SettingsEditor.swift` — Foundation-only editing model behind Settings (tested).
- `ConnectionDiagnostics.swift` — Test Connection error→message mapping (tested).
- `HostCandidates.swift` — comma-separated host parsing + `ConnectionResolver` (tested).
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

Config is now a **native preferences store**, edited through a native **Settings
window** (⌘,) — no more hand-edited JSONC.

- Persisted as JSON at
  `~/Library/Application Support/Transmission Remote/preferences.json`
  (`PreferencesStore` in `AppConfig.swift`). Holds the `servers` array
  (host/port/credentials/HTTPS/rpcPath), `currentServer`, and `refreshSeconds`.
  The owner's real server config lives there — **do not print the password**.
- **Migration:** on first run, if no native store exists, `PreferencesStore.load`
  migrates the legacy JSONC at `~/.config/transmission-remote-mac/config.jsonc`
  (left in place as a backup) into the native store; otherwise it seeds
  `AppConfig.default`. Verified live: the owner's real server (with credentials)
  migrated correctly.
- **Settings window** (`SettingsWindowController.swift`): tabbed (Servers /
  General), inside the tab box's gray content area. Servers tab has the
  **default-server popup at the top**, then a list with +/- and an editable detail
  form (name/host/port/HTTPS/rpcPath/username/password); General tab has the
  refresh interval (field + stepper). All editing logic (working copy, baseline,
  dirty detection, add/remove/edit/default/save) is factored into the
  Foundation-only **`SettingsEditor`** (in `SettingsEditor.swift`); the controller
  is a thin view layer over it.
  - Edits mutate the working copy and are **only persisted + applied when the user
    clicks Save** (bottom-right; enabled only when dirty). Save is **not** the
    Return/default button — Return commits the focused field, not the whole dialog.
  - Save enables on **every keystroke** (`controlTextDidChange`), not just on
    end-editing. Live edits update just the affected row label, **never**
    `reloadData()` (which dropped the table selection mid-edit and broke
    Test/Remove).
  - Saving runs `onChange` → `PreferencesStore.save` + `windowController.applyConfig`
    + Server-menu rebuild. Closing dirty prompts Save / Discard / Cancel;
    `AppDelegate.showSettings` calls `reset(to:)` on reopen.
  - **Test Connection** (left of Save) builds a `ServerConfig` from the **current
    form fields** (so you can test before saving), runs `session-get`, and shows a
    field-targeted success/failure alert (diagnostic mapping in the Foundation-only
    `ConnectionDiagnostics.message(for:server:)`).
- `PreferencesStore` exposes path-injectable cores
  (`load(storeURL:legacyURL:)`, `save(_:to:)`, `encode`/`decode`,
  `loadLegacyJSONC(from:)`) so the store is unit-tested against temp dirs without
  touching the real Application Support file.
- "Reveal Preferences in Finder" (File menu) selects the JSON store.

### Hosts & ATS

The app talks to a self-hosted daemon, usually over **plain HTTP** on a LAN/VPN.
macOS App Transport Security blocks cleartext HTTP to *named* hosts by default, so
`Info.plist` sets **`NSAllowsArbitraryLoads`** — otherwise `n5.local` would fail
where the bare IP `10.0.1.2` works. Verified live: `10.0.1.2` and `n5.local` both
connect over HTTP; the **Tailscale** host
`transmission.raptor-ruffe.ts.net` speaks **HTTPS** (valid cert) on :9091 and :443,
so it needs **Use HTTPS** checked (plain HTTP there returns "Client sent an HTTP
request to an HTTPS server").

### Multi-host failover

One server can list **several hosts** for the same daemon — type a comma- **or
line-separated** list in the Host field, e.g.
`10.0.1.2, n5.local, https://transmission.raptor-ruffe.ts.net`. The Host field is a
**2-line wrapping field** so a fallback list stays visible at once. On connect (and
after any failed poll) the app probes the candidates **in order** and uses the
first that responds, so leaving/joining the tailnet fails over transparently.

- `ServerConfig.connectionCandidates` (`HostCandidates.swift`) splits the Host
  field on commas **and newlines** (`split(whereSeparator:)` on `","`/`.isNewline`,
  so `\r\n` is handled as one separator) and parses each token as a connection
  string: bare host, `host:port`, or `scheme://host[:port][/path]` (incl. bracketed
  IPv6). Parts a token omits are inherited from the server (useHTTPS, port, rpcPath,
  credentials). A single host yields one candidate — existing configs are unchanged.
  `hasMultipleHostCandidates` derives from the parsed count (not a raw `,` test).
- `ConnectionResolver.firstReachable(_:probe:)` is the pure, injectable selection
  core (unit-tested). `RefreshController.resolveReachableClient()` uses it with a
  real `session-get` probe and a short per-candidate timeout (`probeTimeout`, 5s),
  re-resolving whenever a poll fails. `TransmissionClient.init(server:timeout:)`
  takes the probe timeout.
- **Test Connection probes EVERY candidate concurrently** (`probeAll`, a `TaskGroup`
  preserving candidate order) and reports a **per-host ✓/✗ list** — a header
  ("N of M hosts responded") plus one line per host
  (`✓ http://host:port — Transmission x` / `✗ … — <short reason>`, via
  `shortError`). A single-host server keeps the focused success/failure message.
  Verified live against the owner's N5 server: all three hosts (IP, `.local`,
  Tailscale-HTTPS) respond, and failover resolves to a reachable host
  (`LiveConnectionTests`).

## Tests

XCTest unit tests live in `macapp/Tests/`, built by the `TransmissionRemoteTests`
target (XcodeGen `bundle.unit-test`). Rather than host the application (which would
launch the real app and connect to the owner's server), the **business-logic
source files are compiled directly into the test bundle**, so tests run standalone
via `xctest` with no `TEST_HOST`.

Coverage (104 hermetic tests): `FuzzyMatch` (subsequence + ranking), `Formatters`
(size/speed/percent/ratio/eta/dates), `Filtering` (every `StatusFilter` predicate,
tints, `SidebarFilter`), `Models` (status/eta-display/normalizeDownloadDir/
trackerHost/seed-ratio + RPC `torrent-get`/files decoding), `AppConfig` /
`PreferencesStore` (decode defaults, round-trip, migration, default seeding,
native-store precedence), `ConnectionDiagnostics` (every `TransmissionError` maps
to a field-targeted message), **`SettingsEditor`** (add/remove/edit/default/
refresh, name trim+dedupe, default-follows-rename, dirty detection, save, reset),
and **`HostCandidates`/`ConnectionResolver`** (comma- and newline-list parsing
incl. scheme/port/path/IPv6/inheritance + first-reachable failover selection).
A `TorrentFactory` helper builds `Torrent` values from a default JSON dict.

```sh
cd macapp
xcodebuild -project TransmissionRemote.xcodeproj -scheme TransmissionRemote \
  -configuration Debug test
```

**Live connection tests** (`LiveConnectionTests`) hit the real daemon and are
**skipped by default**. They read credentials from the legacy JSONC at runtime
(never hard-coded) and cover IP/`.local`/Tailscale-HTTPS, multi-host failover
resolution, plus failures (unknown host, wrong password). Note: a host-less test bundle's ATS is governed by the
`xctest` runner (not the bundle's `Info.plist`), so the cleartext-HTTP cases
`XCTSkip` in the runner — those are verified through the app + `curl` instead.
Forward the opt-in env var with the `TEST_RUNNER_` prefix:

```sh
TEST_RUNNER_RUN_LIVE_TRANSMISSION_TESTS=1 xcodebuild ... test \
  -only-testing:TransmissionRemoteTests/LiveConnectionTests
```

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
