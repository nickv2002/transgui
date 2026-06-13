import AppKit

/// A table cell showing a progress bar with the percentage overlaid as text.
final class ProgressCellView: NSTableCellView {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ProgressCell")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(bar)
        addSubview(label)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(fraction: Double) {
        bar.doubleValue = min(max(fraction, 0), 1)
        label.stringValue = Formatters.percent(fraction)
    }
}
