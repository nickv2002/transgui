import AppKit

/// One field in the info grid: a tiny gray uppercase caption above a value.
/// Clicking anywhere on the card copies the value to the pasteboard and calls
/// `onCopy` (so the owner can show a "Copied: …" toast). Shows a pointing-hand
/// cursor over the whole card. The value wraps to the card's width, or truncates
/// to one line for `truncate` fields like the name (still copyable in full).
///
/// Laid out internally with Auto Layout but positioned by its parent with an
/// explicit frame, so it reports the right height for any width via `fittingSize`.
@MainActor
final class InfoCardView: NSView {
    private let caption = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")

    /// Called with the copied value after a click.
    var onCopy: ((String) -> Void)?

    var displayedValue: String { value.stringValue }
    /// Nothing to copy for an empty value or the "—" placeholder.
    private var isCopyable: Bool { !value.stringValue.isEmpty && value.stringValue != "—" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.font = .systemFont(ofSize: 9, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        value.translatesAutoresizingMaskIntoConstraints = false
        value.lineBreakMode = .byWordWrapping
        value.maximumNumberOfLines = 0
        value.font = .systemFont(ofSize: NSFont.systemFontSize)
        value.textColor = .labelColor
        addSubview(caption)
        addSubview(value)
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: topAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 1),
            value.leadingAnchor.constraint(equalTo: leadingAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(caption captionText: String, value valueText: String,
                   truncate: Bool, onCopy: @escaping (String) -> Void) {
        caption.stringValue = captionText.uppercased()
        value.stringValue = valueText
        value.lineBreakMode = truncate ? .byTruncatingTail : .byWordWrapping
        value.maximumNumberOfLines = truncate ? 1 : 0
        self.onCopy = onCopy
    }

    func setValue(_ text: String) { value.stringValue = text }

    override func layout() {
        super.layout()
        value.preferredMaxLayoutWidth = bounds.width
    }

    /// Height this card needs at the given width.
    func height(forWidth width: CGFloat) -> CGFloat {
        frame = NSRect(x: 0, y: 0, width: width, height: 1)
        layoutSubtreeIfNeeded()
        return fittingSize.height
    }

    // The whole card is the click target — grab clicks anywhere inside it, not just
    // over the value label.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func resetCursorRects() {
        if isCopyable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isCopyable else { return }
        let text = value.stringValue
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        onCopy?(text)
    }
}

/// One info field: a caption, its display value, whether it spans the full width
/// (long strings) or sits in the multi-column grid (short stats), how many columns
/// it occupies, and whether the value truncates to one line. Pure data so the
/// field list is unit-testable without instantiating any views.
struct InfoField: Equatable {
    let caption: String
    let value: String
    let fullWidth: Bool
    var truncate: Bool = false
    var span: Int = 1
    /// Force this field onto a fresh row even if the current one has room.
    var breakBefore: Bool = false
}

/// The torrent Info pane: an adaptive multi-column card grid (up to four columns
/// when wide, fewer when narrow). The name spans two columns; other short stats
/// take one; long fields (error, location, comment, hash) span the full width and
/// wrap. Clicking any card copies its value.
///
/// Laid out manually by reflowing on `layout()` and reporting height through
/// `intrinsicContentSize`. This imposes **no minimum width**, so the enclosing
/// split view can be resized freely — unlike an `NSGridView` whose fixed column
/// widths would lock the split divider.
@MainActor
final class InfoGridView: NSView {
    /// Called with the copied value after a card is clicked, so the owner can
    /// show a "Copied: <value>" toast.
    var onCopy: ((String) -> Void)?

    private struct Item {
        let view: NSView
        let fullWidth: Bool
        let span: Int
        let breakBefore: Bool
    }

    private var items: [Item] = []
    private var cardsByCaption: [String: InfoCardView] = [:]
    private var contentHeight: CGFloat = 0
    private var laidOutRowCount = 0

    /// Identity of what's currently rendered, so polls that don't change the
    /// structure update values in place instead of rebuilding.
    private var currentTorrentId: Int?
    private var currentSignature: [String] = []

    private static let maxColumns = 4
    private static let minColumnWidth: CGFloat = 170
    private static let gutter: CGFloat = 12
    private static let rowGap: CGFloat = 8

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    // MARK: - Update

    /// Render the selected torrent, or a placeholder when nothing / many are
    /// selected. Reuses the existing cards (updating only their values) when the
    /// structure is unchanged, so the ~4s poll doesn't rebuild the grid each time.
    func update(with torrent: Torrent?, selectionCount: Int) {
        guard let t = torrent else {
            showPlaceholder(selectionCount == 0
                ? "No torrent selected."
                : "\(selectionCount) torrents selected.")
            return
        }
        let fields = Self.fields(for: t)
        let signature = fields.map { ($0.fullWidth ? "W·" : "S·") + $0.caption }
        if currentTorrentId == t.id, signature == currentSignature {
            for f in fields { cardsByCaption[f.caption]?.setValue(f.value) }
            needsLayout = true
            return
        }
        rebuild(fields: fields)
        currentTorrentId = t.id
        currentSignature = signature
    }

    // MARK: - Layout

    /// Columns that fit at the given width (1...maxColumns).
    private func columnCount(forWidth width: CGFloat) -> Int {
        let fit = Int((width + Self.gutter) / (Self.minColumnWidth + Self.gutter))
        return max(1, min(Self.maxColumns, fit))
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0 else { return }
        let cols = columnCount(forWidth: width)
        let colWidth = max(1, (width - Self.gutter * CGFloat(cols - 1)) / CGFloat(cols))

        var y: CGFloat = 0
        var rowCount = 0
        var run: [(view: NSView, span: Int, breakBefore: Bool)] = []   // short cards awaiting packing

        func widthForSpan(_ span: Int) -> CGFloat {
            CGFloat(span) * colWidth + CGFloat(span - 1) * Self.gutter
        }

        func flushRun() {
            guard !run.isEmpty else { return }
            var col = 0
            var rowStartY = y
            var rowHeight: CGFloat = 0
            for (view, rawSpan, breakBefore) in run {
                let span = max(1, min(rawSpan, cols))
                if col > 0, breakBefore || col + span > cols {   // wrap to next row
                    y = rowStartY + rowHeight + Self.rowGap
                    rowStartY = y
                    rowHeight = 0
                    col = 0
                    rowCount += 1
                }
                let x = CGFloat(col) * (colWidth + Self.gutter)
                let w = widthForSpan(span)
                let h = (view as? InfoCardView)?.height(forWidth: w) ?? 0
                view.frame = NSRect(x: x, y: rowStartY, width: w, height: h)
                rowHeight = max(rowHeight, h)
                col += span
            }
            y = rowStartY + rowHeight + Self.rowGap        // finalize the last row
            rowCount += 1
            run.removeAll()
        }

        for item in items {
            if item.fullWidth {
                flushRun()
                let v = item.view
                let h = (v as? InfoCardView)?.height(forWidth: width) ?? {
                    v.frame = NSRect(x: 0, y: y, width: width, height: 1)
                    v.layoutSubtreeIfNeeded()
                    return v.fittingSize.height
                }()
                v.frame = NSRect(x: 0, y: y, width: width, height: h)
                y += h + Self.rowGap
                rowCount += 1
            } else {
                run.append((item.view, item.span, item.breakBefore))
            }
        }
        flushRun()

        laidOutRowCount = rowCount
        let newHeight = max(0, y - Self.rowGap)
        if abs(newHeight - contentHeight) > 0.5 {
            contentHeight = newHeight
            invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Build

    private func clear() {
        for item in items { item.view.removeFromSuperview() }
        items.removeAll()
        cardsByCaption.removeAll()
    }

    private func showPlaceholder(_ text: String) {
        guard placeholderText != text else { return }
        clear()
        currentTorrentId = nil
        currentSignature = []
        placeholderText = text
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(label)
        items = [Item(view: label, fullWidth: true, span: 1, breakBefore: false)]
        needsLayout = true
    }

    private func rebuild(fields: [InfoField]) {
        clear()
        placeholderText = nil
        for field in fields {
            items.append(Item(view: makeCard(field), fullWidth: field.fullWidth,
                              span: field.span, breakBefore: field.breakBefore))
        }
        needsLayout = true
    }

    private func makeCard(_ field: InfoField) -> InfoCardView {
        let card = InfoCardView()
        card.configure(caption: field.caption, value: field.value, truncate: field.truncate) {
            [weak self] copied in self?.onCopy?(copied)
        }
        addSubview(card)
        cardsByCaption[field.caption] = card
        return card
    }

    // MARK: - Test hooks

    /// Currently-displayed placeholder text, or nil when showing a torrent.
    private(set) var placeholderText: String?
    /// Number of rows produced by the most recent layout pass.
    var renderedRowCount: Int { laidOutRowCount }
    /// The displayed value for a caption, or nil if absent.
    func renderedValue(forCaption caption: String) -> String? {
        cardsByCaption[caption]?.displayedValue
    }
    /// The card for a caption, so tests can exercise click-to-copy.
    func renderedCard(forCaption caption: String) -> InfoCardView? {
        cardsByCaption[caption]
    }

    // MARK: - Field list

    /// Build the ordered field list for a torrent. Pure — no view dependencies —
    /// so it is unit-testable directly.
    static func fields(for t: Torrent) -> [InfoField] {
        func dash(_ s: String) -> String { s.isEmpty ? "—" : s }

        var fields: [InfoField] = []
        func short(_ caption: String, _ value: String, truncate: Bool = false,
                   span: Int = 1, breakBefore: Bool = false) {
            fields.append(InfoField(caption: caption, value: value, fullWidth: false,
                                    truncate: truncate, span: span, breakBefore: breakBefore))
        }
        func wide(_ caption: String, _ value: String) {
            fields.append(InfoField(caption: caption, value: value, fullWidth: true))
        }

        // Top row: name and location share it, two columns each. Name truncates to
        // one line (copyable in full); location wraps so the deep folder stays visible.
        short("Name", t.name, truncate: true, span: 2)
        short("Location", t.downloadDir, span: 2)
        if t.hasError { wide("Error", "[\(t.errorCode)] \(t.errorString)") }

        short("Status", t.status.displayName)
        short("Progress", Formatters.percent(t.percentDone))
        short("Ratio", Formatters.ratio(t.uploadRatio))
        // "want" only differs when some files are unwanted; omit the noise otherwise.
        let size = t.sizeWhenDone == t.totalSize
            ? Formatters.size(t.totalSize)
            : "\(Formatters.size(t.totalSize)) (want \(Formatters.size(t.sizeWhenDone)))"
        short("Size", size)
        short("Downloaded", Formatters.size(t.downloadedEver))
        short("Uploaded", Formatters.size(t.uploadedEver))
        short("Priority", t.bandwidthPriority.displayName)
        short("Queue", "\(t.queuePosition + 1)")
        short("Download ↓", dash(Formatters.speed(t.rateDownload)))
        short("Upload ↑", dash(Formatters.speed(t.rateUpload)))
        short("ETA", dash(t.etaDisplay))
        short("Peers", "\(t.peersConnected) connected (↓\(t.peersSendingToUs) ↑\(t.peersGettingFromUs))")
        if let host = t.trackerHost { short("Tracker", host) }
        short("Added", Formatters.dateTime(t.addedDate))
        if t.doneDate > 0 { short("Completed", Formatters.dateTime(t.doneDate)) }
        short("Last activity", Formatters.dateTime(t.activityDate))
        // Bottom row: comment + hash share it, two columns each (mirrors name/location).
        if !t.comment.isEmpty {
            short("Comment", t.comment, span: 2, breakBefore: true)
            short("Hash", t.hashString, span: 2)
        } else {
            short("Hash", t.hashString, span: 2, breakBefore: true)
        }
        return fields
    }
}
