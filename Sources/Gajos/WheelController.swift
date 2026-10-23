import AppKit

/// Muestra y oculta la ventana flotante con la rueda bajo el cursor.
final class WheelController {
    private(set) var kind: WheelKind?
    private let panel: NSPanel
    private let wheelView: WheelView
    private let glass: NSVisualEffectView
    private var pendingHide: DispatchWorkItem?

    var isVisible: Bool { panel.isVisible }

    init() {
        let side = (WheelView.outerRadius + 20) * 2
        let frame = NSRect(x: 0, y: 0, width: side, height: side)

        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: frame)
        glass = NSVisualEffectView(frame: frame)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        wheelView = WheelView(frame: frame)
        wheelView.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        container.addSubview(wheelView)
        panel.contentView = container

        wheelView.onDrop = { [weak self] segment, urls in
            self?.hide()
            Executor.run(segment, on: urls)
        }
    }

    func show(_ kind: WheelKind, files: [URL], at point: NSPoint) {
        let segments = Wheels.segments(for: kind, files: files)
        guard !segments.isEmpty else {
            hide()
            let what = kind == .tools ? "herramientas" : "conversiones"
            Toast.show("No hay \(what) para este tipo de archivo", ok: false)
            return
        }
        pendingHide?.cancel()
        self.kind = kind
        let style = Settings.shared.style
        wheelView.style = style
        wheelView.files = files
        wheelView.segments = segments
        glass.isHidden = style == .solid
        glass.maskImage = wheelView.maskImage()

        var frame = panel.frame
        frame.origin = NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval = 0) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.kind = nil
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Imagen de la rueda para probar el dibujo sin abrir la ventana.
    func snapshot(_ kind: WheelKind, files: [URL]) -> NSBitmapImageRep? {
        wheelView.style = .solid
        wheelView.files = files
        wheelView.segments = Wheels.segments(for: kind, files: files)
        guard let rep = wheelView.bitmapImageRepForCachingDisplay(in: wheelView.bounds) else { return nil }
        wheelView.cacheDisplay(in: wheelView.bounds, to: rep)
        return rep
    }
}
