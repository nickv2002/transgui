import AppKit

/// A flat, state-coloured progress bar with the percentage overlaid — a richer
/// take than the stock `NSProgressIndicator` (which can't be tinted per row).
final class ProgressCellView: NSTableCellView {
    /// Width (pt) of the cell above which we show one decimal place (e.g. "99.9%").
    private static let preciseThreshold: CGFloat = 52

    private let bar = BarView()
    private let label = NSTextField(labelWithString: "")
    private var fraction: Double = 0
    private var currentPrecise: Bool?

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ProgressCell")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment = .center
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(bar)
        addSubview(label)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(fraction: Double, color: NSColor = .controlAccentColor) {
        let f = min(max(fraction, 0), 1)
        bar.fraction = f
        bar.fillColor = color
        bar.needsDisplay = true
        self.fraction = fraction
        currentPrecise = nil      // force re-render on reuse
        applyLabel()
    }

    override func layout() {
        super.layout()
        applyLabel()
    }

    private func applyLabel() {
        let precise = bounds.width >= Self.preciseThreshold
        guard currentPrecise != precise else { return }
        currentPrecise = precise
        label.stringValue = Formatters.percent(fraction, precise: precise)
    }

    /// The drawn track + fill.
    private final class BarView: NSView {
        var fraction: Double = 0
        var fillColor: NSColor = .controlAccentColor

        override var wantsUpdateLayer: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            let radius = bounds.height / 2
            let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
            NSColor.quaternaryLabelColor.setFill()
            track.fill()

            guard fraction > 0 else { return }
            var fillRect = bounds
            fillRect.size.width = max(bounds.height, bounds.width * CGFloat(fraction))
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
            fillColor.setFill()
            fill.fill()
        }
    }
}
