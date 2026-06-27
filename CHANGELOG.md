# Changelog

## 2026.06.26.2 — 2026-06-26

- Add GitHub link to About panel and Check for Update menu item
- Sort Move dialog location list alphabetically

## 2026.06.26.1 — 2026-06-26

- Add recent-directory combo box to Move dialog

## 2026.06.24.1 — 2026-06-24

- Add make help default and dev/run/clean targets
- Speed up cold first refresh, especially over LTE
- Add manual refresh via Server menu (⌘R) and idle-dot click
- Show aggregate stats in Info pane for multi-torrent selection
- Enable standard macOS toolbar customization

## 2026.06.23.1 — 2026-06-23

- makefile
- Add Torrent menu with keyboard shortcuts mirroring the context menu
- Add Return-key rename shortcut for single selection in torrent table
- README: add app icon at the top for visual flare
- Add welcoming README, CONTRIBUTING, and Code of Conduct
- release.sh: target the fork explicitly with gh --repo

## 2026.06.19.1 — 2026-06-19

- Add Developer ID signing, notarization, and release automation
- README: rewrite for the native macOS app
- Flatten macapp/ to repo root
- Remove legacy Lazarus/Pascal codebase; preserved on legacy-pascal branch
- Use PlaceholderTextView and clear default host
- Docs: write-up recommending against installing Span coding hooks
- Native: replace Info-tab text block with a copyable InfoGridView
- Native: persist search match mode across launches (default Exact)
- Native: double-click opens locally, centered click-dismiss toast, crisp small icons
- Native: per-server remote→local path mappings (Reveal in Finder / Open)
- Native: File ▸ Close (⌘W) so the Settings window closes with the keyboard
- Native: multi-host UX — 2-line host field, newline split, per-host Test Connection
- Docs: multi-host failover (context 09, CLAUDE.md)
- Native: multi-host failover (comma-separated candidates per server)
- Docs: hostnames/ATS, Test Connection + Save fixes, SettingsEditor tests (context 08, CLAUDE.md)
- Native: Save is click-only (not Return default) to avoid accidental saves
- Native: ATS exception for HTTP hostnames + Test Connection dialog fix + SettingsEditor tests
- Native: live Save enable + Test Connection uses current field text
- Native: move Save/Test Connection buttons inside the Settings tab box
- Native: Settings Save button, Test Connection, default-server popup at top
- Docs: native prefs + Settings window + tests (context 08, macapp CLAUDE.md)
- Native: XCTest unit tests (53) + testable PreferencesStore
- Native: Application Support preferences store + Settings window (replaces JSONC)
- Native: column h-scroll, status tints, window-frame persistence
- Native: drop locale separator in middle Added-date form
- Native: round-06 multi-server + UX polish
- Docs: mark 05 native-followups-2 done; note folder label sort
- Native: sort sidebar folders by displayed label, not full path
- Docs: record 05 native-followups-2 done in macapp/CLAUDE.md
- Native: preserve sidebar scroll across polls + reorderable sections
- Native: ETA '—' for completed torrents + merge folder-dupe locations
- Native: add asset-catalog AppIcon so the Dock tile renders
- Docs: index the 05 native-followups-2 plan in macapp/CLAUDE.md
- Docs: record native follow-ups done; label filtering dropped
- Recolor app icon handle to Finder blue, modern icns
- Show "Connecting…" instead of an error during first connect
- Disambiguate sidebar folder filter labels
- Add sortable Ratio-Limit column to the torrent list
- Add Ratio-Limit column model fields and display
- Docs: point CLAUDE.md at the numbered .context plan series
- Docs: mark feature-ranking items done; update macapp/CLAUDE.md status
- Persist window, split, column, and sort state
- Polish the Info detail tab
- Aggregate status bar + free-space display
- Column customization + list polish
- Add source-list sidebar with status / tracker / folder filters
- Add torrents: .torrent file, magnet/URL, drag-and-drop, Dock drop
- Add Files tab: per-file list with wanted toggle + priority
- Add verify, queue, priority, remove actions + fuzzy/exact search toggle
- Add macapp/CLAUDE.md; remove TODO.md (backlog moved to .context)
- Add feature backlog (TODO.md) for the native macOS app
- Add toolbar search bar that filters the torrent list
- Add native macOS Swift/AppKit MVP (macapp/)
- ignore context
- [ci-skip] Update README.md
- Building RPM installation package for Fedora 41+ (#147)
- Development version is now 5.18.9.f

