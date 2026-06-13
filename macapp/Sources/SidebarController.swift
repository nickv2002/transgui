import AppKit

/// One of the three reorderable top-level sidebar sections. The raw values are the
/// stable identifiers persisted in `UserDefaults` for the user's chosen order.
enum SidebarGroup: String, CaseIterable, Sendable {
    case status, trackers, folders
}

/// A source-list sidebar (`NSOutlineView`) that groups torrents by status,
/// tracker, and download folder — the native take on the legacy `filtering.pas`
/// filter panel. Selecting a row reports the active `SidebarFilter`; the torrent
/// list filters on it.
@MainActor
final class SidebarController: NSObject {
    /// A node in the outline: a non-selectable group header or a selectable filter.
    final class Node {
        let title: String
        let symbol: String?
        let filter: SidebarFilter?
        /// Set only on top-level group headers; identifies the reorderable section.
        let group: SidebarGroup?
        var count: Int
        var children: [Node]

        init(title: String, symbol: String? = nil, filter: SidebarFilter? = nil,
             group: SidebarGroup? = nil, count: Int = 0, children: [Node] = []) {
            self.title = title
            self.symbol = symbol
            self.filter = filter
            self.group = group
            self.count = count
            self.children = children
        }

        var isGroup: Bool { filter == nil }
    }

    let outlineView = NSOutlineView()
    let scrollView = NSScrollView()

    /// Reported whenever the selected filter changes (including back to `.all`).
    var onFilterChange: ((SidebarFilter) -> Void)?

    private var groups: [Node] = []
    /// The currently selected filter, preserved across rebuilds.
    private(set) var selectedFilter: SidebarFilter = .all

    /// The persisted top-level section order.
    private var groupOrder: [SidebarGroup] = SidebarController.loadGroupOrder()
    /// The most recent torrents, retained so a reorder can rebuild without a poll.
    private var lastTorrents: [Torrent] = []
    /// Structural fingerprint of the last-built outline. When it's unchanged we
    /// update counts in place instead of reloading (preserves scroll + expansion).
    private var currentSignature = ""

    private static let groupOrderKey = "SidebarGroupOrder"
    private static let dragType =
        NSPasteboard.PasteboardType("com.nickvance.transmission-remote-mac.sidebarGroup")

    override init() {
        super.init()
        buildOutline()
    }

    private func buildOutline() {
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 14
        outlineView.autosaveExpandedItems = false
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes([Self.dragType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        // Right-click "Move Up / Move Down" on a group header — a keyboard-free
        // fallback to drag-reordering the sections.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
    }

    // MARK: - Group order persistence

    private static func loadGroupOrder() -> [SidebarGroup] {
        let fallback: [SidebarGroup] = [.status, .trackers, .folders]
        guard let raw = UserDefaults.standard.array(forKey: groupOrderKey) as? [String]
        else { return fallback }
        // Parse, dedupe, then append any missing sections so the result always
        // contains every group exactly once even if the stored value is stale.
        var seen = Set<SidebarGroup>()
        var result: [SidebarGroup] = []
        for g in raw.compactMap({ SidebarGroup(rawValue: $0) }) where !seen.contains(g) {
            seen.insert(g); result.append(g)
        }
        for g in fallback where !seen.contains(g) { result.append(g) }
        return result
    }

    private func saveGroupOrder() {
        UserDefaults.standard.set(groupOrder.map(\.rawValue), forKey: Self.groupOrderKey)
    }

    // MARK: - Rebuild from the torrent list

    /// Recompute group rows and counts from the current torrents, preserving the
    /// expanded state, the active selection, and the scroll position.
    func update(with torrents: [Torrent]) {
        lastTorrents = torrents
        rebuild()
    }

    /// Build the section nodes from `lastTorrents` in the persisted order and apply
    /// them to the outline with the least-disruptive update available.
    private func rebuild() {
        let torrents = lastTorrents

        // Status group: every case, with counts.
        let statusNode = Node(title: "Status", group: .status)
        statusNode.children = StatusFilter.allCases.map { sf in
            Node(title: sf.displayName, symbol: sf.symbol, filter: .status(sf),
                 count: torrents.lazy.filter(sf.matches).count)
        }

        // Trackers group: distinct hosts, sorted, with counts.
        var trackerCounts: [String: Int] = [:]
        for t in torrents { if let host = t.trackerHost { trackerCounts[host, default: 0] += 1 } }
        let trackerNode = Node(title: "Trackers", group: .trackers)
        trackerNode.children = trackerCounts.keys.sorted().map { host in
            Node(title: host, symbol: "antenna.radiowaves.left.and.right",
                 filter: .tracker(host), count: trackerCounts[host] ?? 0)
        }

        // Folders group: distinct download dirs, keyed on the *normalized* location
        // so trailing-slash / doubled-separator variants collapse into one node.
        var folderCounts: [String: Int] = [:]
        for t in torrents { folderCounts[t.normalizedDownloadDir, default: 0] += 1 }
        let folderNode = Node(title: "Folders", group: .folders)
        let folderLabels = disambiguatedFolderLabels(Array(folderCounts.keys))
        // Sort by the *displayed* label (the disambiguating suffix), not the full
        // path, using a natural/localized order so "2024/9" precedes "2024/10".
        folderNode.children = folderCounts.keys
            .sorted { (folderLabels[$0] ?? $0).localizedStandardCompare(folderLabels[$1] ?? $1) == .orderedAscending }
            .map { dir in
                Node(title: folderLabels[dir] ?? dir,
                     symbol: "folder", filter: .folder(dir), count: folderCounts[dir] ?? 0)
            }

        let byGroup: [SidebarGroup: Node] = [
            .status: statusNode, .trackers: trackerNode, .folders: folderNode,
        ]
        let newGroups = groupOrder.compactMap { byGroup[$0] }

        // If the selected tracker/folder vanished, fall back to All.
        if case .tracker(let h) = selectedFilter, trackerCounts[h] == nil { selectedFilter = .all }
        if case .folder(let d) = selectedFilter,
           folderCounts[Torrent.normalizeDownloadDir(d)] == nil { selectedFilter = .all }

        let signature = Self.signature(of: newGroups)
        if signature == currentSignature && !groups.isEmpty {
            // Structure is identical — only counts may differ. Update the existing
            // nodes in place and redraw just the changed rows; scroll/expansion hold.
            for (gi, group) in groups.enumerated() where gi < newGroups.count {
                let fresh = newGroups[gi].children
                for (ci, child) in group.children.enumerated()
                where ci < fresh.count && child.count != fresh[ci].count {
                    child.count = fresh[ci].count
                    outlineView.reloadItem(child)
                }
            }
            return
        }

        // Structure changed (folders/trackers added/removed, or reordered): full
        // reload, but capture and restore the scroll offset around it.
        let savedOrigin = scrollView.contentView.bounds.origin
        groups = newGroups
        currentSignature = signature
        outlineView.reloadData()
        for group in groups where !outlineView.isItemExpanded(group) {
            outlineView.expandItem(group)
        }
        reselectActive()
        scrollView.contentView.scroll(to: savedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// A stable fingerprint of the outline's structure (group order + each group's
    /// child filters), ignoring counts. Two builds with the same signature differ
    /// only in their badge counts.
    private static func signature(of groups: [Node]) -> String {
        groups.map { g in
            (g.group?.rawValue ?? g.title) + ":"
                + g.children.map { filterKey($0.filter) }.joined(separator: ",")
        }.joined(separator: "|")
    }

    private static func filterKey(_ f: SidebarFilter?) -> String {
        switch f {
        case .none: return "-"
        case .status(let s): return "s:\(s.rawValue)"
        case .tracker(let h): return "t:\(h)"
        case .folder(let d): return "f:\(d)"
        }
    }

    // MARK: - Reordering sections

    /// Move `group` to sit at root index `target` (the index of the row it should
    /// land above), persist, and rebuild.
    private func moveGroup(_ group: SidebarGroup, toIndex target: Int) {
        guard let from = groupOrder.firstIndex(of: group) else { return }
        var order = groupOrder
        order.remove(at: from)
        var insertAt = target
        if from < target { insertAt -= 1 }
        insertAt = max(0, min(insertAt, order.count))
        order.insert(group, at: insertAt)
        guard order != groupOrder else { return }
        groupOrder = order
        saveGroupOrder()
        currentSignature = ""  // force a structural rebuild
        rebuild()
    }

    @objc private func moveGroupUp(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? SidebarGroup,
              let idx = groupOrder.firstIndex(of: group), idx > 0 else { return }
        moveGroup(group, toIndex: idx - 1)
    }

    @objc private func moveGroupDown(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? SidebarGroup,
              let idx = groupOrder.firstIndex(of: group), idx < groupOrder.count - 1 else { return }
        // +2: index of the row two below, so removing self lands us one slot down.
        moveGroup(group, toIndex: idx + 2)
    }

    /// Compute the shortest trailing-path suffix for each folder that makes it
    /// distinguishable from every other folder. Folders with a unique leaf keep
    /// just the leaf (e.g. "movies"); those that collide grow toward the root one
    /// component at a time until unique (e.g. "2024/11" vs "2025/11"). A folder
    /// that can't be extended further falls back to its full path.
    private func disambiguatedFolderLabels(_ dirs: [String]) -> [String: String] {
        // Split each distinct dir into its non-empty path components.
        let components: [String: [String]] = Dictionary(uniqueKeysWithValues: Set(dirs).map { dir in
            (dir, (dir as NSString).pathComponents.filter { $0 != "/" && !$0.isEmpty })
        })

        // Current suffix depth per dir (number of trailing components used).
        var depth: [String: Int] = components.mapValues { min(1, $0.count) }

        func label(for dir: String) -> String {
            let parts = components[dir] ?? []
            let d = max(depth[dir] ?? 1, 1)
            let suffix = parts.suffix(d)
            return suffix.isEmpty ? dir : suffix.joined(separator: "/")
        }

        // Repeatedly grow the depth of any label shared by more than one dir,
        // but only for dirs that still have a deeper parent to include.
        while true {
            var labelToDirs: [String: [String]] = [:]
            for dir in components.keys { labelToDirs[label(for: dir), default: []].append(dir) }
            var grew = false
            for (_, group) in labelToDirs where group.count > 1 {
                for dir in group {
                    let parts = components[dir] ?? []
                    if (depth[dir] ?? 1) < parts.count {
                        depth[dir, default: 1] += 1
                        grew = true
                    }
                }
            }
            if !grew { break }
        }

        return Dictionary(uniqueKeysWithValues: components.keys.map { ($0, label(for: $0)) })
    }

    /// Reselect the row matching `selectedFilter` after a reload.
    private func reselectActive() {
        for group in groups {
            for child in group.children where child.filter == selectedFilter {
                let row = outlineView.row(forItem: child)
                if row >= 0 {
                    outlineView.selectRowIndexes([row], byExtendingSelection: false)
                    return
                }
            }
        }
    }

    /// The node currently selected, if any.
    private func selectedNode() -> Node? {
        let row = outlineView.selectedRow
        return row >= 0 ? outlineView.item(atRow: row) as? Node : nil
    }
}

// MARK: - Data source

extension SidebarController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return groups.count }
        return (item as? Node)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return groups[index] }
        return (item as! Node).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    // MARK: Drag-to-reorder top-level sections

    func outlineView(_ outlineView: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // Only the top-level group headers are draggable; filters stay put.
        guard let node = item as? Node, let group = node.group else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(group.rawValue, forType: Self.dragType)
        return pbItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Accept only a group dropped between other groups at the root.
        guard item == nil, index >= 0,
              info.draggingPasteboard.canReadItem(withDataConformingToTypes: [Self.dragType.rawValue])
        else { return [] }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard item == nil, index >= 0,
              let raw = info.draggingPasteboard.string(forType: Self.dragType),
              let dragged = SidebarGroup(rawValue: raw)
        else { return false }
        moveGroup(dragged, toIndex: index)
        return true
    }
}

// MARK: - Context menu (Move Up / Move Down fallback)

extension SidebarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node,
              let group = node.group, let idx = groupOrder.firstIndex(of: group) else { return }

        let up = NSMenuItem(title: "Move Up", action: #selector(moveGroupUp(_:)), keyEquivalent: "")
        up.target = self
        up.representedObject = group
        up.isEnabled = idx > 0

        let down = NSMenuItem(title: "Move Down", action: #selector(moveGroupDown(_:)), keyEquivalent: "")
        down.target = self
        down.representedObject = group
        down.isEnabled = idx < groupOrder.count - 1

        menu.addItem(up)
        menu.addItem(down)
    }
}

// MARK: - Delegate

extension SidebarController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? Node)?.isGroup ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }

        if node.isGroup {
            let id = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf); c.textField = tf
                c.identifier = id
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = node.title.uppercased()
            return cell
        }

        let id = NSUserInterfaceItemIdentifier("FilterCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? FilterCellView)
            ?? FilterCellView(identifier: id)
        cell.configure(symbol: node.symbol, title: node.title, count: node.count)
        // For folders show the full path on hover; the visible label is only the
        // minimal disambiguating suffix.
        if case .folder(let dir) = node.filter {
            cell.toolTip = dir
        } else {
            cell.toolTip = node.title
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let filter = selectedNode()?.filter else { return }
        selectedFilter = filter
        onFilterChange?(filter)
    }
}

/// A sidebar row: icon + title on the left, a count badge on the right.
private final class FilterCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .right
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(icon); addSubview(title); addSubview(badge)
        self.textField = title
        self.imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(symbol: String?, title titleText: String, count: Int) {
        if let symbol { icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        title.stringValue = titleText
        badge.stringValue = count > 0 ? "\(count)" : ""
    }
}
