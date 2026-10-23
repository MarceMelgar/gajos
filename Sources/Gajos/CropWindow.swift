import AppKit

/// Ventana para elegir el área a recortar de una imagen.
final class CropWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<CropWindowController> = []

    private let url: URL
    private let image: CGImage
    private let cropView: CropView
    private let sizeLabel = NSTextField(labelWithString: "")

    private static let ratios: [(String, CGFloat?)] = [
        ("Libre", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 3.0 / 2), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
    ]

    static func present(_ url: URL) throws {
        guard let image = try ImageConverter.loadImages(url).first else {
            throw ConvertError.notAnImage(url.lastPathComponent)
        }
        let controller = CropWindowController(url: url, image: image)
        open.insert(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(url: URL, image: CGImage) {
        self.url = url
        self.image = image
        cropView = CropView(image: image)

        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let maxSize = NSSize(width: min(1000, visible.width * 0.8), height: min(760, visible.height * 0.8) - 56)
        let scale = min(maxSize.width / CGFloat(image.width), maxSize.height / CGFloat(image.height), 1)
        let contentSize = NSSize(width: max(CGFloat(image.width) * scale + 48, 560),
                                 height: max(CGFloat(image.height) * scale + 48, 300) + 56)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Recortar — \(url.lastPathComponent)"
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildLayout(in: window)
        cropView.onChange = { [weak self] in self?.updateSizeLabel() }
        updateSizeLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout(in window: NSWindow) {
        let ratio = NSSegmentedControl(labels: Self.ratios.map(\.0), trackingMode: .selectOne,
                                       target: self, action: #selector(ratioChanged(_:)))
        ratio.selectedSegment = 0

        let cancel = NSButton(title: "Cancelar", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Guardar recorte", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [ratio, sizeLabel, spacer, cancel, save])
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

        let content = NSView()
        for view in [cropView, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            cropView.topAnchor.constraint(equalTo: content.topAnchor),
            cropView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            cropView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            cropView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 56),
        ])
        window.contentView = content
    }

    private func updateSizeLabel() {
        let rect = cropView.crop.integral
        sizeLabel.stringValue = "\(Int(rect.width)) × \(Int(rect.height)) px"
    }

    @objc private func ratioChanged(_ sender: NSSegmentedControl) {
        cropView.aspect = Self.ratios[sender.selectedSegment].1
    }

    @objc private func cancel() { close() }

    @objc private func save() {
        let rect = cropView.crop.integral
        guard let cropped = image.cropping(to: rect) else {
            Toast.show("No se pudo recortar", ok: false)
            return
        }
        do {
            let out = try ImageTools.save(cropped, like: url, suffix: " recortado")
            close()
            Toast.show("Guardado \(out.lastPathComponent)", ok: true)
        } catch {
            Toast.show(error.localizedDescription, ok: false)
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.remove(self)
    }
}

/// Muestra la imagen con un rectángulo que se mueve y se agranda desde las esquinas.
/// `crop` está en píxeles de la imagen, con el origen arriba a la izquierda.
final class CropView: NSView {
    private let image: CGImage
    private let nsImage: NSImage
    private(set) var crop: CGRect
    var onChange: (() -> Void)?

    var aspect: CGFloat? {
        didSet { fitAspect(); changed() }
    }

    private enum Drag {
        case move(offset: CGPoint)
        case resize(anchor: CGPoint)
    }
    private var drag: Drag?

    init(image: CGImage) {
        self.image = image
        nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        crop = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var imageBounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    private var imageRect: CGRect {
        let area = bounds.insetBy(dx: 24, dy: 24)
        let scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    private var scale: CGFloat { max(imageRect.width / CGFloat(image.width), 0.0001) }

    private func toView(_ r: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + r.minX * scale, y: imageRect.minY + r.minY * scale,
               width: r.width * scale, height: r.height * scale)
    }

    private func toImage(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let x = (p.x - imageRect.minX) / scale, y = (p.y - imageRect.minY) / scale
        return CGPoint(x: min(max(x, 0), CGFloat(image.width)), y: min(max(y, 0), CGFloat(image.height)))
    }

    private func changed() {
        needsDisplay = true
        onChange?()
    }

    // MARK: Dibujo

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.1, alpha: 1).setFill()
        bounds.fill()
        nsImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        let box = toView(crop)
        let shade = NSBezierPath(rect: imageRect)
        shade.append(NSBezierPath(rect: box))
        shade.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.55).setFill()
        shade.fill()

        let thirds = NSBezierPath()
        for i in 1...2 {
            let x = box.minX + box.width * CGFloat(i) / 3, y = box.minY + box.height * CGFloat(i) / 3
            thirds.move(to: NSPoint(x: x, y: box.minY)); thirds.line(to: NSPoint(x: x, y: box.maxY))
            thirds.move(to: NSPoint(x: box.minX, y: y)); thirds.line(to: NSPoint(x: box.maxX, y: y))
        }
        NSColor(white: 1, alpha: 0.35).setStroke()
        thirds.lineWidth = 1
        thirds.stroke()

        let border = NSBezierPath(rect: box)
        NSColor.white.setStroke()
        border.lineWidth = 1.5
        border.stroke()

        WheelView.accent.setFill()
        for corner in corners(of: box) {
            NSBezierPath(roundedRect: CGRect(x: corner.x - 6, y: corner.y - 6, width: 12, height: 12),
                         xRadius: 3, yRadius: 3).fill()
        }
    }

    private func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = toImage(event)
        let tolerance = 14 / scale
        let points = corners(of: crop)
        if let i = points.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < tolerance }) {
            drag = .resize(anchor: points[3 - i]) // esquina opuesta
        } else if crop.contains(p) {
            drag = .move(offset: CGPoint(x: p.x - crop.minX, y: p.y - crop.minY))
        } else {
            drag = .resize(anchor: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(event)
        switch drag {
        case .move(let offset):
            var origin = CGPoint(x: p.x - offset.x, y: p.y - offset.y)
            origin.x = min(max(origin.x, 0), CGFloat(image.width) - crop.width)
            origin.y = min(max(origin.y, 0), CGFloat(image.height) - crop.height)
            crop.origin = origin
        case .resize(let anchor):
            crop = rect(from: anchor, to: p)
        case nil:
            return
        }
        changed()
    }

    override func mouseUp(with event: NSEvent) { drag = nil }

    private func rect(from anchor: CGPoint, to p: CGPoint) -> CGRect {
        var w = p.x - anchor.x, h = p.y - anchor.y
        let sx: CGFloat = w < 0 ? -1 : 1, sy: CGFloat = h < 0 ? -1 : 1

        // Espacio disponible desde el ancla hasta el borde de la imagen, en esa dirección.
        let roomX = sx > 0 ? CGFloat(image.width) - anchor.x : anchor.x
        let roomY = sy > 0 ? CGFloat(image.height) - anchor.y : anchor.y

        if let ratio = aspect {
            var width = max(abs(w), abs(h) * ratio)
            width = min(width, roomX, roomY * ratio)
            w = sx * width
            h = sy * width / ratio
        }
        w = sx * max(min(abs(w), roomX), 4)
        h = sy * max(min(abs(h), roomY), 4)
        return CGRect(x: min(anchor.x, anchor.x + w), y: min(anchor.y, anchor.y + h), width: abs(w), height: abs(h))
            .intersection(imageBounds)
    }

    /// Ajusta el recorte actual a la proporción elegida, centrado.
    private func fitAspect() {
        guard let ratio = aspect else { return }
        var width = crop.width, height = width / ratio
        if height > crop.height { height = crop.height; width = height * ratio }
        if width < 8 || height < 8 {
            let full = imageBounds
            width = full.width; height = width / ratio
            if height > full.height { height = full.height; width = height * ratio }
        }
        var rect = CGRect(x: crop.midX - width / 2, y: crop.midY - height / 2, width: width, height: height)
        rect.origin.x = min(max(rect.minX, 0), CGFloat(image.width) - width)
        rect.origin.y = min(max(rect.minY, 0), CGFloat(image.height) - height)
        crop = rect
    }
}
