import AppKit

/// Dibuja la rueda de gajos y recibe los archivos que se sueltan sobre ella.
final class WheelView: NSView {
    static let innerRadius: CGFloat = 54
    static let outerRadius: CGFloat = 160
    static let gap: CGFloat = 3
    static let accent = NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.16, alpha: 0.95)

    var segments: [Segment] = [] { didSet { needsDisplay = true } }
    var files: [URL] = [] { didSet { needsDisplay = true } }
    var style: WheelStyle = .glass { didSet { needsDisplay = true } }
    var onDrop: ((Segment, [URL]) -> Void)?

    private var highlighted: Int? {
        didSet {
            guard highlighted != oldValue else { return }
            needsDisplay = true
            if highlighted != nil, Settings.shared.sound {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private var step: CGFloat { 2 * .pi / CGFloat(max(segments.count, 1)) }

    // MARK: Geometría

    /// Ángulo medido desde arriba en sentido horario, como en un reloj.
    private func index(at point: NSPoint) -> Int? {
        let dx = point.x - center.x, dy = point.y - center.y
        let r = hypot(dx, dy)
        guard !segments.isEmpty, r >= Self.innerRadius, r <= Self.outerRadius + 12 else { return nil }
        var angle = atan2(dx, dy)
        if angle < 0 { angle += 2 * .pi }
        return Int((angle + step / 2) / step) % segments.count
    }

    func sectorPath(_ i: Int) -> NSBezierPath {
        let mid = 90 - CGFloat(i) * step * 180 / .pi
        let halfStep = step / 2
        let outerHalf = (halfStep - asin(Self.gap / Self.outerRadius)) * 180 / .pi
        let innerHalf = (halfStep - asin(Self.gap / Self.innerRadius)) * 180 / .pi
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: Self.outerRadius,
                       startAngle: mid + outerHalf, endAngle: mid - outerHalf, clockwise: true)
        path.appendArc(withCenter: center, radius: Self.innerRadius,
                       startAngle: mid - innerHalf, endAngle: mid + innerHalf, clockwise: false)
        path.close()
        return path
    }

    /// Forma completa de la rueda, usada como máscara del fondo de vidrio.
    func maskImage() -> NSImage {
        NSImage(size: bounds.size, flipped: false) { [weak self] _ in
            guard let self else { return false }
            NSColor.black.setFill()
            for i in self.segments.indices { self.sectorPath(i).fill() }
            NSBezierPath(ovalIn: self.centerRect.insetBy(dx: 4, dy: 4)).fill()
            return true
        }
    }

    private var centerRect: NSRect {
        let r = Self.innerRadius - Self.gap
        return NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    // MARK: Dibujo

    override func draw(_ dirtyRect: NSRect) {
        let base = style == .solid
            ? NSColor(white: 0.13, alpha: 0.97)
            : NSColor(white: 0.08, alpha: 0.42)

        for (i, segment) in segments.enumerated() {
            let path = sectorPath(i)
            (i == highlighted ? Self.accent : base).setFill()
            path.fill()
            NSColor(white: 1, alpha: 0.08).setStroke()
            path.lineWidth = 1
            path.stroke()
            drawLabel(segment, at: i)
        }

        base.setFill()
        NSBezierPath(ovalIn: centerRect.insetBy(dx: 4, dy: 4)).fill()
        drawCenter()
    }

    private func drawLabel(_ segment: Segment, at i: Int) {
        let angle = CGFloat(i) * step
        let r = (Self.innerRadius + Self.outerRadius) / 2 + 4
        let p = NSPoint(x: center.x + r * sin(angle), y: center.y + r * cos(angle))
        let alpha: CGFloat = segment.enabled ? 1 : 0.35
        let color = NSColor(white: 1, alpha: alpha)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: color,
            .kern: 0.6,
        ]
        let title = NSAttributedString(string: segment.title.uppercased(), attributes: attrs)
        let size = title.size()

        var textY = p.y - size.height / 2
        if let symbol = segment.symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) {
            let tinted = image.tinted(color)
            let s = tinted.size
            textY = p.y - size.height / 2 - 9
            tinted.draw(in: NSRect(x: p.x - s.width / 2, y: p.y + 2, width: s.width, height: s.height))
        }
        title.draw(at: NSPoint(x: p.x - size.width / 2, y: textY))

        if let subtitle = segment.subtitle {
            let sub = NSAttributedString(string: subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.5),
            ])
            let ss = sub.size()
            sub.draw(at: NSPoint(x: p.x - ss.width / 2, y: textY - ss.height))
        }
    }

    private func drawCenter() {
        guard let first = files.first else { return }
        let icon = NSWorkspace.shared.icon(forFile: first.path)
        let side: CGFloat = 56
        icon.draw(in: NSRect(x: center.x - side / 2, y: center.y - side / 2 + 8, width: side, height: side))

        var name = first.lastPathComponent
        if files.count > 1 { name = "\(files.count) archivos" }
        if name.count > 22 { name = String(name.prefix(20)) + "…" }
        let label = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        let pill = NSRect(x: center.x - size.width / 2 - 7, y: center.y - 36,
                          width: size.width + 14, height: size.height + 4)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        label.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 2))
    }

    // MARK: Arrastrar y soltar

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        // Nunca pedir "mover": la app de origen podría borrar el archivo original.
        let mask = sender.draggingSourceOperationMask
        for op: NSDragOperation in [.copy, .generic, .link] where mask.contains(op) { return op }
        return .copy
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = index(at: convert(sender.draggingLocation, from: nil))
        guard let i = highlighted, segments[i].enabled else { return [] }
        return operation(for: sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = highlighted, segments[i].enabled else { return false }
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? files
        let segment = segments[i]
        highlighted = nil
        onDrop?(segment, urls.isEmpty ? files : urls)
        return true
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
