import AppKit

/// A small sparkline of recent download (green) and upload (blue) speeds for the
/// selected torrent — the native equivalent of the legacy detail-tab speed graph.
final class SpeedGraphView: NSView {
    private var download: [Int64] = []
    private var upload: [Int64] = []

    /// Replace the plotted history (oldest first).
    func update(download: [Int64], upload: [Int64]) {
        self.download = download
        self.upload = upload
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 52) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.withAlphaComponent(0.5).setFill()
        let frame = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        frame.fill()

        let peak = max(download.max() ?? 0, upload.max() ?? 0)
        guard peak > 0, download.count > 1 || upload.count > 1 else {
            drawEmpty()
            return
        }

        plot(download, color: .systemGreen, peak: peak)
        plot(upload, color: .systemBlue, peak: peak)

        // Legend: current values.
        let down = Formatters.speed(download.last ?? 0)
        let up = Formatters.speed(upload.last ?? 0)
        let legend = "↓ \(down.isEmpty ? "0" : down)   ↑ \(up.isEmpty ? "0" : up)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        (legend as NSString).draw(at: NSPoint(x: 6, y: bounds.height - 16), withAttributes: attrs)
    }

    private func drawEmpty() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        ("Gathering speed…" as NSString).draw(at: NSPoint(x: 6, y: bounds.midY - 6), withAttributes: attrs)
    }

    private func plot(_ samples: [Int64], color: NSColor, peak: Int64) {
        guard samples.count > 1 else { return }
        let inset: CGFloat = 4
        let w = bounds.width - inset * 2
        let h = bounds.height - inset * 2
        let stepX = w / CGFloat(samples.count - 1)
        let path = NSBezierPath()
        for (i, value) in samples.enumerated() {
            let x = inset + CGFloat(i) * stepX
            let y = inset + h * CGFloat(value) / CGFloat(peak)
            let point = NSPoint(x: x, y: y)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        color.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}
